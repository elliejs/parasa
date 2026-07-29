#!/bin/sh
# update_foundation -- Check for upstream changes and rebuild a foundation.
#
# Reads the foundation's recipe (.conf), syncs the source tree to the latest
# commit on that branch, and rebuilds if the source has changed. Installs
# directly into the archive so both old and new ZFS snapshots coexist for
# incremental sends to systems/containers.
#
# See plans/build_system.md for design context.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
update_foundation -- Check for upstream changes and rebuild a foundation.

Usage:
  update_foundation [-h] [-d] [-s NAME] [-q [-q]]

Options:
  -h        Show this help and exit
  -d        Dry run: print commands without executing them
  -s NAME   Foundation name (required in quiet mode, prompted otherwise)
  -q        Quiet: suppress prompts, show progress.
  -qq       Silent: suppress prompts AND progress output.

This command:
  1. Reads the foundation's recipe for SRC_BRANCH, KERNCONF, MAKE_JOBS
  2. Syncs the source tree to the latest commit on that branch
  3. Compares the would-be artifact name to the current archive snapshot
  4. If unchanged: "nothing to update"
  5. If changed: rebuilds world+kernel and installs into the archive
  6. Commits the new state to foundation.git
  7. Creates a new ZFS snapshot on the archive

On failure during install, the archive is rolled back to the previous
snapshot via zfs rollback.

Examples:
  update_foundation                       Interactive update
  update_foundation -s 15.1releng         Update specific foundation
  update_foundation -s 15.1releng -qq     Silent update
  update_foundation -s 15.1releng -d      Dry-run update
EOF
	exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────

DRY_RUN=false
QUIET=0
FOUNDATION_NAME=""

while getopts ":hds:q" opt; do
	case "$opt" in
		h) print_help ;;
		d) DRY_RUN=true ;;
		s) FOUNDATION_NAME="$OPTARG" ;;
		q) QUIET=$((QUIET + 1)) ;;
		\?) die "Unknown option: -${OPTARG}. Use -h for help." ;;
		:)  die "Option -${OPTARG} requires an argument." ;;
	esac
done
shift $((OPTIND - 1))

# ── Dry-run wrapper ─────────────────────────────────────────────────────────

run() {
	if $DRY_RUN; then
		printf "  [dry] %s\n" "$*" >&2
	else
		"$@"
	fi
}

# ── Progress output ─────────────────────────────────────────────────────────

progress() {
	[ "$QUIET" -lt 2 ] && printf "\n==> %s\n" "$1" >&2
	return 0
}

# ── Cleanup trap ────────────────────────────────────────────────────────────

_INSTALL_STARTED=""
GIT_TMPDIR=""
CURRENT_ARTIFACT=""
FOUNDATION_ARCHIVE=""

update_cleanup() {
	# Roll back archive if we started modifying it
	if [ -n "$_INSTALL_STARTED" ] && [ -n "$CURRENT_ARTIFACT" ] && [ -n "$FOUNDATION_ARCHIVE" ]; then
		printf "Rolling back archive to @%s...\n" "$CURRENT_ARTIFACT" >&2
		zfs rollback -r "${FOUNDATION_ARCHIVE}@${CURRENT_ARTIFACT}" 2>/dev/null || true
		zfs rollback -r "${FOUNDATION_ARCHIVE}/var@${CURRENT_ARTIFACT}" 2>/dev/null || true
	fi
	[ -n "$GIT_TMPDIR" ] && rm -rf "$GIT_TMPDIR" 2>/dev/null || true
	zunmount zbamidbar/foundation.git 2>/dev/null || true
	zunmount zbamidbar/foundation.zfs 2>/dev/null || true
	zunmount zshemot/src.git 2>/dev/null || true
}

# ── Phase 1: Input & validation ────────────────────────────────────────────

collect_update_name() {
	if [ -n "$FOUNDATION_NAME" ]; then
		validate_name "$FOUNDATION_NAME" "Foundation name" || exit 1
		return
	fi
	if [ "$QUIET" -gt 0 ]; then
		die "Foundation name required in quiet mode (-s NAME)."
	fi

	# List foundations that have both a recipe and an archive (updatable)
	local recipes_dir="${RECIPES_DIR}/foundations"
	local idx=0 name
	for f in "$recipes_dir"/*.conf; do
		[ -f "$f" ] || continue
		name=$(basename "$f" .conf)
		# Must have an archive and be a complete recipe
		zfs_dataset_exists "zbamidbar/foundation.zfs/${name}" || continue
		recipe_is_complete "$f" || continue
		idx=$((idx + 1))
		[ "$idx" -eq 1 ] && printf "Updatable foundations:\n" >&2
		printf "  %d) %s\n" "$idx" "$name" >&2
	done

	[ "$idx" -eq 0 ] && die "No updatable foundations found."

	local resp
	while true; do
		printf "Foundation name or number: " >&2
		read -r resp || die "EOF reading foundation name"
		case "$resp" in
			[0-9]|[0-9][0-9])
				local cur=0
				for f in "$recipes_dir"/*.conf; do
					[ -f "$f" ] || continue
					name=$(basename "$f" .conf)
					zfs_dataset_exists "zbamidbar/foundation.zfs/${name}" || continue
					recipe_is_complete "$f" || continue
					cur=$((cur + 1))
					if [ "$cur" -eq "$resp" ]; then
						FOUNDATION_NAME="$name"
						return
					fi
				done
				printf "  Invalid number.\n" >&2
				continue
				;;
		esac
		if validate_name "$resp" "Foundation name"; then
			FOUNDATION_NAME="$resp"
			return
		fi
	done
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	root_only
	trap update_cleanup EXIT

	# Phase 1: Input & validation
	run zmount zbamidbar/foundation.zfs /zbamidbar/foundation.zfs

	collect_update_name

	local build_conf="${RECIPES_DIR}/foundations/${FOUNDATION_NAME}.conf"
	[ -f "$build_conf" ] || die "No recipe found for foundation '${FOUNDATION_NAME}'."
	recipe_is_complete "$build_conf" || \
		die "Recipe '${FOUNDATION_NAME}' is a template (missing SRC_BRANCH). Cannot update a template."

	FOUNDATION_ARCHIVE="zbamidbar/foundation.zfs/${FOUNDATION_NAME}"
	zfs_dataset_exists "$FOUNDATION_ARCHIVE" || \
		die "Foundation archive not found: ${FOUNDATION_ARCHIVE}. Run new_foundation first."

	SRC_BRANCH=$(sysrc -f "$build_conf" -qn SRC_BRANCH 2>/dev/null)
	KERNCONF=$(msysrc "$build_conf" KERNCONF "GENERIC")
	MAKE_JOBS=$(msysrc "$build_conf" MAKE_JOBS "$(sysctl -n hw.ncpu 2>/dev/null || printf 4)")

	# Phase 2: Check for updates
	progress "Syncing source tree"
	run zmount zshemot/src.git /zshemot/src.git

	if ! $DRY_RUN; then
		if [ ! -d "/zshemot/src.git/.git" ]; then
			die "No source tree at /zshemot/src.git. Run new_foundation first."
		fi
		git -C /zshemot/src.git fetch origin
		git -C /zshemot/src.git checkout "$SRC_BRANCH"
		git -C /zshemot/src.git pull --ff-only
	fi

	local would_be_artifact
	if ! $DRY_RUN; then
		would_be_artifact=$(get_artifact_name /zshemot/src.git "$FOUNDATION_NAME")
		CURRENT_ARTIFACT=$(get_current_artifact "$FOUNDATION_ARCHIVE")

		if [ "$would_be_artifact" = "$CURRENT_ARTIFACT" ]; then
			progress "Foundation '${FOUNDATION_NAME}' is up to date at ${CURRENT_ARTIFACT}."
			exit 0
		fi
	else
		would_be_artifact="[dry-run-artifact]"
		CURRENT_ARTIFACT="[dry-run-current]"
	fi

	progress "Update available"
	printf "  Foundation:    %s\n" "$FOUNDATION_NAME" >&2
	printf "  SRC_BRANCH:    %s\n" "$SRC_BRANCH" >&2
	printf "  KERNCONF:      %s\n" "$KERNCONF" >&2
	printf "  Current:       %s\n" "$CURRENT_ARTIFACT" >&2
	printf "  New:           %s\n" "$would_be_artifact" >&2

	if [ "$QUIET" -eq 0 ]; then
		confirm "Proceed with foundation update?" || exit 0
	fi

	# Phase 3: Build
	local srcdir="/zshemot/src.git"

	progress "Building world (make -j${MAKE_JOBS} buildworld)"
	run make -C "$srcdir" -j"$MAKE_JOBS" buildworld

	progress "Building kernel (make -j${MAKE_JOBS} buildkernel KERNCONF=${KERNCONF})"
	run make -C "$srcdir" -j"$MAKE_JOBS" buildkernel KERNCONF="$KERNCONF"

	# Phase 4: Install into archive
	local archive_mount="/zbamidbar/foundation.zfs/${FOUNDATION_NAME}"

	progress "Mounting archive"
	run zmount "${FOUNDATION_ARCHIVE}/var" "${archive_mount}/var"

	progress "Clearing immutable flags"
	if ! $DRY_RUN; then
		clear_mtree "$archive_mount"
	else
		printf "  [dry] clear_mtree %s\n" "$archive_mount" >&2
	fi

	_INSTALL_STARTED=true

	progress "Installing kernel to archive"
	run make -C "$srcdir" -j"$MAKE_JOBS" DESTDIR="$archive_mount" installkernel KERNCONF="$KERNCONF"

	progress "Installing world to archive"
	run make -C "$srcdir" -j"$MAKE_JOBS" DESTDIR="$archive_mount" installworld

	progress "Running distribution target"
	run make -C "$srcdir" -j"$MAKE_JOBS" DESTDIR="$archive_mount" distribution

	progress "Removing obsolete files"
	run make -C "$srcdir" DESTDIR="$archive_mount" BATCH_DELETE_OLD_FILES=YES delete-old

	# Phase 5: Git tracking
	progress "Committing to foundation.git"
	run zmount zbamidbar/foundation.git /zbamidbar/foundation.git

	GIT_TMPDIR=$(mktemp -d /tmp/foundation-update-git-XXXXXX)

	if ! $DRY_RUN; then
		git -C "$GIT_TMPDIR" init -b main
		git -C "$GIT_TMPDIR" config core.worktree "$archive_mount"
		git -C "$GIT_TMPDIR" remote add origin /zbamidbar/foundation.git
		git -C "$GIT_TMPDIR" fetch origin
		# Align to existing branch without touching work tree
		git -C "$GIT_TMPDIR" checkout -f "${FOUNDATION_NAME}"
		git -C "$GIT_TMPDIR" add -A
		git -C "$GIT_TMPDIR" commit -m "$would_be_artifact"
		git -C "$GIT_TMPDIR" push origin "${FOUNDATION_NAME}"
	else
		printf "  [dry] git init + fetch + checkout %s + add -A + commit '%s' + push\n" \
			"$FOUNDATION_NAME" "$would_be_artifact" >&2
	fi

	rm -rf "$GIT_TMPDIR"
	GIT_TMPDIR=""

	# Phase 6: Snapshot
	progress "Creating archive snapshots"
	run zfs snapshot "${FOUNDATION_ARCHIVE}@${would_be_artifact}"
	run zfs snapshot "${FOUNDATION_ARCHIVE}/var@${would_be_artifact}"

	# Install succeeded — clear rollback flag
	_INSTALL_STARTED=""

	# Cleanup mounts
	run zunmount zbamidbar/foundation.git
	run zunmount zbamidbar/foundation.zfs
	run zunmount zshemot/src.git

	# Clear trap (clean exit)
	trap - EXIT

	progress "Foundation '${FOUNDATION_NAME}' updated successfully."
	printf "  Old artifact: %s\n" "$CURRENT_ARTIFACT" >&2
	printf "  New artifact: %s\n" "$would_be_artifact" >&2
	printf "  Archive:      %s\n" "$FOUNDATION_ARCHIVE" >&2
	printf "\nRun 'update.sh -s <workspace>' to rebase systems/containers.\n" >&2
}

main
