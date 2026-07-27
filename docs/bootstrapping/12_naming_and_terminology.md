# Naming Conventions and Terminology

## Glossary

| Term | Meaning |
|------|---------|
| **Foundation** | A pristine FreeBSD world+kernel build. Produced by `new_foundation`. Systems and containers are built on top of foundations. |
| **System** | A bootable FreeBSD installation tracked by parasa. Lives on `zbereshit/systems/`. Boots via `nextboot(8)`. |
| **Container** | A FreeBSD jail tracked by parasa. Lives on `zbereshit/containers/`. Started via `jail(8)`. |
| **Artifact** | A specific build of a foundation. Named `<branch>_<date>_<sha>[_<suffix>]`. Used as both git commit message and ZFS snapshot tag. |
| **Recipes** | Per-target configuration directory. Lives under `recipes/{systems,containers}/${NAME}/`. Contains compose.sh, pkg.list, mtree.dist, derivations.local, and .foundation file. |
| **Delta chain** | The sequence of git commits on a system/container branch, starting from the inaugural commit. Rebased onto new foundations during update. |
| **Inaugural commit** | The first commit on a system/container branch. For systems, writes /etc/fstab. For containers, may be empty (branch creation is the point). |
| **Derivation** | A text-to-binary relationship. The text source is merged by git, then a command regenerates the binary. Example: `master.passwd` -> `pwd.db` via `pwd_mkdb`. |
| **Compose** | Opaque replay commands that can't be auto-detected. Stored in compose.sh with `pre_pkg()` and `post_pkg()` functions. |
| **Preserve** | A non-derivable semi-static binary (SSH keys, certs) that is git-tracked and kept as-is across rebases. |
| **Beam down** | Informal term for ZFS send/recv of a foundation from zbamidbar to zbereshit. |
| **Workspace** / **buildspace** | Transient ZFS dataset under `zshemot/buildspace/` used during builds. Destroyed after use. Formerly called "amim" (Hebrew for "peoples") or "tablets". |
| **Data-lake mount** | A zbamidbar dataset (var, home, usr-local, tmp) mounted into a system or container. These persist across rebases. |
| **Cross-mount** | A nullfs mount where one container accesses another container's or system's dataset. Containers only. |

## Pool names (Hebrew)

| Pool | Hebrew | Literal meaning | Torah book |
|------|--------|-----------------|------------|
| zbereshit | בראשית | "in the beginning" | Genesis (1st) |
| zshemot | שמות | "names" | Exodus (2nd) |
| zbamidbar | במדבר | "in the wilderness" | Numbers (4th) |

## Historical name changes

These names appear in older docs and plans but have been renamed:

| Old name | New name | When |
|----------|----------|------|
| `sinai.git` / `tablets.git` | `foundation.git` | Build system redesign |
| `sinai.zfs` / `tablets.zfs` | `foundation.zfs` | Build system redesign |
| `sinai/` parent dataset | Removed (flattened) | Build system redesign |
| `zshemot/tablets` | `zshemot/buildspace` | Build system redesign |
| `amim` | `buildspace` | Build system redesign |
| `torah` | `src.git` | Build system redesign |
| `minhag` / `customs` | `recipes` | Recipe terminology redesign |
| `foundation/` branch prefix | Bare foundation name | Branch naming simplification |
| `system/` branch prefix | `systems/` | Plural consistency |
| `container/` branch prefix | `containers/` | Plural consistency |

## Naming rules (enforced by `validate_name()`)

Names for foundations, systems, and containers must:
- Be non-empty
- Not start with a hyphen
- Contain only letters, digits, hyphens, underscores, and dots

## Case conventions

| Context | Convention | Example |
|---------|-----------|---------|
| Shell functions / commands | underscore | `parasa_new_foundation`, `get_tree_root` |
| ZFS dataset components | kebab-case | `usr-local`, `system-data`, `container-data` |
| Parasa target names | underscore | `generic_stable15`, `my_system` |
| Git branch paths | slash-separated, plural | `systems/wonderland`, `containers/webserver` |
| Recipe directory paths | plural | `recipes/systems/`, `recipes/containers/`, `recipes/foundations/` |
| Config keys | uppercase underscore | `SRC_BRANCH`, `KERNCONF`, `MAKE_JOBS` |
