# Container `mount.fstab` references `/home`, but nothing creates that mountpoint

**Files:** `scripts/new_container.sh` (`create_container_recipe_extras`),
`scripts/new_foundation.sh` (`run_build` / `make distribution`)
**Severity:** Bug — `jail -c` fails on any container created with the
(default-enabled) home dataset, against a foundation built exactly as
documented.

## The bug

`new_container.sh` defaults `home_dataset` to `yes`
(`OPT_HOME="yes"` at the top of the script), and when enabled,
`create_container_recipe_extras()` unconditionally writes a `mount.fstab`
line mounting it inside the container root:

```
zbamidbar/container-data/demo1/home	/containers/demo1/home	zfs	rw	0	0
```

But a foundation built by `new_foundation.sh`'s `run_build()` — which
just runs the standard `buildworld`/`buildkernel`/`installworld`/
`installkernel`/`distribution` targets, nothing container-specific — never
creates a `/home` directory or symlink at all. Confirmed by grepping the
foundation's own `mtree.dist` (captured immediately after `make
distribution` via `generate_mtree`, before anything container-related
touches the tree): zero occurrences of `home` anywhere. This matches
normal FreeBSD behavior — `/home` is conventionally created by the
interactive installer (bsdinstall), not by `make distribution`, which
only produces the base OS tree.

Since nothing in `new_container.sh`/`workspace.sh`/`deploy_container.sh`
creates the `/containers/<name>/home` directory before `jail(8)` tries to
process `mount.fstab`, starting the container fails immediately:

```
jail: demo1: mount.fstab: /containers/demo1/home: No such file or directory
```

`var`, `usr/local`, and `tmp` don't have this problem — `var` and `tmp`
are both part of the standard base distribution tree already, and
`usr/local` exists as an empty directory in the base tree too (created
for package installs). Only `home` is missing, precisely because it's the
one directory `make distribution` doesn't provide.

## How we hit it

Hit this for real starting our test container `demo1` (created with
default options, i.e. `home_dataset=yes`) against a `stable15` foundation
built exactly per `new_foundation.sh`'s standard flow. Worked around it
for this test by manually `mkdir -p /containers/demo1/home` before
starting the jail.

## Suggested fix

Either:
- Have `create_data_datasets`/`create_container_recipe_extras` `mkdir -p`
  the mountpoint directories (`home`, and any `user_homes` /
  `mount_map` custom targets) inside the deployed container root as part
  of `deploy_container.sh` (the step that actually populates
  `/containers/<name>`), since that's the first point where the real root
  tree exists to create directories in, or
- Have `new_foundation.sh`'s `run_build()` explicitly create `/home` (and
  `/usr/home`, if that's the real target) as part of finishing the
  foundation, matching what a normal FreeBSD install would have.

The first option is more robust — it also covers `user_homes` per-user
directories and arbitrary `mount_map` targets, which have the exact same
"mountpoint might not exist in the base tree" problem.
