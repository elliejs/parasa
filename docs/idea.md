# Project Parasa, a composable, easy to update, thin interface to your FreeBSD computer.

## Overview

A parasa (parasang) is an ancient unit of distance — the length of a journey, not the destination. This project is named for that idea: parasa measures and manages the distance between a pristine FreeBSD build and your running system. It creates a composable framework for tracking, versioning, and deploying your system state across a wilderness of configuration drift and accumulated cruft.

# Important

- We are using ZFS as our underlying filesystem
- We are on FreeBSD, NOT Linux. Do not rely on Linux knowledge. You may double check any of your work.
- Write /bin/sh compatible scripts, and shebang them. Do not rely on bash-isms.
- When reading a man page, use a simple pager: `man -P cat`.
- Container and jail are synonyms. We do not use docker, etc. A container is a jail.
- Use underscores, not kebab-case, for all parasa function and command names (e.g. `parasa_bootstrap`, not `parasa-bootstrap`).
- All implementation plans and design outlines go in `plans/` at the repo root. Keep good records — this project has many moving pieces.

# Concept 0: Bootstrapping

## Phase 0: Hardware setup
Our system comes pre-equipped with three zfs pools set up how I want, but we should write bootstrapping scripts for the github anyway.

```
##
# GELI
##
#  -l -- keylen 256 (AES-XTS)
#  -s -- 4k sectors
#  -B -- no backup files (add to datalake later)

# zbereshit
#  -b -- decrypt during boot
#  -g -- bootable, use interactive decrypt
geli init -B none -bg -l 256 -s 4096 nda0p4
geli attach nda0p4
# zshemot
geli init -B none -b -l 256 -s 4096 ada0
geli attach ada0
# zbamidbar
geli init -B none -b -l 256 -s 4096 ada1
geli attach ada1
# forgot to do this?
# geli configure -b [prov]

##
# GLABEL
##
# zbereshit
glabel label glados nda0.eli
# zshemot
glabel label wumpus ada0.eli
# zbamidbar
glabel label grue ada1.eli

##
# ZPOOL
##
ZPOOL_SETTINGS="-o ashift=12 -o autotrim=on"
zpool create ${POOL_SETTINGS} zbereshit label/glados
zpool create ${POOL_SETTINGS} zshemot label/wumpus
zpool create "${POOL_SETTINGS}" zbamidbar label/grue

DATASET_SETTINGS="atime=off"
DATASET_SETTINGS="${DATASET_SETTINGS} compression=zstd"
DATASET_SETTINGS="${DATASET_SETTINGS} aclmode=passthrough"
DATASET_SETTINGS="${DATASET_SETTINGS} mountpoint=none"
DATASET_SETTINGS="${DATASET_SETTINGS} canmount=noauto"

zfs set ${DATASET_SETTINGS} zbereshit
zfs set ${DATASET_SETTINGS} zshemot
zfs set ${DATASET_SETTINGS} zbamidbar


```

This bootstrap sequence first encrypts the drives in their entirety with geli(8) and then labels them with names of iconic videogame villains. The label allows us to build zpools on top of a tag that will not change if we change the order of the drives in the bay or add another drive. (editors note: in an ideal world we would label a drive and then encrypt the glabel(8) entity, which would theoretically allow us to see the label name on boot, so we don't have to quess which drive number designation is which entity, but this requires work in the bootloader to make happen. Perhaps a future project).

We then pass useful parameters to the creation of the zpools and zdatasets, which are pretty standard.

These pools have the following meaning:

- zbereshit: Literally "in the beginning". This is our boot pool, is a fast nvme, and should be our home base for running jails and the running system. It will house our root mountpoint dataset and the non-data portions of our running jails.
- zshemot: Literally "names". The second book of the torah, this is the name and configuration index for our entire project. If our boot pool dies, this data pool should allow us to recover the configurations used to construct the boot pool.
- zbamidbar: Literally "in the wilderness". The fourth book of the torah, this pool is our data lake. It contains all manner of large data stores and is 8 Terabytes in size. Things like: Jail user directories, pkg install directories, build repositories.

## Bootstrap phase 1: Parasa dataset organization

Within these pools, parasa controls an authoritative layout of the system.

- zbereshit/
  - foundations/      Clone source for containers (replicated from zbamidbar/sinai.zfs)
  - systems/          Root dataset for the active boot system, and any other inactive, but cross-bootable, systems. The active dataset will be mounted at /, and the other datasets are unmounted, though could be mounted at /systems
  - containers/       Root dataset for containers, mounted at /containers. Each container is a ZFS clone from zbereshit/foundations/
- zshemot/
  - torah/            The FreeBSD src repository
  - parasa/          The parasa framework itself (public git repo clone)
    - recipes/         Literally "customs". User configuration per target. See below.
    - etc/            Defaults shipped with parasa (derivation databases, jail.conf template)
  - amim/             Literally "peoples". Per-name build workspaces (concurrent-safe)
    - [name]/         One per foundation/system/container being built. Transient.
      - var/          Separate var dataset (also transient)
- zbamidbar/
  - container-data/   Root dataset for container data. Each container's dataset, eg container-data/[container-name]/home, lives under a child dataset of the container's name, and is mounted in under the container's real root after zbereshit has been properly configured. (more on this in later phases). Includes usr-local (packages), var, and home.
  - system-data/      Identical to container-data/ above, but for systems.
  - sinai.git         Bare git remote for foundation/system/container branches
  - sinai.zfs         ZFS send/recv archive (foundations only — systems tracked by git+mtree+compose)
    - foundations/    Pristine ZFS archives of each foundation build
  - parasa.git       Bare git remote for the parasa config repo (zshemot/parasa's local remote)

  Unless otherwise noted (zbereshit/containers, zbamidbar/container-data zbamidbar/system-data), all datasets are mounted at their logical mount point, eg /[pool-name]/[dataset-hierarchy]/

### Phase Summary:

The boostrap phase should be one interactive shell function which asks the user for disk lists (eg ada0 ada1) and zpool keywords (eg mirror) to pass to zpool-create(8). Simply pass their string to zpool create and retry if failed, and surface the error. Ask for each of the three main data pools in a parasa system. After that, it should perform the entire bootstrap format phase of all disks. NOTE: Do not allow the user to overwrite the currently running disk. Check for root access before starting, as zfs will require it. Perform interactive password input for the geli passwords. Write a help message for the function.
IMPORTANT: Do not ever test this function without permission. You can overwrite the entire system this way.
Future: migrate to bsddialog(1)

# Intermission: Pool philosophy

The three pools serve distinct roles:

- **zbereshit** (running pool): The result of all our scripting, scaffolding,
  and foreign mounts. This is what's actually running — live systems and
  containers with their delta chains committed to git. Its remote is
  zbamidbar/sinai.git.
- **zshemot** (config pool): Where the scaffolds and scripts live. Basically
  just a clone of the parasa repo, plus the FreeBSD src tree. The build
  workspaces live under zshemot/amim/ — one per build, named after the
  target. Created on demand, destroyed after use. Concurrent-safe. Its local remote is
  zbamidbar/parasa.git.
- **zbamidbar** (data lake): Heavy data and accountable foreign mounts.
  Container and system data datasets (usr-local for packages, var, home) are
  stored here and mounted on top of zbereshit containers/systems before
  startup. Also stores the bare git remote (sinai.git) and ZFS foundation
  archives (sinai.zfs).

## zdataset hygiene

Datasets should follow a least-mounted policy. If a dataset can be
unmounted, it should be. Generally mounted datasets are: the active
zbereshit/system (mounted at /), the corresponding zbamidbar/system-data
mounts, zbereshit/containers, and the corresponding zbamidbar/container-data
mounts. Most other datasets should be default unmounted and only mounted
for script running purposes.

## Package handling

The base artifact is built from source (`make installworld`) and contains no
packages. Every package on a running system or container is admin-added.
The full `pkg info` output IS the delta from the base — no diffing needed.

Packages live on zbamidbar in the target's data dataset:
`zbamidbar/[system|container]-data/[name]/usr-local`, mounted at
`/usr/local` (systems) or `/containers/[name]/usr/local` (containers).

On save, `parasa-diff` collects the full package list into `pkg.list` in
the target's recipes directory. On rebase or fresh start, if the usr-local
dataset already exists, `pkg upgrade` / `pkg install` updates it
incrementally rather than reinstalling from scratch.

## Save workflow

See [save_workflow.md](save_workflow.md) for the full save workflow design.

# Concept 1: Releases

## Phase 0: Build Upgrade

The next thing we have to do after bootstrapping our entire layout is build a system template (or at least provide the functionality).

### Recipe config layout

To properly drive parasa for anything other than bootstrapping, we need
configuration files. Because zbereshit is ephemeral (it's a system that can
be torn down or rebuilt *through* the parasa framework), the standard
~/.config/ location isn't durable enough. Configuration lives under
`zshemot/parasa/recipes/`, inside the parasa repo clone.

The repo itself is cloned into `zshemot/parasa/`. It ships with default
derivation databases, a jail.conf template, and stage scripts. User
configuration lives under `recipes/` within the repo — separated visually
into systems and containers but structurally identical to the framework.

```
zshemot/parasa/
  parasa.conf                  Parasa-wide build defaults. Provides fallback
                                values for all targets. sysrc(8) format.
  etc/                          Shipped with the framework (public, upstream)
    derivations/                Default text→binary derivation databases
      stable-14.db              per FreeBSD branch
      stable-15.db
    jail.conf                   Default jail.conf, includes recipes/jail.conf.d/*
    mtree.ignore                Paths to exclude from mtree (ships with parasa)
  recipes/
    foundations/                 Build configurations (shared across systems/containers)
      [foundation-name]/
        build.conf              SRC_BRANCH, KERNCONF, MAKE_JOBS, etc.
                                Two-tier: values here override parasa.conf.
    systems/                    Per-system target directories
      [system-name]/
        [foundation].foundation Contains artifact name (patch level).
                                Filename = foundation identity (stream+major.minor).
        compose.sh              Opaque replay commands (see drift_manifest.md, category 5)
        derivations.local       Custom text→binary derivation entries
        mtree.dist              Baseline mtree for the target
        pkg.list                Packages to install (auto-populated or manual)
    containers/                 Per-container target directories
      [container-name]/
        [foundation].foundation Contains artifact name (patch level)
        compose.sh
        derivations.local
        mtree.dist
        pkg.list
        jail.conf               Jail configuration for this container
        mount.fstab             All container mounts (processed by jail start/stop).
                                Use `# shared` comment to mark cross-referenced datasets.
    jail.conf.d/                Symlinked or included by etc/jail.conf
```

### Foundations

A **foundation** is a build configuration that produces a pristine
FreeBSD world+kernel. Build config (SRC_BRANCH, KERNCONF, MAKE_JOBS)
lives in `recipes/foundations/<name>/build.conf`. Systems and containers
are built **on top of** a foundation — they don't carry their own build
config.

Each system/container has exactly one file named
`<foundation-name>.foundation` in its recipes dir. The filename encodes
the foundation identity (stream + major.minor, e.g.,
`generic-stable15.0.foundation`). The file **contains the artifact name**
(patch level / ZFS snapshot tag). On a patch-level update, rewrite the
contents. On a stream/major.minor change, rename the file and write the
new artifact name.

Reading: `basename "$(ls "$dir"/*.foundation)" .foundation` for the
foundation name; `cat "$dir"/*.foundation` for the artifact name.
Multiple `.foundation` files = error.

Foundation names should include the FreeBSD major.minor version:
`generic-stable15.0`, not `generic-stable15`.

This eliminates the ideological difference between systems and
containers. What differentiates them is how you use them, not how they
are built. A container has a `jail.conf`; a system has a KERNCONF in its
foundation's `build.conf`. These are not mutually exclusive.

### zbereshit/foundations — clone hierarchy

Each foundation exists in two places:

- `zbamidbar/sinai.zfs/foundations/<name>@<artifact>` — canonical archive
- `zbereshit/foundations/<name>@<artifact>` — deployment clone source
  (replicated from zbamidbar via `zfs send | recv`)

Containers (and optionally systems) are ZFS **clones** from the
zbereshit copy. Two containers at the same patch level share all base
blocks. Even containers at different patch levels share most blocks
through the incremental snapshot chain. Old snapshots on
zbereshit/foundations can be pruned once no clone references them.

### Git branch naming in sinai.git

- `foundation/<name>` — pristine world+kernel build (orphan branch)
- `system/<name>` — forks from a foundation commit; inaugural commit writes /etc/fstab
- `container/<name>` — forks from a foundation commit

### Mount architecture

**Systems** use `/etc/fstab` inside the system (git-tracked). Data-lake
mounts (var, tmp, usr/local, home, custom) are written during the
inaugural commit. All mounts go in one place — no split.

**Containers** use `recipes/containers/<name>/mount.fstab`, which is
referenced by the container's jail.conf. The jail framework processes
these entries at jail start and reverses them at jail stop. All
container mounts — data-lake, custom, shared — go in this one file.
Shared datasets (cross-referenced by multiple containers) are marked
with `# shared` comments for parasa tooling to detect dependencies.

Why fstab over `zfs set mountpoint=`: fstab is per-system/container
(one value per consumer), `zfs set mountpoint=` is per-dataset (one
value total). Shared datasets can mount at different paths on different
containers. FreeBSD `mount -a` with `late` handles ZFS after pool import.

### Command family

| Command | Purpose |
|---------|---------|
| `new_foundation` | Build world+kernel from source, archive to zbamidbar |
| `new_system` | Create a system on top of a foundation, optionally deploy |
| `new_container` | Create a container on top of a foundation |
| `deploy_system` | Deploy an archived system to zbereshit for boot |
| `update_system` | Rebuild/upgrade an existing system onto a new foundation |
| `edit_system` | Interactively edit system metadata, fstab, recipes config |
| `destroy_system` | Tear down a system |

See `plans/build_system.md` for the full implementation plan.

Build configuration is two-tier: `parasa.conf` provides defaults,
`build.conf` (in the foundation) provides per-target overrides. The
effective config for any build is the maximal set of both, preferring
`build.conf` where values overlap. `sysrc -f` can query either file.

### Build process (new_foundation)

Building is now a two-step process: first build a **foundation** (pristine
world+kernel), then create **systems** or **containers** on top of it.

`new_foundation` creates a transient `zshemot/amim/<name>` workspace,
builds from `zshemot/torah`, commits to an orphan `foundation/<name>`
branch on `zbamidbar/sinai.git`, snapshots and archives to
`zbamidbar/sinai.zfs/foundations/<name>`, then destroys the workspace.

The foundation .gitignore covers `var/`, `usr/local/`, `tmp/` only — NOT
`home/`. Whether to gitignore home is per-system/container, decided during
`new_system`/`new_container`.

mtree is generated with `mtree -c -x -R time,nlink,flags -K sha512` and an
ignore file (`etc/mtree.ignore`, containing `.git`). See helpers.sh
`generate_mtree()`.

The artifact name is derived from the src branch, date, and short SHA via
`get_artifact_name()` in helpers.sh.

### System/container creation (new_system)

`new_system` takes an existing foundation and creates a system on top of it.
The core operation is the **inaugural commit** — a commit on `system/<name>`
branching from `foundation/<name>` that writes data-lake mount entries into
`/etc/fstab` (var, tmp, usr/local are always included; home is optional).

The ZFS flow: `zbamidbar/sinai.zfs/foundations/<name>` recv to
`zshemot/amim/<system-name>` (temporarily), branch and commit, push,
destroy workspace. If there are no fstab changes, the branch is created
on the bare repo without recv'ing.

### Deployment (deploy_system)

`deploy_system` sends a foundation's ZFS dataset from zbamidbar to
`zbereshit/systems/<name>`, then applies the system branch via git checkout
to layer system-specific state (fstab entries, etc.) on top.

Deploy resolves the right ZFS snapshot by tracing the system branch back to
its foundation fork-point — the foundation commit's message IS the artifact
name, which is the ZFS snapshot tag.

Optional `-n` flag sets `nextboot -e vfs.root.mountfrom="zfs:zbereshit/systems/<name>"`
for one-shot boot with auto-revert on failure. `mountpoint=/` is only set
when nextboot is enabled.

See `plans/build_system.md` for the full implementation plan with execution
flows, argument parsing, and phase details.

## Phase 2: Rebase

[TODO]

## Phase 3: Reflash

[TODO]

# Concept 2: Container orchestration

Containers and systems share the same tracking and rebase machinery.
A container is structurally identical to a system — same delta chain, same
stratified change tracking, same rebase procedure. The differences are:

- A container has a `jail.conf` in its recipes target directory
- A container does not build or install a kernel
- A container lives on zbereshit/containers, not zbereshit/systems
- A container is started by jail(8), not the boot loader

In scripting, the distinction is detected by file presence (jail.conf =
container, KERNCONF in build.conf = system), not by directory hierarchy.
The hierarchy (recipes/systems/ vs recipes/containers/) is for human
readability only.

Container target directories live at
`/zshemot/parasa/recipes/containers/[container-name]/` and contain the same
files as system targets: compose.sh, derivations.local, mtree.dist,
pkg.list, plus a jail.conf and mount.fstab.

To appropriate the resources for a container, the foundation artifact
is found via the container's `.foundation` file and resolved through
`zbamidbar/sinai.zfs/foundations/<foundation>@<artifact>`. The foundation
is replicated to `zbereshit/foundations/<foundation>@<artifact>` if not
already present, and the container is created as a ZFS **clone** from
that snapshot. This gives block-level deduplication: containers at the
same patch level share all base blocks.

Data-lake datasets (var, usr-local, home) live under
`zbamidbar/container-data/[container-name]/`. var is copied from the
foundation archive (independent copy of pristine var). usr-local and
home are created empty.

Container data-lake mounts use jail(8)'s native `mount.fstab` mechanism.
Each container's jail.conf references a mount.fstab file in recipes that
maps zbamidbar data datasets into the container path. The jail framework
processes these at jail start and reverses them at jail stop — no manual
mount/unmount needed. The host's `/etc/jail.conf` includes container
configs via `include "/zshemot/parasa/recipes/containers/*/jail.conf"`.

See `docs/user_stories_containers.md` for the full container lifecycle.

## Zoom out and filling in the missing blanks

What about that missing git link? We haven't really explained that at all. What's the conflict between Concept 1 and Concept 2?

The overarching idea of both systems and containers is this. Build a clean system, build an mtree to track permissions lost by git, track all base system files via git, and then beam it up to the safe data lake pool.

The problem comes when the user starts making tweaks. If, for example, they change an etc/ file, that's a text file and can be really well tracked in git. For example, when the user wishes to save a running system's deltas from the base system, we could generate a new mtree for the new files, add all new or modified files, and commit that all up to git. This works pretty well for text files, and runs into problems with binary files. There's also the problem of the var/ and usr/local directorys in a pure git world. Var changes every session, so we end up with a ton of binary noise in var every time we save deltas. usr/local is huge and full of binary files. It's not worth tracking all that with git.

So we then send those off to new datasets in the data-lake and mount them into the filesystem where they should live, so the directory tree sees a complete system. In a .gitignore we should ignore all mounted in filesystems (Not discussed above, but we will explain the finer points later).

Finally, git breaks down under one last issue. If the user adds a new user to the system or jail, the passwd file is binary, and becomes a binary diff when we want to rebase the system changes onto an updated base system. This doesn't resolve naturally in git.

So to solve these breakdowns we introduce composition files, as talked about in Concept 2. composition files allow us to simply write down the commands we need to take from the base system to get where we are, which saves the issue of binary diffs and unaccountable mounted directories, but come with an obvious drawback. We must remember everything we do, and if we ever forget to write something down in the composition file, we'll fail to perform it after a system upgrade, and that will result in a broken system, potentially months after we've forgotten what worked and what we failed to log down. Git fixes these deficiencies by tracking all files and playing backstop for us and our wild sysadmin attempts to just get something to work.

The right answer, of course, lives somewhere in the middle. The key insight
is that different kinds of changes have different replay strategies, and
trying to force them all through one mechanism (pure git OR pure compose.sh)
is where the burden comes from. In a perfect world we:

- Use git to track all non-foreign-mounted text file changes (automatic)
- Update the composition file's package list against the package database's
  list of installed first-class (non-dependencies) packages (automatic)
- For known derived binaries (pwd.db from master.passwd, login.conf.db from
  login.conf): merge the text source via three-way merge, then regenerate the
  binary via the known command (pwd_mkdb, cap_mkdb, etc.). No compose.sh entry
  needed — the derivation relationships are well-known and ship with parasa.
- For environment state (SSH host keys, SSL certs, keytabs): git-track the
  binary directly. These are small, rarely change, and should be preserved
  across rebases, not regenerated. On conflict, keep ours.
- For everything else: the composition file. But because the other categories
  are handled automatically, compose.sh shrinks to only the genuinely
  irreducible commands — opaque binary producers that can't be auto-detected
  or derived.

Detection uses mtree: the build phase produces `mtree.dist` (in the target's recipes directory) with
sha512 content hashes. A `parasa-diff` tool compares the live filesystem
against this baseline and auto-classifies what it can (text → git, derived
binary → derivations.db, already git-tracked → environment state). Only
truly unknown binaries require admin input, and the classification prompt
happens at detection time (when the change is fresh in memory), not at
rebase time (months later).

Rebase ordering is critical: compose.sh runs first (packages + commands on
the new base), then git rebase (text files + environment state), then
derived binary regeneration, then validation.

See [drift_manifest.md](drift_manifest.md) for the full design.

# Addendum with context: Blending Concept 1 and 2

Edit to Concept 1 Phase 1: When we recv a foundation from sinai.zfs to the transient amim workspace, recursively send so that we get the var/ dataset too, or create a new var/ dataset locally to zshemot. This is important because a new base system does involve a few files in var/

Edit 2 to Concept 1 Phase 1: We want to track all these foreign-mount files from the base system (eg in var. None exist in home/ or usr/local), but we don't want to track any further files in them. So we should:

1) build complete system
2) make mtree
3) add all files to git
4) make .gitignore with var/ usr/local/ home/
5) add .gitignore
6) commit

This keeps us tracking the base system files in var, but bans tracking any further files.

# Helpers: A useful composition

Useful tiny functions should be created and used widely. Most to all of these tiny functions should be available to the parasa system administrator, and should be sourced on login.

### msysrc [sys] [var] - a function interface to sysrc that checks the system or container and the system-wide config files for the variable.
