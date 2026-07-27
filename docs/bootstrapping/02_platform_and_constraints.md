# Platform and Constraints

## Hard requirements

- **FreeBSD** (not Linux). Do not assume Linux behavior for any system
  tool. When in doubt, check the FreeBSD man page with `man -P cat`.
- **ZFS** as the sole filesystem. The entire architecture depends on ZFS
  datasets, snapshots, clones, and send/recv.
- **GELI** for full-disk encryption. All three pools are encrypted.
- **/bin/sh** for all scripts. No bash. No bashisms. All scripts use
  `#!/bin/sh` and `set -eu`.
- **sysrc(8)** format for configuration files (VAR=value, one per line).

## Naming conventions

- **Shell functions and commands**: underscores, never kebab-case.
  `parasa_bootstrap`, not `parasa-bootstrap`. `new_foundation`, not
  `new-foundation`.
- **ZFS dataset names**: kebab-case. `usr-local`, `container-data`,
  `system-data`. Not underscores.
- **Plural forms in code paths**: always `containers/`, `systems/`,
  `foundations/`. Singular is always a typo.
- **Parasa names** (foundation names, system names, container names):
  underscores. `generic_stable15`, not `generic-stable15`.

## What "container" means

Container and jail are synonyms in this project. We use FreeBSD's
`jail(8)` system. There is no Docker, no OCI, no container runtime. A
container is a jail. `jexec` runs commands inside one.

## FreeBSD tools used throughout

| Tool | Purpose |
|------|---------|
| `zfs(8)` / `zpool(8)` | All storage operations |
| `geli(8)` | Full-disk encryption |
| `jail(8)` / `jexec(8)` | Container management |
| `mtree(8)` | Filesystem manifest generation and comparison |
| `pkg(8)` | Package management |
| `sysrc(8)` | Config file read/write |
| `nextboot(8)` | One-shot boot target with auto-revert |
| `chroot(8)` | System-level command execution during updates |
| `chflags(8)` | Remove schg flags before overwriting base files |
| `glabel(8)` | Stable disk labels for pool devices |
| `gpart(8)` | GPT partitioning |
| `file(1)` | Binary/text file detection |
| `git(1)` | All version tracking |

## Test framework

Tests use [ShellSpec](https://shellspec.info/) (`shellspec` command).
Config in `.shellspec`: `--shell sh --require spec_helper`. Tests are in
`spec/`. All ZFS, git, and filesystem operations are mocked in tests.
