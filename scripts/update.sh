#!/bin/sh
# update.sh -- Rebase a workspace onto a new foundation patch level.
#
# Core principle: NEVER destroy the running clone during update.
# Builds {kind}s/${NAME}-new alongside the live clone. The old box keeps
# running until the admin verifies the new one works. Then finalize_update
# does the swap.
#
# See plans/rebase_pipeline.md Phase 4 for the full design.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR="${PARASA_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
update -- Rebase a workspace onto a new foundation patch level.

Usage:
  update.sh -s NAME [-k KIND] [-a ARTIFACT] [-h] [-d] [-q]

Options:
  -h          Show this help and exit
  -d          Dry run: print commands without executing them
  -s NAME     Workspace name (required)
  -k KIND     "system" or "container" (auto-detected if omitted)
  -a ARTIFACT New artifact name (default: latest on foundation archive)
  -q          Quiet mode: abort on conflicts instead of prompting

This command:
  1. Pre-flight: verify no unsaved changes, check -new doesn't exist
  2. Beam down: incremental send new artifact to zbereshit, clone to -new
  3. Mount + start the -new clone (jail for containers, chroot for systems)
  4. Run recipe: pre_pkg → packages → post_pkg
  5. Git rebase: replay admin delta chain onto new artifact commit
  6. Regenerate derivations whose source files changed
  7. Validate: regenerate mtree, run diff
  8. Offer swap or print finalize_update instructions

Rollback:
  zfs destroy -r zbereshit/{kind}s/${NAME}-new

Examples:
  update.sh -s wonderland                 Interactive update
  update.sh -s webserver -k container -q  Quiet update (abort on conflict)
  update.sh -s wonderland -d              Dry-run update
  update.sh -s wonderland -a stable-15_2026-07-01_def5678  Specific artifact
EOF
	exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────

DRY_RUN=false
WS_NAME=""
WS_KIND=""
QUIET=0
NEW_ARTIFACT=""

while getopts ":hds:k:a:q" opt; do
	case "$opt" in
		h) print_help ;;
		d) DRY_RUN=true ;;
		s) WS_NAME="$OPTARG" ;;
		k) WS_KIND="$OPTARG" ;;
		a) NEW_ARTIFACT="$OPTARG" ;;
		q) QUIET=1 ;;
		\?) die "Unknown option: -${OPTARG}. Use -h for help." ;;
		:)  die "Option -${OPTARG} requires an argument." ;;
	esac
done

[ -n "$WS_NAME" ] || die "Workspace name required (-s NAME). Use -h for help."

# ── Resolve target ──────────────────────────────────────────────────────────

if [ -z "$WS_KIND" ]; then
	WS_KIND=$(detect_kind "$WS_NAME")
fi

TREE_ROOT=$(get_tree_root "$WS_KIND" "$WS_NAME")
RECIPE_DIR=$(get_recipes_dir "$WS_KIND" "$WS_NAME")

[ -d "$RECIPE_DIR" ] || die "Recipe directory not found: ${RECIPE_DIR}"

WS_DATASET=$(get_ws_dataset "$WS_KIND" "$WS_NAME")
FOUNDATION_NAME=$(get_foundation "$WS_DATASET")
OLD_ARTIFACT=$(read_artifact_name "$WS_DATASET")

# Foundation archive dataset
FOUNDATION_ARCHIVE="zbamidbar/foundation.zfs/${FOUNDATION_NAME}"

# ── Dry-run wrapper ─────────────────────────────────────────────────────────

run() {
	if $DRY_RUN; then
		printf "  [dry] %s\n" "$*" >&2
	else
		"$@"
	fi
}

# ── Cleanup trap ────────────────────────────────────────────────────────────

update_cleanup() {
	if [ -n "${_UPDATE_STARTED:-}" ]; then
		printf "WARNING: Partial update at %ss/%s-new\n" "$WS_KIND" "$WS_NAME" >&2
		printf "To rollback: zfs destroy -r zbereshit/%ss/%s-new\n" "$WS_KIND" "$WS_NAME" >&2
	fi
	# Stop -new jail if running
	case "$WS_KIND" in
		container)
			jail -r "${WS_NAME}-new" 2>/dev/null || true
			;;
	esac
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	# ── Step 1: Pre-flight ───────────────────────────────────────────────
	printf "==> Pre-flight checks...\n" >&2

	# Check -new doesn't already exist
	if zfs_dataset_exists "zbereshit/${WS_KIND}s/${WS_NAME}-new"; then
		die "${WS_KIND}s/${WS_NAME}-new already exists. Finalize or destroy it first."
	fi

	# Resolve new artifact
	if [ -z "$NEW_ARTIFACT" ]; then
		if ! $DRY_RUN; then
			NEW_ARTIFACT=$(get_current_artifact "$FOUNDATION_ARCHIVE")
			[ -n "$NEW_ARTIFACT" ] || die "No snapshots found on ${FOUNDATION_ARCHIVE}"
		else
			NEW_ARTIFACT="<latest>"
		fi
	fi

	# Check we're actually updating
	if [ "$NEW_ARTIFACT" = "$OLD_ARTIFACT" ]; then
		die "Already at artifact ${OLD_ARTIFACT}. Nothing to update."
	fi

	# Verify no unsaved changes (skip in dry-run)
	if ! $DRY_RUN; then
		"${SCRIPT_DIR}/diff.sh" -s "$WS_NAME" -k "$WS_KIND" -q || \
			die "Unsaved drift detected. Run save.sh first."
	else
		printf "  [dry] diff.sh -s %s -k %s -q\n" "$WS_NAME" "$WS_KIND" >&2
	fi

	printf "  old artifact: %s\n" "$OLD_ARTIFACT" >&2
	printf "  new artifact: %s\n" "$NEW_ARTIFACT" >&2
	printf "  foundation:   %s\n" "$FOUNDATION_NAME" >&2

	trap update_cleanup EXIT
	_UPDATE_STARTED=true

	# ── Step 2: Beam down new foundation ─────────────────────────────────
	printf "==> Beaming down new foundation artifact...\n" >&2

	# Incremental send from old to new
	run zfs send -i "@${OLD_ARTIFACT}" "${FOUNDATION_ARCHIVE}@${NEW_ARTIFACT}" \| \
		zfs recv "zbereshit/foundations/${FOUNDATION_NAME}"

	# Clone from new artifact into -new
	printf "==> Cloning into %ss/%s-new...\n" "$WS_KIND" "$WS_NAME" >&2
	run zfs clone "zbereshit/foundations/${FOUNDATION_NAME}@${NEW_ARTIFACT}" \
		"zbereshit/${WS_KIND}s/${WS_NAME}-new"

	# ── Step 3: Mount + start the -new clone ─────────────────────────────
	printf "==> Mounting -new clone...\n" >&2

	local new_root
	case "$WS_KIND" in
		system)
			new_root="/zbereshit/systems/${WS_NAME}-new"
			# Mount data-lake datasets into -new tree
			local data_root="zbamidbar/system-data/${WS_NAME}"
			run zfs set mountpoint="${new_root}/var" "${data_root}/var"
			run zfs mount "${data_root}/var"
			run zfs set mountpoint="${new_root}/usr/local" "${data_root}/usr-local"
			run zfs mount "${data_root}/usr-local"
			if zfs_dataset_exists "${data_root}/home"; then
				run zfs set mountpoint="${new_root}/home" "${data_root}/home"
				run zfs mount "${data_root}/home"
			fi
			if zfs_dataset_exists "${data_root}/tmp"; then
				run zfs set mountpoint="${new_root}/tmp" "${data_root}/tmp"
				run zfs mount "${data_root}/tmp"
			fi
			;;
		container)
			new_root="/containers/${WS_NAME}-new"
			# Start temporary jail for -new
			# TODO: update.sh uses -new name; need a temp jail.conf or inline params
			run jail -c name="${WS_NAME}-new" path="$new_root" \
				host.hostname="${WS_NAME}-new" ip4=inherit ip6=inherit \
				mount.devfs persist
			# Mount data-lake datasets
			local data_root="zbamidbar/container-data/${WS_NAME}"
			run zfs set mountpoint="${new_root}/var" "${data_root}/var"
			run zfs mount "${data_root}/var"
			run zfs set mountpoint="${new_root}/usr/local" "${data_root}/usr-local"
			run zfs mount "${data_root}/usr-local"
			if zfs_dataset_exists "${data_root}/home"; then
				run zfs set mountpoint="${new_root}/home" "${data_root}/home"
				run zfs mount "${data_root}/home"
			fi
			if zfs_dataset_exists "${data_root}/tmp"; then
				run zfs set mountpoint="${new_root}/tmp" "${data_root}/tmp"
				run zfs mount "${data_root}/tmp"
			fi
			;;
	esac

	# ── Step 4: Run recipe on -new ───────────────────────────────────────
	printf "==> Running recipe (pre_pkg)...\n" >&2
	local compose="${RECIPE_DIR}/compose.sh"

	case "$WS_KIND" in
		system)
			if [ -f "$compose" ]; then
				run cp "$compose" "${new_root}/tmp/_compose.sh"
				run chroot "$new_root" sh -ec '. /tmp/_compose.sh; pre_pkg'
			fi
			;;
		container)
			if [ -f "$compose" ]; then
				run cp "$compose" "${new_root}/tmp/_compose.sh"
				run jexec "${WS_NAME}-new" sh -ec '. /tmp/_compose.sh; pre_pkg'
			fi
			;;
	esac

	printf "==> Installing packages...\n" >&2
	local pkg_list="${RECIPE_DIR}/pkg.list"
	if [ -f "$pkg_list" ] && [ -s "$pkg_list" ]; then
		case "$WS_KIND" in
			system)
				run chroot "$new_root" pkg install -y $(cat "$pkg_list")
				;;
			container)
				run pkg -j "${WS_NAME}-new" install -y $(cat "$pkg_list")
				;;
		esac
	fi

	printf "==> Running recipe (post_pkg)...\n" >&2
	case "$WS_KIND" in
		system)
			if [ -f "$compose" ]; then
				run chroot "$new_root" sh -ec '. /tmp/_compose.sh; post_pkg'
			fi
			;;
		container)
			if [ -f "$compose" ]; then
				run jexec "${WS_NAME}-new" sh -ec '. /tmp/_compose.sh; post_pkg'
			fi
			;;
	esac

	# ── Step 5: Git rebase ───────────────────────────────────────────────
	printf "==> Rebasing admin delta chain...\n" >&2

	local foundation_git="/zbamidbar/foundation.git"
	run zmount zbamidbar/foundation.git "$foundation_git"

	if ! $DRY_RUN; then
		# Set up git in -new tree (new archives lack .git)
		if [ ! -d "${new_root}/.git" ]; then
			# Create .git as child dataset so future zfs send -R excludes it
			zfs create -o mountpoint="${new_root}/.git" -o canmount=on \
				"zbereshit/${WS_KIND}s/${WS_NAME}-new/.git"
			git -C "$new_root" init -b main
			git -C "$new_root" remote add origin "$foundation_git"
		fi
		git -C "$new_root" fetch origin

		# Find the old and new artifact commits (artifact name = commit message)
		local old_commit new_commit
		old_commit=$(git -C "$new_root" log --all --format=%H --grep="$OLD_ARTIFACT" | head -1)
		new_commit=$(git -C "$new_root" log --all --format=%H --grep="$NEW_ARTIFACT" | head -1)

		[ -n "$old_commit" ] || die "Cannot find old artifact commit: ${OLD_ARTIFACT}"
		[ -n "$new_commit" ] || die "Cannot find new artifact commit: ${NEW_ARTIFACT}"

		# Align index with the new foundation working tree
		git -C "$new_root" checkout -f "$new_commit"

		# Create local workspace branch from remote tracking ref
		git -C "$new_root" branch "${WS_KIND}s/${WS_NAME}" \
			"origin/${WS_KIND}s/${WS_NAME}"

		# Rebase the workspace branch onto new artifact
		if ! git -C "$new_root" rebase --onto "$new_commit" "$old_commit" "${WS_KIND}s/${WS_NAME}"; then
			if [ "$QUIET" -gt 0 ]; then
				git -C "$new_root" rebase --abort
				die "Rebase conflict in quiet mode. Aborting. Old clone untouched."
			fi
			printf "\n*** Rebase conflict. Resolve in: %s\n" "$new_root" >&2
			printf "    Then: git rebase --continue\n" >&2
			printf "    Or:   git rebase --abort (to cancel update)\n" >&2
			printf "\n    Press Enter when resolved (or type 'abort'): " >&2
			local resp
			while true; do
				read -r resp || { git -C "$new_root" rebase --abort; die "EOF during rebase"; }
				case "$resp" in
					abort*) git -C "$new_root" rebase --abort; die "Rebase aborted by user." ;;
					*)
						if git -C "$new_root" rebase --continue 2>/dev/null; then
							break
						fi
						printf "    Still unresolved. Fix conflicts and press Enter: " >&2
						;;
				esac
			done
		fi
	else
		printf "  [dry] git -C %s rebase --onto <%s> <%s> %ss/%s\n" \
			"$new_root" "$NEW_ARTIFACT" "$OLD_ARTIFACT" "$WS_KIND" "$WS_NAME" >&2
	fi

	# ── Step 6: Regenerate derived binaries ──────────────────────────────
	printf "==> Regenerating derivations...\n" >&2

	local fbsd_ver
	fbsd_ver=$(get_foundation_version "$FOUNDATION_NAME")
	local global_db
	global_db=$(resolve_derivations_db "$fbsd_ver") || \
		die "No derivations db found for FreeBSD ${fbsd_ver}"
	local local_db="${RECIPE_DIR}/derivations.local"

	# Check each derivation: did its source change?
	local src derived cmd
	for db in "$local_db" "$global_db"; do
		[ -f "$db" ] || continue
		while IFS='	' read -r src derived cmd; do
			[ -n "$src" ] || continue
			case "$src" in \#*) continue ;; esac
			if ! $DRY_RUN; then
				# Did source change between old and new?
				if git -C "$new_root" diff --quiet "$old_commit" HEAD -- "$src" 2>/dev/null; then
					continue  # Source unchanged, skip
				fi
				printf "  regen: %s → %s\n" "$src" "$derived" >&2
				case "$WS_KIND" in
					system)    chroot "$new_root" sh -c "$cmd" ;;
					container) jexec "${WS_NAME}-new" sh -c "$cmd" ;;
				esac
			else
				printf "  [dry] regen if changed: %s → %s (%s)\n" "$src" "$derived" "$cmd" >&2
			fi
		done < "$db"
	done

	# ── Step 7: Validate ─────────────────────────────────────────────────
	printf "==> Validating...\n" >&2

	# Regenerate mtree for -new
	local ignore="${PARASA_DIR}/etc/mtree.ignore"
	run generate_mtree "$new_root" "$RECIPE_DIR" "$ignore"

	if ! $DRY_RUN; then
		"${SCRIPT_DIR}/diff.sh" -s "$WS_NAME" -k "$WS_KIND" -q || {
			if [ "$QUIET" -gt 0 ]; then
				die "Validation failed: unclassified drift in -new. Old clone untouched."
			fi
			printf "Unclassified drift found. Running interactive classification...\n" >&2
			"${SCRIPT_DIR}/diff.sh" -s "$WS_NAME" -k "$WS_KIND" || \
				die "Classification incomplete. Old clone untouched."
		}
	else
		printf "  [dry] diff.sh -s %s -k %s -q (validate)\n" "$WS_NAME" "$WS_KIND" >&2
	fi

	# ── Step 8: Offer swap ───────────────────────────────────────────────
	printf "==> Update built successfully at %ss/%s-new\n" "$WS_KIND" "$WS_NAME" >&2

	# Stop -new jail / unmount -new data
	case "$WS_KIND" in
		container)
			run jail -r "${WS_NAME}-new"
			;;
		system)
			# Unmount data datasets from -new tree
			run zunmount "${data_root}/var" 2>/dev/null
			run zunmount "${data_root}/usr-local" 2>/dev/null
			run zunmount "${data_root}/home" 2>/dev/null
			run zunmount "${data_root}/tmp" 2>/dev/null
			;;
	esac

	_UPDATE_STARTED=""  # Clear so cleanup trap doesn't fire

	if [ "$QUIET" -eq 0 ] && [ -t 0 ]; then
		printf "\nStop the old %s and try the new one? [y/N]: " "$WS_KIND" >&2
		local resp
		read -r resp || resp=""
		case "$resp" in
			[Yy]|[Yy][Ee][Ss])
				case "$WS_KIND" in
					container) run jail -r "$WS_NAME" ;;
				esac
				trap - EXIT
				if confirm "Finalize update now?"; then
					exec sh "${SCRIPT_DIR}/finalize_update.sh" -s "$WS_NAME" -k "$WS_KIND"
				else
					printf "When ready: finalize_update.sh -s %s -k %s\n" \
						"$WS_NAME" "$WS_KIND" >&2
				fi
				return
				;;
			*)
				printf "When ready: finalize_update.sh -s %s -k %s\n" \
					"$WS_NAME" "$WS_KIND" >&2
				;;
		esac
	else
		printf "Run: finalize_update.sh -s %s -k %s\n" "$WS_NAME" "$WS_KIND" >&2
	fi

	trap - EXIT
}

main
