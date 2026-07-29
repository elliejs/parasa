# Dataset Layout

Every ZFS dataset managed by parasa, its purpose, mount policy, and
naming convention.

## Naming rules

- Dataset name components use kebab-case: `usr-local`, `system-data`,
  `container-data`.
- `${NAME}` placeholders refer to the user-chosen foundation, system, or
  container name.
- `${ARTIFACT}` refers to a build artifact name, formatted as
  `<branch>_<ISO-date>_<short-sha>[_<suffix>]`.
- `${FOUNDATION}` refers to a foundation name.

## Pool: zbereshit

| Dataset | Mount policy | Purpose |
|---------|-------------|---------|
| `zbereshit/foundations/` | `mountpoint=none` | Clone source for systems/containers. Recv'd from zbamidbar. |
| `zbereshit/foundations/${FOUNDATION}` | `mountpoint=none` | Per-foundation dataset with snapshot chain (`@${ARTIFACT}`) |
| `zbereshit/systems/` | `mountpoint=none` | Parent for deployed systems |
| `zbereshit/systems/${NAME}` | `mountpoint=/` only when booting via nextboot | ZFS clone from a foundation snapshot. Active system. |
| `zbereshit/containers/` | `mountpoint=/containers`, `canmount=on` | Parent for running jails. Auto-mounted. |
| `zbereshit/containers/${NAME}` | Inherits `/containers/${NAME}` | ZFS clone from a foundation snapshot. Running jail. |

## Pool: zshemot

| Dataset | Mount policy | Purpose |
|---------|-------------|---------|
| `zshemot/src.git` | `mountpoint=/zshemot/src.git`, `canmount=noauto` | FreeBSD source tree. Mounted only during builds. |
| `zshemot/parasa` | `mountpoint=/zshemot/parasa`, `canmount=noauto` | Parasa framework repo clone (scripts, recipes, etc). |
| `zshemot/buildspace/` | `mountpoint=none` | Parent for transient build workspaces. NOT created by bootstrap -- created on demand. |
| `zshemot/buildspace/${NAME}` | Transient | Per-build workspace. Created by new_foundation/new_system/new_container. Destroyed after use. |
| `zshemot/buildspace/${NAME}/var` | Transient | Separate var dataset within workspace. Also transient. |

## Pool: zbamidbar

| Dataset | Mount policy | Purpose |
|---------|-------------|---------|
| `zbamidbar/foundation.git` | `mountpoint=none`, mounted on demand | Bare git repo. All branches (foundations, systems, containers). |
| `zbamidbar/foundation.zfs/` | `mountpoint=none` | Parent for foundation archives. |
| `zbamidbar/foundation.zfs/` | `mountpoint=none` | Parent for per-foundation archives. |
| `zbamidbar/foundation.zfs/${FOUNDATION}` | `mountpoint=none` | Pristine build archive with snapshot chain (`@${ARTIFACT}`). |
| `zbamidbar/system-data/` | `mountpoint=none` | Parent for per-system data. |
| `zbamidbar/system-data/${NAME}/` | `mountpoint=none` | Per-system data root. |
| `zbamidbar/system-data/${NAME}/var` | `mountpoint=none` | System's /var. Copied from foundation's pristine var. |
| `zbamidbar/system-data/${NAME}/usr-local` | `mountpoint=none` | System's /usr/local (packages). |
| `zbamidbar/system-data/${NAME}/home` | `mountpoint=none` | System's /home (optional). |
| `zbamidbar/system-data/${NAME}/tmp` | `mountpoint=none` | System's /tmp (optional). |
| `zbamidbar/system-data/${NAME}/home/${USER}` | `mountpoint=none` | Per-user home dataset (optional). |
| `zbamidbar/container-data/` | `mountpoint=none` | Parent for per-container data. |
| `zbamidbar/container-data/${NAME}/` | `mountpoint=none` | Per-container data root. Same child structure as system-data. |
| `zbamidbar/parasa.git` | `mountpoint=none` | Bare git remote for the parasa config repo. |

## Mount topology at runtime

### System (mounted at `/`)

```
/            <-- zbereshit/systems/${NAME}     (base system from foundation)
/var         <-- zbamidbar/system-data/${NAME}/var       (zfs mount, rw,late)
/home        <-- zbamidbar/system-data/${NAME}/home      (zfs mount, rw,late)
/tmp         <-- zbamidbar/system-data/${NAME}/tmp       (zfs mount, rw,late)
/usr/local   <-- zbamidbar/system-data/${NAME}/usr-local (zfs mount, rw,late)
```

All mounts are in `/etc/fstab` inside the system tree (git-tracked).
Systems do not use nullfs -- they own their datasets.

### Container (jailed at `/containers/${NAME}`)

```
/var         <-- zbamidbar/container-data/${NAME}/var       (zfs via mount.fstab)
/home        <-- zbamidbar/container-data/${NAME}/home      (zfs via mount.fstab)
/tmp         <-- zbamidbar/container-data/${NAME}/tmp       (zfs via mount.fstab)
/usr/local   <-- zbamidbar/container-data/${NAME}/usr-local (zfs via mount.fstab)
/shared/foo  <-- /containers/other/shared/foo               (nullfs, cross-mount)
```

Container mounts use `mount.fstab` in the recipes directory, processed
by `jail(8)` at jail start/stop. Own-dataset mounts use `zfs` type.
Cross-mounts (another container's data) use `nullfs`.
