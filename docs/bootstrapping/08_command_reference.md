# Command Reference

All parasa commands are exposed as shell functions via `index.sh` (sourced
on login). Each function delegates to a script in `scripts/`.

## Creation commands

### `parasa_bootstrap` -- `scripts/stage0-bootstrap.sh`

One-time disk initialization. Partitions the boot disk, GELI-encrypts all
pool devices, creates ZFS pools and the dataset hierarchy.

| Flag | Purpose |
|------|---------|
| `-d` | Dry run |
| `-h` | Help |

**DANGER**: Destroys all data on selected disks.

### `parasa_new_foundation` -- `scripts/new_foundation.sh`

Builds a FreeBSD world+kernel from source and archives the result.

| Flag | Purpose |
|------|---------|
| `-h` | Help |
| `-d` | Dry run |
| `-s NAME` | Foundation name |
| `-o K=V` | Build config override (src_branch, kernconf, make_jobs) |
| `-q` | Quiet (no prompts). `-qq` = suppress progress too |

Flow: collect name/config -> create recipes dir -> checkout src ->
build world+kernel -> git commit to orphan branch -> ZFS snapshot ->
archive to zbamidbar -> destroy workspace.

### `parasa_new_system` -- `scripts/new_system.sh`

Creates a system on top of a foundation.

| Flag | Purpose |
|------|---------|
| `-h` | Help |
| `-d` | Dry run |
| `-s NAME` | System name |
| `-f FOUND` | Foundation name |
| `-o K=V` | Property override (home_dataset, tmp_dataset, roothome_dataset, user_homes, mount_map) |
| `-q` | Quiet. `-qq` = silent |
| `-b` | Deploy after creation. `-bb` = deploy + nextboot |

Flow: collect name/foundation/options -> create recipes dir ->
create data datasets on zbamidbar -> inaugural commit (writes /etc/fstab)
-> optionally deploy.

### `parasa_new_container` -- `scripts/new_container.sh`

Creates a container (jail) on top of a foundation. Mirrors new_system
but adds jail.conf and mount.fstab.

| Flag | Purpose |
|------|---------|
| `-h` | Help |
| `-d` | Dry run |
| `-s NAME` | Container name |
| `-f FOUND` | Foundation name |
| `-o K=V` | Property override (home_dataset, tmp_dataset, user_homes, mount_map) |
| `-q` | Quiet. `-qq` = silent |

No `-b` flag. Containers are deployed separately via `jail(8)`.

### `parasa_deploy_system` -- `scripts/deploy_system.sh`

Deploys an archived system to zbereshit for boot.

| Flag | Purpose |
|------|---------|
| `-h` | Help |
| `-d` | Dry run |
| `-s NAME` | System name (required) |
| `-n` | Set nextboot after deploy |

Flow: resolve foundation/artifact from recipes -> ZFS send/recv to
zbereshit -> git checkout system branch -> optionally set nextboot.

## Maintenance commands

### `parasa_diff` -- `scripts/diff.sh`

Detects drift between a deployed workspace and its recipe.

| Flag | Purpose |
|------|---------|
| `-h` | Help |
| `-d` | Dry run |
| `-s NAME` | Workspace name (required) |
| `-k KIND` | "system" or "container" (auto-detected) |
| `-q` | Quiet: exit 1 on unclassified, no prompts |

Flow: mtree comparison -> classify each changed file -> prompt for
unclassified (or exit 1 in quiet mode).

### `parasa_save` -- `scripts/save.sh`

Two-commit state capture: tree state + recipe metadata.

| Flag | Purpose |
|------|---------|
| `-h` | Help |
| `-d` | Dry run |
| `-s NAME` | Workspace name (required) |
| `-k KIND` | "system" or "container" (auto-detected) |
| `-m MSG` | Commit message (required in quiet mode) |
| `-q` | Quiet mode |

Flow: run diff -> capture pkg list -> regenerate mtree -> commit state
to foundation.git -> commit recipe to parasa repo.

### `parasa_update` -- `scripts/update.sh`

Rebases a workspace onto a new foundation patch level. Builds `-new`
alongside the live clone -- never destroys the running system.

| Flag | Purpose |
|------|---------|
| `-h` | Help |
| `-d` | Dry run |
| `-s NAME` | Workspace name (required) |
| `-k KIND` | "system" or "container" (auto-detected) |
| `-a ARTIFACT` | New artifact (default: latest) |
| `-q` | Quiet: abort on conflicts |

Flow: pre-flight checks -> beam down new artifact -> clone to -new ->
mount + start -> recipe replay -> git rebase -> regen derivations ->
validate -> offer swap.

Rollback: `zfs destroy -r zbereshit/{kind}s/${NAME}-new`

### `parasa_finalize_update` -- `scripts/finalize_update.sh`

Swaps a `-new` clone into place. The only destructive step in the update
flow.

| Flag | Purpose |
|------|---------|
| `-h` | Help |
| `-d` | Dry run |
| `-s NAME` | Workspace name (required) |
| `-k KIND` | "system" or "container" (auto-detected) |
| `-n` | Set nextboot (systems only) |

Flow: verify -new exists -> stop old -> destroy old -> rename -new to
plain -> update .foundation -> save -> optionally start/nextboot.

## Diagnostic commands

### `parasa_doctor` -- `scripts/doctor.sh`

Checks if the system layout is acceptable for running parasa. Verifies
pools, datasets, git repos, required tools, and repo integrity.
Interactively offers to repair what it can.

| Flag | Purpose |
|------|---------|
| `-h` | Help |
| `-q` | Quiet: report only, no repairs |
| `-f` | Fix: attempt all repairs without prompting |

## Interaction modes

Most commands support three modes:

| Flags | Mode | Behavior |
|-------|------|----------|
| (none) | Interactive | All questions asked, no defaults pre-filled |
| `-s` (no `-q`) | Semi-interactive | `-o` values pre-fill defaults, still prompt |
| `-s -q` | Quiet | No prompts, uses defaults + `-o` overrides |
| `-s -qq` | Silent | Quiet + suppress progress output |
