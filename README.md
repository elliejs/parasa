<div align="center">

<img src="epigraph.svg?v=3" alt="Ashmedai swallowed the ring and grew until he placed one wing in the heaven and one wing on the earth. He threw Solomon a distance of four hundred parasangs.">

<sub>Gittin 68b:15 &mdash; William Davidson Talmud, via <a href="https://www.sefaria.org/Gittin.68b.15">Sefaria</a></sub>

---

</div>

# Parasa

A composable system-tracking framework for FreeBSD. Build clean base
systems from source, track every delta with git, and rebase your
customizations onto new releases without losing anything.

## What it does

Parasa sits between you and your FreeBSD systems (bare metal and jails).
It builds base system artifacts from the FreeBSD source tree, tracks your
customizations as a git delta chain on top of those artifacts, and gives
you a clean path to rebase those customizations when the base system is
upgraded.

The hard problem is binary files. Git can three-way merge text configs
beautifully, but binary files (passwd databases, login.conf.db, keytabs,
certificates) produce unresolvable conflicts. Parasa solves this with
**stratified change tracking** — different types of changes get different
replay strategies:

- **Text config edits** — tracked by git, rebased automatically
- **Packages** — tracked by package list, reinstalled on new base
- **Derived binaries** (pwd.db, login.conf.db) — text source is merged,
  then the binary is regenerated via a known command (pwd_mkdb, cap_mkdb)
- **Environment state** (SSH host keys, certs, keytabs) — git-tracked as
  binary blobs, preserved across rebases
- **Opaque commands** — recorded in a compose.sh file, replayed on new base

Only the last category requires the admin to remember anything. Everything
else is automatic.

## Pool layout

Parasa organizes storage across three ZFS pools, each GELI-encrypted:

- **zbereshit** (boot pool) — the running system. Contains live systems
  and containers with their git delta chains. This is the result of all
  the scaffolding, scripts, and foreign mounts working together.
- **zshemot** (config pool) — where the scaffolds and scripts live. Houses
  the FreeBSD source tree, the parasa framework clone, and the build
  workspace.
- **zbamidbar** (data lake) — heavy data and foreign mounts. Per-target
  datasets for packages (usr-local), var, and home are stored here and
  mounted on top of zbereshit systems/containers before startup. Also
  stores bare git remotes and ZFS archives for long-term retention.

## Repo structure

```
index.sh              Source on login. Exposes parasa_* shell functions.
parasa.conf           Parasa-wide build defaults (sysrc format).

scripts/
  helpers.sh          Shared /bin/sh utilities (ZFS, mtree, prompts).
  stage0-bootstrap.sh One-time disk partitioning, GELI, pool + dataset setup.
  new_foundation.sh   Build world+kernel from source, archive as foundation.
  new_system.sh       Create a system on a foundation, optionally deploy.
  new_container.sh    Create a container on a foundation.
  deploy_system.sh    Deploy an archived system to zbereshit for boot.

man/man8/             mdoc(7) man pages for each command.

etc/
  derivations/        Default text-to-binary derivation databases, per branch.
    stable-15.db      master.passwd->pwd.db, login.conf->login.conf.db, etc.

recipes/               Per-target configuration ("customs").
  foundations/        Build configurations (SRC_BRANCH, KERNCONF, etc.)
    <name>/
      build.conf      Build overrides. Empty = default kernel + world.
  systems/            System targets (bare metal, bootable).
    <name>/
      <foundation>.foundation  Contains artifact name; filename = foundation.
      compose.sh         Opaque replay commands (one per line).
      derivations.local  Custom text-to-binary entries.
      mtree.dist         Baseline mtree for the target.
      pkg.list           Full package list (auto-populated).
  containers/         Container targets (jails).
    <name>/
      (same as systems, plus:)
      jail.conf       Jail configuration.
      mount.fstab     All container mounts (processed by jail start/stop).

docs/                 Design documents and implementation plans.
old/                  Previous-era scripts, preserved for reference.
```

## Configuration

Two-tier, sysrc(8) format. `parasa.conf` provides defaults. Each
foundation's `build.conf` overrides them. An empty `build.conf` builds a
default GENERIC kernel and world.

```sh
# Query effective config:
sysrc -f parasa.conf SRC_BRANCH
sysrc -f recipes/foundations/mybase/build.conf SRC_BRANCH
```

## How rebase works

1. Build a new base artifact from source
2. Install packages from `pkg.list`
3. Replay compose.sh commands on the new base
4. Three-way merge text files (git rebase of the delta chain)
5. Regenerate derived binaries (pwd_mkdb, cap_mkdb, etc.)
6. Environment state carries through the git rebase automatically
7. Validate with `parasa-diff` — should find zero unclassified changes

## Save workflow

Saving a system or container is one interactive session, two git commits:

1. **zbereshit commit** — `parasa-diff` detects changes via mtree,
   auto-classifies text files and known derivations, prompts the admin
   for any unclassified binaries, commits the delta.
2. **zshemot commit** — classifications from step 1 updated the target's
   recipes files (compose.sh, derivations.local, pkg.list). Commit those.

The zbereshit commit records the *state*. The zshemot commit records the
*recipe*.

## Requirements

- FreeBSD (not Linux)
- ZFS
- GELI
- /bin/sh (no bash)

## License

See [LICENSE](LICENSE).
