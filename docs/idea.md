# Project Mishkan, a composable, easy to update, thin interface to your FreeBSD computer.

## Overview

The mishkan was the Israelites' portable residence of Hashem. Much like the mishkan, this project creates a framework for portably moving your computer around a wilderness of scrap files and "mold" -- the cruft from misfiring ideas and dependency installs that ended up not doing what you wanted them to.

# Important

- We are using ZFS as our underlying filesystem
- We are on FreeBSD, NOT Linux. Do not rely on Linux knowledge. You may double check any of your work.
- Write /bin/sh compatible scripts, and shebang them. Do not rely on bash-isms.
- When reading a man page, use a simple pager: `man -P cat`.
- Container and jail are synonyms. We do not use docker, etc. A container is a jail.

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

## Bootstrap phase 1: Mishkan dataset organization

Within these pools, mishkan controls an authoritative layout of the system.

- zbereshit/
  - systems/          Root dataset for the active boot system, and any other inactive, but cross-bootable, systems. The active dataset will be mounted at /, and the other datasets are unmounted, though could be mounted at /systems
  - containers/       Root dataset for containers, mounted at /containers
- zshemot/
  - torah/            The FreeBSD src repository
  - mishkan/          The mishkan framework itself (public git repo clone)
    - minhag/         Literally "customs". User configuration per target. See below.
    - etc/            Defaults shipped with mishkan (derivation databases, jail.conf template)
  - tablets/          Build location for zshemot/torah
    - var/            Mounted separate var dataset
- zbamidbar/
  - container-data/   Root dataset for container data. Each container's dataset, eg container-data/[container-name]/home, lives under a child dataset of the container's name, and is mounted in under the container's real root after zbereshit has been properly configured. (more on this in later phases). Includes usr-local (packages), var, and home.
  - system-data/      Identical to container-data/ above, but for systems.
  - sinai/            Long-term storage for git repos and ZFS archives
    - tablets.git     Bare git remote for system/container delta chains (zbereshit's remote)
    - tablets.zfs     ZFS send/recv archive, indexed by target name
    - mishkan.git     Bare git remote for the mishkan config repo (zshemot/mishkan's local remote)

  Unless otherwise noted (zbereshit/containers, zbamidbar/container-data zbamidbar/system-data), all datasets are mounted at their logical mount point, eg /[pool-name]/[dataset-hierarchy]/

### Phase Summary:

The boostrap phase should be one interactive shell function which asks the user for disk lists (eg ada0 ada1) and zpool keywords (eg mirror) to pass to zpool-create(8). Simply pass their string to zpool create and retry if failed, and surface the error. Ask for each of the three main data pools in a mishkan system. After that, it should perform the entire bootstrap format phase of all disks. NOTE: Do not allow the user to overwrite the currently running disk. Check for root access before starting, as zfs will require it. Perform interactive password input for the geli passwords. Write a help message for the function.
IMPORTANT: Do not ever test this function without permission. You can overwrite the entire system this way.
Future: migrate to bsddialog(1)

# Intermission: Pool philosophy

The three pools serve distinct roles:

- **zbereshit** (running pool): The result of all our scripting, scaffolding,
  and foreign mounts. This is what's actually running — live systems and
  containers with their delta chains committed to git. Its remote is
  zbamidbar/sinai/tablets.git.
- **zshemot** (config pool): Where the scaffolds and scripts live. Basically
  just a clone of the mishkan repo, plus the FreeBSD src tree and the build
  workspace. Its local remote is zbamidbar/sinai/mishkan.git.
- **zbamidbar** (data lake): Heavy data and accountable foreign mounts.
  Container and system data datasets (usr-local for packages, var, home) are
  stored here and mounted on top of zbereshit containers/systems before
  startup. Also stores the bare git remotes and ZFS archives in sinai/.

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

On save, `mishkan-diff` collects the full package list into `pkg.list` in
the target's minhag directory. On rebase or fresh start, if the usr-local
dataset already exists, `pkg upgrade` / `pkg install` updates it
incrementally rather than reinstalling from scratch.

## Save workflow

Saving a system or container is a single interactive session that produces
two git commits:

### Commit 1: zbereshit (system tree → zbamidbar/sinai/tablets.git)

1. Run `mishkan-diff` against the live tree
2. Auto-classify changes:
   - Text files → `git add` (automatic)
   - Known derived binaries → verified, no action needed
   - Already git-tracked binaries → environment state, no action needed
3. Prompt for unclassified binaries:
   - `[d]` derived → writes to minhag target's `derivations.local`
   - `[e]` environment → `git add` the binary file
   - `[c]` command → writes to minhag target's `compose.ini`
   - `[s]` skip → will ask again next time (blocks rebase)
4. Regenerate `etc/mtree/system.dist`
5. Commit the delta to the zbereshit branch

### Commit 2: zshemot (mishkan repo → zbamidbar/sinai/mishkan.git)

1. Collect changes produced by commit 1's classification:
   - Updated `derivations.local` (new `[d]` entries)
   - Updated `compose.ini` (new `[c]` entries)
   - Updated `pkg.list` (full package list from `pkg info`)
2. Commit to the mishkan repo

The zbereshit commit records the *state*. The zshemot commit records the
*recipe*. Together they fully describe how to reproduce or rebase the
target.

# Concept 1: Releases

## Phase 0: Build Upgrade

The next thing we have to do after bootstrapping our entire layout is build a system template (or at least provide the functionality).

### Minhag config layout

To properly drive mishkan for anything other than bootstrapping, we need
configuration files. Because zbereshit is ephemeral (it's a system that can
be torn down or rebuilt *through* the mishkan framework), the standard
~/.config/ location isn't durable enough. Configuration lives under
`zshemot/mishkan/minhag/`, inside the mishkan repo clone.

The repo itself is cloned into `zshemot/mishkan/`. It ships with default
derivation databases, a jail.conf template, and stage scripts. User
configuration lives under `minhag/` within the repo — separated visually
into systems and containers but structurally identical to the framework.

```
zshemot/mishkan/
  mishkan.conf                  Mishkan-wide build defaults. Provides fallback
                                values for all targets. sysrc(8) format.
  etc/                          Shipped with the framework (public, upstream)
    derivations/                Default text→binary derivation databases
      stable-14.db              per FreeBSD branch
      stable-15.db
    jail.conf                   Default jail.conf, includes minhag/jail.conf.d/*
  minhag/
    systems/                    Per-system target directories
      [system-name]/
        build.conf              Build overrides (SRC_BRANCH, KERNCONF, etc.)
                                Two-tier: values here override mishkan.conf.
                                An empty file builds a default kernel + world.
        compose.ini             Opaque replay commands (category 5 only)
        derivations.local       Custom text→binary derivation entries
        pkg.list                Packages to install (auto-populated or manual)
    containers/                 Per-container target directories
      [container-name]/
        build.conf              Same shape as systems. No kernel config needed.
        compose.ini
        derivations.local
        pkg.list
        jail.conf               Jail configuration for this container
    jail.conf.d/                Symlinked or included by etc/jail.conf
```

Scripting does not need to distinguish between systems and containers.
The hierarchy is visual. In code, a target is a system if `build.conf`
specifies a kernel config (KERNCONF), and a container if `jail.conf` is
present. These are not mutually exclusive.

Build configuration is two-tier: `mishkan.conf` provides defaults,
`build.conf` provides per-target overrides. The effective config for any
build is the maximal set of both, preferring `build.conf` where values
overlap. `sysrc -f` can query either file.

### Build process

The series of steps is as follows:

1) Check if zshemot/torah (/zshemot/torah) is a git repo. If not, confirm with the user that we should clone the FreeBSD source repo https://git.freebsd.org/src.git into it.
2) get the target name to build.
3) search /zshemot/mishkan/minhag/systems/[target-name]/ and /zshemot/mishkan/minhag/containers/[target-name]/ for a build.conf.
4) If it doesn't exist, warn the user and ask if a target directory should be created (and whether it's a system or container). If no, assume the target name was a typo and back out. If yes, create the target directory with an empty build.conf and continue.

NOTE: Configuration is two-tier. For any variable lookup, first check the target's build.conf, then fall back to mishkan.conf. The effective config is the maximal set of both, preferring build.conf for overridden values. Use `sysrc -f` to query these files. If the variable exists in neither, surface an error if optional, or stop completely if mandatory. Set new variables in the most private scope (the target's build.conf, not mishkan.conf).

5) search for the variable SRC_BRANCH, and check out that branch from the src repo. If the variable doesn't exist, list the available branches on the remote and ask to set one. The user should be able to select a branch via name or via list item number (number the branches as you output the options).
6) sync to head, destroying any local changes (warn the user before doing so if any local changes exist).
7) If zbamidbar/sinai/tablets.zfs/[system-name] exists, zfs send it and zfs recv it into /zshemot/tablets and clear out the build directory /zshemot/tablets entirely of any artifacts, and confirm it's ready for us. (we need to be on the latest zfs snapshot for that system's build tree for a reason later). If that dataset doesn't exist, just make sure /zshemot/tablets exists and is empty.
8) build, using `make -j12` inside the src dir with the following targets, in order
  1) buildworld
  2) buildkernel
  NOTE: for the following targets, since they move from src to dest, we must define a custom DESTDIR=/zshemot/tablets, since that's our mishkan-wide artifact build dir (eg `make DESTDIR=/zshemot/tablets -j12 installkernel)
  3) installkernel
  4) installworld
  5) distribution     (this target actually finishes giving permissions and final touches. A build is not complete without it).
If any portion of this build phase fails, tell the user and stop, reporting which phase we were on.
FUTURE GOAL: allow each system to also include a make env file to control kernel and world configuration variables (see build(8) and src.conf(5))
9) make an mtree file called /zshemot/tablets/etc/system.dist
  - A good starting point is `tree -c -x -R time,nlink,flags -K sha512 -p . > "etc/mtree/system.dist"` which works if you're in the /zshemot/tablets root dir of the built distribution. see mtree(8) for detail on flags, but here's an explanation:

> Use `-R` to remove the flag options time, nlink, and flags because git clobbers hardlinks and I can't ever fix that, so why cache it, flags are used by zfs to let us know there's a snapshot and we can't control that on the git-clone side, and because time modified is not something I care about tracking. Use -x to not descend below mountpoints. Use `-K` to add the sha512 hash to the file to determine file integrity. Finally, use `-c` to print a config.

10) Initialize a new git repo in our dest dir, /zshemot/tablets and point the remote to /zbamidbar/sinai/tablets.git. Since the dir is non-empty, you will have to force this operation.

11) commit everything and write a templated commit message with an artifact name including the system name. You can derive the artifact name I want like so (run on the torah dataset in /zshemot/torah to get the right source rev and branch) I'd also like the system name stapled onto the end of the artifact name, like `_${system_name}`. Add that to this function.:
```
get-artifact-name() {
	local repo="${1:-}"
	[ -d "${repo}/.git" ] || error "${repo} doesn't look like a git repo\n" || return
	local artifact_name="$(git -c "${repo}" rev-parse --abbrev-ref head | tr '/' '-')"
	artifact_name="${artifact_name}_$(date -i)"
	artifact_name="${artifact_name}_$(git -c "${repo}" rev-parse --short head)"
	echo "${artifact_name}"
}
```

12) commit everything and write a templated commit message with the aforementioned artifact name including the system name
13) take a snapshot of the built dataset with the aforementioned snapshot naming scheme.
14) send this dataset to /zbamidbar/sinai/tablets.zfs/[system-name]. If the dest dataset already exists, we can do a snapshot incremental send, and if it doesn't, we'll have to send the whole stream. See zfs-send(8) and zfs-receive(8) for more information.

### Phase Summary:

The purpose of this phase is to create a cleanroom environment to build clean upgrades from source, and to commit those upgrades to a git repo on our large zbamidbar disk. We will eventually cleverly use a mix of scripting, zfs, and git to re-compose customized systems from this starting point, but first we must successfully make and track a build. At this point we should have a built artifact, with a system name, an mtree for tracking permissions git drops, a git commit for tracking file deltas across revisions, and a cold storage of the whole zfs dataset as an incremental change from the same system config build (useful when we start building custom kernels later) in a system specific dataset tree on our data-lake.

## Phase 2: Rebase

[TODO]

## Phase 3: Reflash

[TODO]

# Concept 2: Container orchestration

Containers and systems share the same tracking and rebase machinery.
A container is structurally identical to a system — same delta chain, same
stratified change tracking, same rebase procedure. The differences are:

- A container has a `jail.conf` in its minhag target directory
- A container does not build or install a kernel
- A container lives on zbereshit/containers, not zbereshit/systems
- A container is started by jail(8), not the boot loader

In scripting, the distinction is detected by file presence (jail.conf =
container, KERNCONF in build.conf = system), not by directory hierarchy.
The hierarchy (minhag/systems/ vs minhag/containers/) is for human
readability only.

Container target directories live at
`/zshemot/mishkan/minhag/containers/[container-name]/` and contain the same
files as system targets: build.conf, compose.ini, derivations.local,
pkg.list, plus a jail.conf.

To appropriate the resources for a container, the BASE_SYSTEM artifact
(specified in build.conf) is found in
zbamidbar/sinai/tablets.zfs/[system-name]@[artifact-name]. We use zfs-send
and zfs-recv to copy this pristine build artifact from zbamidbar to
zbereshit/containers/[container-name]@[artifact-name]. The subordinate var/
dataset is sent from zbamidbar/sinai to
zbamidbar/container-data/[container-name]/var. Why not clone, since it's in
the same pool? var/ doesn't relate to the release, and its tracking will be
done via git. This container-data dataset is mounted into /containers so it
overlays on top of the jail's root tree from
zbereshit/containers/[container-name]. Two more container-data datasets are
created: container-data/[container-name]/usr-local, which mounts at
/containers/[container-name]/usr/local for packages, and
container-data/[container-name]/home.

After resources are appropriated, start the jail with jail(8). Install
packages from pkg.list, then run compose.ini commands.

## Zoom out and filling in the missing blanks

What about that missing git link? We haven't really explained that at all. What's the conflict between Concept 1 and Concept 2?

The overarching idea of both systems and containers is this. Build a clean system, build an mtree to track permissions lost by git, track all base system files via git, and then beam it up to the safe data lake pool.

The problem comes when the user starts making tweaks. If, for example, they change an etc/ file, that's a text file and can be really well tracked in git. For example, when the user wishes to save a running system's deltas from the base system, we could generate a new mtree for the new files, add all new or modified files, and commit that all up to git. This works pretty well for text files, and runs into problems with binary files. There's also the problem of the var/ and usr/local directorys in a pure git world. Var changes every session, so we end up with a ton of binary noise in var every time we save deltas. usr/local is huge and full of binary files. It's not worth tracking all that with git.

So we then send those off to new datasets in the data-lake and mount them into the filesystem where they should live, so the directory tree sees a complete system. In a .gitignore we should ignore all mounted in filesystems (Not discussed above, but we will explain the finer points later).

Finally, git breaks down under one last issue. If the user adds a new user to the system or jail, the passwd file is binary, and becomes a binary diff when we want to rebase the system changes onto an updated base system. This doesn't resolve naturally in git.

So to solve these breakdowns we introduce composition files, as talked about in Concept 2. composition files allow us to simply write down the commands we need to take from the base system to get where we are, which saves the issue of binary diffs and unaccountable mounted directories, but come with an obvious drawback. We must remember everything we do, and if we ever forget to write something down in the composition file, we'll fail to perform it after a system upgrade, and that will result in a broken system, potentially months after we've forgotten what worked and what we failed to log down. Git fixes these deficiencies by tracking all files and playing backstop for us and our wild sysadmin attempts to just get something to work.

The right answer, of course, lives somewhere in the middle. The key insight
is that different kinds of changes have different replay strategies, and
trying to force them all through one mechanism (pure git OR pure compose)
is where the burden comes from. In a perfect world we:

- Use git to track all non-foreign-mounted text file changes (automatic)
- Update the composition file's package list against the package database's
  list of installed first-class (non-dependencies) packages (automatic)
- For known derived binaries (pwd.db from master.passwd, login.conf.db from
  login.conf): merge the text source via three-way merge, then regenerate the
  binary via the known command (pwd_mkdb, cap_mkdb, etc.). No compose entry
  needed — the derivation relationships are well-known and ship with mishkan.
- For environment state (SSH host keys, SSL certs, keytabs): git-track the
  binary directly. These are small, rarely change, and should be preserved
  across rebases, not regenerated. On conflict, keep ours.
- For everything else: the composition file. But because the other categories
  are handled automatically, the compose file shrinks to only the genuinely
  irreducible commands — opaque binary producers that can't be auto-detected
  or derived.

Detection uses mtree: the build phase produces `etc/mtree/system.dist` with
sha512 content hashes. A `mishkan-diff` tool compares the live filesystem
against this baseline and auto-classifies what it can (text → git, derived
binary → derivations.db, already git-tracked → environment state). Only
truly unknown binaries require admin input, and the classification prompt
happens at detection time (when the change is fresh in memory), not at
rebase time (months later).

Rebase ordering is critical: compose runs first (packages + commands on
the new base), then git rebase (text files + environment state), then
derived binary regeneration, then validation.

See [drift_manifest.md](drift_manifest.md) for the full design.

# Addendum with context: Blending Concept 1 and 2

Edit to Concept 1 Phase 1: When we either beam down the tablets.zfs system we're upgrading or create a new clean directory, recursively send so that we get the var/ dataset too, or create a new var/ dataset locally to zshemot. This is important because a new base system does involve a few files in var/

Edit 2 to Concept 1 Phase 1: We want to track all these foreign-mount files from the base system (eg in var. None exist in home/ or usr/local), but we don't want to track any further files in them. So we should:

1) build complete system
2) make mtree
3) add all files to git
4) make .gitignore with var/ usr/local/ home/
5) add .gitignore
6) commit

This keeps us tracking the base system files in var, but bans tracking any further files.

# Helpers: A useful composition

Useful tiny functions should be created and used widely. Most to all of these tiny functions should be available to the mishkan system administrator, and should be sourced on login.

### msysrc [sys] [var] - a function interface to sysrc that checks the system or container and the system-wide config files for the variable.
