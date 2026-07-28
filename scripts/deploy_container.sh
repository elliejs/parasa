#!/bin/sh
# deploy_container -- Deploy a container from zbamidbar to zbereshit.
#
# Sends a foundation's ZFS archive to zbereshit/containers/<name>, then
# applies the container branch via git checkout to layer container-specific
# state (mount.fstab, jail.conf, etc.) on top of the pristine foundation.
#
# Mirrors deploy_system.sh but for containers — no nextboot, containers
# are started via jail(8).
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
deploy_container -- Deploy a container from zbamidbar to zbereshit.

Usage:
  deploy_container -s NAME [-h] [-d]

Options:
  -h        Show this help and exit
  -d        Dry run: print commands without executing them
  -s NAME   Container name (required)

This command:
  1. Reads the container's foundation from recipes/containers/<name>/*.foundation
  2. Resolves the foundation's ZFS snapshot via foundation.git commit history
  3. Sends the foundation archive to zbereshit/containers/<name>
  4. Applies the container branch (git checkout) for container-specific state

After deploy, start the container with jail(8).

Examples:
  deploy_container -s nginx            Deploy container
  deploy_container -s nginx -d         Dry-run deploy
EOF
	exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────

DRY_RUN=false
CONTAINER_NAME=""

while getopts ":hds:" opt; do
	case "$opt" in
		h) print_help ;;
		d) DRY_RUN=true ;;
		s) CONTAINER_NAME="$OPTARG" ;;
		\?) die "Unknown option: -${OPTARG}. Use -h for help." ;;
		:)  die "Option -${OPTARG} requires an argument." ;;
	esac
done
shift $((OPTIND - 1))

[ -n "$CONTAINER_NAME" ] || die "Container name required (-s NAME). Use -h for help."

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
	local recipes="${PARASA_DIR}/recipes/containers/${CONTAINER_NAME}"
	[ -d "$recipes" ] || die "Container recipes dir not found: ${recipes}"

	FOUNDATION_NAME=$(get_foundation "$recipes")
	progress "Foundation: ${FOUNDATION_NAME}"

	# Validate foundation archive exists
	local archive="zbamidbar/foundation.zfs/foundations/${FOUNDATION_NAME}"
	zfs_dataset_exists "$archive" || \
		die "Foundation archive not found: ${archive}"

	# Mount foundation.git to read commit history
	run zmount zbamidbar/foundation.git /zbamidbar/foundation.git

	local foundation_git="/zbamidbar/foundation.git"
	local container_branch="containers/${CONTAINER_NAME}"
	local foundation_branch="${FOUNDATION_NAME}"

	# Find the foundation commit this container forks from
	if ! $DRY_RUN; then
		git_branch_exists "$foundation_git" "$container_branch" || \
			die "Container branch '${container_branch}' not found in foundation.git."
		git_branch_exists "$foundation_git" "$foundation_branch" || \
			die "Foundation branch '${foundation_branch}' not found in foundation.git."

		# The merge-base between the container branch and the foundation
		# branch gives us the foundation commit the container forked from.
		local fork_commit
		fork_commit=$(git -C "$foundation_git" merge-base \
			"refs/heads/${container_branch}" \
			"refs/heads/${foundation_branch}") || \
			die "Cannot find fork point between ${container_branch} and ${foundation_branch}"

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
	local dest="zbereshit/containers/${CONTAINER_NAME}"
	local container_mount="/containers/${CONTAINER_NAME}"

	progress "Deploying ${CONTAINER_NAME} to zbereshit/containers"

	# Ensure destination doesn't already exist (new deploy only)
	if zfs_dataset_exists "$dest"; then
		die "Dataset ${dest} already exists. Use update_container (future) for re-deploy."
	fi

	# Ensure foundation.zfs is mounted (archive source for materialization)
	run zmount zbamidbar/foundation.zfs /zbamidbar/foundation.zfs

	# Materialize the foundation on zbereshit (the "available foundations"
	# mirror), then shallow-clone it: containers are CoW clones of a
	# foundation snapshot, not independent full copies.
	ensure_foundation_on_zbereshit "$FOUNDATION_NAME" "$ARTIFACT_NAME"

	progress "Cloning foundation ${FOUNDATION_NAME}@${ARTIFACT_NAME} → ${dest}"
	if ! $DRY_RUN; then
		zfs clone -o mountpoint="$container_mount" -o canmount=on \
			"zbereshit/foundations/${FOUNDATION_NAME}@${ARTIFACT_NAME}" "$dest"
		zfs mount "$dest" 2>/dev/null || true
	else
		printf "  [dry] zfs clone zbereshit/foundations/%s@%s %s\n" \
			"$FOUNDATION_NAME" "$ARTIFACT_NAME" "$dest" >&2
	fi

	# Apply the container branch (recipe content) on top of the clone. The
	# cloned foundation tree carries .git from the foundation build.
	progress "Applying container branch"
	if ! $DRY_RUN; then
		git -C "$container_mount" fetch origin "containers/${CONTAINER_NAME}"
		git -C "$container_mount" checkout "containers/${CONTAINER_NAME}"
	else
		printf "  [dry] git -C %s fetch origin containers/%s\n" "$container_mount" "$CONTAINER_NAME" >&2
		printf "  [dry] git -C %s checkout containers/%s\n" "$container_mount" "$CONTAINER_NAME" >&2
	fi

	# Create mountpoint directories referenced by mount.fstab.
	# The foundation tree from make distribution may not include all of
	# them (e.g. /home is not part of the base distribution).
	ensure_mount_destinations "$container_mount"
}

# ── Mount destination creation ──────────────────────────────────────────────

# Read mount.fstab and mkdir any destination directories that don't exist
# inside the container root. jail(8) will fail at mount time if they're
# missing.
ensure_mount_destinations() {
	local root="$1"
	local fstab="${PARASA_DIR}/recipes/containers/${CONTAINER_NAME}/mount.fstab"
	[ -f "$fstab" ] || return 0

	progress "Ensuring mount destinations exist"
	local dest
	while IFS='	' read -r _ dest _; do
		[ -n "$dest" ] || continue
		case "$dest" in \#*) continue ;; esac
		if [ ! -d "$dest" ]; then
			run mkdir -p "$dest"
		fi
	done < "$fstab"
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	root_only

	resolve_snapshot
	deploy

	printf "\nContainer '%s' deployed to zbereshit/containers/%s.\n" \
		"$CONTAINER_NAME" "$CONTAINER_NAME" >&2
	printf "Start with: jail -c %s\n" "$CONTAINER_NAME" >&2

	# Cleanup mounts
	run zunmount zbamidbar/foundation.git
	run zunmount zbamidbar/foundation.zfs

	progress "Deploy complete."
}

main
