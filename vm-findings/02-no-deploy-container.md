# No `deploy_container.sh` — containers never get a populated root filesystem

**Status: FIXED** in commit `093c870` ("Fix running_disk() for ZFS-root,
add deploy_container.sh"). `scripts/deploy_container.sh` now exists,
mirroring `deploy_system.sh`: sends the foundation archive to
`zbereshit/containers/<name>`, sets its mountpoint, and applies the
`containers/<name>` git branch. `new_container.sh`'s own guidance text was
updated to point at it. Not yet verified end-to-end against a real
foundation on this VM — see the "Status" section below for what's still
pending. The write-up below is kept as the original gap report.

**Files:** `scripts/new_container.sh`, `scripts/workspace.sh`
**Severity:** Gap — the documented container workflow can't actually reach
a runnable jail with the scripts as they exist today.

## What `new_container.sh` actually does

Tracing `workspace.sh`'s shared lifecycle (used by both `new_system.sh` and
`new_container.sh` via `WS_*` functions):

1. `create_recipe_boilerplate` — writes `recipes/containers/<name>/`
   (`.foundation`, `compose.sh`, `derivations.local`, `pkg.list`,
   `mtree.dist`).
2. `create_data_datasets` — creates the data-lake datasets under
   `zbamidbar/container-data/<name>/` (`var`, `usr-local`, optionally
   `home`/`tmp`).
3. `ws_begin` — receives the foundation's ZFS archive into a **transient**
   workspace at `zshemot/buildspace/<name>`, just long enough to set up a
   git branch (`containers/<name>`) and let `ws_commit` make the inaugural
   commit.
4. `ws_end` — **destroys** `zshemot/buildspace/<name>` (`zfs destroy -r`)
   and unmounts the working datasets.

At no point does anything write to `zbereshit/containers/<name>` (the
mountpoint stage0-bootstrap actually created for running jails,
`zbereshit/containers` with `mountpoint=/containers canmount=on`). After
`new_container.sh` finishes, `/containers/<name>` simply doesn't exist.

Compare this to `deploy_system.sh`, which has the equivalent step systems
need but containers don't get: it `zfs send`s the foundation archive
snapshot into `zbereshit/systems/<name>`, then `git fetch`/`git checkout`s
the system's branch on top of it. There is no `deploy_container.sh`
anywhere in `scripts/`.

The script's own output even says as much:

```
$ new_container -s myapp -f stable15
...
Edit jail.conf and use jail(8) to start the container.
```

...but `jail(8)` needs `path = "/containers/myapp"` (as written into
`jail.conf` by `create_container_recipe_extras`) to actually contain a
FreeBSD userland, which nothing has put there. `new_container.sh -h`'s own
usage text acknowledges this directly: *"Unlike new_system, there is no -b
(deploy/nextboot) flag. Containers are deployed to zbereshit/containers/
and started via jail(8). Use deploy_container (future) or jail(8)
directly."* — "future" here means not yet implemented.

## Status

This finding is currently from reading `workspace.sh`/`new_container.sh`
closely, not yet from running them (the foundation build they depend on
was still in progress at time of writing). The code trace above is
unambiguous — `ws_end` really does `zfs destroy -r` the only workspace
that ever held foundation content — but we'll update this file to confirm
empirically (does `new_container.sh` complete, does `/containers/<name>`
really end up empty, does `jail -c` really fail) once the foundation build
finishes and `new_container.sh` actually runs.

## Planned workaround for this proof-out

At the time of writing, the foundation build was still running, so the
container-deploy step below had not yet been executed against a real
foundation — this section will be updated with results once it has. The
plan is to hand-run the equivalent of `deploy_system.sh`'s `deploy()`,
substituting `zbereshit/containers/<name>` for `zbereshit/systems/<name>`:

```sh
zfs send -R "zbamidbar/foundation.zfs/foundations/<foundation>@<artifact>" \
  | zfs recv -F "zbereshit/containers/<name>"
zfs set mountpoint="/containers/<name>" zbereshit/containers/<name>
zfs mount zbereshit/containers/<name>
git -C /containers/<name> fetch origin "containers/<name>"
git -C /containers/<name> checkout "containers/<name>"
```

then manually mounted the `mount.fstab` entries `new_container.sh` had
already written before starting the jail. This is not something an
end user should have to know to do — it should be a real
`deploy_container.sh`, mirroring `deploy_system.sh`.

## Suggested fix

Add `scripts/deploy_container.sh` mirroring `deploy_system.sh`'s
`resolve_snapshot`/`deploy` logic, targeting `zbereshit/containers/<name>`
and the `containers/<name>` git branch instead of the system equivalents,
and have it apply `mount.fstab` (or at least document that `jail(8)` will
do so via `mount.fstab` in `jail.conf` once the root is populated).
