# The Three Pools

Parasa organizes storage across three GELI-encrypted ZFS pools. Each pool
has a distinct role. The names come from books of the Torah.

## zbereshit -- "in the beginning" (boot pool, NVMe)

The **running state**. This is what's actually executing on the machine.

Contains:
- `zbereshit/foundations/` -- clone source for systems and containers,
  recv'd from zbamidbar
- `zbereshit/systems/` -- deployed bootable systems. The active system is
  mounted at `/` via `nextboot(8)`.
- `zbereshit/containers/` -- deployed jails, mounted at `/containers/`.

This pool is fast (NVMe) and is the result of all the scaffolding,
scripts, and foreign mounts working together. It is **ephemeral** in the
sense that everything on it can be recreated from zbamidbar + zshemot.

## zshemot -- "names" (config pool, SSD)

The **scaffolding**. Where the build tools and configuration live.

Contains:
- `zshemot/src.git` -- FreeBSD source tree clone. Mounted only during
  builds.
- `zshemot/parasa` -- the parasa framework repo clone. Contains scripts,
  default derivation databases, and user configuration (`recipes/`).
- `zshemot/buildspace/` -- transient per-name build workspaces. Created on
  demand, destroyed after use. Multiple can exist concurrently.

If zbereshit dies, zshemot + zbamidbar can rebuild everything.

## zbamidbar -- "in the wilderness" (data lake, HDD, 8TB)

The **authoritative archive** and persistent data store.

Contains:
- `zbamidbar/foundation.git` -- bare git repo. All foundation, system, and
  container branches live here.
- `zbamidbar/foundation.zfs/` -- ZFS send/recv archives of pristine
  foundation builds.
- `zbamidbar/system-data/` -- per-system persistent data datasets (var,
  home, usr-local, tmp).
- `zbamidbar/container-data/` -- per-container persistent data datasets.
- `zbamidbar/parasa.git` -- bare git remote for the parasa config repo.

This pool is the single point of truth. If it is lost, all delta chains,
compose scripts, and package lists are gone. Backup strategy is critical
and currently undocumented.

## Pool philosophy

- **zbereshit** = the result (what runs)
- **zshemot** = the tools (how to build)
- **zbamidbar** = the record (what was built, what changed)

## Data flow direction

```
zshemot/src.git  --make-->  zshemot/buildspace/  --zfs send-->  zbamidbar/foundation.zfs/
                                                 --git push-->  zbamidbar/foundation.git

zbamidbar/foundation.zfs/  --zfs send-->  zbereshit/foundations/  --zfs clone-->  zbereshit/systems/
zbamidbar/foundation.git   --git checkout-->  zbereshit/systems/ (applies deltas)

zbereshit/systems/  --git push (save)-->  zbamidbar/foundation.git
```

## Encryption

Each pool has its own GELI passphrase:
- zbereshit: `-bg` flags (boot-decryptable, prompts at boot)
- zshemot: `-b` flag (decrypted by rc.d/geli at early boot)
- zbamidbar: `-b` flag (decrypted by rc.d/geli at early boot)

All passphrases are interactive. Backup keys (`-B none`) are not created
during bootstrap -- this is a known risk.

## Mount hygiene

Datasets follow a **least-mounted policy**. If a dataset can be unmounted,
it should be. Generally mounted datasets are:
- The active `zbereshit/system` (at `/`)
- Its corresponding `zbamidbar/system-data/` mounts
- `zbereshit/containers` (at `/containers/`)
- Container data mounts

Everything else is mounted on demand by parasa scripts and unmounted after.
