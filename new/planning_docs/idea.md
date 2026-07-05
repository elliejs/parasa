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
  - minhag/           Literally "customs", the user controllable config files for the mishkan system
  - tablets/          Build location for zshemot/torah
    - var/            Mounted separate var dataset
- zbamidbar/
  - container-data/   Root dataset for container data. Each container's dataset, eg container-data/[container-name]/home, lives under a child dataset of the container's name, and is mounted in under the container's real root after zbereshit has been properly configured. (more on this in later phases)
  - system-data/      Identical to container-data/ above, but for systems.
  - sinai/         A complete system-tracking git repo, for all system deltas from the built zshemot/tablets. (more on this in later phases)
    - tablets.git  Where the git repo lives
    - tablets.zfs  Where the zfs archive lives

  Unless otherwise noted (zbereshit/containers, zbamidbar/container-data zbamidbar/system-data), all datasets are mounted at their logical mount point, eg /[pool-name]/[dataset-hierarchy]/

### Phase Summary:

The boostrap phase should be one interactive shell function which asks the user for disk lists (eg ada0 ada1) and zpool keywords (eg mirror) to pass to zpool-create(8). Simply pass their string to zpool create and retry if failed, and surface the error. Ask for each of the three main data pools in a mishkan system. After that, it should perform the entire bootstrap format phase of all disks. NOTE: Do not allow the user to overwrite the currently running disk. Check for root access before starting, as zfs will require it. Perform interactive password input for the geli passwords. Write a help message for the function.
IMPORTANT: Do not ever test this function without permission. You can overwrite the entire system this way.
Future: migrate to bsddialog(1)

# Intermission: zdataset hygiene

datasets should follow a least-mounted policy. If a dataset can be unmounted, it should be. Generally mounted datasets will be the mounted zbereshit/system (mounted at /) the corresponding zbamidbar/system-data, mounted zbereshit/containers, and the corresponding zbamidbar/container-data. Most other datasets should be default unmounted and only mounted for script running purposes.

# Concept 1: Releases

## Phase 0: Build Upgrade

The next thing we have to do after bootstrapping our entire layout is build a system template (or at least provide the functionality).

### Minhag config layout

To properly drive mishkan for anything other than bootstrapping, we need configuration files. Of course, because zbereshit is more ephermeral than mishkan, (it's a system, which can be torn down or rebuilt *through* the mishkan framework), the standard ~/.config/ location of config files isn't durable enough for us. We will use /zshemot/minhag to store our config files. There are mishkan-wide configuration files and per-system and per-container files:

- zshemot/minhag/
  - mishkan.conf   mishkan system-wide configuration variables. (perhaps we can even utilize sysrc(8) to operate on this file?)
  - containers/    container-wide configuration files. (more on this later)
  - systems/       system-wide configuration files. (more on this in this section)

### Build process

The series of steps is as follows:

1) Check if zshemot/torah (/zshemot/torah) is a git repo. If not, confirm with the user that we should clone the FreeBSD source repo https://git.freebsd.org/src.git into it.
2) get the system name to build.
3) search /zshemot/minhag/systems/ for [system-name].conf
4) If it doesn't exist, warn the user and ask if it should be created. If no, assume the system name was a typo and back out. if yes, create the conf file and continue.

NOTE: any time a config file search is talked about, first search the appropriate system or container config file and secondarily fall back to the system-wide mishkan.conf file. If the variable exists in neither, we will either have to surface an error if the variable is optional, or stop the process completely and back out if it's mandatory. Set all variables in the most private scope available (eg at the system or container level, not the mishkan-wide level).

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

This concept doesn't really lead well from the previous, but it must be presented as a possibility so a future argument between Concept 1 and Concept 2 make sense.

Containers should be repeatable and destroyable. A container config file should live in `/zshemot/minhag/containers/[container-name].conf`. This will define, in sysrc fashion, all necessary state. For example:

BASE_SYSTEM    The system artifact name used as the underlying base for the jail
PACKAGES           The list of packages to install in the jail
FIRST_START    list of commands to run upon first start of the jail, in order

To appropriate the resources for a jail, the BASE_SYSTEM is found in zbamidbar/sinai/tablets.zfs/[system-name]@[artifact-name]. Then we use zfs-send and zfs-recv to copy this pristine build artifact from zbamidbar to zbereshit/containers/[container-name]@[artifact-name]. Then the subordinate var/ dataset zfs-send & zfs-recv from zbamidbar/sinai to zbamidbar/container-data/[container-name]/var. Why not clone, since it's in the same pool? well var/ doesn't really relate to the release, and its tracking will be done via git. (more on this later). This container-data dataset is mounted into /containers on the root filesystem, so that it overlays on top of the jails root tree which comes from zbereshit/containers/[container-name]. Finally, two more container-data datasets are created: container-data/[container-name]/usr-local, which mounts in at /containers/[container-name]/usr/local, and stores the packages, and container-data/[container-name]/home, which is intuitive.

After the resources have been appropriated, we start up the jail with service jail onestart or jail(8). We then install all packages, and finally run the FIRST_START commands.

## Zoom out and filling in the missing blanks

What about that missing git link? We haven't really explained that at all. What's the conflict between Concept 1 and Concept 2?

The overarching idea of both systems and containers is this. Build a clean system, build an mtree to track permissions lost by git, track all base system files via git, and then beam it up to the safe data lake pool.

The problem comes when the user starts making tweaks. If, for example, they change an etc/ file, that's a text file and can be really well tracked in git. For example, when the user wishes to save a running system's deltas from the base system, we could generate a new mtree for the new files, add all new or modified files, and commit that all up to git. This works pretty well for text files, and runs into problems with binary files. There's also the problem of the var/ and usr/local directorys in a pure git world. Var changes every session, so we end up with a ton of binary noise in var every time we save deltas. usr/local is huge and full of binary files. It's not worth tracking all that with git.

So we then send those off to new datasets in the data-lake and mount them into the filesystem where they should live, so the directory tree sees a complete system. In a .gitignore we should ignore all mounted in filesystems (Not discussed above, but we will explain the finer points later).

Finally, git breaks down under one last issue. If the user adds a new user to the system or jail, the passwd file is binary, and becomes a binary diff when we want to rebase the system changes onto an updated base system. This doesn't resolve naturally in git.

So to solve these breakdowns we introduce composition files, as talked about in Concept 2. composition files allow us to simply write down the commands we need to take from the base system to get where we are, which saves the issue of binary diffs and unaccountable mounted directories, but come with an obvious drawback. We must remember everything we do, and if we ever forget to write something down in the composition file, we'll fail to perform it after a system upgrade, and that will result in a broken system, potentially months after we've forgotten what worked and what we failed to log down. Git fixes these deficiencies by tracking all files and playing backstop for us and our wild sysadmin attempts to just get something to work.

The right answer, of course, lives somewhere in the middle. In a perfect world we:

- Update the composition file's package list against the package database's list of installed first-class (non-dependencies) packages
- Use git to track all non-foreign-mounted text file changes
- I'm not sure what to do with the remaining non-text file changes. We should show them to the user and ask if they've been added to the composition file, but we can't then track them to watch for new changes later, (so as to not double-ask down the road), since then they'd end up in the git deltas, where we don't really want to try applying them in a rebase, since that requires human intervention because it's binary.

HINT: we may want to look into etcupdate(8) for inspiration on this last point.

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
