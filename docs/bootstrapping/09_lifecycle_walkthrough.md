# Lifecycle Walkthrough

End-to-end: from bare disks to a running, updatable system.

## Stage 0: Bootstrap

One-time setup. Run from a live environment against new disks.

```
parasa_bootstrap
```

1. Partition boot disk (EFI 260m + swap + ZFS remainder)
2. GELI-encrypt all three pool devices
3. GLABEL each device with a stable name
4. Create ZFS pools: zbereshit, zshemot, zbamidbar
5. Create the dataset hierarchy

After bootstrap, the machine has three empty pools with the correct
dataset structure.

## Stage 1: Build a foundation

```
parasa_new_foundation
```

Interactive session:
1. Name the foundation (e.g., `generic_stable15`)
2. Choose build config (SRC_BRANCH, KERNCONF, MAKE_JOBS)
3. Confirm
4. Builds world+kernel from FreeBSD source (long)
5. Commits pristine build to orphan branch on foundation.git
6. Archives ZFS snapshot to zbamidbar/foundation.zfs
7. Destroys transient workspace

Result: a pristine foundation archived and tracked.

## Stage 2: Create a system

```
parasa_new_system
```

Interactive session:
1. Name the system (e.g., `wonderland`)
2. Select foundation
3. Answer dataset questions (/home? /tmp? user homes? custom mounts?)
4. Confirm
5. Creates recipes dir with boilerplate files
6. Creates data datasets on zbamidbar/system-data
7. Inaugural commit: writes /etc/fstab with data-lake mount entries
8. Optionally deploys immediately

## Stage 3: Deploy

```
parasa_deploy_system -s wonderland -n
```

1. Reads foundation and artifact from recipes
2. ZFS send/recv from zbamidbar to zbereshit/systems/wonderland
3. Git checkout applies the system branch (fstab entries, etc.)
4. Sets nextboot for one-shot boot with auto-revert
5. Optionally reboots

The system is now running.

## Stage 4: Customize

SSH in and make changes:

```
pkg install nginx
sysrc nginx_enable=YES
service nginx start
vi /etc/pf.conf
# ... etc
```

Changes accumulate on the live filesystem:
- Text config edits tracked by git
- Packages on zbamidbar/system-data/*/usr-local
- Binary changes detected by mtree on next diff

## Stage 5: Save state

```
parasa_save -s wonderland
```

Interactive session:
1. Runs diff: mtree comparison detects all changes
2. Auto-classifies text files, known derivations, git-tracked binaries
3. Prompts for any unclassified binaries:
   - `[d]` Derivation -> writes to derivations.local
   - `[p]` Preserve -> git add
   - `[c]` Command -> writes to compose.sh
   - `[s]` Skip -> ask next time
4. Captures package list
5. Regenerates mtree.dist
6. Commit 1: state to foundation.git (push)
7. Commit 2: recipe to parasa repo

Two commits: state records what changed, recipe records how to reproduce.

## Stage 6: Update to a new foundation

Months later, a new foundation is built with a newer FreeBSD snapshot:

```
parasa_new_foundation -s generic_stable15
# (now has artifact-v2)
```

Then update the running system:

```
parasa_update -s wonderland
```

1. Pre-flight: verify no unsaved changes, check -new doesn't exist
2. Beam down new artifact via incremental ZFS send
3. Clone to `systems/wonderland-new`
4. Mount data datasets into -new tree
5. Run recipe: pre_pkg -> packages -> post_pkg
6. Git rebase: replay admin delta chain onto new artifact
7. Regenerate derived binaries (pwd.db etc.) if source changed
8. Validate with diff
9. Offer swap

The old system is **untouched** throughout. Rollback:
`zfs destroy -r zbereshit/systems/wonderland-new`

## Stage 7: Finalize

```
parasa_finalize_update -s wonderland -n
```

1. Stop old system
2. Destroy old clone
3. Rename `wonderland-new` to `wonderland`
4. Save state
5. Set nextboot

This is the only destructive step. After this, the system is running on
the new base with all customizations preserved.

## Container lifecycle

Containers follow the same stages but with jail-specific differences:

- `new_container` instead of `new_system` (adds jail.conf + mount.fstab)
- Deployed by starting the jail: `jail -c mycontainer`
- Data-lake mounts processed by jail(8) via mount.fstab (no /etc/fstab)
- Updates use `jexec` instead of `chroot`
- No nextboot -- containers are started/stopped via `jail(8)`
