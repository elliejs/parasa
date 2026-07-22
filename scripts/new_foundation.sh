#!/bin/sh
# new_foundation -- Build a FreeBSD world+kernel and archive as a foundation.
#
# A foundation is a pristine build that systems and containers branch from.
# Build config (SRC_BRANCH, KERNCONF, MAKE_JOBS) is collected interactively
# or via flags and stored in minhag/foundations/<name>/build.conf.
#
# See plans/build_system.md for the full design.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
new_foundation -- Build a FreeBSD world+kernel and archive as a foundation.

Usage:
  new_foundation [-h] [-d] [-s NAME] [-o K=V ...] [-q [-q]]

Options:
  -h        Show this help and exit
  -d        Dry run: print commands without executing them
  -s NAME   Foundation name (skips the name prompt)
  -o K=V    Build config override (repeatable). Keys:
              src_branch   FreeBSD source branch (default: stable/15)
              kernconf     Kernel config file   (default: GENERIC)
              make_jobs    Parallel make jobs   (default: hw.ncpu)
  -q        Quiet: suppress prompts, use defaults for unanswered questions.
            Progress output is still shown.
  -qq       Silent: suppress prompts AND progress output.

Modes:
  Interactive      No -s flag. All questions asked; no defaults pre-filled.
  Semi-interactive -s without -q. Questions asked with -o values as defaults.
  Quiet            -s with -q.  No prompts; -o values + defaults only.

Examples:
  new_foundation                           Interactive build
  new_foundation -s stable15 -d            Dry-run with name pre-set
  new_foundation -s stable15 -qq           Fully silent build
  new_foundation -s custom -o kernconf=MYKERNEL -o make_jobs=8

Execution flow:
  1. Collect foundation name and build config
  2. Create minhag/foundations/<name>/build.conf
  3. Ensure FreeBSD source tree is ready (zshemot/torah)
  4. Create transient build workspace (zshemot/amim/<name>)
  5. Build world + kernel (five make targets)
  6. Commit to foundation/<name> branch on zbamidbar/sinai.git
  7. Archive ZFS snapshot to zbamidbar/sinai.zfs/foundations/<name>
  8. Destroy transient build workspace

DANGER: This runs 'make buildworld' and 'make buildkernel', which are
        long-running and resource-intensive operations.
EOF
	exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────

DRY_RUN=false
QUIET=0
FOUNDATION_NAME=""
OPT_SRC_BRANCH=""
OPT_KERNCONF=""
OPT_MAKE_JOBS=""

while getopts ":hds:o:q" opt; do
	case "$opt" in
		h) print_help ;;
		d) DRY_RUN=true ;;
		s) FOUNDATION_NAME="$OPTARG" ;;
		o)
			case "$OPTARG" in
				src_branch=*)  OPT_SRC_BRANCH="${OPTARG#src_branch=}" ;;
				kernconf=*)    OPT_KERNCONF="${OPTARG#kernconf=}" ;;
				make_jobs=*)   OPT_MAKE_JOBS="${OPTARG#make_jobs=}" ;;
				*) die "Unknown -o key: ${OPTARG}. Valid keys: src_branch, kernconf, make_jobs" ;;
			esac
			;;
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

cleanup() {
	if [ -n "$FOUNDATION_NAME" ] && zfs_dataset_exists "zshemot/amim/${FOUNDATION_NAME}"; then
		printf "Cleaning up transient zshemot/amim/%s...\n" "$FOUNDATION_NAME" >&2
		zfs destroy -r "zshemot/amim/${FOUNDATION_NAME}" 2>/dev/null || true
	fi
}

# ── Phase 1: Input ──────────────────────────────────────────────────────────

collect_foundation_name() {
	if [ -n "$FOUNDATION_NAME" ]; then
		validate_name "$FOUNDATION_NAME" "Foundation name" || exit 1
		return
	fi
	if [ "$QUIET" -gt 0 ]; then
		die "Foundation name required in quiet mode (-s NAME)."
	fi
	local resp
	while true; do
		printf "Foundation name: " >&2
		read -r resp || die "EOF reading foundation name"
		if validate_name "$resp" "Foundation name"; then
			FOUNDATION_NAME="$resp"
			return
		fi
	done
}

check_foundation_available() {
	local minhag="${PARASA_DIR}/minhag/foundations/${FOUNDATION_NAME}"
	if [ -d "$minhag" ]; then
		die "Foundation '${FOUNDATION_NAME}' already exists in minhag. Use destroy_foundation (future) or pick a new name."
	fi
	if zfs_dataset_exists "zbamidbar/sinai.zfs/foundations/${FOUNDATION_NAME}"; then
		die "Foundation '${FOUNDATION_NAME}' already archived in zbamidbar/sinai.zfs. Use destroy_foundation (future) or pick a new name."
	fi
	# Check sinai.git branch (must mount temporarily)
	if zfs_dataset_exists "zbamidbar/sinai.git"; then
		local sinai_mounted=false
		if yesish "$(zfs get -H -o value mounted zbamidbar/sinai.git 2>/dev/null)"; then
			sinai_mounted=true
		else
			run zmount zbamidbar/sinai.git /zbamidbar/sinai.git
		fi
		if [ -d "/zbamidbar/sinai.git/refs" ] && \
		   git_branch_exists /zbamidbar/sinai.git "foundation/${FOUNDATION_NAME}"; then
			die "Branch 'foundation/${FOUNDATION_NAME}' already exists in sinai.git."
		fi
		$sinai_mounted || run zunmount zbamidbar/sinai.git
	fi
}

resolve_build_config() {
	local build_conf="${PARASA_DIR}/minhag/foundations/${FOUNDATION_NAME}/build.conf"
	local default_jobs
	default_jobs=$(sysctl -n hw.ncpu 2>/dev/null || printf "4")

	# Determine defaults: -o overrides > parasa.conf > hardcoded
	local def_branch="${OPT_SRC_BRANCH}"
	local def_kernconf="${OPT_KERNCONF}"
	local def_jobs="${OPT_MAKE_JOBS}"

	[ -n "$def_branch" ] || def_branch=$(msysrc "$build_conf" SRC_BRANCH "stable/15")
	[ -n "$def_kernconf" ] || def_kernconf=$(msysrc "$build_conf" KERNCONF "GENERIC")
	[ -n "$def_jobs" ] || def_jobs=$(msysrc "$build_conf" MAKE_JOBS "$default_jobs")

	SRC_BRANCH=$(prompt_or_default "Source branch" "$def_branch" "$QUIET")
	KERNCONF=$(prompt_or_default "Kernel config" "$def_kernconf" "$QUIET")
	MAKE_JOBS=$(prompt_or_default "Parallel jobs" "$def_jobs" "$QUIET")
}

print_summary() {
	cat >&2 <<-EOF

	Foundation: ${FOUNDATION_NAME}
	  SRC_BRANCH = ${SRC_BRANCH}
	  KERNCONF   = ${KERNCONF}
	  MAKE_JOBS  = ${MAKE_JOBS}
	EOF
}

# ── Phase 2: Preparation ───────────────────────────────────────────────────

create_minhag_dir() {
	local minhag="${PARASA_DIR}/minhag/foundations/${FOUNDATION_NAME}"
	progress "Creating minhag dir: ${minhag}"
	run mkdir -p "$minhag"

	# Write build.conf
	if ! $DRY_RUN; then
		cat > "${minhag}/build.conf" <<-EOF
		# build.conf for foundation: ${FOUNDATION_NAME}
		# Per-foundation overrides. Falls back to parasa.conf.
		SRC_BRANCH="${SRC_BRANCH}"
		KERNCONF="${KERNCONF}"
		MAKE_JOBS="${MAKE_JOBS}"
		EOF
	else
		printf "  [dry] write %s/build.conf\n" "$minhag" >&2
	fi

	# Offer $EDITOR in interactive mode
	if [ "$QUIET" -eq 0 ] && [ -n "${EDITOR:-}" ]; then
		if confirm "Open foundation directory in \$EDITOR before building?"; then
			"$EDITOR" "$minhag"
			# Re-read config in case user changed it
			SRC_BRANCH=$(msysrc "${minhag}/build.conf" SRC_BRANCH "$SRC_BRANCH")
			KERNCONF=$(msysrc "${minhag}/build.conf" KERNCONF "$KERNCONF")
			MAKE_JOBS=$(msysrc "${minhag}/build.conf" MAKE_JOBS "$MAKE_JOBS")
		fi
	fi
}

ensure_src_tree() {
	progress "Preparing source tree (zshemot/torah)"
	run zmount zshemot/torah /zshemot/torah

	if [ ! -d "/zshemot/torah/.git" ]; then
		if [ "$QUIET" -eq 0 ]; then
			confirm "No source tree found. Clone FreeBSD src into zshemot/torah?" \
				|| die "Cannot proceed without a source tree."
		fi
		progress "Cloning FreeBSD source (this will take a while)"
		run git clone https://git.freebsd.org/src.git /zshemot/torah
	fi

	progress "Checking out ${SRC_BRANCH}"
	run git -C /zshemot/torah fetch origin
	# Check if branch exists on remote
	if ! $DRY_RUN; then
		if ! git -C /zshemot/torah rev-parse --verify "origin/${SRC_BRANCH}" >/dev/null 2>&1; then
			die "Branch '${SRC_BRANCH}' not found on remote. Available branches:"
			git -C /zshemot/torah branch -r | head -20 >&2
		fi
	fi
	run git -C /zshemot/torah checkout "$SRC_BRANCH"
	run git -C /zshemot/torah pull --ff-only
}

prepare_workspace() {
	progress "Creating transient build workspace (zshemot/amim/${FOUNDATION_NAME})"

	# Destroy any leftover workspace from a failed run
	if zfs_dataset_exists "zshemot/amim/${FOUNDATION_NAME}"; then
		progress "Destroying leftover zshemot/amim/${FOUNDATION_NAME}"
		run zfs destroy -r "zshemot/amim/${FOUNDATION_NAME}"
	fi

	# Ensure parent dataset exists
	run ztouch zshemot/amim

	run zfs create -o mountpoint="/zshemot/amim/${FOUNDATION_NAME}" -o canmount=on "zshemot/amim/${FOUNDATION_NAME}"
	run zfs create -o mountpoint="/zshemot/amim/${FOUNDATION_NAME}/var" -o canmount=on "zshemot/amim/${FOUNDATION_NAME}/var"
}

prepare_workspace_git() {
	progress "Initializing git in workspace"
	local sinai_git="/zbamidbar/sinai.git"
	local workspace="/zshemot/amim/${FOUNDATION_NAME}"

	# Ensure sinai.git is mounted and initialized
	run zmount zbamidbar/sinai.git "$sinai_git"
	if [ ! -d "${sinai_git}/refs" ] && ! $DRY_RUN; then
		run git init --bare "$sinai_git"
	fi

	# Initialize git in workspace
	run git -C "$workspace" init
	run git -C "$workspace" remote add origin "$sinai_git"

	# Fetch existing refs (needed for ref awareness, even on first run)
	if ! $DRY_RUN; then
		git -C "$workspace" fetch origin 2>/dev/null || true
	fi

	# Create orphan branch for this foundation
	run git -C "$workspace" checkout --orphan "foundation/${FOUNDATION_NAME}"

	# Clear index (orphan branch starts with whatever was staged)
	if ! $DRY_RUN; then
		git -C "$workspace" rm -rf --cached . >/dev/null 2>&1 || true
	fi
}

# ── Phase 3: Build ──────────────────────────────────────────────────────────

run_build() {
	local srcdir="/zshemot/torah"
	local destdir="/zshemot/amim/${FOUNDATION_NAME}"
	local jobs="$MAKE_JOBS"

	progress "Building world (make -j${jobs} buildworld)"
	run make -C "$srcdir" -j"$jobs" buildworld

	progress "Building kernel (make -j${jobs} buildkernel KERNCONF=${KERNCONF})"
	run make -C "$srcdir" -j"$jobs" buildkernel KERNCONF="$KERNCONF"

	progress "Installing kernel to ${destdir}"
	run make -C "$srcdir" -j"$jobs" DESTDIR="$destdir" installkernel KERNCONF="$KERNCONF"

	progress "Installing world to ${destdir}"
	run make -C "$srcdir" -j"$jobs" DESTDIR="$destdir" installworld

	progress "Running distribution target"
	run make -C "$srcdir" -j"$jobs" DESTDIR="$destdir" distribution
}

# ── Phase 4: Track ──────────────────────────────────────────────────────────

commit_build() {
	local workspace="/zshemot/amim/${FOUNDATION_NAME}"
	local minhag="${PARASA_DIR}/minhag/foundations/${FOUNDATION_NAME}"

	progress "Committing build to git"

	# Stage everything first (including base var/ files)
	run git -C "$workspace" add .

	# Create .gitignore: var/, usr/local/, tmp/ — NOT home/
	if ! $DRY_RUN; then
		cat > "${workspace}/.gitignore" <<-'GITIGNORE'
		var/
		usr/local/
		tmp/
		GITIGNORE
	fi
	run git -C "$workspace" add .gitignore

	# Generate mtree
	progress "Generating mtree baseline"
	if ! $DRY_RUN; then
		generate_mtree "$workspace" "$minhag" "${PARASA_DIR}/etc/mtree.ignore"
	else
		printf "  [dry] generate_mtree %s %s %s\n" "$workspace" "$minhag" "${PARASA_DIR}/etc/mtree.ignore" >&2
	fi

	# Build artifact name
	if ! $DRY_RUN; then
		ARTIFACT_NAME=$(get_artifact_name /zshemot/torah "$FOUNDATION_NAME")
	else
		ARTIFACT_NAME="[dry-run-artifact]"
	fi
	progress "Artifact: ${ARTIFACT_NAME}"

	# Commit
	run git -C "$workspace" commit -m "$ARTIFACT_NAME"

	# Push
	run git -C "$workspace" push origin "foundation/${FOUNDATION_NAME}"
}

archive_to_zbamidbar() {
	local workspace="zshemot/amim/${FOUNDATION_NAME}"
	local dest="zbamidbar/sinai.zfs/foundations/${FOUNDATION_NAME}"

	progress "Archiving to zbamidbar"

	# Ensure sinai.zfs is mounted
	run zmount zbamidbar/sinai.zfs /zbamidbar/sinai.zfs

	# Snapshot the build
	run zfs snapshot -r "${workspace}@${ARTIFACT_NAME}"

	# Create destination and send
	run ztouch "$dest" -o mountpoint=none -o canmount=noauto
	progress "ZFS send → ${dest}"
	if ! $DRY_RUN; then
		zfs send -R "${workspace}@${ARTIFACT_NAME}" | zfs recv -F "$dest"
	else
		printf "  [dry] zfs send -R %s@%s | zfs recv -F %s\n" \
			"$workspace" "$ARTIFACT_NAME" "$dest" >&2
	fi
}

wipe_workspace() {
	progress "Destroying transient workspace"
	if zfs_dataset_exists "zshemot/amim/${FOUNDATION_NAME}"; then
		# Clear schg flags before destroy
		if [ -d "/zshemot/amim/${FOUNDATION_NAME}" ] && ! $DRY_RUN; then
			clear_mtree "/zshemot/amim/${FOUNDATION_NAME}"
		fi
		run zfs destroy -r "zshemot/amim/${FOUNDATION_NAME}"
	fi
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	root_only
	trap cleanup EXIT

	# Phase 1: Input
	collect_foundation_name
	check_foundation_available
	resolve_build_config
	print_summary
	if [ "$QUIET" -eq 0 ]; then
		confirm "Proceed with foundation build?" || exit 0
	fi

	# Phase 2: Preparation
	create_minhag_dir
	ensure_src_tree
	prepare_workspace
	prepare_workspace_git

	# Phase 3: Build
	run_build

	# Phase 4: Track
	commit_build
	archive_to_zbamidbar
	wipe_workspace

	# Cleanup: unmount working datasets
	run zunmount zbamidbar/sinai.git
	run zunmount zbamidbar/sinai.zfs
	run zunmount zshemot/torah

	progress "Foundation '${FOUNDATION_NAME}' created successfully."
	printf "  Artifact: %s\n" "$ARTIFACT_NAME" >&2
	printf "  Branch:   foundation/%s\n" "$FOUNDATION_NAME" >&2
	printf "  Archive:  zbamidbar/sinai.zfs/foundations/%s\n" "$FOUNDATION_NAME" >&2
}

main
