#!/bin/sh
# deploy_system -- Deploy a system from zbamidbar to zbereshit.
#
# Sends a foundation's ZFS archive to zbereshit/systems/<name>, then
# applies the system branch via git checkout to layer system-specific
# state (fstab entries, etc.) on top of the pristine foundation.
#
# See plans/build_system.md Part 3 for the full design.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
deploy_system -- Deploy a system from zbamidbar to zbereshit.

Usage:
  deploy_system -s NAME [-h] [-d] [-n]

Options:
  -h        Show this help and exit
  -d        Dry run: print commands without executing them
  -s NAME   System name (required)
  -n        Set nextboot after deploy. Configures the system as the
            next boot target using nextboot(8). Without -n, the system
            is deployed but not made bootable.

This command:
  1. Reads the system's foundation from recipes/systems/<name>/*.foundation
  2. Resolves the foundation's ZFS snapshot via foundation.git commit history
  3. Sends the foundation archive to zbereshit/systems/<name>
  4. Applies the system branch (git checkout) for system-specific state
  5. Optionally sets nextboot for one-shot boot with auto-revert

Examples:
  deploy_system -s wonderland            Deploy without nextboot
  deploy_system -s wonderland -n         Deploy and set nextboot
  deploy_system -s wonderland -d         Dry-run deploy
EOF
	exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────

DRY_RUN=false
SYSTEM_NAME=""
NEXTBOOT=false

while getopts ":hds:n" opt; do
	case "$opt" in
		h) print_help ;;
		d) DRY_RUN=true ;;
		s) SYSTEM_NAME="$OPTARG" ;;
		n) NEXTBOOT=true ;;
		\?) die "Unknown option: -${OPTARG}. Use -h for help." ;;
		:)  die "Option -${OPTARG} requires an argument." ;;
	esac
done
shift $((OPTIND - 1))

[ -n "$SYSTEM_NAME" ] || die "System name required (-s NAME). Use -h for help."

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
	printf "\n==> %s\n" "$1" >&2
}

# ── Resolve foundation and snapshot ─────────────────────────────────────────

resolve_snapshot() {
	local recipes="${PARASA_DIR}/recipes/systems/${SYSTEM_NAME}"
	[ -d "$recipes" ] || die "System recipes dir not found: ${recipes}"

	FOUNDATION_NAME=$(get_foundation "$recipes")
	progress "Foundation: ${FOUNDATION_NAME}"

	# Validate foundation archive exists
	local archive="zbamidbar/foundation.zfs/foundations/${FOUNDATION_NAME}"
	zfs_dataset_exists "$archive" || \
		die "Foundation archive not found: ${archive}"

	# Mount foundation.git to read commit history
	run zmount zbamidbar/foundation.git /zbamidbar/foundation.git

	local foundation_git="/zbamidbar/foundation.git"
	local system_branch="systems/${SYSTEM_NAME}"
	local foundation_branch="${FOUNDATION_NAME}"

	# Find the foundation commit this system forks from
	if ! $DRY_RUN; then
		git_branch_exists "$foundation_git" "$system_branch" || \
			die "System branch '${system_branch}' not found in foundation.git."
		git_branch_exists "$foundation_git" "$foundation_branch" || \
			die "Foundation branch '${foundation_branch}' not found in foundation.git."

		# The merge-base between the system branch and the foundation
		# branch gives us the foundation commit the system forked from.
		local fork_commit
		fork_commit=$(git -C "$foundation_git" merge-base \
			"refs/heads/${system_branch}" \
			"refs/heads/${foundation_branch}") || \
			die "Cannot find fork point between ${system_branch} and ${foundation_branch}"

		# The commit message IS the artifact name
		ARTIFACT_NAME=$(git -C "$foundation_git" log -1 --format='%s' "$fork_commit")
	else
		ARTIFACT_NAME="[dry-run-artifact]"
	fi

	progress "Artifact: ${ARTIFACT_NAME}"

	# Validate the snapshot exists
	local snap="${archive}@${ARTIFACT_NAME}"
	if ! $DRY_RUN; then
		zfs list -H -t snapshot -o name "$snap" >/dev/null 2>&1 || \
			die "Snapshot not found: ${snap}"
	fi
}

# ── Deploy ──────────────────────────────────────────────────────────────────

deploy() {
	local src="zbamidbar/foundation.zfs/foundations/${FOUNDATION_NAME}@${ARTIFACT_NAME}"
	local dest="zbereshit/systems/${SYSTEM_NAME}"

	progress "Deploying ${SYSTEM_NAME} to zbereshit"

	# Ensure destination doesn't already exist (new deploy only)
	if zfs_dataset_exists "$dest"; then
		die "Dataset ${dest} already exists. Use update_system (future) for re-deploy."
	fi

	# Ensure foundation.zfs is mounted
	run zmount zbamidbar/foundation.zfs /zbamidbar/foundation.zfs

	# Full send (new system)
	progress "ZFS send → ${dest}"
	if ! $DRY_RUN; then
		zfs send -R "$src" | \
			zfs recv -F -o mountpoint=none -o canmount=noauto "$dest"
	else
		printf "  [dry] zfs send -R %s | zfs recv -F -o mountpoint=none %s\n" "$src" "$dest" >&2
	fi

	# Apply system branch via git checkout
	progress "Applying system branch"
	local system_mount="/zbereshit/systems/${SYSTEM_NAME}"
	run zmount "$dest" "$system_mount"

	if ! $DRY_RUN; then
		if [ ! -d "${system_mount}/.git" ]; then
			# New archive (no .git) — create .git as child dataset so
			# future zfs send -R of this system excludes git state.
			zfs create -o mountpoint="${system_mount}/.git" -o canmount=on \
				"${dest}/.git"
			git -C "$system_mount" init -b main
			git -C "$system_mount" remote add origin /zbamidbar/foundation.git
		fi
		git -C "$system_mount" fetch origin
		git -C "$system_mount" checkout -f "systems/${SYSTEM_NAME}"
	else
		printf "  [dry] zfs create %s/.git + git init + fetch + checkout -f systems/%s\n" \
			"$dest" "$SYSTEM_NAME" >&2
	fi

	run zunmount "$dest"
}

# ── Nextboot ────────────────────────────────────────────────────────────────

set_nextboot() {
	local dest="zbereshit/systems/${SYSTEM_NAME}"

	progress "Setting nextboot"

	# Set root mountpoint (without mounting — dataset should be unmounted)
	run zfs set -u mountpoint=/ "$dest"

	# Configure nextboot for one-shot boot
	run nextboot -e "vfs.root.mountfrom=\"zfs:${dest}\""

	printf "\nSystem '%s' set as next boot target.\n" "$SYSTEM_NAME" >&2
	printf "This is a one-shot setting — if boot fails, the system\n" >&2
	printf "will automatically revert to the previous boot dataset.\n" >&2

	# Only ask about reboot if stdout is a terminal
	if [ -t 0 ]; then
		confirm "Reboot now?" && run reboot
	fi
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	root_only

	resolve_snapshot
	deploy

	if $NEXTBOOT; then
		set_nextboot
	else
		printf "\nSystem '%s' deployed to zbereshit/systems/%s.\n" \
			"$SYSTEM_NAME" "$SYSTEM_NAME" >&2
		if [ -t 0 ] && confirm "Set as next boot target?"; then
			set_nextboot
		fi
	fi

	# Cleanup mounts
	run zunmount zbamidbar/foundation.git
	run zunmount zbamidbar/foundation.zfs

	progress "Deploy complete."
}

main
