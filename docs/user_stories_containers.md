# User Stories: Container Lifecycle

These stories illustrate how containers are created, deployed, customized,
saved, updated, and destroyed. They follow a container from birth to death
and cover the interactions between the container's minhag config, its
sinai.git branch, its ZFS datasets, and the running jail.

See `docs/user_stories_build_system.md` for foundation and system stories.

---

## Architecture notes

### Foundation versioning

Foundation names include the FreeBSD stream and major.minor version:
`generic-stable15.0`, not `generic-stable15`. This makes it explicit which
OS release a container is built on and distinguishes patch-level updates
(same major.minor, new artifact) from stream changes (new major.minor).

### The .foundation file

Each system/container has exactly one file named
`<foundation-name>.foundation` in its minhag dir. The filename encodes
the foundation identity (stream + major.minor). The file **contains the
artifact name** (patch level), which is the ZFS snapshot tag and sinai.git
commit message for the foundation build.

- **Patch-level update**: Rewrite the file's contents with the new
  artifact name. Filename stays the same.
- **Stream/major.minor change**: Rename the file (e.g.,
  `generic-stable15.0.foundation` → `generic-stable15.1.foundation`)
  and write the new artifact name.

Reading: `basename "$(ls "$dir"/*.foundation)" .foundation` for the
foundation name; `cat "$dir"/*.foundation` for the artifact name.
Multiple `.foundation` files = error.

### The zbereshit/foundations clone hierarchy

Each foundation exists in two places:

- `zbamidbar/sinai.zfs/foundations/<name>@<artifact>` — canonical archive.
  This is the authoritative copy produced by `new_foundation`.
- `zbereshit/foundations/<name>@<artifact>` — deployment clone source.
  Replicated from zbamidbar via `zfs send | recv`.

Containers are ZFS **clones** from `zbereshit/foundations/<name>@<artifact>`.
This gives us block-level deduplication: two containers at the same patch
level share all base blocks (minus their deltas). Containers at different
patch levels still share most blocks via the incremental snapshot chain.

When updating containers (destroy old clone, create new clone from new
artifact), if a snapshot on zbereshit/foundations becomes older than
anything in use, it can be pruned.

### Jail mount architecture

Container data-lake mounts use jail(8)'s native `mount.fstab` mechanism,
not `/etc/fstab` inside the container. Each container's jail.conf
references a `mount.fstab` file in the minhag directory. The jail
framework processes these entries at jail start and reverses them at
jail stop — no manual mount/unmount scripts needed.

The host's `/etc/jail.conf` includes container configs:
```
include "/zshemot/parasa/minhag/containers/*/jail.conf";
```

This is set up during bootstrap.

### Build workspaces (amim)

All parasa build and inauguration operations use per-name workspaces
under `zshemot/amim/` (literally "peoples"). Each workspace is named
after the thing being built:

- `zshemot/amim/generic-stable15.0` — foundation build
- `zshemot/amim/webserver` — container inauguration
- `zshemot/amim/wonderland` — system inauguration

Because each operation gets its own workspace, multiple builds can
run concurrently without colliding. A foundation build and a container
inauguration can happen at the same time.

**Future work**: The current mount/unmount helpers use greedy unmounting
(unmount a dataset as soon as the script is done with it). This doesn't
handle concurrency well — one script may unmount a shared dataset
(like sinai.git) while another script still needs it. Fixing this
requires reference-counted mounts or a mount broker.

### The .git problem

Foundation archives include `.git` from the build process (because we
`git init` and commit in the amim workspace before `zfs send`). This
means every container clone inherits `.git`, which accumulates cruft over
time. Ideologically, foundations shouldn't carry `.git` at all — git
tracking belongs in sinai.git (bare repo), not embedded in the dataset.

**Open question**: How to solve this. Options include:
1. Strip `.git` from the ZFS archive before sending (messy, fragile)
2. Move git tracking entirely out of the dataset (init git in clones
   by adding sinai.git as remote, not by inheriting `.git`)
3. Accept `.git` exists and manage the size (periodic gc, shallow clones)
4. Store `.git` on a separate child dataset that can be excluded from
   sends

No decision yet. The stories proceed as if `.git` is present in
foundations and inherited by clones, which is the current behavior.

---

## Story A: New container, interactive

Alice has a `generic-stable15.0` foundation. She runs
`parasa_new_container` with no arguments.

1. **Name**: Prompted. She types `webserver`. The command checks that:
   - `minhag/containers/webserver/` doesn't exist
   - `zbereshit/containers/webserver` doesn't exist
   - `zbamidbar/container-data/webserver` doesn't exist

2. **Foundation**: The command lists available foundations (reads from
   `minhag/foundations/`). Alice selects `generic-stable15.0`. The command
   verifies the foundation is archived in zbamidbar/sinai.zfs and that a
   matching artifact exists on zbereshit/foundations (or offers to
   replicate it).

3. **Dataset questions**: Same pattern as systems:
   - Make a /home dataset? (default: yes) → Alice says no, it's a web server
   - Make /tmp its own dataset? (default: yes) → yes
   - User home datasets? → none
   - Custom mounts? → Alice adds `zbamidbar/web-content:/srv/www`

4. **Summary + confirm**.

5. **Minhag setup**: Creates `minhag/containers/webserver/` with:
   - `generic-stable15.0.foundation` (contains the artifact name)
   - `compose.sh` (empty)
   - `derivations.local` (empty)
   - `pkg.list` (empty)
   - `mtree.dist` (empty)
   - `jail.conf` (skeleton — hostname, path, devfs, exec.start/stop,
     mount.fstab reference)
   - `mount.fstab` (all mount entries — data-lake and custom — processed
     by jail start/stop)

6. **Create datasets**: On zbamidbar:
   - `zbamidbar/container-data/webserver` (parent)
   - `zfs send | recv` from foundation's var to `.../webserver/var`
   - `zbamidbar/container-data/webserver/usr-local`
   - `zbamidbar/container-data/webserver/tmp`
   - (no home — declined)

7. **Inaugural commit**:
   - Recv foundation to `zshemot/amim/webserver`
   - `git checkout -b container/webserver foundation/generic-stable15.0`
   - Commit (minimal — branch creation is the point)
   - Push to sinai.git
   - Destroy `zshemot/amim/webserver`

Alice now has a container definition but nothing running yet.

---

## Story B: Deploy container

Alice wants to bring `webserver` online. She runs:
```
parasa_deploy_container webserver
```

1. **Resolve**: Reads `minhag/containers/webserver/*.foundation` to find
   `generic-stable15.0`. Reads the file's contents to get the artifact
   name. Verifies the artifact exists on
   `zbamidbar/sinai.zfs/foundations/generic-stable15.0@<artifact>`.

2. **Replicate to zbereshit** (if needed): If
   `zbereshit/foundations/generic-stable15.0@<artifact>` doesn't exist
   yet, do a `zfs send | recv` from zbamidbar to create it. This is the
   deployment clone source shared by all containers on this foundation
   and patch level.

3. **Clone**: `zfs clone` from
   `zbereshit/foundations/generic-stable15.0@<artifact>` to
   `zbereshit/containers/webserver`. This is a zero-copy operation — the
   clone shares all blocks with the foundation until deltas accumulate.

4. **Apply container branch**: The clone inherits `.git` from the
   foundation (see open question above). Fetch `container/webserver`
   from sinai.git, `git checkout container/webserver`. This applies the
   inaugural commit on top of the foundation.

5. **Start jail**: The container's jail.conf (included by `/etc/jail.conf`)
   references `mount.fstab`, which maps data-lake datasets into the
   container path. `jail -c webserver` processes mount.fstab automatically:
   ```
   mount.fstab entries (processed by jail start):
     zbamidbar/container-data/webserver/var       → /containers/webserver/var
     zbamidbar/container-data/webserver/usr-local  → /containers/webserver/usr/local
     zbamidbar/container-data/webserver/tmp        → /containers/webserver/tmp
     zbamidbar/web-content                         → /containers/webserver/srv/www
   ```

   When the jail stops, these mounts are reversed automatically.

The container is now deployed and running.

---

## Story C: First boot — packages and compose

Alice enters the running container and installs her packages:
```
jexec webserver sh
pkg install -y nginx
sysrc nginx_enable=YES
service nginx start
```

At this point the container is running but unsaved. The nginx package
is in `/containers/webserver/usr/local` (which is really
`zbamidbar/container-data/webserver/usr-local`), the `rc.conf` edit is in
`/containers/webserver/etc/rc.conf` (on `zbereshit/containers/webserver`,
tracked by git).

---

## Story D: Save container state

Alice has been running `webserver` for a while. She's added nginx config
files, edited rc.conf, and installed a few more packages. She runs:
```
parasa_save webserver
```

1. **Detect changes**: `parasa_diff` compares the live filesystem at
   `/containers/webserver` against the mtree baseline in
   `minhag/containers/webserver/mtree.dist`. It finds:
   - `etc/rc.conf` — text file, modified → auto-classified as git-tracked
   - `etc/nginx/` — new text files → auto-classified as git-tracked
   - Nothing unexpected in var/ or usr/local/ (gitignored, on separate datasets)

2. **Package list**: `pkg -j webserver info -o` is captured into
   `minhag/containers/webserver/pkg.list`. No admin input needed.

3. **Admin message**: The admin is prompted for a message describing
   what changed (e.g., "added nginx with default config").

4. **Commit to zbereshit**: Stage all detected changes on
   `zbereshit/containers/webserver`, update mtree.dist, commit to the
   `container/webserver` branch. The commit message format:
   ```
   <artifact-name>
   <admin message>
   ```
   Push to sinai.git.

5. **Commit to zshemot**: The updated pkg.list (and any compose.sh
   changes, derivation entries) are committed to the parasa repo in
   zshemot.

Two commits: the zbereshit commit records the state, the zshemot commit
records the recipe.

---

## Story E: Update container to a new foundation

Months later, Alice builds a new foundation `generic-stable15.1` from a
newer `stable/15` snapshot. She wants to update `webserver` to this
new base. She runs:
```
parasa_update_container webserver -f generic-stable15.1
```

1. **Pre-flight** (non-interactive checks first):
   - The new foundation exists in sinai.zfs
   - There are no unsaved changes (`parasa_diff` clean)
   - The current foundation is `generic-stable15.0` (reads `.foundation` file)
   
   Then, if the container is running (`jls -j webserver` succeeds),
   **ask the admin** whether to shut it down. Only prompt after all other
   blockers are verified — don't make the admin stop a jail only to find
   out the foundation doesn't exist.

2. **Rebase the git branch**: In sinai.git:
   - `git rebase --onto foundation/generic-stable15.1 foundation/generic-stable15.0 container/webserver`
   - Text files (rc.conf, nginx configs) merge automatically via
     three-way merge. If conflicts arise, the command drops to an
     interactive rebase session (or fails in quiet mode).

3. **Update the ZFS base**: Destroy the old zbereshit container clone.
   If `zbereshit/foundations/generic-stable15.1@<artifact>` exists, clone
   from it. If not, `zfs send | recv` from zbamidbar to create it on
   zbereshit, then clone. `git checkout container/webserver` to apply
   the rebased branch.

4. **Replay compose.sh**: Run each line of `compose.sh` inside the
   container via `jexec`. These run BEFORE git checkout because git's
   three-way merge is better at deferring same-same changes than
   compose.sh is — so let compose.sh create/modify files first, then
   let git resolve what's changed vs. what's the same.

5. **Apply git branch**: The git checkout/rebase applies the container's
   text file deltas on top of the compose output + new foundation.

6. **Regenerate derived binaries**: Read `derivations.local` and the
   default derivation database. For each entry (e.g.,
   `master.passwd → pwd.db via pwd_mkdb`), regenerate the binary from
   the merged text source.

7. **Package upgrade** (interactive): Ask the admin whether to run
   `pkg upgrade`. This might be a breaking change (major version bumps,
   ABI changes) and the admin may want to do it in two stages — update
   the base first, verify, then upgrade packages separately.

8. **Validate**: Run `parasa_diff` against the updated mtree. If it
   finds zero unclassified changes, the update is clean. If anything
   is unexpected, the admin is prompted.

9. **Update minhag**: For a patch-level update within the same
   major.minor, rewrite the `.foundation` file contents with the new
   artifact name (filename stays `generic-stable15.0.foundation`). For a
   stream/major.minor change (as in this example), rename the file
   (`generic-stable15.0.foundation` → `generic-stable15.1.foundation`)
   and write the new artifact name. Update mtree.dist. Commit to zshemot.

10. **Restart**: Ask to start the jail (`jail -c webserver`).

---

## Story F: Container with dependencies (shared mounts)

Alice creates a `postgres` container that stores its data on a
shared dataset. Later, she creates an `app` container that needs
read access to postgres's data for backups.

### Creating postgres:
```
parasa_new_container postgres -f generic-stable15.0
```

During dataset questions, Alice adds a custom mount:
- `zbamidbar/shared-data/postgres:/var/db/postgres`

This mount goes into `minhag/containers/postgres/mount.fstab` alongside
the standard data-lake mounts. Alice marks it as shared:
```
# mount.fstab for postgres
# ...standard data-lake mounts...
# shared
/zbamidbar/shared-data/postgres  /containers/postgres/var/db/postgres  nullfs  rw  0  0
```

The `# shared` comment is a convention for parasa tooling. It signals
that this dataset is cross-referenced — other containers may depend on
it. Parasa scans all containers' mount.fstab files to find these
relationships.

### Creating app:
```
parasa_new_container app -f generic-stable15.0
```

During custom mounts, Alice adds:
- `zbamidbar/shared-data/postgres:/mnt/pgdata` (read-only)

The entry in `minhag/containers/app/mount.fstab`:
```
# shared
/zbamidbar/shared-data/postgres  /containers/app/mnt/pgdata  nullfs  ro  0  0
```

Both containers' mount.fstab files now reference the same dataset. The
jail framework handles the mounts at start/stop automatically.

### Why foreign datasets are safe during updates

When Alice updates `postgres` to a new foundation,
`parasa_update_container` destroys and re-clones only the zbereshit
container dataset. Data-lake datasets under zbamidbar/container-data
are never destroyed during updates — they persist across foundation
changes. Shared datasets like `zbamidbar/shared-data/postgres` are
not owned by any container and are never touched.

Similarly, `parasa_destroy_container postgres` scans all containers'
mount.fstab files for `# shared` entries referencing the same datasets.
If `app` depends on `zbamidbar/shared-data/postgres`, parasa warns and
refuses to destroy the shared dataset without explicit confirmation.

---

## Story G: Destroy container

Alice no longer needs `webserver`. She runs:
```
parasa_destroy_container webserver
```

1. **Pre-flight**: Checks for dependents — are any other containers'
   `mount.fstab` files referencing `# shared` datasets that this
   container also references? If so, warn (the shared dataset won't
   be destroyed, but the dependency should be noted).

   If the container is still running, **ask to shut it down**.

2. **Summary**: Lists everything that will be destroyed:
   - `zbereshit/containers/webserver` (deployed container clone)
   - `zbamidbar/container-data/webserver` (all child datasets: var,
     usr-local, tmp)
   - `container/webserver` branch in sinai.git
   - `minhag/containers/webserver/` directory
   - `webserver` entry removed from jail.conf.d

3. **Interactive confirmation**: Each item is listed and the admin
   can choose what to keep. For example:
   - Keep the git branch? (for history/audit) → Alice says no
   - Keep the minhag recipe? (to recreate later) → Alice says yes
   - Keep container-data datasets? → Alice says no

   In quiet mode, everything is destroyed.

4. **Destroy**: In this order (respecting admin choices):
   - Stop jail if running
   - Remove jail.conf.d entry
   - Unmount and destroy `zbereshit/containers/webserver`
   - Unmount and destroy `zbamidbar/container-data/webserver` recursively
   - Delete branch `container/webserver` from sinai.git
   - Remove `minhag/containers/webserver/`
   - Commit removal to zshemot

Nothing shared is touched. The `zbamidbar/web-content` dataset Alice
mounted at `/srv/www` is NOT destroyed — it's not under container-data,
so it's not owned by this container.

---

## Story H: Clone a container

Alice wants a staging copy of `webserver`. She runs:
```
parasa_clone_container webserver webserver-staging
```

1. **Branch**: In sinai.git, create
   `container/webserver-staging` from `container/webserver`
   (not from the foundation — from the current container state,
   preserving all commits).

2. **Minhag**: Copy `minhag/containers/webserver/` to
   `minhag/containers/webserver-staging/`. Update the jail.conf
   hostname. Review mount.fstab entries — remove any shared mounts
   that shouldn't be duplicated (interactive prompt).

3. **Datasets**: Create fresh `zbamidbar/container-data/webserver-staging`
   datasets. For var: `zfs send | recv` from webserver's var
   snapshot (preserving current state, not pristine foundation var).
   For usr-local: snapshot + send (preserving installed packages).

4. **Deploy**: Optional — if requested, clone the zbereshit dataset
   and install the jail.conf entry.

The staging container starts as an exact copy and diverges from there.
Updates to `webserver` do not propagate to `webserver-staging` — they
are independent branches.

---

## Story I: Quiet batch container creation

Bob runs:
```
parasa_new_container cache -f generic-stable15.0 -o home_dataset=no -o tmp_dataset=yes -qq
```

No interaction. Creates the container with default datasets (var, usr-local,
tmp; no home), creates the inaugural commit, and exits. Bob will deploy and
start it separately.

---

## Command family summary

| Command | Purpose | Status |
|---------|---------|--------|
| `new_container` | Create minhag, datasets, inaugural commit | Implemented |
| `deploy_container` | Clone foundation to zbereshit, apply branch, start jail | Future |
| `save` | Detect changes, commit state + recipe | Future |
| `update_container` | Rebase onto new foundation, replay, reinstall | Future |
| `destroy_container` | Tear down container state (interactive per-item) | Future |
| `clone_container` | Duplicate a container as a new independent copy | Future |

---

## Lifecycle diagram

```
new_container ──→ deploy_container ──→ jail -c ──→ [running]
                                                       │
                                           save ←──────┘
                                             │
                           update_container ←┘ (rebase onto new foundation)
                                             │
                                     jail -c ──→ [running on new base]
                                                       │
                                   destroy_container ←─┘
```

---

## Open questions

1. **The .git problem**: See architecture notes above. Needs a design
   decision before `deploy_container` is implemented.

2. **mount.fstab ZFS backing**: The exact mechanism for getting ZFS
   datasets mounted at their zbamidbar paths so that nullfs can overlay
   them into the container. Options: `exec.prestart` ZFS mount commands,
   or setting dataset mountpoints and relying on pool import.

3. **Foundation replication trigger**: When should
   `zbereshit/foundations/<name>@<artifact>` be created? During
   `new_foundation` (eager)? During first `deploy_container` that needs
   it (lazy)? Both have trade-offs.

4. **Concurrent mount management**: Current helpers use greedy unmounting.
   Needs reference-counted mounts or a mount broker for safe concurrency.
   See architecture notes.
