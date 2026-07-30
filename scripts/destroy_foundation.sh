#!/bin/sh
# destroy_foundation -- Remove all traces of a foundation.
#
# Handles both fully and partially constructed foundations. Removes:
#   - zbamidbar/foundation.zfs/<name> (archive + var child + snapshots)
#   - zbereshit/foundations/<name> (deployed copy)
#   - <name> branch in foundation.git
#   - zshemot/buildspace/<name> (leftover from failed build)
#   - Recipe file in recipes repo (optional, with confirmation)
#
# Refuses to destroy foundations that are in use by containers or systems.
# Safe to run on partial constructions (e.g. after a failed new_foundation).
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
destroy_foundation -- Remove all traces of a foundation.

Usage:
  destroy_foundation [-h] [-d] [-s NAME] [-q]

Options:
  -h        Show this help and exit
  -d        Dry run: print commands without executing them
  -s NAME   Foundation name (prompted if omitted)
  -q        Quiet: skip confirmation prompts

This command removes:
  1. zbamidbar/foundation.zfs/<name> (archive + snapshots)
  2. zbereshit/foundations/<name> (deployed copy)
  3. <name> branch in foundation.git
  4. zshemot/buildspace/<name> (leftover build workspace)

Refuses to destroy if any container or system recipe references this
foundation. The recipe .conf file is kept so the foundation can be rebuilt.
Safe to run on partially constructed foundations.

Examples:
  destroy_foundation                         Interactive
  destroy_foundation -s 15.1releng           Named
  destroy_foundation -s 15.1releng -q        No prompts
  destroy_foundation -s 15.1releng -d        Dry run
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
		q) QUIET=1 ;;
		\?) die "Unknown option: -${OPTARG}. Use -h for help." ;;
		:)  die "Option -${OPTARG} requires an argument." ;;
	esac
done

# ── Interactive name selection ──────────────────────────────────────────────

collect_foundation_name() {
	if [ -n "$FOUNDATION_NAME" ]; then
		validate_name "$FOUNDATION_NAME" "Foundation name" || exit 1
		return
	fi
	if [ "$QUIET" -gt 0 ]; then
		die "Foundation name required in quiet mode (-s NAME)."
	fi

	# List foundations that have any trace (archive, deployed, recipe, branch, buildspace)
	local idx=0 name seen=""

	# Archives
	for ds in $(zfs list -r -H -o name zbamidbar/foundation.zfs 2>/dev/null); do
		[ "$ds" = "zbamidbar/foundation.zfs" ] && continue
		name="${ds#zbamidbar/foundation.zfs/}"
		case "$name" in */*) continue ;; esac
		case "$seen" in *" ${name} "*) continue ;; esac
		seen="${seen} ${name} "
		idx=$((idx + 1))
		[ "$idx" -eq 1 ] && printf "Foundations:\n" >&2
		printf "  %d) %s\n" "$idx" "$name" >&2
	done

	# Deployed copies not already listed
	for ds in $(zfs list -r -H -o name zbereshit/foundations 2>/dev/null); do
		[ "$ds" = "zbereshit/foundations" ] && continue
		name="${ds#zbereshit/foundations/}"
		case "$name" in */*) continue ;; esac
		case "$seen" in *" ${name} "*) continue ;; esac
		seen="${seen} ${name} "
		idx=$((idx + 1))
		[ "$idx" -eq 1 ] && printf "Foundations:\n" >&2
		printf "  %d) %s (deployed only)\n" "$idx" "$name" >&2
	done

	# Buildspace leftovers not already listed
	for ds in $(zfs list -r -H -o name zshemot/buildspace 2>/dev/null); do
		[ "$ds" = "zshemot/buildspace" ] && continue
		name="${ds#zshemot/buildspace/}"
		case "$name" in */*) continue ;; esac
		case "$seen" in *" ${name} "*) continue ;; esac
		seen="${seen} ${name} "
		idx=$((idx + 1))
		[ "$idx" -eq 1 ] && printf "Foundations:\n" >&2
		printf "  %d) %s (buildspace only)\n" "$idx" "$name" >&2
	done

	# Recipes not already listed
	for f in "${RECIPES_DIR}/foundations"/*.conf; do
		[ -f "$f" ] || continue
		name=$(basename "$f" .conf)
		case "$seen" in *" ${name} "*) continue ;; esac
		seen="${seen} ${name} "
		idx=$((idx + 1))
		[ "$idx" -eq 1 ] && printf "Foundations:\n" >&2
		printf "  %d) %s (recipe only)\n" "$idx" "$name" >&2
	done

	[ "$idx" -eq 0 ] && die "No foundations found."

	local resp
	while true; do
		printf "Foundation name or number: " >&2
		read -r resp || die "EOF reading foundation name"
		case "$resp" in
			[0-9]|[0-9][0-9])
				local cur=0
				# Replay scan to resolve number
				for ds in $(zfs list -r -H -o name zbamidbar/foundation.zfs 2>/dev/null); do
					[ "$ds" = "zbamidbar/foundation.zfs" ] && continue
					name="${ds#zbamidbar/foundation.zfs/}"
					case "$name" in */*) continue ;; esac
					cur=$((cur + 1))
					if [ "$cur" -eq "$resp" ]; then FOUNDATION_NAME="$name"; return; fi
				done
				local seen2=""
				for ds in $(zfs list -r -H -o name zbamidbar/foundation.zfs 2>/dev/null); do
					[ "$ds" = "zbamidbar/foundation.zfs" ] && continue
					name="${ds#zbamidbar/foundation.zfs/}"
					case "$name" in */*) continue ;; esac
					seen2="${seen2} ${name} "
				done
				for ds in $(zfs list -r -H -o name zbereshit/foundations 2>/dev/null); do
					[ "$ds" = "zbereshit/foundations" ] && continue
					name="${ds#zbereshit/foundations/}"
					case "$name" in */*) continue ;; esac
					case "$seen2" in *" ${name} "*) continue ;; esac
					seen2="${seen2} ${name} "
					cur=$((cur + 1))
					if [ "$cur" -eq "$resp" ]; then FOUNDATION_NAME="$name"; return; fi
				done
				for ds in $(zfs list -r -H -o name zshemot/buildspace 2>/dev/null); do
					[ "$ds" = "zshemot/buildspace" ] && continue
					name="${ds#zshemot/buildspace/}"
					case "$name" in */*) continue ;; esac
					case "$seen2" in *" ${name} "*) continue ;; esac
					seen2="${seen2} ${name} "
					cur=$((cur + 1))
					if [ "$cur" -eq "$resp" ]; then FOUNDATION_NAME="$name"; return; fi
				done
				for f in "${RECIPES_DIR}/foundations"/*.conf; do
					[ -f "$f" ] || continue
					name=$(basename "$f" .conf)
					case "$seen2" in *" ${name} "*) continue ;; esac
					cur=$((cur + 1))
					if [ "$cur" -eq "$resp" ]; then FOUNDATION_NAME="$name"; return; fi
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

collect_foundation_name

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

# ── Dependency check ──────────────────────────────────────────────────────

check_dependents() {
	local deps="" ds name origin

	# Check deployed containers cloned from this foundation
	for ds in $(zfs list -r -H -o name zbereshit/containers 2>/dev/null); do
		[ "$ds" = "zbereshit/containers" ] && continue
		name="${ds#zbereshit/containers/}"
		case "$name" in */*) continue ;; esac
		origin=$(zfs get -H -o value origin "$ds" 2>/dev/null) || continue
		case "$origin" in
			"zbereshit/foundations/${FOUNDATION_NAME}@"*)
				deps="${deps}  container: ${name}\n" ;;
		esac
	done

	# Check deployed systems cloned from this foundation
	for ds in $(zfs list -r -H -o name zbereshit/systems 2>/dev/null); do
		[ "$ds" = "zbereshit/systems" ] && continue
		name="${ds#zbereshit/systems/}"
		case "$name" in */*) continue ;; esac
		origin=$(zfs get -H -o value origin "$ds" 2>/dev/null) || continue
		case "$origin" in
			"zbereshit/foundations/${FOUNDATION_NAME}@"*)
				deps="${deps}  system: ${name}\n" ;;
		esac
	done

	if [ -n "$deps" ]; then
		printf "Cannot destroy foundation '%s' — in use by:\n" "$FOUNDATION_NAME" >&2
		printf "$deps" >&2
		printf "Destroy those workspaces first.\n" >&2
		exit 1
	fi
}

# ── Discovery ──────────────────────────────────────────────────────────────

discover() {
	_FOUND=""

	printf "Scanning for foundation '%s'...\n" "$FOUNDATION_NAME" >&2

	# Archive
	if zfs_dataset_exists "zbamidbar/foundation.zfs/${FOUNDATION_NAME}"; then
		printf "  ● zbamidbar/foundation.zfs/%s\n" "$FOUNDATION_NAME" >&2
		_FOUND="${_FOUND} archive"
	fi

	# Deployed copy on zbereshit
	if zfs_dataset_exists "zbereshit/foundations/${FOUNDATION_NAME}"; then
		printf "  ● zbereshit/foundations/%s\n" "$FOUNDATION_NAME" >&2
		_FOUND="${_FOUND} deployed"
	fi

	# Git branch
	if zfs_dataset_exists "zbamidbar/foundation.git"; then
		zmount zbamidbar/foundation.git /zbamidbar/foundation.git 2>/dev/null || true
		if git_branch_exists /zbamidbar/foundation.git "$FOUNDATION_NAME" 2>/dev/null; then
			printf "  ● foundation.git branch %s\n" "$FOUNDATION_NAME" >&2
			_FOUND="${_FOUND} branch"
		fi
	fi

	# Leftover buildspace
	if zfs_dataset_exists "zshemot/buildspace/${FOUNDATION_NAME}"; then
		printf "  ● zshemot/buildspace/%s (leftover)\n" "$FOUNDATION_NAME" >&2
		_FOUND="${_FOUND} buildspace"
	fi

	if [ -z "$_FOUND" ]; then
		printf "  (nothing found)\n" >&2
		return 1
	fi
	return 0
}

# ── Destroy steps ──────────────────────────────────────────────────────────

destroy_archive() {
	case "$_FOUND" in *archive*)
		local archive="zbamidbar/foundation.zfs/${FOUNDATION_NAME}"

		progress "Destroying zbamidbar/foundation.zfs/${FOUNDATION_NAME}"

		run zmount zbamidbar/foundation.zfs /zbamidbar/foundation.zfs

		# var child dataset first
		if zfs_dataset_exists "${archive}/var"; then
			run zfs destroy -rf "${archive}/var"
		fi

		run zfs destroy -rf "$archive"
	;; esac
}

destroy_deployed() {
	case "$_FOUND" in *deployed*)
		local dest="zbereshit/foundations/${FOUNDATION_NAME}"

		progress "Destroying zbereshit/foundations/${FOUNDATION_NAME}"

		# Clear schg flags
		local mnt
		mnt=$(zfs get -H -o value mountpoint "$dest" 2>/dev/null) || true
		if [ -n "$mnt" ] && [ "$mnt" != "none" ] && [ -d "$mnt" ]; then
			if ! $DRY_RUN; then
				clear_mtree "$mnt" 2>/dev/null || true
			fi
		fi

		run zfs destroy -rf "$dest"
	;; esac
}

destroy_branch() {
	case "$_FOUND" in *branch*)
		progress "Deleting foundation.git branch ${FOUNDATION_NAME}"
		run zmount zbamidbar/foundation.git /zbamidbar/foundation.git
		run git -C /zbamidbar/foundation.git branch -D "$FOUNDATION_NAME"
		run git -C /zbamidbar/foundation.git gc --prune=now
	;; esac
}

destroy_buildspace() {
	case "$_FOUND" in *buildspace*)
		local bs="zshemot/buildspace/${FOUNDATION_NAME}"

		progress "Destroying zshemot/buildspace/${FOUNDATION_NAME}"

		# May have .git and var child datasets
		if zfs_dataset_exists "${bs}/.git"; then
			run zfs destroy -rf "${bs}/.git"
		fi
		if zfs_dataset_exists "${bs}/var"; then
			run zfs destroy -rf "${bs}/var"
		fi

		run zfs destroy -rf "$bs"
	;; esac
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	root_only

	check_dependents

	discover || { printf "Nothing to destroy.\n" >&2; exit 0; }

	if [ "$QUIET" -eq 0 ] && ! $DRY_RUN; then
		confirm "Destroy foundation '${FOUNDATION_NAME}'?" || exit 0
	fi

	destroy_deployed
	destroy_archive
	destroy_branch
	destroy_buildspace

	zunmount zbamidbar/foundation.git 2>/dev/null || true
	zunmount zbamidbar/foundation.zfs 2>/dev/null || true

	progress "Foundation '${FOUNDATION_NAME}' destroyed."
}

main
