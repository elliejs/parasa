#!/bin/sh
# save.sh -- Save workspace state: capture packages, mtree, commit.
#
# Performs two commits:
#   1. State commit: git add -A in the tree root, commit with artifact + message
#   2. Recipe commit: git add recipes/{kind}s/{name}/ in PARASA_DIR
#
# See plans/rebase_pipeline.md Phase 3 for the full design.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR="${PARASA_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
save -- Save workspace state to git.

Usage:
  save.sh -s NAME [-k KIND] [-m MSG] [-h] [-d] [-q]

Options:
  -h        Show this help and exit
  -d        Dry run: print commands without executing them
  -s NAME   Workspace name (required)
  -k KIND   "system" or "container" (auto-detected if omitted)
  -m MSG    Commit message (required in quiet mode)
  -q        Quiet mode: no interactive prompts

This command:
  1. Runs diff to verify all changes are classified
  2. Captures package list (pkg info -o)
  3. Regenerates mtree.dist
  4. Commits state in the tree root (push to foundation.git)
  5. Commits recipe in PARASA_DIR

Examples:
  save.sh -s wonderland                 Interactive save
  save.sh -s wonderland -q -m "update"  Quiet save with message
  save.sh -s wonderland -d              Dry-run save
EOF
	exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────

DRY_RUN=false
WS_NAME=""
WS_KIND=""
QUIET=0
COMMIT_MSG=""

while getopts ":hds:k:m:q" opt; do
	case "$opt" in
		h) print_help ;;
		d) DRY_RUN=true ;;
		s) WS_NAME="$OPTARG" ;;
		k) WS_KIND="$OPTARG" ;;
		m) COMMIT_MSG="$OPTARG" ;;
		q) QUIET=1 ;;
		\?) die "Unknown option: -${OPTARG}. Use -h for help." ;;
		:)  die "Option -${OPTARG} requires an argument." ;;
	esac
done

[ -n "$WS_NAME" ] || die "Workspace name required (-s NAME). Use -h for help."
if [ "$QUIET" -gt 0 ] && [ -z "$COMMIT_MSG" ]; then
	die "Commit message required in quiet mode (-m MSG)."
fi

# ── Resolve target ──────────────────────────────────────────────────────────

if [ -z "$WS_KIND" ]; then
	WS_KIND=$(detect_kind "$WS_NAME")
fi

TREE_ROOT=$(get_tree_root "$WS_KIND" "$WS_NAME")
RECIPE_DIR=$(get_recipes_dir "$WS_KIND" "$WS_NAME")

[ -d "$RECIPE_DIR" ] || die "Recipe directory not found: ${RECIPE_DIR}"

FOUNDATION_NAME=$(get_foundation "$RECIPE_DIR")
ARTIFACT=$(read_artifact_name "$RECIPE_DIR")

# ── Dry-run wrapper ─────────────────────────────────────────────────────────

run() {
	if $DRY_RUN; then
		printf "  [dry] %s\n" "$*" >&2
	else
		"$@"
	fi
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	# Ensure foundation.git is mounted before we try to push to it as origin.
	run zmount zbamidbar/foundation.git /zbamidbar/foundation.git

	# Step 1: Run diff (quiet mode)
	if ! $DRY_RUN; then
		printf "==> Running diff check...\n" >&2
		"${SCRIPT_DIR}/diff.sh" -s "$WS_NAME" -k "$WS_KIND" -q || \
			die "Unsaved drift detected. Run diff.sh interactively first."
	else
		printf "  [dry] diff.sh -s %s -k %s -q\n" "$WS_NAME" "$WS_KIND" >&2
	fi

	# Step 2: Capture package list
	printf "==> Capturing package list...\n" >&2
	case "$WS_KIND" in
		system)
			run chroot "$TREE_ROOT" pkg info -a -o > "${RECIPE_DIR}/pkg.list"
			;;
		container)
			run pkg -j "$WS_NAME" info -a -o > "${RECIPE_DIR}/pkg.list"
			;;
	esac

	# Step 3: Regenerate mtree.dist
	printf "==> Regenerating mtree.dist...\n" >&2
	local ignore="${PARASA_DIR}/etc/mtree.ignore"
	run generate_mtree "$TREE_ROOT" "$RECIPE_DIR" "$ignore"

	# Step 4: Prompt for message if needed
	if [ -z "$COMMIT_MSG" ]; then
		printf "Commit message: " >&2
		read -r COMMIT_MSG || die "EOF reading commit message"
		[ -n "$COMMIT_MSG" ] || die "Commit message cannot be empty."
	fi

	# Step 5: Commit state in tree root
	printf "==> Committing state...\n" >&2
	run git -C "$TREE_ROOT" add -A
	run git -C "$TREE_ROOT" commit -m "${ARTIFACT}
${COMMIT_MSG}"
	run git -C "$TREE_ROOT" push origin "${WS_KIND}s/${WS_NAME}"

	# Step 6: Commit recipe in PARASA_DIR
	printf "==> Committing recipe...\n" >&2
	run git -C "$PARASA_DIR" add "recipes/${WS_KIND}s/${WS_NAME}/"
	run git -C "$PARASA_DIR" commit -m "${WS_NAME}: ${COMMIT_MSG}"

	run zunmount zbamidbar/foundation.git

	printf "==> Save complete.\n" >&2
}

main
