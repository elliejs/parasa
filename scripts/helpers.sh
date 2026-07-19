#!/bin/sh
# helpers.sh -- shared utilities for parasa stage scripts.
# Source this file; do not execute it directly.

# ── Messaging ─────────────────────────────────────────────────────────────────

# Print an error message to stderr and return 1.
# Usage: error "something went wrong" || return
error() {
	printf "ERROR: %s\n" "$1" >&2
	return 1
}

# Print an error message to stderr and exit.
die() {
	printf "ERROR: %s\n" "$1" >&2
	exit 1
}

# ── Access control ────────────────────────────────────────────────────────────

root_only() {
	[ "$(id -u)" -eq 0 ] || die "This script must be run as root."
}

# ── Interactive prompts ───────────────────────────────────────────────────────

# Prompt for yes/no. Returns 0 on yes, 1 on no. Empty input = yes.
# Usage: confirm "Are you sure?" || exit
confirm() {
	local prompt="${1:-Are you sure?}" resp
	while true; do
		printf "%s [Y/n]: " "$prompt" >&2
		read -r resp || return 1   # EOF = no
		case "$resp" in
			""|[Yy]|[Yy][Ee][Ss]) return 0 ;;
			[Nn]|[Nn][Oo])        return 1 ;;
			*) printf "Please answer y or n.\n" >&2 ;;
		esac
	done
}

# Truthy/falsy string tests.
yesish() {
	case "$1" in
		[Yy][Ee][Ss]|[Yy]|[Tt][Rr][Uu][Ee]|1|""|[Tt]) return 0 ;;
		*) return 1 ;;
	esac
}

noish() {
	case "$1" in
		[Nn][Oo]|[Nn]|[Ff][Aa][Ll][Ss][Ee]|0|[Ff]) return 0 ;;
		*) return 1 ;;
	esac
}

# ── ZFS helpers ───────────────────────────────────────────────────────────────

# Mount a ZFS dataset at the given path (default: /dataset).
zmount() {
	local dataset="${1:?zmount: dataset required}"
	local dest="${2:-/${1}}"
	zfs set mountpoint="$dest" "$dataset"
	zfs mount "$dataset"
}

# Unmount a ZFS dataset and clear its mountpoint.
zunmount() {
	local dataset="${1:?zunmount: dataset required}"
	sync
	zfs unmount "$dataset" 2>/dev/null || true
	zfs set mountpoint=none "$dataset"
}

# Create a ZFS dataset if it doesn't already exist.
# Usage: ztouch pool/dataset [-o key=val ...]
ztouch() {
	local dataset="${1:?ztouch: dataset required}"
	shift
	zfs list -H -o name "$dataset" >/dev/null 2>&1 || zfs create "$@" "$dataset"
}

# Scoped mount: mount a dataset, run a callback, unmount only if it
# wasn't already mounted on entry.
# Usage: zwith pool/dataset callback_fn [args...]
zwith() {
	local dataset="${1:?zwith: dataset required}"
	shift
	local callback="$1"
	shift

	local was_mounted=false rc
	if yesish "$(zfs get -H -o value mounted "$dataset" 2>/dev/null)"; then
		was_mounted=true
	else
		zfs mount "$dataset" || return 1
	fi

	"$callback" "$@"
	rc=$?

	$was_mounted || zunmount "$dataset"
	return $rc
}

# ── mtree helpers ─────────────────────────────────────────────────────────────

# Generate mtree.dist for a tree, writing to the target's minhag directory.
# Strips time/nlink/flags (git-incompatible), adds sha512.
generate_mtree() {
	local tree="${1:?generate_mtree: tree root required}"
	local minhag_dir="${2:?generate_mtree: minhag target directory required}"
	local ignore="${3:?generate_mtree: ignore file required}"
	[ -d "$minhag_dir" ] || die "generate_mtree: minhag dir not found: ${minhag_dir}"
	[ -f "$ignore" ]     || die "generate_mtree: ignore file not found: ${ignore}"
	mtree -c -x -R time,nlink,flags -K sha512 -p "$tree" \
		-X "$ignore" > "${minhag_dir}/mtree.dist"
}

# Apply mtree.dist to restore permissions and flags.
apply_mtree() {
	local tree="${1:?apply_mtree: tree root required}"
	local minhag_dir="${2:?apply_mtree: minhag target directory required}"
	local spec="${minhag_dir}/mtree.dist"
	[ -f "$spec" ] || die "apply_mtree: no mtree.dist in ${minhag_dir}"
	# Differences between spec and live tree are expected; don't fail.
	mtree -f "$spec" -iu -p "$tree" || true
}

# Strip schg flags so files can be deleted or overwritten.
clear_mtree() {
	local tree="${1:?clear_mtree: tree root required}"
	[ -d "$tree" ] || die "clear_mtree: directory not found: ${tree}"
	chflags -R noschg "$tree"
}

# ── Config helpers ────────────────────────────────────────────────────────────

# Two-tier config lookup: target build.conf → parasa.conf → default.
# Usage: msysrc build_conf_path VAR_NAME [default]
# Prints the value to stdout. Returns 1 if not found and no default.
msysrc() {
	local conf="${1:?msysrc: build.conf path required}"
	local var="${2:?msysrc: variable name required}"
	local default="${3:-}"
	local val
	if [ -f "$conf" ]; then
		val=$(sysrc -f "$conf" -qn "$var" 2>/dev/null) || true
		if [ -n "$val" ]; then
			printf "%s" "$val"
			return 0
		fi
	fi
	val=$(sysrc -f "${PARASA_DIR}/parasa.conf" -qn "$var" 2>/dev/null) || true
	if [ -n "$val" ]; then
		printf "%s" "$val"
		return 0
	fi
	if [ -n "$default" ]; then
		printf "%s" "$default"
		return 0
	fi
	return 1
}

# ── ZFS query helpers ────────────────────────────────────────────────────────

# Check if a ZFS dataset exists.
zfs_dataset_exists() {
	zfs list -H -o name "${1:?zfs_dataset_exists: dataset required}" \
		>/dev/null 2>&1
}

# ── Git query helpers ────────────────────────────────────────────────────────

# Check if a git branch exists in a repository.
# Usage: git_branch_exists repo_path branch_name
git_branch_exists() {
	local repo="${1:?git_branch_exists: repo path required}"
	local branch="${2:?git_branch_exists: branch name required}"
	git -C "$repo" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1
}

# ── Foundation helpers ───────────────────────────────────────────────────────

# Read foundation name from a system/container minhag dir.
# Returns the name via stdout. Dies if zero or multiple .foundation files.
get_foundation() {
	local dir="${1:?get_foundation: minhag dir required}"
	local found="" count=0 f
	for f in "$dir"/*.foundation; do
		[ -e "$f" ] || die "get_foundation: no .foundation file in ${dir}"
		count=$((count + 1))
		found="$f"
	done
	[ "$count" -eq 1 ] || die "get_foundation: expected 1 .foundation file in ${dir}, found ${count}"
	basename "$found" .foundation
}

# ── Name validation ──────────────────────────────────────────────────────────

# Validate a name for use as a dataset/branch component.
# Must be non-empty, start with a letter or digit, contain only
# alphanumeric characters plus hyphens, underscores, and dots.
validate_name() {
	local name="${1:-}"
	local label="${2:-Name}"
	[ -n "$name" ] || { error "${label} cannot be empty"; return 1; }
	case "$name" in
		-*) error "${label} cannot start with a hyphen"; return 1 ;;
	esac
	case "$name" in
		*[!a-zA-Z0-9._-]*)
			error "${label} may only contain letters, digits, hyphens, underscores, and dots"
			return 1 ;;
	esac
	return 0
}

# ── Interactive prompt helpers ───────────────────────────────────────────────

# Prompt with a default value. If QUIET > 0, return the default silently.
# Usage: prompt_or_default "prompt text" default_value quiet_level
prompt_or_default() {
	local prompt="$1" default="$2" quiet="${3:-0}" resp
	if [ "$quiet" -gt 0 ]; then
		printf "%s" "$default"
		return 0
	fi
	printf "%s [%s]: " "$prompt" "$default" >&2
	read -r resp || resp=""
	printf "%s" "${resp:-$default}"
}

# Prompt for a yes/no with a default. Respects quiet mode.
# Usage: prompt_yesno "question" default_yesno quiet_level
# Returns 0 for yes, 1 for no.
prompt_yesno() {
	local prompt="$1" default="$2" quiet="${3:-0}" resp
	if [ "$quiet" -gt 0 ]; then
		yesish "$default" && return 0 || return 1
	fi
	local hint
	if yesish "$default"; then hint="Y/n"; else hint="y/N"; fi
	while true; do
		printf "%s [%s]: " "$prompt" "$hint" >&2
		read -r resp || return 1
		[ -n "$resp" ] || resp="$default"
		yesish "$resp" && return 0
		noish "$resp" && return 1
		printf "Please answer y or n.\n" >&2
	done
}

# List available foundations and prompt for selection.
# Usage: select_foundation quiet_level
# Prints the chosen foundation name to stdout.
select_foundation() {
	local quiet="${1:-0}" minhag_dir="${PARASA_DIR}/minhag/foundations"
	local name found="" count=0 idx=0

	for d in "$minhag_dir"/*/; do
		[ -d "$d" ] || continue
		name=$(basename "$d")
		count=$((count + 1))
		found="$name"
	done

	[ "$count" -gt 0 ] || die "No foundations found in ${minhag_dir}/. Run new_foundation first."

	if [ "$count" -eq 1 ]; then
		if [ "$quiet" -gt 0 ]; then
			printf "%s" "$found"
			return 0
		fi
		printf "Only one foundation available: %s\n" "$found" >&2
		printf "%s" "$found"
		return 0
	fi

	if [ "$quiet" -gt 0 ]; then
		die "Multiple foundations available; use -f to specify one."
	fi

	printf "Available foundations:\n" >&2
	idx=0
	for d in "$minhag_dir"/*/; do
		[ -d "$d" ] || continue
		idx=$((idx + 1))
		name=$(basename "$d")
		printf "  %d) %s\n" "$idx" "$name" >&2
	done

	local resp
	while true; do
		printf "Foundation name or number: " >&2
		read -r resp || die "EOF reading foundation selection"
		# If numeric, resolve to name
		case "$resp" in
			[0-9]|[0-9][0-9])
				local cur=0
				for d in "$minhag_dir"/*/; do
					[ -d "$d" ] || continue
					cur=$((cur + 1))
					if [ "$cur" -eq "$resp" ]; then
						printf "%s" "$(basename "$d")"
						return 0
					fi
				done
				printf "  Invalid number.\n" >&2
				continue
				;;
		esac
		# Name given directly
		if [ -d "${minhag_dir}/${resp}" ]; then
			printf "%s" "$resp"
			return 0
		fi
		printf "  Foundation '%s' not found.\n" "$resp" >&2
	done
}

# ── Git / artifact helpers ────────────────────────────────────────────────────

# Build an artifact name from a FreeBSD src repo.
# Format: <branch>_<ISO-date>_<short-sha>[_<suffix>]
get_artifact_name() {
	local repo="${1:?get_artifact_name: repo path required}"
	local suffix="${2:-}"
	[ -d "${repo}/.git" ] || die "get_artifact_name: not a git repo: ${repo}"
	local name
	name="$(git -C "$repo" rev-parse --abbrev-ref HEAD | tr '/' '-')"
	name="${name}_$(date -I)_$(git -C "$repo" rev-parse --short HEAD)"
	[ -n "$suffix" ] && name="${name}_${suffix}"
	printf "%s" "$name"
}

# Return the tag portion of the most recent snapshot on a dataset.
get_current_artifact() {
	local dataset="${1:?get_current_artifact: dataset required}"
	zfs list -H -t snapshot -r -o name -S creation -d 1 "$dataset" \
		| head -n 1 \
		| cut -d '@' -f 2
}
