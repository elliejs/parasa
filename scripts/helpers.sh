#!/bin/sh
# helpers.sh -- shared utilities for mishkan stage scripts.
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
