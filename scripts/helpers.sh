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

# ── Recipes directory ────────────────────────────────────────────────────────

# Root of the recipes repository. On deployed systems this is
# /zshemot/recipes.git (a separate repo from the parasa tool).
# Override via environment for development/testing.
RECIPES_DIR="${RECIPES_DIR:-/zshemot/recipes.git}"

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
	if ! yesish "$(zfs get -H -o value mounted "$dataset" 2>/dev/null)"; then
		zfs mount "$dataset"
	fi
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

# Generate mtree.dist for a tree, writing to the target's recipes directory.
# Strips time/nlink/flags (git-incompatible), adds sha512.
generate_mtree() {
	local tree="${1:?generate_mtree: tree root required}"
	local recipes_dir="${2:?generate_mtree: recipes target directory required}"
	local ignore="${3:?generate_mtree: ignore file required}"
	[ -d "$recipes_dir" ] || die "generate_mtree: recipes dir not found: ${recipes_dir}"
	[ -f "$ignore" ]     || die "generate_mtree: ignore file not found: ${ignore}"
	mtree -c -x -R time,nlink,flags -K sha512 -p "$tree" \
		-X "$ignore" > "${recipes_dir}/mtree.dist"
}

# Apply mtree.dist to restore permissions and flags.
apply_mtree() {
	local tree="${1:?apply_mtree: tree root required}"
	local recipes_dir="${2:?apply_mtree: recipes target directory required}"
	local spec="${recipes_dir}/mtree.dist"
	[ -f "$spec" ] || die "apply_mtree: no mtree.dist in ${recipes_dir}"
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

# Read foundation name from a system/container recipes dir.
# Returns the name via stdout. Dies if zero or multiple .foundation files.
get_foundation() {
	local dir="${1:?get_foundation: recipes dir required}"
	local found="" count=0 f
	for f in "$dir"/*.foundation; do
		[ -e "$f" ] || die "get_foundation: no .foundation file in ${dir}"
		count=$((count + 1))
		found="$f"
	done
	[ "$count" -eq 1 ] || die "get_foundation: expected 1 .foundation file in ${dir}, found ${count}"
	basename "$found" .foundation
}

# Check if a foundation recipe has SRC_BRANCH set in the file itself
# (not via msysrc fallback to parasa.conf). Returns 0 if complete, 1 if partial.
# Usage: recipe_is_complete /path/to/recipe.conf
recipe_is_complete() {
	local conf="${1:?recipe_is_complete: conf path required}"
	[ -f "$conf" ] || return 1
	sysrc -f "$conf" -qn SRC_BRANCH >/dev/null 2>&1
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

# ── Fuzzy matching & validated prompts ────────────────────────────────────────

# Suggest matches from a list for a given input.
# Tries prefix match first, then substring. Prints matches to stderr.
# Returns 0 if any matches found, 1 if none.
# Usage: fuzzy_suggest "input" "newline-separated list"
fuzzy_suggest() {
	local input="$1" list="$2"
	local lower_input match_count=0

	# Case-fold input for matching
	lower_input=$(printf "%s" "$input" | tr '[:upper:]' '[:lower:]')

	# Prefix matches first
	local line lower_line prefix_matches="" substr_matches=""
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		lower_line=$(printf "%s" "$line" | tr '[:upper:]' '[:lower:]')
		case "$lower_line" in
			"${lower_input}"*)
				prefix_matches="${prefix_matches}${prefix_matches:+
}${line}"
				match_count=$((match_count + 1))
				;;
			*"${lower_input}"*)
				substr_matches="${substr_matches}${substr_matches:+
}${line}"
				match_count=$((match_count + 1))
				;;
		esac
	done <<-FUZZYIN
	$(printf "%s\n" "$list")
	FUZZYIN

	[ "$match_count" -gt 0 ] || return 1

	printf "  Did you mean:\n" >&2
	if [ -n "$prefix_matches" ]; then
		printf "%s\n" "$prefix_matches" | while IFS= read -r line; do
			printf "    %s\n" "$line" >&2
		done
	fi
	if [ -n "$substr_matches" ]; then
		printf "%s\n" "$substr_matches" | while IFS= read -r line; do
			printf "    %s\n" "$line" >&2
		done
	fi
	return 0
}

# List remote branches from a git repo (strips refs/heads/ or origin/ prefix).
# Usage: list_src_branches /path/to/repo
list_src_branches() {
	local repo="$1"
	git -C "$repo" branch -r 2>/dev/null \
		| sed 's|^[[:space:]]*origin/||' \
		| grep -v '^HEAD ' \
		| sort
}

# List kernel config files for the current architecture.
# Usage: list_kernconfs /path/to/src
list_kernconfs() {
	local srcdir="$1"
	local arch
	arch=$(uname -m 2>/dev/null || printf "amd64")
	local f
	for f in "${srcdir}/sys/${arch}/conf"/[A-Z]*; do
		[ -f "$f" ] && basename "$f"
	done
}

# Prompt with validation against a known list of values.
# Accepts exact matches, '?' to list all options, and offers fuzzy
# suggestions on mismatch. Falls back to prompt_or_default when the
# list is empty (e.g. src not populated yet).
# Usage: prompt_from_list "label" "default" quiet_level "newline-separated list"
prompt_from_list() {
	local label="$1" default="$2" quiet="${3:-0}" valid_list="$4"

	# Empty list → can't validate, fall back to free-form
	if [ -z "$valid_list" ]; then
		prompt_or_default "$label" "$default" "$quiet"
		return
	fi

	# Quiet mode → return default without validation
	if [ "$quiet" -gt 0 ]; then
		printf "%s" "$default"
		return 0
	fi

	local resp
	while true; do
		printf "%s [%s] (? for list): " "$label" "$default" >&2
		read -r resp || resp=""
		[ -n "$resp" ] || resp="$default"

		# '?' lists all options
		if [ "$resp" = "?" ]; then
			printf "%s\n" "$valid_list" | while IFS= read -r line; do
				printf "    %s\n" "$line" >&2
			done
			continue
		fi

		# Exact match?
		if printf "%s\n" "$valid_list" | grep -qxF "$resp"; then
			printf "%s" "$resp"
			return 0
		fi

		# No exact match — try fuzzy
		printf "  '%s' not found.\n" "$resp" >&2
		fuzzy_suggest "$resp" "$valid_list" || true
	done
}

# List available foundations and prompt for selection.
# Usage: select_foundation quiet_level
# Prints the chosen foundation name to stdout.
select_foundation() {
	local quiet="${1:-0}" recipes_dir="${RECIPES_DIR}/foundations"
	local name found="" count=0 idx=0

	for f in "$recipes_dir"/*.conf; do
		[ -f "$f" ] || continue
		name=$(basename "$f" .conf)
		count=$((count + 1))
		found="$name"
	done

	[ "$count" -gt 0 ] || die "No foundations found in ${recipes_dir}/. Run new_foundation first."

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
	for f in "$recipes_dir"/*.conf; do
		[ -f "$f" ] || continue
		idx=$((idx + 1))
		name=$(basename "$f" .conf)
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
				for f in "$recipes_dir"/*.conf; do
					[ -f "$f" ] || continue
					cur=$((cur + 1))
					if [ "$cur" -eq "$resp" ]; then
						printf "%s" "$(basename "$f" .conf)"
						return 0
					fi
				done
				printf "  Invalid number.\n" >&2
				continue
				;;
		esac
		# Name given directly
		if [ -f "${recipes_dir}/${resp}.conf" ]; then
			printf "%s" "$resp"
			return 0
		fi
		printf "  Foundation '%s' not found.\n" "$resp" >&2
	done
}

# ── Tree / recipes resolution ────────────────────────────────────────────────

# Get the tree root path for a deployed system or container.
# Usage: get_tree_root kind name
get_tree_root() {
	local kind="${1:?get_tree_root: kind required}"
	local name="${2:?get_tree_root: name required}"
	case "$kind" in
		system)    printf "/zbereshit/systems/%s" "$name" ;;
		container) printf "/containers/%s" "$name" ;;
		*) die "get_tree_root: unknown kind: $kind" ;;
	esac
}

# Get the recipes directory for a system or container.
# Usage: get_recipes_dir kind name
get_recipes_dir() {
	local kind="${1:?get_recipes_dir: kind required}"
	local name="${2:?get_recipes_dir: name required}"
	printf "%s/%ss/%s" "${RECIPES_DIR}" "$kind" "$name"
}

# Detect kind (system or container) from recipes directory existence.
# Usage: detect_kind name
# Prints "system" or "container" to stdout. Dies if ambiguous or not found.
detect_kind() {
	local name="${1:?detect_kind: name required}"
	local is_system=false is_container=false
	[ -d "${RECIPES_DIR}/systems/${name}" ] && is_system=true
	[ -d "${RECIPES_DIR}/containers/${name}" ] && is_container=true
	if $is_system && $is_container; then
		die "detect_kind: '${name}' exists as both system and container"
	fi
	if $is_system; then
		printf "system"
	elif $is_container; then
		printf "container"
	else
		die "detect_kind: '${name}' not found in recipes"
	fi
}

# ── FreeBSD version helpers ──────────────────────────────────────────────────

# Extract FreeBSD major.minor version from a SRC_BRANCH string.
# stable/15 → 15.0, releng/15.1 → 15.1, main → main
# Usage: branch_to_version "stable/15"
branch_to_version() {
	local branch="${1:?branch_to_version: branch required}"
	case "$branch" in
		stable/*)
			# stable/15 → 15.0
			printf "%s.0" "${branch#stable/}"
			;;
		releng/*)
			# releng/15.1 → 15.1
			printf "%s" "${branch#releng/}"
			;;
		*)
			# main or anything else — pass through
			printf "%s" "$branch"
			;;
	esac
}

# Get the FreeBSD version for a foundation from its build.conf.
# Usage: get_foundation_version foundation_name
# Prints version (e.g., "15.0") to stdout.
get_foundation_version() {
	local fname="${1:?get_foundation_version: foundation name required}"
	local build_conf="${RECIPES_DIR}/foundations/${fname}.conf"
	local branch
	branch=$(msysrc "$build_conf" SRC_BRANCH "stable/15")
	branch_to_version "$branch"
}

# Resolve the best-matching global derivations db for a version.
# Finds the newest db file whose version is <= the given version.
# Usage: resolve_derivations_db version
# Prints the db file path to stdout. Returns 1 if none found.
resolve_derivations_db() {
	local target="${1:?resolve_derivations_db: version required}"
	local db_dir="${RECIPES_DIR}/derivations"
	local best="" best_ver="" f ver

	# Handle "main" — use the newest available db
	case "$target" in
		main)
			for f in "$db_dir"/*.db; do
				[ -f "$f" ] || continue
				ver=$(basename "$f" .db)
				if [ -z "$best_ver" ] || ver_ge "$ver" "$best_ver"; then
					best="$f"
					best_ver="$ver"
				fi
			done
			;;
		*)
			for f in "$db_dir"/*.db; do
				[ -f "$f" ] || continue
				ver=$(basename "$f" .db)
				# Skip if ver > target
				ver_ge "$target" "$ver" || continue
				# Keep if newest <= target
				if [ -z "$best_ver" ] || ver_ge "$ver" "$best_ver"; then
					best="$f"
					best_ver="$ver"
				fi
			done
			;;
	esac

	if [ -n "$best" ]; then
		printf "%s" "$best"
		return 0
	fi
	return 1
}

# Compare two dotted version strings: is $1 >= $2?
# Usage: ver_ge "15.1" "15.0" → true (0), ver_ge "14.0" "15.0" → false (1)
ver_ge() {
	local a_major a_minor b_major b_minor
	a_major="${1%%.*}"
	a_minor="${1#*.}"
	[ "$a_minor" = "$1" ] && a_minor=0
	b_major="${2%%.*}"
	b_minor="${2#*.}"
	[ "$b_minor" = "$2" ] && b_minor=0

	[ "$a_major" -gt "$b_major" ] && return 0
	[ "$a_major" -lt "$b_major" ] && return 1
	[ "$a_minor" -ge "$b_minor" ] && return 0
	return 1
}

# ── Binary / derivation helpers ──────────────────────────────────────────────

# Check if a file is binary.
# Returns 0 if binary (ELF, data, etc.), 1 if text.
is_binary_file() {
	local path="${1:?is_binary_file: path required}"
	[ -f "$path" ] || return 1
	local ftype
	ftype=$(file -b "$path")
	case "$ftype" in
		ELF*|*executable*|*"shared object"*|*data*|*archive*)
			return 0 ;;
		*)
			return 1 ;;
	esac
}

# Look up a derivation entry for a relative path.
# Searches the global db and then derivations.local.
# Usage: lookup_derivation relpath db_file [local_db_file]
# Prints "source\tcommand" to stdout if found, returns 1 if not.
lookup_derivation() {
	local relpath="${1:?lookup_derivation: relpath required}"
	local db="${2:?lookup_derivation: db file required}"
	local local_db="${3:-}"
	local src cmd line

	# Check local db first (overrides global)
	if [ -n "$local_db" ] && [ -f "$local_db" ]; then
		while IFS='	' read -r src line cmd; do
			[ -n "$src" ] || continue
			case "$src" in \#*) continue ;; esac
			if [ "$line" = "$relpath" ]; then
				printf "%s\t%s" "$src" "$cmd"
				return 0
			fi
		done < "$local_db"
	fi

	# Check global db
	if [ -f "$db" ]; then
		while IFS='	' read -r src line cmd; do
			[ -n "$src" ] || continue
			case "$src" in \#*) continue ;; esac
			if [ "$line" = "$relpath" ]; then
				printf "%s\t%s" "$src" "$cmd"
				return 0
			fi
		done < "$db"
	fi

	return 1
}

# Read the artifact name from a recipes directory's .foundation file.
# Usage: read_artifact_name recipes_dir
# Prints the artifact name to stdout. Dies if file missing or empty.
read_artifact_name() {
	local dir="${1:?read_artifact_name: recipes dir required}"
	local f artifact
	for f in "$dir"/*.foundation; do
		[ -e "$f" ] || die "read_artifact_name: no .foundation file in ${dir}"
		artifact=$(cat "$f")
		[ -n "$artifact" ] || die "read_artifact_name: .foundation file is empty in ${dir}"
		printf "%s" "$artifact"
		return 0
	done
	die "read_artifact_name: no .foundation file in ${dir}"
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
	name="${name}_$(git -C "$repo" rev-parse --short HEAD)"
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
