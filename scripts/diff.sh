#!/bin/sh
# diff.sh -- Detect drift between a deployed workspace and its recipe.
#
# Compares the live tree against mtree.dist, classifies each changed file,
# and interactively prompts for unclassified entries. Exit 0 if clean or
# all classified; exit 1 if unclassified remain (blocks rebase).
#
# See plans/rebase_pipeline.md Phase 2 for the full design.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR="${PARASA_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
diff -- Detect drift between a deployed workspace and its recipe.

Usage:
  diff.sh -s NAME [-k KIND] [-h] [-d] [-q]

Options:
  -h        Show this help and exit
  -d        Dry run: show what would be compared without running mtree
  -s NAME   Workspace name (required)
  -k KIND   "system" or "container" (auto-detected if omitted)
  -q        Quiet mode: no interactive prompts, exit 1 on unclassified

This command:
  1. Resolves the tree root and recipe directory for the target
  2. Runs mtree comparison against mtree.dist
  3. Classifies each changed file:
     - In exempt mount (var/, usr/local/, home/, tmp/) → skip
     - Text file → git handles it
     - Known derivation → auto-classified
     - Git-tracked binary → preserve
     - Unclassified → interactive prompt or exit 1 in quiet mode
  4. Interactive classification options:
     [d] Derivation — text source → binary regeneration
     [p] Preserve — non-derivable binary, keep as-is
     [c] Command — binary produced by a command, no text source
     [s] Skip — ask again next time (blocks rebase)

Examples:
  diff.sh -s wonderland              Interactive diff of system
  diff.sh -s webserver -k container  Diff container
  diff.sh -s wonderland -q           Quiet: exit 1 if unclassified
  diff.sh -s wonderland -d           Dry-run: show plan only
EOF
	exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────

DRY_RUN=false
WS_NAME=""
WS_KIND=""
QUIET=0

while getopts ":hds:k:q" opt; do
	case "$opt" in
		h) print_help ;;
		d) DRY_RUN=true ;;
		s) WS_NAME="$OPTARG" ;;
		k) WS_KIND="$OPTARG" ;;
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

# Resolve derivation databases via version chain
FBSD_VERSION=$(get_foundation_version "$FOUNDATION_NAME")
GLOBAL_DB=$(resolve_derivations_db "$FBSD_VERSION") || \
	die "No derivations db found for FreeBSD ${FBSD_VERSION}"
LOCAL_DB="${RECIPE_DIR}/derivations.local"

# ── Exempt mount prefixes ───────────────────────────────────────────────────

is_exempt_path() {
	local relpath="$1"
	case "$relpath" in
		var/*|usr/local/*|home/*|tmp/*|root/*) return 0 ;;
		*) return 1 ;;
	esac
}

# ── Classification ──────────────────────────────────────────────────────────

# Classify a single changed file. Prints classification to stdout.
# Returns 0 if classified, 1 if unclassified.
classify_file() {
	local relpath="$1"

	# Exempt mount?
	if is_exempt_path "$relpath"; then
		printf "exempt"
		return 0
	fi

	# Text file? Git handles it.
	if ! is_binary_file "${TREE_ROOT}/${relpath}"; then
		printf "text"
		return 0
	fi

	# Known derivation?
	if lookup_derivation "$relpath" "$GLOBAL_DB" "$LOCAL_DB" >/dev/null 2>&1; then
		printf "derivation"
		return 0
	fi

	# Git-tracked binary?
	if git -C "$TREE_ROOT" ls-files --error-unmatch "$relpath" >/dev/null 2>&1; then
		printf "preserve"
		return 0
	fi

	# Unclassified
	printf "unclassified"
	return 1
}

# Interactively classify a file. Writes to derivations.local or compose.sh.
prompt_classification() {
	local relpath="$1"
	local resp source cmd phase

	printf "\n  Unclassified: %s\n" "$relpath" >&2
	printf "  [d] Derivation (text source → binary)\n" >&2
	printf "  [p] Preserve (keep as-is across rebases)\n" >&2
	printf "  [c] Command (produced from scratch)\n" >&2
	printf "  [s] Skip (ask again next time)\n" >&2

	while true; do
		printf "  Choice: " >&2
		read -r resp || return 1
		case "$resp" in
			d|D)
				printf "  Source file (relative): " >&2
				read -r source || return 1
				printf "  Regeneration command: " >&2
				read -r cmd || return 1
				printf "%s\t%s\t%s\n" "$source" "$relpath" "$cmd" >> "$LOCAL_DB"
				printf "derivation"
				return 0
				;;
			p|P)
				git -C "$TREE_ROOT" add "$relpath"
				printf "preserve"
				return 0
				;;
			c|C)
				printf "  Command to produce this file: " >&2
				read -r cmd || return 1
				printf "  Phase [pre_pkg/post_pkg]: " >&2
				read -r phase || return 1
				case "$phase" in
					pre*) phase="pre_pkg" ;;
					*)    phase="post_pkg" ;;
				esac
				# Append to compose.sh function
				local compose="${RECIPE_DIR}/compose.sh"
				if [ -f "$compose" ]; then
					sed -i '' "/${phase}() {/a\\
	${cmd}" "$compose" 2>/dev/null || \
					sed -i "/${phase}() {/a\\	${cmd}" "$compose"
				fi
				printf "command"
				return 0
				;;
			s|S)
				printf "skip"
				return 1
				;;
			*)
				printf "  Please enter d, p, c, or s.\n" >&2
				;;
		esac
	done
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	local mtree_dist="${RECIPE_DIR}/mtree.dist"
	local ignore="${PARASA_DIR}/etc/mtree.ignore"

	if $DRY_RUN; then
		printf "  [dry] diff: %s vs %s/mtree.dist\n" "$TREE_ROOT" "$RECIPE_DIR" >&2
		printf "  [dry] foundation: %s\n" "$FOUNDATION_NAME" >&2
		printf "  [dry] global db: %s\n" "$GLOBAL_DB" >&2
		printf "  [dry] local db: %s\n" "$LOCAL_DB" >&2
		printf "  [dry] ignore: %s\n" "$ignore" >&2
		exit 0
	fi

	[ -f "$mtree_dist" ] || die "No mtree.dist in ${RECIPE_DIR}. Run save first."
	[ -d "$TREE_ROOT" ] || die "Tree root not found: ${TREE_ROOT}"

	# Run mtree comparison
	local changed_files="" mtree_output=""
	mtree_output=$(mtree -f "$mtree_dist" -p "$TREE_ROOT" -X "$ignore" 2>/dev/null) || true

	if [ -z "$mtree_output" ]; then
		[ "$QUIET" -lt 1 ] && printf "Clean: no drift detected.\n" >&2
		exit 0
	fi

	# Parse mtree output for changed paths
	# mtree outputs lines like: "path/to/file changed\n\t..."
	changed_files=$(printf "%s\n" "$mtree_output" | grep -v '^	' | sed 's/ .*//' | sort -u)

	local unclassified=0 total=0 classified=0
	local relpath classification
	local changed_files_tmp
	changed_files_tmp=$(mktemp)
	printf "%s\n" "$changed_files" > "$changed_files_tmp"

	while IFS= read -r relpath; do
		[ -n "$relpath" ] || continue
		total=$((total + 1))

		classification=$(classify_file "$relpath") || true

		case "$classification" in
			exempt)
				;;
			text|derivation|preserve)
				classified=$((classified + 1))
				if [ "$QUIET" -lt 1 ]; then
					printf "  [%s] %s\n" "$classification" "$relpath" >&2
				fi
				;;
			unclassified)
				if [ "$QUIET" -gt 0 ]; then
					printf "  [unclassified] %s\n" "$relpath" >&2
					unclassified=$((unclassified + 1))
				else
					if prompt_classification "$relpath" >/dev/null; then
						classified=$((classified + 1))
					else
						unclassified=$((unclassified + 1))
					fi
				fi
				;;
		esac
	done < "$changed_files_tmp"
	rm -f "$changed_files_tmp"

	if [ "$unclassified" -gt 0 ]; then
		printf "ERROR: %d unclassified file(s) remain. Cannot proceed with rebase.\n" "$unclassified" >&2
		exit 1
	fi

	if [ "$QUIET" -lt 1 ]; then
		printf "All changes classified.\n" >&2
		if [ "$classified" -gt 0 ] && [ -t 0 ] && \
		   confirm "Save state now?"; then
			exec sh "${SCRIPT_DIR}/save.sh" -s "$WS_NAME" -k "$WS_KIND"
		fi
	fi
	exit 0
}

main
