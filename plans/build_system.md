# Plan: Foundation Architecture — New-Era Stage 1

> **Superseded decisions** (this plan predates later iterations):
> - `zshemot/tablets` → `zshemot/buildspace/<name>` (per-name workspaces, concurrent-safe)
> - `fstab.local` eliminated — systems use `/etc/fstab`, containers use `mount.fstab` in minhag
> - Recipe vs non-recipe mount distinction removed — all mounts in one file
> - `.foundation` file contains artifact name (not zero-byte)
> - Foundation names include major.minor (e.g., `generic-stable15.0`)
> - `zbereshit/foundations/` added as clone source for containers
> - Container mounts use jail(8) native `mount.fstab`, not `/etc/fstab` inside the container
>
> See `docs/idea.md` and `docs/user_stories_containers.md` for current architecture.

## Context

The build layer is separated from the system/container layer. A **foundation** is a build configuration (SRC_BRANCH, KERNCONF, etc.) that produces a pristine FreeBSD world+kernel. Systems and containers are built **on top of** a foundation via git branching. This eliminates `build.conf` from system/container dirs and reduces the ideological difference between systems and containers — what differentiates them is how you use them.

### Command Family

| Command | Purpose | Status |
|---------|---------|--------|
| `new_foundation` | Build world+kernel from source, archive to zbamidbar | **This plan** |
| `new_system` | Create a system on top of a foundation, optionally deploy | **This plan** |
| `new_container` | Create a container on top of a foundation | Future (mirrors new_system) |
| `deploy_system` | Deploy an archived system to zbereshit for boot | **This plan** (split out) |
| `update_system` | Rebuild/upgrade an existing system onto a new foundation | Future |
| `edit_system` | Interactively edit system metadata, fstab, minhag config | Future |
| `destroy_system` | Tear down a system (minhag, datasets, git branch) | Future |

### Architectural Summary

```
minhag/
  foundations/<name>/
    build.conf                    SRC_BRANCH, KERNCONF, MAKE_JOBS, etc.
  systems/<name>/
    <foundation-name>.foundation  Zero-byte file; filename = foundation
    compose.sh                    Opaque replay commands
    derivations.local             Custom text→binary derivations
    fstab.local                   Recipe-only mounts (container deps, shared
                                  jail data-pools — NOT normal system mounts)
    mtree.dist                    Baseline mtree
    pkg.list                      Package list
  containers/<name>/
    <foundation-name>.foundation  Same as systems
    compose.sh / derivations.local / fstab.local / mtree.dist / pkg.list
    jail.conf                     Jail configuration

foundation.git branches:        (bare repo at zbamidbar/foundation.git)
  foundation/<name>               Pristine build (world+kernel)
  system/<name>                   Forks from a foundation/ commit;
                                  inaugural commit writes /etc/fstab
  container/<name>                Forks from a foundation/ commit

foundation.zfs:                 (zbamidbar/foundation.zfs/)
  foundations/<name>              Pristine ZFS archive (includes var/)
  (NO systems/ or containers/ — tracked by git+mtree+compose)

zbereshit:
  zbereshit/systems/<name>        Deployed from a foundation via zfs send,
                                  then git checkout system/<name> applies
                                  system-specific state (fstab, etc.)
  zbereshit/containers/<name>     Same

zbamidbar/system-data/<name>/     Per-system data datasets (var, home, etc.)
zbamidbar/container-data/<name>/  Per-container data datasets
```

### Two kinds of fstab entries

| Kind | Where it lives | Examples | When written |
|------|---------------|----------|--------------|
| **System fstab** | `/etc/fstab` inside the system (git-tracked) | var, home, tmp, user homes | Inaugural system commit during `new_system` |
| **Recipe fstab** | `minhag/systems/<name>/fstab.local` | Container deps, shared jail data-pools | When the recipe requires it (future) |

Normal data-lake mounts go into the system's `/etc/fstab` as the first commit on the system branch. `fstab.local` in minhag is reserved for recipe-critical mounts that are part of the system's identity (e.g., a container that depends on another container's shared dataset). This distinction will matter more when we get to container dependencies.

---

## Files to Create / Modify

| File | Action | Purpose |
|------|--------|---------|
| `scripts/new_foundation.sh` | **Create** | Build world+kernel, archive to zbamidbar |
| `scripts/new_system.sh` | **Create** | Create system on a foundation, optionally deploy |
| `scripts/deploy_system.sh` | **Create** | Deploy archived system to zbereshit + nextboot |
| `scripts/helpers.sh` | **Edit** | Add `msysrc()`, `zfs_dataset_exists()`, `git_branch_exists()`, `get_foundation()` |
| `index.sh` | **Edit** | Add `parasa_new_foundation()`, `parasa_new_system()`, `parasa_deploy_system()` |
| `etc/mtree.ignore` | **Create** | Ships with parasa repo; contains `.git` |
| `docs/idea.md` | **Edit** | Foundation concept, fstab split, command family, dataset renames |
| `docs/user_stories_build_system.md` | **Rewrite** | Split into foundation + system stories |
| `docs/drift_manifest.md` | **Edit** | Update build.conf refs to foundations |
| `scripts/stage0-bootstrap.sh` | **Edit** | Rename `tablets.git` → `foundation.git`, `tablets.zfs` → `foundation.zfs` |

---

## Part 1: `new_foundation`

### Arguments

```
getopts ":hs:o:qd" opt
```

| Flag | Variable | Meaning |
|------|----------|---------|
| `-h` | — | Print help, exit |
| `-s NAME` | `FOUNDATION_NAME` | Foundation name |
| `-o K=V` | accumulated | Build config overrides (repeatable) |
| `-q` | `QUIET` counter | `-q` = no prompts, show progress. `-qq` = suppress progress too |
| `-d` | `DRY_RUN=true` | Print commands, don't execute |

Mode detection:
- No `-s` → interactive
- `-s` without `-q` → semi-interactive
- `-s` with `-q` → quiet

`-o` keys: `src_branch`, `kernconf`, `make_jobs`

### Execution Flow

#### Phase 0: Init
1. Source helpers, `root_only`, parse args, trap cleanup

#### Phase 1: Input
2. **`collect_foundation_name`** — prompt if interactive; validate
3. **`check_name_available`** — must NOT exist in:
   - `minhag/foundations/<name>/`
   - `zbamidbar/foundation.zfs/foundations/<name>`
   - `foundation.git` branch `foundation/<name>`
   If exists, error suggesting `destroy_foundation` (future) or pick a new name.
4. **`resolve_build_config`** — collect SRC_BRANCH (default `stable/15`), KERNCONF (default `GENERIC`), MAKE_JOBS (default `hw.ncpu`). In semi mode, `-o` values become pre-filled defaults; still ask every question. Enter = accept default.
5. Print summary, confirm

#### Phase 2: Preparation
6. **`create_minhag_dir`** — create `minhag/foundations/<name>/build.conf` with collected values. In interactive mode (not `-q`), offer to open the foundation dir in `$EDITOR` before proceeding.
7. **`ensure_src_tree`** — mount `zshemot/src.git`, clone if missing, checkout SRC_BRANCH, pull
8. **`prepare_tablets`** — create `zshemot/tablets` + `zshemot/tablets/var` (transient). Ensure empty.
9. **`prepare_tablets_git`**:
   - Mount `zbamidbar/foundation.git`. Init bare if needed.
   - In `/zshemot/tablets`: `git init`, `git remote add origin <path>`, `git fetch` (fetch is needed to get remote refs — branch list, existing foundations. There is no lighter metadata-only option in git.)
   - `git checkout --orphan foundation/<name>`
   - Clear everything except `.git`

#### Phase 3: Build
10. **`run_build`** — five make targets from `zshemot/src.git`:
    1. `make -j$N buildworld`
    2. `make -j$N buildkernel KERNCONF=$KERNCONF`
    3. `make -j$N DESTDIR=/zshemot/tablets installkernel KERNCONF=$KERNCONF`
    4. `make -j$N DESTDIR=/zshemot/tablets installworld`
    5. `make -j$N DESTDIR=/zshemot/tablets distribution`
11. Generate artifact name: `get_artifact_name /zshemot/src.git "$FOUNDATION_NAME"`

#### Phase 4: Track
12. **`commit_build`**:
    1. `git add .` — stages everything including base var/ files
    2. Create `.gitignore`: `var/`, `usr/local/`, `tmp/`. NOT `home/` — whether to gitignore home is a per-system/container decision, asked during `new_system`/`new_container` and applied in the inaugural commit.
    3. `git add .gitignore`
    4. Generate mtree: `generate_mtree /zshemot/tablets $MINHAG_DIR $PARASA_DIR/etc/mtree.ignore`
    5. `git commit -m "$ARTIFACT_NAME"`
    6. `git push origin foundation/$FOUNDATION_NAME`

13. **`archive_to_zbamidbar`**:
    1. `zfs snapshot -r zshemot/tablets@$ARTIFACT_NAME`
    2. `ztouch zbamidbar/foundation.zfs/foundations/$FOUNDATION_NAME`
    3. Full send to `zbamidbar/foundation.zfs/foundations/$FOUNDATION_NAME`

14. **`wipe_tablets`** — `zfs destroy -r zshemot/tablets`

---

## Part 2: `new_system`

Takes an existing foundation and creates a system on top of it. The key operation is creating the **inaugural system commit** — a commit on `system/<name>` branching from `foundation/<name>` that writes the system's mount configuration into `/etc/fstab`. If no etc/fstab configuration needs writing, simply generate the branch name as a branch from the foundation commit.

### Arguments

```
getopts ":hs:f:o:qdb" opt
```

| Flag | Variable | Meaning |
|------|----------|---------|
| `-h` | — | Help |
| `-s NAME` | `SYSTEM_NAME` | System name |
| `-f FOUNDATION` | `FOUNDATION_NAME` | Which foundation to base on |
| `-o K=V` | accumulated | Property answers (repeatable) |
| `-q` | `QUIET` counter | Quiet mode |
| `-d` | `DRY_RUN=true` | Dry run |
| `-b` | `BOOT` counter | `-b` = deploy, `-bb` = deploy + nextboot |

`-o` property keys:

| Key | Default | Dataset created |
|-----|---------|-----------------|
| `home_dataset` | yes | `zbamidbar/system-data/<name>/home` |
| `tmp_dataset` | yes | `zbamidbar/system-data/<name>/tmp` |
| `roothome_dataset` | no | `zbamidbar/system-data/<name>/home/root` |
| `user_homes` | "" | Comma-separated → `home/<user>` each |
| `mount_map` | "" | Custom non-recipe mount entries |

The standard data-lake mounts (var, tmp, usr/local) are always auto-included in the system's inaugural `/etc/fstab` — these are not optional and not asked as questions. Home is optional (asked). For each additional custom mount, ask: **is this recipe-related?** If yes → goes in `minhag/<name>/fstab.local`. If no → goes in `/etc/fstab` via the inaugural commit.

### Execution Flow

#### Phase 0: Init
1. Source helpers, `root_only`, parse args, trap cleanup

#### Phase 1: Input
2. **`collect_system_name`** — prompt if interactive; validate
3. **`check_name_available`** — must NOT exist in:
   - `minhag/systems/<name>/`
   - `zbereshit/systems/<name>`
4. **`collect_foundation`** — if `-f` provided, validate it exists in `minhag/foundations/<name>/` AND `zbamidbar/foundation.zfs/foundations/<name>`. If not provided, list available foundations and prompt.
5. **`collect_build_options`** — boilerplate dataset questions + custom mounts. For each mount, ask if recipe-related (default: no). Defaults use `zbamidbar/system-data/<name>/<stem>`, user can override.
6. Print summary, confirm

#### Phase 2: Setup
7. **`create_minhag_dir`** — create `minhag/systems/<name>/` with:
   - `<foundation-name>.foundation` (zero-byte file)
   - `compose.sh` (empty)
   - `derivations.local` (empty)
   - `pkg.list` (empty)
   - `fstab.local` (recipe-only mounts, or empty if none)
   - `mtree.dist` (empty, populated later by parasa-diff)
8. **`create_system_datasets`** — on zbamidbar:
   - `ztouch zbamidbar/system-data/$SYSTEM_NAME`
   - Full `zfs send | recv` from `zbamidbar/foundation.zfs/foundations/$FOUNDATION_NAME/var` to `zbamidbar/system-data/$SYSTEM_NAME/var` (independent copy of pristine var)
   - `ztouch` for home, tmp, roothome, user homes per collected options
9. **`create_inaugural_commit`** — the core operation:
   1. Recv foundation from `zbamidbar/foundation.zfs/foundations/$FOUNDATION_NAME` to `zshemot/tablets` (temporarily — we need the filesystem to modify and commit)
   2. Set up git: the recv'd dataset includes `.git` from the foundation build. Verify remote points to `foundation.git`. `git fetch origin`.
   3. Create branch: `git checkout -b system/$SYSTEM_NAME foundation/$FOUNDATION_NAME`
   4. Write non-recipe fstab entries into `/etc/fstab` inside tablets (append the generated mount lines in fstab format with `zfs` type and `late` option)
   5. If `fstab.local` has recipe-only mounts, also append those to `/etc/fstab`
   6. `git add etc/fstab`
   7. `git commit -m "system/$SYSTEM_NAME inaugural"` (or a more descriptive message)
   8. `git push origin system/$SYSTEM_NAME`
   9. Wipe tablets: `zfs destroy -r zshemot/tablets`
   If there are no fstab changes to commit (no home dataset, no custom mounts, no recipe mounts), simply create the branch on the bare repo without recv'ing tablets.

#### Phase 3: Deploy (optional, gated by `-b` / interactive prompt)
Calls `deploy_system.sh` — see Part 3.

---

## Part 3: `deploy_system`

Standalone script. Sends a foundation's ZFS dataset from zbamidbar to zbereshit, then applies the system branch via git checkout to layer system-specific state on top.

### Arguments

```
getopts ":hs:a:nd" opt
```

| Flag | Meaning |
|------|---------|
| `-h` | Help |
| `-s NAME` | System name (required) |
| `-a ARTIFACT` | Artifact/snapshot to deploy (default: latest). This targets the system's git history — the foundation snapshot is derived from the commit the system branch forks from. |
| `-n` | Set nextboot after deploy |
| `-d` | Dry run |

### How deploy finds the right ZFS snapshot

The system branch forks from a `foundation/<name>` commit. The artifact name is the commit message of that foundation commit. This artifact name is the ZFS snapshot tag on `zbamidbar/foundation.zfs/foundations/<name>`. So:

1. Read the system's foundation from `minhag/systems/<name>/*.foundation`
2. In `foundation.git`, find which foundation commit `system/<name>` forks from (the merge base or first parent on the foundation branch)
3. Read that commit's message — it IS the artifact name
4. Use that artifact name to locate `zbamidbar/foundation.zfs/foundations/<foundation>@<artifact>`

### Flow
1. Look up foundation and resolve the ZFS snapshot (as above)
2. Validate archive exists
3. `zfs send | recv` from `zbamidbar/foundation.zfs/foundations/<foundation>@<artifact>` to `zbereshit/systems/<name>`. For a new system this is always a full send (we verified it doesn't exist on zbereshit in `check_name_available`). For `update_system` (future), incremental sends apply.
4. Mount `zbamidbar/foundation.git`
5. Temporarily mount `zbereshit/systems/<name>`. The recv'd dataset includes `.git` from the foundation build. Fetch the system branch: `git fetch origin system/<name>`. Checkout: `git checkout system/<name>`. This applies the inaugural commit (fstab entries, etc.) on top of the foundation.
6. Unmount `zbereshit/systems/<name>`
7. If `-n` (nextboot):
   - Set root mountpoint: `zfs set -u mountpoint=/ zbereshit/systems/<name>`
   - `nextboot -e vfs.root.mountfrom="zfs:zbereshit/systems/<name>"`
   - Prompt to reboot (if interactive)
8. If NOT `-n`: do NOT set `mountpoint=/` — leave the dataset unmounted until the user explicitly requests nextboot.

---

## fstab Split

### System fstab (in `/etc/fstab`, git-tracked)

Written during the inaugural system commit in `new_system`. Contains all normal data-lake mounts:

```
# device                                    mountpoint      fstype    options    dump  pass
zbamidbar/system-data/wonderland/var        /var             zfs      rw,late    0     0
zbamidbar/system-data/wonderland/home       /home            zfs      rw,late    0     0
zbamidbar/system-data/wonderland/usr/local  /usr/local       zfs      rw,late    0     0
zbamidbar/system-data/wonderland/tmp        /tmp             zfs      rw,late    0     0
zbamidbar/alice-home                        /home/alice      zfs      rw,late    0     0
```

These are deployment config, not recipe material. They vary per deployment and don't affect the system's identity.

### Recipe fstab (`minhag/systems/<name>/fstab.local`)

Reserved for recipe-critical mounts that are part of the system's identity:
- Container dependencies (container A needs data from container B's shared pool)
- Shared jail data-pools

This will matter more when we implement container dependencies. For now, most systems will have an empty `fstab.local`.

### Why fstab over `zfs set mountpoint=`

1. **No collisions**: fstab is per-system, `zfs set mountpoint=` is per-dataset (one value)
2. **Shared datasets**: Same dataset mountable at different paths on different systems
3. **FreeBSD native**: `mount -a` with `late` option handles ZFS after pool import

---

## .foundation File Convention

Each system/container has exactly one zero-byte file named `<foundation-name>.foundation` in its minhag dir.

**Reading**: `basename "$(ls "$dir"/*.foundation)" .foundation`

**Guard**: Multiple `.foundation` files = error (corruption or mistake).

**Why zero-byte**: Filename IS the data. Visible in `ls`/`tree`. No parsing.

---

## New Helpers for `scripts/helpers.sh`

**`msysrc()`** — two-tier config lookup:
```
# Usage: msysrc foundation_name VAR_NAME [default]
# Checks minhag/foundations/<name>/build.conf first, falls back to parasa.conf.
```

**`zfs_dataset_exists()`** — `zfs list -H -o name "$1" >/dev/null 2>&1`

**`git_branch_exists()`** — `git rev-parse --verify "refs/heads/$1" >/dev/null 2>&1`

**`get_foundation()`** — read foundation name from a system/container minhag dir:
```
# Usage: get_foundation minhag_dir
# Returns foundation name. Dies if zero or multiple .foundation files.
```

---

## Key Design Decisions

1. **Foundations separate from systems/containers**: Build config lives in `minhag/foundations/`. Systems/containers point to a foundation. Difference between system and container = how you use it.

2. **foundation.zfs only has foundations/**: No systems/containers in the archive. System/container state is tracked by git+mtree+compose.

3. **Inaugural commit creates the system branch**: `new_system` recv's the foundation to tablets, branches `system/<name>` from `foundation/<name>`, writes fstab entries into `/etc/fstab`, commits, pushes. Deploy just sends the ZFS + checks out the system branch.

4. **Two kinds of fstab**: Normal mounts → `/etc/fstab` (git-tracked, inaugural commit). Recipe mounts → `minhag/<name>/fstab.local` (for container deps, future).

5. **Zero-byte `.foundation` file**: Filename is the data.

6. **`git add .` BEFORE `.gitignore`**: Stages base var/ files, then gitignore prevents future additions.

7. **ZFS flow: zshemot → zbamidbar → zbereshit**: zbamidbar is authoritative.

8. **`nextboot(8)` over raw kenv**: One-shot boot, auto-reverts on failure.

9. **`mountpoint=/` only when nextboot enabled**: Don't set root mountpoint unless the user actually wants to boot into it.

10. **`zshemot/tablets` fully transient**: Created on demand, destroyed after use. Used by both `new_foundation` (full build) and `new_system` (inaugural commit).

11. **Foundation .gitignore**: `var/`, `usr/local/`, `tmp/` only. NOT `home/`. Home gitignore is per-system/container, decided and applied in the inaugural commit.

12. **Semi-interactive: `-o` values pre-fill defaults, still prompt**: Every question is asked; enter = accept default.

13. **Interactive: offer `$EDITOR`**: After creating foundation minhag dir, offer to open it in `$EDITOR` before proceeding with the build.

14. **foundation.git / foundation.zfs**: Renamed from `tablets.git` / `tablets.zfs` — dropped the extra nesting layer.

---

## Dataset Renames (bootstrap update) — DONE

In `scripts/stage0-bootstrap.sh`:
- `zbamidbar/sinai/tablets.git` → `zbamidbar/foundation.git` ✓
- `zbamidbar/sinai/tablets.zfs` → `zbamidbar/foundation.zfs` ✓
- `zbamidbar/sinai/parasa.git` → `zbamidbar/parasa.git` (flattened) ✓
- `zbamidbar/sinai` parent dataset removed (no longer needed) ✓
- `zshemot/tablets` + `zshemot/tablets/var` removed from bootstrap (transient) ✓

---

## Doc Updates — DONE

1. **`docs/idea.md`**: ✓ Foundation concept, minhag layout, fstab split, command family, dataset renames, git branch naming
2. **`docs/user_stories_build_system.md`**: ✓ Rewritten around new_foundation + new_system + deploy_system
3. **`docs/drift_manifest.md`**: ✓ Updated dataset refs, rebase = git rebase foundation/<name>
4. **`scripts/stage0-bootstrap.sh`**: ✓ Dataset renames
5. **`docs/save_workflow.md`**: ✓ Updated dataset refs
6. **`docs/stage0_bootstrap.md`**: ✓ Updated dataset layout

---

## Verification

1. `parasa_new_foundation -s generic-stable15 -d` — dry-run foundation build
2. `parasa_new_foundation` — interactive foundation build (with `$EDITOR` offer)
3. `parasa_new_system -s wonderland -f generic-stable15` — interactive new system
4. `parasa_new_system -s testbox -f generic-stable15 -qbb` — quiet full pipeline
5. `parasa_deploy_system -s wonderland -n` — standalone deploy + nextboot
6. Name collision → clear error
7. Missing foundation → error listing available foundations
8. Verify inaugural commit: after `new_system`, check `system/<name>` branch has fstab changes
9. Verify deploy: after `deploy_system`, check `/etc/fstab` on zbereshit has the mount entries
