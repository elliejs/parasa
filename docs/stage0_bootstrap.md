# Stage 0 Bootstrap: Implementation Plan

## What this script does

Performs one-time disk initialization for a fresh parasa system. Meant to
be run once, from an installer environment or a live system, against disks
that are not the running root. Order of operations:

1. Partition the boot disk (EFI + swap + ZFS partition)
2. Format the EFI partition and install the UEFI loader
3. GELI-encrypt all three pool devices (separate passphrases per pool)
4. GLABEL the GELI providers with stable names
5. Create the three ZFS pools
6. Build the parasa dataset hierarchy

## Script location and structure

```
scripts/
  helpers.sh             shared helpers, sourced by all stage scripts
  stage0-bootstrap.sh    this script
```

Stage scripts are standalone executables with a `#!/bin/sh` shebang.
They source `helpers.sh` from the same directory at runtime. The top-level
`index.sh` provides wrapper functions and is sourced on login.

## Boot disk partitioning (gpart)

The boot disk gets a GPT partition table with three partitions, in this
fixed order:

| Index | Type           | Size         | GPT Label  | Purpose                |
|-------|----------------|--------------|------------|------------------------|
| p1    | efi            | 260m         | efi        | UEFI boot files        |
| p2    | freebsd-swap   | user-defined | swap0      | Swap space             |
| p3    | freebsd-zfs    | remainder    | user-chosen | zbereshit pool device |

EFI is formatted FAT32 with `newfs_msdos -F 32 -c 1`. The EFI loader is
installed by copying `/boot/loader.efi` to `EFI/BOOT/BOOTX64.EFI` on the
mounted EFI partition. A temporary mount point under `/tmp` is used.

No legacy BIOS (freebsd-boot) partition is created. EFI only.

## GELI encryption

Three passphrases, one per pool, entered interactively by geli itself.
The script adds informational messages before each `geli init` call so the
user knows which passphrase they are setting.

| Pool       | Device          | geli flags | Notes                                    |
|------------|-----------------|------------|------------------------------------------|
| zbereshit  | `${BOOT}p3`     | `-bg`      | boot-decryptable, prompts pre-boot       |
| zshemot    | per-disk        | `-b`       | decrypted by rc.d/geli at early boot     |
| zbamidbar  | per-disk        | `-b`       | decrypted by rc.d/geli at early boot     |

zshemot and zbamidbar accept a list of disks for multi-disk vdevs. Each disk
in the list is individually GELI-initialized and attached with the same pool
passphrase (geli prompts once per disk; the user enters the same passphrase
for each disk in the same pool).

## GLABEL naming

Glabel gives the `.eli` providers stable names that survive device reordering.
All labels are **user-specified**, one label per disk. After the user enters
each disk device name, they are immediately prompted for that disk's label.
Labels are validated to be non-empty and free of whitespace or `/` characters.

The label is used directly in the zpool vdev string as `label/<user-label>`.

Example session for a two-disk zshemot mirror:
```
Disk 1 for zshemot: ada0
  Label for /dev/ada0: wumpus
Disk 2 for zshemot: ada1
  Label for /dev/ada1: wumpus-mirror
```

Resulting vdev: `mirror label/wumpus label/wumpus-mirror`

## ZFS pool creation

All three pools share these pool-level settings:

```
-o ashift=12 -o autotrim=on
```

And these root-dataset settings (applied via `-O` at create time):

```
-O atime=off -O compression=zstd -O aclmode=passthrough
-O mountpoint=none -O canmount=noauto
```

### zbereshit (boot pool)

Always a single-device pool on `label/<user-chosen>`. No topology keyword.

### zshemot and zbamidbar (data pools)

The user provides a disk list and an optional topology keyword (e.g.,
`mirror`, `raidz1`). The script builds the vdev string:

- Single disk → `label/wumpus`
- Mirror of two → `mirror label/wumpus label/wumpus1`

## Dataset hierarchy

All datasets inherit `mountpoint=none, canmount=noauto` from pool root.
Per-dataset overrides set below. Datasets should follow the least-mounted
policy: only mounted when a parasa script needs them.

### zbereshit

```
zbereshit/systems
  mountpoint=none, canmount=noauto
  Root for bootable system datasets. Each system is a child dataset.
  Active system is mounted at / via boot loader; others remain unmounted.

zbereshit/containers
  mountpoint=/containers, canmount=on
  Root for running jail datasets. Auto-mounted when the system is up.
```

### zshemot

```
zshemot/torah
  mountpoint=/zshemot/torah, canmount=noauto
  FreeBSD src.git clone. Mounted only during build phases.

zshemot/parasa
  mountpoint=/zshemot/parasa, canmount=noauto
  The parasa framework repo clone. Contains scripts, default derivation
  databases, and user configuration (recipes/) per target. Mounted when
  parasa scripts need config or during builds.

Note: zshemot/amim is NOT created by bootstrap. It is the parent for
per-name build workspaces (e.g., zshemot/amim/generic-stable15.0),
created on demand by new_foundation/new_system/new_container. Each
child workspace is destroyed after use. Multiple can exist concurrently.
```

### zbamidbar

```
zbamidbar/container-data
  mountpoint=none, canmount=noauto
  Parent for per-container data datasets.

zbamidbar/system-data
  mountpoint=none, canmount=noauto
  Parent for per-system data datasets.

zbamidbar/sinai.git
  mountpoint=none, canmount=noauto
  Bare git remote. Foundation/system/container branches pushed here.

zbamidbar/sinai.zfs
  mountpoint=none, canmount=noauto
  ZFS send/recv archive. Contains foundations/ (pristine build archives).

zbamidbar/parasa.git
  mountpoint=none, canmount=noauto
  Bare git remote for the parasa config repo (zshemot/parasa's local remote).
```

## Script flags

| Flag | Meaning                                         |
|------|-------------------------------------------------|
| `-d` | Dry run: print all commands, execute nothing    |
| `-h` | Show help and exit                              |

## Input collection

All interactive input is collected before any destructive action begins.
The script shows a summary and requires explicit confirmation before
proceeding. Collected values:

- Boot disk device name and its glabel label
- Swap partition size
- zshemot disk device(s), each with its own glabel label
- zshemot zpool topology keyword (optional)
- zbamidbar disk device(s), each with its own glabel label
- zbamidbar zpool topology keyword (optional)

Each disk is prompted one at a time. Immediately after the user enters a disk
device, they are prompted for that disk's label. Disk validation: the device
must exist under `/dev/` and must not be the disk hosting the running root
filesystem. Label validation: non-empty, no whitespace, no `/`.

## Safety

- Root check before any disk operations
- Running disk detection: `df /` → strip partition suffix and `.eli` → base
  disk name. Any disk matching this is rejected.
- All destructive commands go through `run()`, which no-ops in dry-run mode.
- A cleanup trap detaches any GELI providers attached during the session if
  the script exits with an error, so the disk is left in a clean state.
  The trap is cleared on successful completion (providers should stay attached
  after a successful bootstrap).
- All vdev members are validated to be `label/` paths before `zpool create`
  is called. Topology keywords (mirror, raidz*, etc.) are allowed through;
  any other token (raw device path, gpt/ path, etc.) causes a hard stop.

## Helpers file additions for stage 0

`scripts/helpers.sh` contains the full set of utilities needed across all
stage scripts. For stage 0, the new helpers introduced are:

- `error` / `die` — print and return/exit
- `root-only` — check uid 0
- `confirm` — y/n prompt loop
- `yesish` / `noish` — truthy/falsy string tests
- `zmount` / `zunmount` / `ztouch` — ZFS dataset helpers

Build-phase helpers (`generate-mtree`, `apply-mtree`, `clear-mtree`,
`get-artifact-name`, `get-current-artifact`) are included in helpers.sh now
so they are available immediately when stage 1 is written, even though they
are not called from stage 0.
