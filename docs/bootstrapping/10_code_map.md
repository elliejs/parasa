# Code Map

Every file in the repo, what it does, and where to look for what.

## Root

| File | Purpose |
|------|---------|
| `index.sh` | Source on login. Provides `parasa_*` shell functions that delegate to scripts/. |
| `parasa.conf` | Parasa-wide build defaults. sysrc format. Fallback for all foundation build.conf files. |
| `LICENSE` | BSD 2-Clause. Copyright eidelbyte. |
| `README.md` | Public-facing project overview. |
| `.shellspec` | ShellSpec test config: `--shell sh --require spec_helper`. |
| `epigraph.svg` | Decorative epigraph for README (Talmudic quote). |

## scripts/

All executable scripts. Each is standalone with `#!/bin/sh` and `set -eu`.

| File | Lines | Purpose | Key functions |
|------|-------|---------|---------------|
| `helpers.sh` | ~550 | Shared utilities. Sourced by all scripts. | `error`, `die`, `root_only`, `confirm`, `yesish`, `noish`, `zmount`, `zunmount`, `ztouch`, `zwith`, `generate_mtree`, `apply_mtree`, `clear_mtree`, `msysrc`, `zfs_dataset_exists`, `git_branch_exists`, `get_foundation`, `validate_name`, `prompt_or_default`, `prompt_yesno`, `select_foundation`, `get_tree_root`, `get_recipes_dir`, `detect_kind`, `branch_to_version`, `get_foundation_version`, `resolve_derivations_db`, `ver_ge`, `is_binary_file`, `lookup_derivation`, `read_artifact_name`, `get_artifact_name`, `get_current_artifact` |
| `workspace.sh` | ~300 | Shared workspace lifecycle for system/container creation. Sourced by new_system/new_container. | `collect_name`, `check_available`, `collect_foundation`, `collect_build_options`, `create_recipe_boilerplate`, `create_data_datasets`, `ws_begin`, `ws_commit`, `ws_end`, `ws_cleanup` |
| `stage0-bootstrap.sh` | ~390 | One-time disk init: partition, GELI, pools, datasets. | `running_disk`, `assert_not_running`, `prompt_disk`, `prompt_label`, `prompt_disk_list`, `prompt_topology`, `geli_setup_one`, `geli_setup_pool`, `build_vdev`, `create_datasets`, `install_efi_loader` |
| `new_foundation.sh` | ~435 | Build world+kernel, archive as foundation. | `collect_foundation_name`, `check_foundation_available`, `resolve_build_config`, `create_recipe_dir`, `ensure_src_tree`, `prepare_workspace`, `prepare_workspace_git`, `run_build`, `commit_build`, `archive_to_zbamidbar`, `wipe_workspace` |
| `new_system.sh` | ~250 | Create system on a foundation. | `collect_system_options`, `build_fstab_lines`, `print_summary`, `main` (delegates to workspace.sh) |
| `new_container.sh` | ~235 | Create container on a foundation. | `collect_container_options`, `create_container_recipe_extras`, `print_summary`, `main` (delegates to workspace.sh) |
| `deploy_system.sh` | ~225 | Deploy system from zbamidbar to zbereshit. | `resolve_snapshot`, `deploy`, `set_nextboot` |
| `diff.sh` | ~270 | Detect drift: mtree comparison + classification. | `is_exempt_path`, `classify_file`, `prompt_classification`, `main` |
| `save.sh` | ~150 | Two-commit state capture (state + recipe). | `main` |
| `update.sh` | ~410 | Rebase onto new foundation. Builds -new alongside. | `update_cleanup`, `main` (8-step pipeline) |
| `finalize_update.sh` | ~165 | Swap -new into place. Destructive. | `main` (7-step pipeline) |
| `doctor.sh` | ~445 | Health check with interactive repair. | `check_os`, `check_tools`, `check_pools`, `check_datasets`, `check_dataset`, `check_git_repos`, `check_bare_repo`, `check_src_tree`, `check_parasa_repo`, `check_dataset_props` |

## etc/

| File | Purpose |
|------|---------|
| `mtree.ignore` | Paths to exclude from mtree comparison. Contains `.git`. |
| `derivations/15.0.db` | Default text-to-binary derivation mappings for FreeBSD 15.0. Tab-separated: source, derived, command. |

## recipes/

| Path | Purpose |
|------|---------|
| `jail.conf` | Default jail.conf for all containers. Includes per-container configs via `.include`. |
| `foundations/` | Per-foundation build configurations. Currently empty (`.gitkeep`). |
| `systems/` | Per-system target directories. Currently empty. |
| `containers/` | Per-container target directories. Currently empty. |

## man/man8/

mdoc(7) man pages for each command. One `.8` file per command.

## spec/

ShellSpec tests. One `*_spec.sh` per script. All ZFS/git/filesystem ops
are mocked.

| File | Tests for |
|------|-----------|
| `spec_helper.sh` | Shared test setup. `setup_parasa_dir()`, `setup_recipes_tree()`, `log_command()`. |
| `helpers_spec.sh` | helpers.sh functions |
| `workspace_spec.sh` | workspace.sh lifecycle |
| `new_foundation_spec.sh` | new_foundation.sh |
| `new_system_spec.sh` | new_system.sh |
| `new_container_spec.sh` | new_container.sh |
| `deploy_system_spec.sh` | deploy_system.sh |
| `diff_spec.sh` | diff.sh |
| `save_spec.sh` | save.sh |
| `update_spec.sh` | update.sh |
| `finalize_update_spec.sh` | finalize_update.sh |
| `doctor_spec.sh` | doctor.sh |

## docs/

Design documents, architecture diagrams, user stories, and risk
assessments. See `docs/README.md` for the full list.

## plans/

Implementation plans and design notes. These predate the implementation
and may contain superseded decisions (noted inline).

| File | Purpose |
|------|---------|
| `build_system.md` | Plan for new_foundation + new_system + deploy_system |
| `rebase_pipeline.md` | Plan for diff + save + update + finalize_update |
| `architecture.txt` | ASCII architecture reference (flows and relationships) |
| `architecture_visual.txt` | Visual box-art companion to architecture.txt |
| `structure.txt` | Canonical dataset/branch naming reference |
| `note-on-stories.md` | Review notes on user_stories_containers.md |
| `notes-on-gap-closing.txt` | Review notes on rebase_pipeline.md |

## old/

Previous-era scripts, preserved for reference. Not used by current code.

| File | Purpose |
|------|---------|
| `index.sh` | Old index with different command names |
| `stage0-bootstrap.sh` | Old bootstrap script |
| `stage1-build-upgrade.sh` | Old build script |
| `stage2-rebase-containers.sh` | Old rebase script |
| `stage3-reflash-system.sh` | Old system flash script |
| `helpers.sh` | Old helper functions |
| `composer/` | Old composition engine (0-appropriate.sh, 1-run-composition.sh, helpers.sh) |
| `hooks/pre-commit` | Old git pre-commit hook |
| `notes.txt` | Old notes (kldxref fix, git hooks path) |
