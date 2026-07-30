#!/bin/sh
# destroy_container -- Remove all traces of a container.
#
# Handles both fully and partially constructed containers. Removes:
#   - Running jail (stopped first)
#   - zbereshit/containers/<name> (deployed clone + .git)
#   - zbamidbar/container-data/<name> (var, usr-local, home, tmp, custom)
#   - containers/<name> branch in foundation.git
#   - Recipe directory in recipes repo (optional, with confirmation)
#
# Safe to run on partial constructions (e.g. after a failed new_container).
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
destroy_container -- Remove all traces of a container.

Usage:
  destroy_container -s NAME [-h] [-d] [-q] [-r]

Options:
  -h        Show this help and exit
  -d        Dry run: print commands without executing them
  -s NAME   Container name (required)
  -q        Quiet: skip confirmation prompts

This command removes:
  1. Running jail (stopped first)
  2. zbereshit/containers/<name> (deployed root)
  3. zbamidbar/container-data/<name>/* (persistent data)
  4. containers/<name> branch in foundation.git

The recipe directory is kept so the container can be re-created.
Safe to run on partially constructed containers.

Examples:
  destroy_container -s nginx           Interactive destroy
  destroy_container -s nginx -q        Destroy without prompts
  destroy_container -s nginx -d        Dry-run destroy
EOF
	exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────

DRY_RUN=false
QUIET=0
CONTAINER_NAME=""
while getopts ":hds:q" opt; do
	case "$opt" in
		h) print_help ;;
		d) DRY_RUN=true ;;
		s) CONTAINER_NAME="$OPTARG" ;;
		q) QUIET=1 ;;
		\?) die "Unknown option: -${OPTARG}. Use -h for help." ;;
		:)  die "Option -${OPTARG} requires an argument." ;;
	esac
done

# ── Interactive name selection ──────────────────────────────────────────────

collect_container_name() {
	if [ -n "$CONTAINER_NAME" ]; then
		validate_name "$CONTAINER_NAME" "Container name" || exit 1
		return
	fi
	if [ "$QUIET" -gt 0 ]; then
		die "Container name required in quiet mode (-s NAME)."
	fi

	# List containers that have any trace (deployed, data, recipe, or branch)
	local idx=0 name seen=""
	# Deployed clones
	for ds in $(zfs list -r -H -o name zbereshit/containers 2>/dev/null); do
		[ "$ds" = "zbereshit/containers" ] && continue
		name="${ds#zbereshit/containers/}"
		# Skip .git children and sub-datasets
		case "$name" in */*) continue ;; esac
		case "$seen" in *" ${name} "*) continue ;; esac
		seen="${seen} ${name} "
		idx=$((idx + 1))
		[ "$idx" -eq 1 ] && printf "Containers:\n" >&2
		printf "  %d) %s\n" "$idx" "$name" >&2
	done
	# Data datasets not already listed
	for ds in $(zfs list -r -H -o name zbamidbar/container-data 2>/dev/null); do
		[ "$ds" = "zbamidbar/container-data" ] && continue
		name="${ds#zbamidbar/container-data/}"
		case "$name" in */*) continue ;; esac
		case "$seen" in *" ${name} "*) continue ;; esac
		seen="${seen} ${name} "
		idx=$((idx + 1))
		[ "$idx" -eq 1 ] && printf "Containers:\n" >&2
		printf "  %d) %s (data only)\n" "$idx" "$name" >&2
	done
	# Recipes not already listed
	for d in "${RECIPES_DIR}/containers"/*/; do
		[ -d "$d" ] || continue
		name=$(basename "$d")
		[ "$name" = "*" ] && continue
		case "$seen" in *" ${name} "*) continue ;; esac
		seen="${seen} ${name} "
		idx=$((idx + 1))
		[ "$idx" -eq 1 ] && printf "Containers:\n" >&2
		printf "  %d) %s (recipe only)\n" "$idx" "$name" >&2
	done

	[ "$idx" -eq 0 ] && die "No containers found."

	local resp
	while true; do
		printf "Container name or number: " >&2
		read -r resp || die "EOF reading container name"
		case "$resp" in
			[0-9]|[0-9][0-9])
				local cur=0
				# Replay the same scan to resolve number
				for ds in $(zfs list -r -H -o name zbereshit/containers 2>/dev/null); do
					[ "$ds" = "zbereshit/containers" ] && continue
					name="${ds#zbereshit/containers/}"
					case "$name" in */*) continue ;; esac
					cur=$((cur + 1))
					if [ "$cur" -eq "$resp" ]; then CONTAINER_NAME="$name"; return; fi
				done
				local seen2=""
				for ds in $(zfs list -r -H -o name zbereshit/containers 2>/dev/null); do
					[ "$ds" = "zbereshit/containers" ] && continue
					name="${ds#zbereshit/containers/}"
					case "$name" in */*) continue ;; esac
					seen2="${seen2} ${name} "
				done
				for ds in $(zfs list -r -H -o name zbamidbar/container-data 2>/dev/null); do
					[ "$ds" = "zbamidbar/container-data" ] && continue
					name="${ds#zbamidbar/container-data/}"
					case "$name" in */*) continue ;; esac
					case "$seen2" in *" ${name} "*) continue ;; esac
					seen2="${seen2} ${name} "
					cur=$((cur + 1))
					if [ "$cur" -eq "$resp" ]; then CONTAINER_NAME="$name"; return; fi
				done
				for d in "${RECIPES_DIR}/containers"/*/; do
					[ -d "$d" ] || continue
					name=$(basename "$d")
					[ "$name" = "*" ] && continue
					case "$seen2" in *" ${name} "*) continue ;; esac
					cur=$((cur + 1))
					if [ "$cur" -eq "$resp" ]; then CONTAINER_NAME="$name"; return; fi
				done
				printf "  Invalid number.\n" >&2
				continue
				;;
		esac
		if validate_name "$resp" "Container name"; then
			CONTAINER_NAME="$resp"
			return
		fi
	done
}

collect_container_name

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

# ── Discovery ──────────────────────────────────────────────────────────────

discover() {
	_FOUND=""
	local cpath="/containers/${CONTAINER_NAME}"

	printf "Scanning for container '%s'...\n" "$CONTAINER_NAME" >&2

	# Jail running?
	if jls -j "$CONTAINER_NAME" >/dev/null 2>&1; then
		printf "  ● jail running\n" >&2
		_FOUND="${_FOUND} jail"
	fi

	# Deployed clone
	if zfs_dataset_exists "zbereshit/containers/${CONTAINER_NAME}"; then
		printf "  ● zbereshit/containers/%s\n" "$CONTAINER_NAME" >&2
		_FOUND="${_FOUND} clone"
	fi

	# Data datasets
	if zfs_dataset_exists "zbamidbar/container-data/${CONTAINER_NAME}"; then
		printf "  ● zbamidbar/container-data/%s\n" "$CONTAINER_NAME" >&2
		_FOUND="${_FOUND} data"
	fi

	# Git branch
	if zfs_dataset_exists "zbamidbar/foundation.git"; then
		zmount zbamidbar/foundation.git /zbamidbar/foundation.git 2>/dev/null || true
		if git_branch_exists /zbamidbar/foundation.git "containers/${CONTAINER_NAME}" 2>/dev/null; then
			printf "  ● foundation.git branch containers/%s\n" "$CONTAINER_NAME" >&2
			_FOUND="${_FOUND} branch"
		fi
	fi


	if [ -z "$_FOUND" ]; then
		printf "  (nothing found)\n" >&2
		return 1
	fi
	return 0
}

# ── Destroy steps ──────────────────────────────────────────────────────────

stop_jail() {
	case "$_FOUND" in *jail*)
		progress "Stopping jail"
		run jail -f "${RECIPES_DIR}/jail.conf" -r "$CONTAINER_NAME" 2>/dev/null || \
			run jail -r "$CONTAINER_NAME" 2>/dev/null || true
	;; esac
}

unmount_all() {
	local cpath="/containers/${CONTAINER_NAME}"
	[ -d "$cpath" ] || return 0

	progress "Unmounting everything under ${cpath}"

	# Unmount all filesystems mounted under the container path
	# (data datasets, nullfs mounts, .git). Reverse sort so children first.
	if ! $DRY_RUN; then
		mount -p | awk -v prefix="$cpath/" '$2 == prefix || substr($2,1,length(prefix)) == prefix {print $2}' | \
			sort -r | while read -r mnt; do
			printf "  unmount %s\n" "$mnt" >&2
			umount "$mnt" 2>/dev/null || umount -f "$mnt" 2>/dev/null || true
		done
	fi

	# Reset mountpoints on data datasets back to none
	if zfs_dataset_exists "zbamidbar/container-data/${CONTAINER_NAME}"; then
		zfs list -r -H -o name "zbamidbar/container-data/${CONTAINER_NAME}" 2>/dev/null | \
			while read -r ds; do
			zfs set mountpoint=none "$ds" 2>/dev/null || true
		done
	fi
}

destroy_clone() {
	case "$_FOUND" in *clone*)
		local dest="zbereshit/containers/${CONTAINER_NAME}"
		local cpath="/containers/${CONTAINER_NAME}"

		progress "Destroying zbereshit/containers/${CONTAINER_NAME}"

		# Clear schg flags so zfs destroy can remove files
		if [ -d "$cpath" ] && ! $DRY_RUN; then
			clear_mtree "$cpath" 2>/dev/null || true
		fi

		# .git child dataset must be destroyed first
		if zfs_dataset_exists "${dest}/.git"; then
			run zfs destroy -f "${dest}/.git"
		fi

		run zfs destroy -rf "$dest"
	;; esac
}

destroy_data() {
	case "$_FOUND" in *data*)
		local data_root="zbamidbar/container-data/${CONTAINER_NAME}"

		progress "Destroying zbamidbar/container-data/${CONTAINER_NAME}"

		# Unmount any mounted children first
		if ! $DRY_RUN; then
			zfs list -r -H -o name "$data_root" 2>/dev/null | \
				sort -r | while read -r ds; do
				zfs unmount "$ds" 2>/dev/null || true
			done
		fi

		run zfs destroy -r "$data_root"
	;; esac
}

destroy_branch() {
	case "$_FOUND" in *branch*)
		progress "Deleting foundation.git branch containers/${CONTAINER_NAME}"
		run zmount zbamidbar/foundation.git /zbamidbar/foundation.git
		run git -C /zbamidbar/foundation.git branch -D "containers/${CONTAINER_NAME}"
		run git -C /zbamidbar/foundation.git gc --prune=now
	;; esac
}


# ── Main ────────────────────────────────────────────────────────────────────

main() {
	root_only

	discover || { printf "Nothing to destroy.\n" >&2; exit 0; }

	if [ "$QUIET" -eq 0 ] && ! $DRY_RUN; then
		confirm "Destroy container '${CONTAINER_NAME}'?" || exit 0
	fi

	stop_jail
	unmount_all
	destroy_data
	destroy_clone
	destroy_branch

	zunmount zbamidbar/foundation.git 2>/dev/null || true

	progress "Container '${CONTAINER_NAME}' destroyed."
}

main
