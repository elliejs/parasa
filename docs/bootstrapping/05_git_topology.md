# Git Topology

All version tracking for foundations, systems, and containers lives in
one bare git repo: `zbamidbar/foundation.git`.

## Branch naming

| Pattern | Type | Notes |
|---------|------|-------|
| `${FOUNDATION_NAME}` | Foundation | Orphan branch. Bare name, no prefix. |
| `systems/${NAME}` | System | Forks from a foundation commit. |
| `containers/${NAME}` | Container | Forks from a foundation commit. |

There is **no master branch**. Foundation branches are orphans -- they
have no shared root.

## Foundation branches

Each foundation build produces one commit on an orphan branch:

```
generic_stable15  (orphan)
  ├── artifact-v1  "stable-15_2026-01-15_abc1234_generic_stable15"
  ├── artifact-v2  "stable-15_2026-03-20_def5678_generic_stable15"
  └── artifact-v3  "stable-15_2026-07-01_789abcd_generic_stable15"
```

**The commit message IS the artifact name**, which is also the ZFS
snapshot tag on `zbamidbar/foundation.zfs/${FOUNDATION}`.

Artifact name format: `<branch>_<ISO-date>_<short-sha>[_<suffix>]`,
built by `get_artifact_name()` in `helpers.sh`.

## System and container branches

Systems and containers fork from a foundation artifact commit:

```
generic_stable15  (orphan)
  ├── artifact-v1
  ├── artifact-v2
  │   ├~> systems/wonderland
  │   │   ├── inaugural (writes /etc/fstab)
  │   │   ├── admin-delta-1
  │   │   └── admin-delta-2
  │   └~> containers/webserver
  │       ├── inaugural
  │       └── admin-delta-1
  └── artifact-v3
```

The **inaugural commit** is created by `new_system` or `new_container`.
For systems, it writes data-lake mount entries into `/etc/fstab`. For
containers, it may be an `--allow-empty` commit (the branch creation
itself is the point).

Subsequent admin changes (config edits, package installs, etc.) form a
delta chain of commits on the system/container branch.

## Rebase during updates

When a new foundation artifact is built, admin delta chains are rebased:

```
git rebase --onto <new-artifact-commit> <old-artifact-commit> systems/${NAME}
```

Before:
```
artifact-v1 <- inaugural <- delta-1 <- delta-2    (old)
```

After:
```
artifact-v2 <- inaugural' <- delta-1' <- delta-2' (rebased)
```

Text files merge via git's three-way merge. Binary files are handled by
the stratified change tracking system (derivations, preserve, compose).

## The .foundation file

Each system/container has exactly one file named
`${FOUNDATION_NAME}.foundation` in its recipes dir.

- **Filename** = foundation identity (which foundation this target uses)
- **Contents** = artifact name (which patch level / snapshot)

Reading:
```sh
# Foundation name:
basename "$(ls "$dir"/*.foundation)" .foundation

# Artifact name:
cat "$dir"/*.foundation
```

Multiple `.foundation` files = error.

On patch-level update: rewrite file contents, filename stays the same.
On stream/major change: rename the file and write new artifact name.

## Where .git lives

Foundation archives include `.git` from the build workspace (because
`git init` and commit happen in buildspace before `zfs send`). Every
system/container clone inherits this `.git`. This is a known architectural
issue -- `.git` accumulates cruft over time. See
[risks_and_consequences.md](../risks_and_consequences.md) for details.
