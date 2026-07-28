#!/bin/sh
# finalize_update.sh -- Swap a -new clone into place after update.
#
# This is the ONLY destructive step in the update flow.
# Destroys the old clone, renames -new to the plain name, saves state.
#
# See plans/rebase_pipeline.md Phase 4 for the full design.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR="${PARASA_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
finalize_update -- Swap a -new clone into place after successful update.

Usage:
  finalize_update.sh -s NAME [-k KIND] [-h] [-d] [-n]

Options:
  -h        Show this help and exit
  -d        Dry run: print commands without executing them
  -s NAME   Workspace name (required)
  -k KIND   "system" or "container" (auto-detected if omitted)
  -n        Set nextboot after finalize (systems only)

This command:
  1. Verifies ${NAME}-new exists
  2. Stops the old container if running
  3. Destroys the old clone: zfs destroy -r zbereshit/{kind}s/${NAME}
  4. Renames -new to plain: zfs rename {kind}s/${NAME}-new {kind}s/${NAME}
  5. Updates .foundation file with new artifact name
  6. Saves state (delegates to save.sh)
  7. Optionally starts container or sets nextboot for system

Rollback (if -new is bad, BEFORE finalizing):
  zfs destroy -r zbereshit/{kind}s/${NAME}-new

Examples:
  finalize_update.sh -s wonderland        Finalize system update
  finalize_update.sh -s webserver         Finalize container update
  finalize_update.sh -s wonderland -d     Dry-run finalize
  finalize_update.sh -s wonderland -n     Finalize + nextboot
EOF
	exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────

DRY_RUN=false
WS_NAME=""
WS_KIND=""
NEXTBOOT=false

while getopts ":hds:k:n" opt; do
	case "$opt" in
		h) print_help ;;
		d) DRY_RUN=true ;;
		s) WS_NAME="$OPTARG" ;;
		k) WS_KIND="$OPTARG" ;;
		n) NEXTBOOT=true ;;
		\?) die "Unknown option: -${OPTARG}. Use -h for help." ;;
		:)  die "Option -${OPTARG} requires an argument." ;;
	esac
done

[ -n "$WS_NAME" ] || die "Workspace name required (-s NAME). Use -h for help."

# ── Resolve target ──────────────────────────────────────────────────────────

if [ -z "$WS_KIND" ]; then
	WS_KIND=$(detect_kind "$WS_NAME")
fi

RECIPE_DIR=$(get_recipes_dir "$WS_KIND" "$WS_NAME")
[ -d "$RECIPE_DIR" ] || die "Recipe directory not found: ${RECIPE_DIR}"

FOUNDATION_NAME=$(get_foundation "$RECIPE_DIR")

# ── Dry-run wrapper ─────────────────────────────────────────────────────────

run() {
	if $DRY_RUN; then
		printf "  [dry] %s\n" "$*" >&2
	else
		"$@"
	fi
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	local old_ds="zbereshit/${WS_KIND}s/${WS_NAME}"
	local new_ds="zbereshit/${WS_KIND}s/${WS_NAME}-new"
	local data_root="zbamidbar/${WS_KIND}-data/${WS_NAME}"
	local new_data_root="${data_root}-new"
	local tree_root
	tree_root=$(get_tree_root "$WS_KIND" "$WS_NAME")

	# Step 1: Verify -new (OS clone + data clone) exists
	if ! $DRY_RUN; then
		zfs_dataset_exists "$new_ds" || die "${new_ds} does not exist. Run update.sh first."
		zfs_dataset_exists "$old_ds" || die "${old_ds} does not exist. Nothing to replace."
	else
		printf "  [dry] verify %s + %s exist\n" "$new_ds" "$new_data_root" >&2
	fi

	# Derive the target foundation + artifact from the -new clone's origin
	# (zbereshit/foundations/<foundation>@<artifact>). This is what makes a
	# cross-version finalize update the .foundation correctly.
	local target_foundation new_artifact
	if ! $DRY_RUN; then
		local origin
		origin=$(zfs get -H -o value origin "$new_ds")
		case "$origin" in
			zbereshit/foundations/*@*)
				target_foundation="${origin#zbereshit/foundations/}"
				target_foundation="${target_foundation%@*}"
				new_artifact="${origin##*@}"
				;;
			*) die "Cannot derive target foundation from ${new_ds} origin: ${origin}" ;;
		esac
	else
		target_foundation="$FOUNDATION_NAME"
		new_artifact="<latest>"
	fi
	printf "==> Finalizing %s onto %s@%s\n" "$WS_NAME" "$target_foundation" "$new_artifact" >&2

	# Step 2: Stop old container if running
	case "$WS_KIND" in
		container)
			printf "==> Stopping old container %s...\n" "$WS_NAME" >&2
			run jail -r "$WS_NAME"
			;;
		system)
			printf "==> System %s: assuming not the running root.\n" "$WS_NAME" >&2
			;;
	esac

	# Step 3: Destroy old OS clone + old data
	printf "==> Destroying old clone + data...\n" >&2
	run zfs destroy -r "$old_ds"
	run zfs destroy -r "$data_root"

	# Step 4: Rename -new (OS + data) into place, remount at the live tree
	printf "==> Renaming -new into place...\n" >&2
	run zfs rename "$new_ds" "$old_ds"
	run zfs rename "$new_data_root" "$data_root"

	run zfs set mountpoint="$tree_root" "$old_ds"
	run zfs mount "$old_ds" 2>/dev/null || true
	run zfs set mountpoint="${tree_root}/var" "${data_root}/var"
	run zfs mount "${data_root}/var" 2>/dev/null || true
	run zfs set mountpoint="${tree_root}/usr/local" "${data_root}/usr-local"
	run zfs mount "${data_root}/usr-local" 2>/dev/null || true
	if zfs_dataset_exists "${data_root}/home"; then
		run zfs set mountpoint="${tree_root}/home" "${data_root}/home"
		run zfs mount "${data_root}/home" 2>/dev/null || true
	fi
	if zfs_dataset_exists "${data_root}/tmp"; then
		run zfs set mountpoint="${tree_root}/tmp" "${data_root}/tmp"
		run zfs mount "${data_root}/tmp" 2>/dev/null || true
	fi

	# Step 5: Update .foundation → target foundation + new artifact
	printf "==> Updating .foundation artifact...\n" >&2
	if ! $DRY_RUN; then
		rm -f "${RECIPE_DIR}"/*.foundation
		printf "%s\n" "$new_artifact" > "${RECIPE_DIR}/${target_foundation}.foundation"
	else
		printf "  [dry] write %s/%s.foundation = %s\n" "$RECIPE_DIR" "$target_foundation" "$new_artifact" >&2
	fi

	# Step 6: Save state
	printf "==> Saving state...\n" >&2
	run "${SCRIPT_DIR}/save.sh" -s "$WS_NAME" -k "$WS_KIND" -q -m "finalize update to ${target_foundation}@${new_artifact}"

	# Step 7: Start / nextboot
	case "$WS_KIND" in
		container)
			printf "==> Starting container %s...\n" "$WS_NAME" >&2
			run jail -c "$WS_NAME"
			;;
		system)
			if $NEXTBOOT; then
				printf "==> Setting nextboot for %s...\n" "$WS_NAME" >&2
				run nextboot -e "vfs.root.mountfrom=\"zfs:zbereshit/systems/${WS_NAME}\""
			fi
			;;
	esac

	printf "==> Finalize complete. %s is now %s@%s.\n" "$WS_NAME" "$target_foundation" "$new_artifact" >&2
}

main
