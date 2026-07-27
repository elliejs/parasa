# Plan: Close the Creation-Maintenance Gap

## Context

Parasa can create foundations, systems, and containers, but cannot save state, detect drift, or rebase onto new foundations. This plan implements three commands: `parasa_diff`, `parasa_save`, and `parasa_update`. Scope is **same-foundation patch updates** (e.g., generic-stable15.0 old-artifact to new-artifact). Cross-foundation updates (15.0 to 15.1) are treated as complete rebuilds, out of scope.

## Architecture corrections (from review)

### ZFS topology: systems and containers are the same

Both systems and containers are **ZFS clones** from `zbereshit/foundations/<name>@<artifact>`. The only difference is:
- Systems mount at `/` (via nextboot) or stay unmounted
- Containers mount at `/containers/<name>` and run as jails

The update flow is therefore **identical** for both at the ZFS level: destroy old clone, create new clone from new artifact, apply rebased recipe.

### Git topology: three branch families, no master

```
15-stable-generic               ← artifact-v1 ← artifact-v2 (patch commits)
systems/wonderland              ← inaugural ← admin-delta-1 ← admin-delta-2
containers/webserver            ← inaugural ← admin-delta-1
```

Foundation branches are orphan (named after their foundation, e.g. `15-stable-generic`). System/container branches use `systems/<name>` or `containers/<name>` and fork from a foundation artifact commit. The entire delta chain gets rebased onto the new foundation tip:
```
git rebase --onto <new-artifact-commit> <old-artifact-commit> {kind}s/<name>
```

### Mounts must be active during recipe replay

Compose scripts, package installation, and derivation regen all need the full mount topology (var, usr/local, home, etc.) active. For containers, this means starting the jail. For systems, this means either manual mounts or temporarily starting the system as a jail.

### compose.sh structure: pre_pkg() + post_pkg()

```sh
pre_pkg() {
    # Before packages: create users, groups, base system prep
}

post_pkg() {
    # After packages: commands that depend on installed software
}
```

### Classification terminology

- **Derivation** = binary regenerated from a text source. The text source gets git-merged first, then a command regenerates the binary. Has an ordering dependency on git rebase.
- **Command** = binary produced from scratch by running a command. No text source. No ordering dependency.
- **Preserve** (was "environment") = non-derivable semi-static binary (SSH keys, certs). Git-tracked, kept as-is. Admin gets "Consider moving to /var/" advisory.

### is_binary_file (inverted from original plan)

Check for binary instead of text. More specific: detect ELF, `data`, etc. Report "not binary" (i.e., text) as the default.

### Commit 2 (recipe) uses broad add

`git add recipes/{kind}s/{name}/` — everything in the recipes dir, not a narrow file list. Nothing should be in that dir that shouldn't be committed.

### .git exclusion

mtree comparison must exclude `.git/` directory. The existing `etc/mtree.ignore` already has `.git` — verify this is sufficient for the mtree comparison in diff.sh.

---

## Key design decisions

- **Never destroy the running clone during update.** Build into `${NAME}-new`, verify, then swap with `finalize_update`.
- **Rebase order**: beam down → clone -new → start with mounts → pre_pkg → packages → post_pkg → git rebase → derivation regen → validate → offer swap
- **Derivation regen** happens after git rebase (depends on knowing which text sources changed), but is conceptually pre_pkg
- **Git conflicts**: pause inline in interactive mode, abort in quiet mode (old clone untouched either way)
- **Classification prompt** asks pre_pkg/post_pkg phase for `[c]` entries
- **Rollback**: just `zfs destroy -r {kind}s/${NAME}-new` — old clone was never touched
- **Finalize**: separate command `finalize_update` does: destroy old → rename -new → save. This is the only destructive step.

---

## ZFS research required (Phase 4 prerequisite)

The user flagged a research question: when the old clone is from `@old-artifact` and we want to clone from `@new-artifact` on the same foundation dataset, does ZFS handle this cleanly?

**Expected answers** (to verify on FreeBSD):
1. Can you clone from any snapshot on a dataset, regardless of other clones? → Yes, snapshots are independent.
2. Can you `zfs rename` a clone? → Yes, rename is a metadata operation.
3. Does `zfs destroy` of a clone affect the foundation snapshot? → No, only dependent clones prevent snapshot deletion.
4. Can you do incremental `zfs send -i @old @new` from zbamidbar to zbereshit to add the new artifact snapshot? → Yes, this is standard incremental replication.

Verify these before implementing Phase 4. If any answer is wrong, the update flow needs revision.

---

## Phase 1: Helpers and compose.sh skeleton

### Modify: `scripts/helpers.sh`

Add after the existing foundation helpers section:

```sh
get_tree_root(kind, name)
  # system → /zbereshit/systems/$name
  # container → /containers/$name

get_recipes_dir(kind, name)
  # → $PARASA_DIR/recipes/${kind}s/$name

is_binary_file(path)
  # Inverted check: look for binary indicators (ELF, data, etc.)
  # Return 0 if binary, 1 if text/not-binary

lookup_derivation(relpath, db, local_db)
  # Check if relpath is a known derived binary in db or local_db
  # Print "source\tcommand" if found, return 1 if not

read_artifact_name(recipes_dir)
  # Read contents of *.foundation file (the artifact name)

detect_kind(name)
  # Auto-detect system/container from recipes directory existence
```

### Modify: `scripts/workspace.sh`

`create_recipes_boilerplate()`: write compose.sh with pre_pkg/post_pkg skeleton instead of empty file.

### Modify: `spec/helpers_spec.sh`

Tests for all new helpers. Follow existing parameterized pattern. Mock `file` for is_binary_file.

### Verification: `shellspec spec/helpers_spec.sh && shellspec spec/workspace_spec.sh`

---

## Phase 2: parasa_diff

### Create: `scripts/diff.sh`

Follows `deploy_system.sh` pattern. Getopts: `-h -d -s NAME -k KIND -q`.

**Algorithm:**

```
1. Resolve target: TREE_ROOT, RECIPE_DIR, FOUNDATION_NAME
2. Load derivation databases: resolve_derivations_db(version) + derivations.local
3. mtree -f RECIPE_DIR/mtree.dist -p TREE_ROOT
   (mtree.ignore already excludes .git — verify)
4. Parse mtree output → list of changed relative paths
5. For each changed path:
   a. In exempt mount? (var/, usr/local/, home/, tmp/) → skip
   b. Not binary (is_binary_file returns 1)? → text, git handles it
   c. lookup_derivation finds it? → derived, auto-classified
   d. git -C TREE_ROOT ls-files tracks it? → preserve (semi-static)
   e. Unclassified → interactive prompt
6. Classification prompt for unclassified:
   [d] Derivation — has a text source that gets git-merged,
       then a command regenerates this binary from the merged text.
       (prompt: source file, command, appends to derivations.local)
   [p] Preserve — non-derivable binary, keep as-is across rebases.
       Consider moving to /var/ if this is mutable state.
       (git add the file)
   [c] Command — a command that produces this binary from scratch,
       no text source dependency.
       (prompt: command, pre_pkg or post_pkg phase,
        appends to compose.sh function body)
   [s] Skip — ask again next time (blocks rebase)
7. Exit 0 if clean, exit 1 if unclassified remain
```

### Create: `spec/diff_spec.sh`

Tests: help/args, auto-classification for each type, quiet mode with unclassified → exit 1, exempt mount skipping, dry-run, full pipeline with mocked mtree.

### Modify: `index.sh` — add `parasa_diff()` wrapper

### Verification: `shellspec spec/diff_spec.sh && shellspec`

---

## Phase 3: parasa_save

### Create: `scripts/save.sh`

Getopts: `-h -d -s NAME -k KIND -m MSG -q`.

**Algorithm:**

```
1. Run diff.sh (same quiet/dry-run flags)
2. Capture package list:
   system:    pkg info -o > RECIPE_DIR/pkg.list
   container: pkg -j NAME info -o > RECIPE_DIR/pkg.list
3. Regenerate mtree.dist
4. Prompt for admin message (required in quiet mode via -m)
5. Commit 1 — state:
   git -C TREE_ROOT add -A
   git -C TREE_ROOT commit -m "$ARTIFACT\n$ADMIN_MSG"
   git -C TREE_ROOT push origin {kind}s/{name}
6. Commit 2 — recipe:
   git -C PARASA_DIR add recipes/{kind}s/{name}/
   git -C PARASA_DIR commit -m "{name}: $ADMIN_MSG"
7. Cleanup
```

If commit 1 succeeds but commit 2 fails: print "State saved but recipe commit failed. Re-run parasa_save to retry."

### Create: `spec/save_spec.sh`

Tests: help/args, dry-run, correct pkg command per kind, both commits in output, commit message format.

### Modify: `index.sh` — add `parasa_save()` wrapper

### Verification: `shellspec spec/save_spec.sh && shellspec`

---

## Phase 4: parasa_update

### ZFS research (prerequisite)

Run on FreeBSD to verify:
```sh
# Can we clone from any snapshot?
zfs clone pool/ds@snap2 pool/newclone   # when pool/oldclone is from @snap1

# Can we rename a clone?
zfs rename pool/oldclone pool/oldclone-old

# Incremental send between snapshots on same dataset?
zfs send -i pool/ds@snap1 pool/ds@snap2 | zfs recv destpool/ds
```

### Create: `scripts/update.sh`

Getopts: `-h -d -s NAME -k KIND -a ARTIFACT -q -n`.

### Create: `scripts/finalize_update.sh`

Getopts: `-h -d -s NAME -k KIND`.

---

**Core principle: never destroy the running clone during update.** Build
`{kind}s/${NAME}-new` alongside the live clone. The old box keeps running
until the admin verifies the new one works. Then `finalize_update` swaps.

**The update flow (unified for systems and containers):**

```
Step 1: Pre-flight
  ├─ Resolve OLD_FOUNDATION, OLD_ARTIFACT from recipes
  ├─ Resolve NEW_ARTIFACT (latest on foundation archive, or -a flag)
  ├─ Verify NEW_ARTIFACT != OLD_ARTIFACT
  ├─ Verify ${NAME}-new does not already exist (name collision check)
  ├─ Run diff.sh -q to verify no unsaved changes
  └─ Mount foundation.git, verify git branches exist

Step 2: Beam down new foundation
  ├─ Ensure new artifact on zbereshit:
  │   zfs send -i @OLD zbamidbar/.../foundation@NEW |
  │     zfs recv zbereshit/foundations/$FOUNDATION
  └─ Clone from new artifact into -new:
      zfs clone zbereshit/foundations/$FOUNDATION@$NEW_ARTIFACT \
        zbereshit/{kind}s/${NAME}-new

Step 3: Mount + start the -new clone
  ├─ Container: start jail ${NAME}-new (temporary jail.conf pointing at -new path)
  │   → mount data-lake datasets into -new container path
  │   → nullfs only needed if cross-mounting another container's/system's datasets
  └─ System: mount data-lake ZFS datasets into -new tree
      (chroot into /zbereshit/systems/${NAME}-new)

Step 4: Run recipe on -new
  ├─ Source compose.sh, call pre_pkg()
  │   Container: jexec ${NAME}-new pre_pkg
  │   System: chroot /zbereshit/systems/${NAME}-new pre_pkg
  ├─ Install packages from pkg.list
  │   Container: pkg -j ${NAME}-new install -y $(cat pkg.list)
  │   System: chroot ... pkg install -y $(cat pkg.list)
  └─ Source compose.sh, call post_pkg()

Step 5: Git rebase
  ├─ The -new tree's .git (inherited from foundation) has all branches via fetch
  ├─ git rebase --onto <new-artifact-commit> <old-artifact-commit> {kind}s/$NAME
  │   The entire delta chain (inaugural + all admin commits) replays
  ├─ Conflict in quiet mode: git rebase --abort, die (old clone untouched)
  └─ Conflict in interactive: pause, prompt admin to resolve, loop
      until git rebase --continue succeeds or admin types 'abort'

Step 6: Regenerate derived binaries
  ├─ For each entry in derivations.db + derivations.local:
  │   Did source file change? (git diff <old-artifact> HEAD -- $source)
  │   If yes: run regen command via jexec/chroot on -new
  │   If no: skip
  └─ Verify hash after regen

Step 7: Validate
  ├─ Regenerate mtree.dist
  ├─ Run diff.sh -q against the -new tree
  │   Clean → proceed
  │   Unclassified in quiet → die (old clone untouched)
  └─ Unclassified in interactive → run diff.sh interactively

Step 8: Offer swap
  ├─ Stop -new jail / unmount -new data datasets
  ├─ Print: "Update built successfully at {kind}s/${NAME}-new"
  ├─ Interactive: "Stop the old box and try the new one? [y/N]"
  │   If yes → stop old container (jail -r $NAME) / (system: no-op, it's running)
  │            → offer finalize_update
  │   If no  → print: "Run finalize_update -s $NAME when ready."
  └─ System with -n: "WARNING: Cannot nextboot -new without finalizing first."
```

**`finalize_update` flow (separate command):**

```
1. Verify ${NAME}-new exists
2. Verify ${NAME} exists (the old clone)
3. If old container is running: stop it (jail -r $NAME)
4. zfs destroy -r zbereshit/{kind}s/$NAME
5. zfs rename zbereshit/{kind}s/${NAME}-new zbereshit/{kind}s/$NAME
6. Update .foundation file contents with NEW_ARTIFACT
7. Save (delegate to save.sh)
8. Container: offer to start (jail -c $NAME)
9. System with -n: set_nextboot (same as deploy_system.sh)
```

**Rollback (if -new is bad):**

```
# Simply destroy the -new clone — old box is untouched
zfs destroy -r zbereshit/{kind}s/${NAME}-new
```

**Cleanup trap (for update.sh failures):**

```
update_cleanup() {
    if ${NAME}-new exists and update didn't complete:
        "WARNING: Partial update at {kind}s/${NAME}-new"
        "To rollback: zfs destroy -r zbereshit/{kind}s/${NAME}-new"
    stop -new jail if running
    zunmount datasets
}
```

**System update execution context — open design question:**

For containers, the jail framework handles mounts and provides jexec. For systems, the options are:

1. **chroot + ZFS mounts**: Mount data-lake datasets directly into the -new tree (they're ZFS datasets under `zbamidbar/system-data/$NAME/` with known mountpoints), use chroot for commands. Systems don't use nullfs — they own their datasets and mount them directly via ZFS.
2. **Temporary jail**: Generate a minimal jail.conf, start the -new tree as a jail during update. Provides jexec but adds complexity.
3. **kenv + reboot**: Set `vfs.root.mountfrom` to the -new dataset and reboot into it. Most realistic test, but heavy — requires two reboots (one to test, one to finalize or rollback).

Option 1 is simplest for v1. We know the dataset paths from `create_data_datasets()` in workspace.sh — they follow a fixed naming convention (`var`, `tmp`, `usr-local`, `home`). Mount them into the -new system tree, chroot, unmount.

Option 3 is the most correct for systems (you can't truly test a system without booting it), but it's a v2 feature. For v1, chroot is sufficient for recipe replay and validation.

### Create: `spec/update_spec.sh`

Tests:
- Pre-flight: already at latest → die, unsaved changes → die, ${NAME}-new exists → die
- Step isolation: each named function with mocks
- Correct ZFS commands (clone into -new, no rename of running clone)
- Compose replay order (pre_pkg before packages before post_pkg)
- Derivation regen: only when source changed
- Git rebase conflict: quiet → abort + die (old clone untouched)
- Dry-run: all steps in output in order
- Cleanup trap: -new clone mentioned

### Create: `spec/finalize_update_spec.sh`

Tests:
- -new exists → rename to plain name, destroy old
- -new does not exist → die
- Running container → stop before destroy

### Modify: `index.sh` — add `parasa_update()`, `parasa_finalize_update()` wrappers

### Verification: `shellspec spec/update_spec.sh && shellspec`

---

## Phase 5: Man pages and docs

### Create man pages (mdoc format, matching existing):

- `man/man8/diff.8`
- `man/man8/save.8`
- `man/man8/update.8`

### Update docs:

- `docs/save_workflow.md` — reflect pre_pkg/post_pkg structure
- `docs/drift_manifest.md` — update classification terminology (preserve, not environment)
- `docs/idea.md` — fill in rebase section

---

## Files summary

### New (8 scripts/specs + 4 man pages):

| File | Purpose |
|------|---------|
| `scripts/diff.sh` | parasa_diff — drift detection + classification |
| `scripts/save.sh` | parasa_save — two-commit state capture |
| `scripts/update.sh` | parasa_update — rebase onto new patch level (builds -new) |
| `scripts/finalize_update.sh` | parasa_finalize_update — swap -new into place |
| `spec/diff_spec.sh` | Tests for diff |
| `spec/save_spec.sh` | Tests for save |
| `spec/update_spec.sh` | Tests for update |
| `spec/finalize_update_spec.sh` | Tests for finalize_update |
| `man/man8/diff.8` | Man page |
| `man/man8/save.8` | Man page |
| `man/man8/update.8` | Man page |
| `man/man8/finalize_update.8` | Man page |

### Modified (4):

| File | Change |
|------|--------|
| `scripts/helpers.sh` | Add get_tree_root, get_recipes_dir, is_binary_file, lookup_derivation, read_artifact_name, detect_kind |
| `scripts/workspace.sh` | compose.sh boilerplate with pre_pkg/post_pkg |
| `spec/helpers_spec.sh` | Tests for new helpers |
| `index.sh` | Add parasa_diff, parasa_save, parasa_update wrappers |

---

## Verification plan

Each phase is independently testable:
```
Phase 1: shellspec spec/helpers_spec.sh spec/workspace_spec.sh
Phase 2: shellspec spec/diff_spec.sh && shellspec
Phase 3: shellspec spec/save_spec.sh && shellspec
Phase 4: ZFS research first, then shellspec spec/update_spec.sh && shellspec
Phase 5: man -l man/man8/diff.8  (verify renders)
```

Dry-run smoke test after Phase 4:
```
parasa_diff -s <target> -d
parasa_save -s <target> -d
parasa_update -s <target> -d
```
