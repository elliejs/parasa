#!/bin/sh
# new_foundation -- Build a FreeBSD world+kernel and archive as a foundation.
#
# A foundation is a pristine build that systems and containers branch from.
# Build config (SRC_BRANCH, KERNCONF, MAKE_JOBS) is collected interactively
# or via flags and stored in foundations/<name>/build.cfg (in the parasa repo).
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
  2. Create foundations/<name>/build.cfg (in the parasa repo)
  3. Ensure FreeBSD source tree is ready (zshemot/src.git)
  4. Create transient build workspace dataset zshemot/foundations/<name>/build
     (mounted at foundations/<name>/build in the parasa repo, gitignored)
  5. Build world + kernel (five make targets)
  6. Commit to <name> orphan branch on zbamidbar/foundation.git
  7. Archive ZFS snapshot to zbamidbar/foundation.zfs/foundations/<name>
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

# Set to true after run_build completes. If the build finished but a
# later step (commit/archive) fails, destroying hours of work is worse
# than leaving the workspace for manual recovery.
BUILD_COMPLETE=false

cleanup() {
	if [ -n "$FOUNDATION_NAME" ] && zfs_dataset_exists "zshemot/foundations/${FOUNDATION_NAME}"; then
		if $BUILD_COMPLETE; then
			printf "\nWARNING: Build completed but a later step failed.\n" >&2
			printf "Workspace preserved at zshemot/foundations/%s for manual recovery.\n" "$FOUNDATION_NAME" >&2
			printf "To retry the commit/archive phase, re-run with the same name.\n" >&2
			printf "To discard: zfs destroy -r zshemot/foundations/%s\n" "$FOUNDATION_NAME" >&2
		else
			printf "Cleaning up transient zshemot/foundations/%s...\n" "$FOUNDATION_NAME" >&2
			zfs destroy -r "zshemot/foundations/${FOUNDATION_NAME}" 2>/dev/null || true
		fi
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
	# A foundation "exists" once it's archived or has a foundation.git branch;
	# a leftover config dir or build dataset from a failed run must NOT block a
	# retry (it gets overwritten / recreated below).
	if zfs_dataset_exists "zbamidbar/foundation.zfs/foundations/${FOUNDATION_NAME}"; then
		die "Foundation '${FOUNDATION_NAME}' already archived in zbamidbar/foundation.zfs. Use destroy_foundation (future) or pick a new name."
	fi
	# Check foundation.git branch (must mount temporarily)
	if zfs_dataset_exists "zbamidbar/foundation.git"; then
		local foundation_git_mounted=false
		if yesish "$(zfs get -H -o value mounted zbamidbar/foundation.git 2>/dev/null)"; then
			foundation_git_mounted=true
		else
			run zmount zbamidbar/foundation.git /zbamidbar/foundation.git
		fi
		if [ -d "/zbamidbar/foundation.git/refs" ] && \
		   git_branch_exists /zbamidbar/foundation.git "${FOUNDATION_NAME}"; then
			die "Branch '${FOUNDATION_NAME}' already exists in foundation.git."
		fi
		$foundation_git_mounted || run zunmount zbamidbar/foundation.git
	fi
}

resolve_build_config() {
	local build_conf="${PARASA_DIR}/foundations/${FOUNDATION_NAME}/build.cfg"
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

create_foundation_config() {
	# The foundation's home is ${PARASA_DIR}/foundations/<name>/ inside the
	# parasa repo clone. build.cfg is a tracked file here; the transient
	# build/ workspace (a ZFS dataset, gitignored) is created separately.
	local fdir="${PARASA_DIR}/foundations/${FOUNDATION_NAME}"
	progress "Creating foundation config dir: ${fdir}"
	run mkdir -p "$fdir"

	# Write build.cfg
	if ! $DRY_RUN; then
		cat > "${fdir}/build.cfg" <<-EOF
		# build.cfg for foundation: ${FOUNDATION_NAME}
		# Per-foundation overrides. Falls back to parasa.conf.
		SRC_BRANCH="${SRC_BRANCH}"
		KERNCONF="${KERNCONF}"
		MAKE_JOBS="${MAKE_JOBS}"
		EOF
	else
		printf "  [dry] write %s/build.cfg\n" "$fdir" >&2
	fi

	# Offer $EDITOR in interactive mode
	if [ "$QUIET" -eq 0 ] && [ -n "${EDITOR:-}" ]; then
		if confirm "Open foundation directory in \$EDITOR before building?"; then
			"$EDITOR" "$fdir"
			# Re-read config in case user changed it
			SRC_BRANCH=$(msysrc "${fdir}/build.cfg" SRC_BRANCH "$SRC_BRANCH")
			KERNCONF=$(msysrc "${fdir}/build.cfg" KERNCONF "$KERNCONF")
			MAKE_JOBS=$(msysrc "${fdir}/build.cfg" MAKE_JOBS "$MAKE_JOBS")
		fi
	fi
}

ensure_src_tree() {
	progress "Preparing source tree (zshemot/src.git)"
	run zmount zshemot/src.git /zshemot/src.git

	if [ ! -d "/zshemot/src.git/.git" ]; then
		if [ "$QUIET" -eq 0 ]; then
			confirm "No source tree found. Clone FreeBSD src into zshemot/src.git?" \
				|| die "Cannot proceed without a source tree."
		fi
		progress "Cloning FreeBSD source (this will take a while)"
		run git clone https://git.freebsd.org/src.git /zshemot/src.git
	fi

	progress "Checking out ${SRC_BRANCH}"
	run git -C /zshemot/src.git fetch origin
	# Check if branch exists on remote
	if ! $DRY_RUN; then
		if ! git -C /zshemot/src.git rev-parse --verify "origin/${SRC_BRANCH}" >/dev/null 2>&1; then
			die "Branch '${SRC_BRANCH}' not found on remote. Available branches:"
			git -C /zshemot/src.git branch -r | head -20 >&2
		fi
	fi
	run git -C /zshemot/src.git checkout "$SRC_BRANCH"
	run git -C /zshemot/src.git pull --ff-only
}

prepare_workspace() {
	local build_dir="${PARASA_DIR}/foundations/${FOUNDATION_NAME}/build"
	progress "Creating transient build workspace (zshemot/foundations/${FOUNDATION_NAME}/build)"

	# Destroy any leftover workspace from a failed run (the whole per-foundation
	# container dataset; build.cfg lives outside it as a tracked file).
	if zfs_dataset_exists "zshemot/foundations/${FOUNDATION_NAME}"; then
		progress "Destroying leftover zshemot/foundations/${FOUNDATION_NAME}"
		run zfs destroy -r "zshemot/foundations/${FOUNDATION_NAME}"
	fi

	# The build dataset is zshemot/foundations/<name>/build, mounted into the
	# parasa repo clone at ${PARASA_DIR}/foundations/<name>/build (gitignored).
	# -p creates the intermediate zshemot/foundations[/<name>] containers, which
	# inherit zshemot's mountpoint=none (they stay unmounted); only build/ and
	# build/var get an explicit mountpoint into the repo.
	run zfs create -p -o mountpoint="${build_dir}" -o canmount=on "zshemot/foundations/${FOUNDATION_NAME}/build"
	run zfs create -o mountpoint="${build_dir}/var" -o canmount=on "zshemot/foundations/${FOUNDATION_NAME}/build/var"
}

prepare_workspace_git() {
	progress "Initializing git in workspace"
	local foundation_git="/zbamidbar/foundation.git"
	local workspace="${PARASA_DIR}/foundations/${FOUNDATION_NAME}/build"

	# Pre-flight: verify git can commit (user.name/user.email must resolve).
	# Fail fast here rather than after hours of buildworld/buildkernel.
	if ! $DRY_RUN; then
		if ! git config user.email >/dev/null 2>&1; then
			die "No git user.email configured. Set it with: git config --global user.email 'you@example.com' && git config --global user.name 'Your Name'"
		fi
	fi

	# Ensure foundation.git is mounted and initialized
	run zmount zbamidbar/foundation.git "$foundation_git"
	if [ ! -d "${foundation_git}/refs" ] && ! $DRY_RUN; then
		run git init --bare "$foundation_git"
	fi

	# Initialize git in workspace
	run git -C "$workspace" init
	run git -C "$workspace" remote add origin "$foundation_git"

	# Fetch existing refs (needed for ref awareness, even on first run)
	if ! $DRY_RUN; then
		git -C "$workspace" fetch origin 2>/dev/null || true
	fi

	# Create orphan branch for this foundation
	run git -C "$workspace" checkout --orphan "${FOUNDATION_NAME}"

	# Clear index (orphan branch starts with whatever was staged)
	if ! $DRY_RUN; then
		git -C "$workspace" rm -rf --cached . >/dev/null 2>&1 || true
	fi
}

# ── Phase 3: Build ──────────────────────────────────────────────────────────

run_build() {
	local srcdir="/zshemot/src.git"
	local destdir="${PARASA_DIR}/foundations/${FOUNDATION_NAME}/build"
	local jobs="$MAKE_JOBS"
	# Per-foundation object tree. Every foundation shares one src checkout
	# (branch-switched in place), so without this the object tree is shared
	# across foundations and a stale object from a different branch's build
	# can be linked into this one (e.g. generated-source objects that never
	# get rebuilt), producing "Invalid record" link failures. Keying obj by
	# foundation name isolates foundations while keeping same-foundation
	# incremental rebuilds fast. All five targets must use the same prefix
	# so install/distribution find what buildworld produced.
	local objprefix="/usr/obj/parasa/${FOUNDATION_NAME}"

	progress "Building world (make -j${jobs} buildworld)"
	run env MAKEOBJDIRPREFIX="$objprefix" make -C "$srcdir" -j"$jobs" buildworld

	progress "Building kernel (make -j${jobs} buildkernel KERNCONF=${KERNCONF})"
	run env MAKEOBJDIRPREFIX="$objprefix" make -C "$srcdir" -j"$jobs" buildkernel KERNCONF="$KERNCONF"

	progress "Installing kernel to ${destdir}"
	run env MAKEOBJDIRPREFIX="$objprefix" make -C "$srcdir" -j"$jobs" DESTDIR="$destdir" installkernel KERNCONF="$KERNCONF"

	progress "Installing world to ${destdir}"
	run env MAKEOBJDIRPREFIX="$objprefix" make -C "$srcdir" -j"$jobs" DESTDIR="$destdir" installworld

	progress "Running distribution target"
	run env MAKEOBJDIRPREFIX="$objprefix" make -C "$srcdir" -j"$jobs" DESTDIR="$destdir" distribution
}

# ── Phase 4: Track ──────────────────────────────────────────────────────────

commit_build() {
	local workspace="${PARASA_DIR}/foundations/${FOUNDATION_NAME}/build"
	local fdir="${PARASA_DIR}/foundations/${FOUNDATION_NAME}"

	progress "Committing build to git"

	# Write .gitignore FIRST, then stage — so the data-lake mount points
	# (var, usr/local, home, tmp) are never tracked in the foundation tree.
	# They are separate ZFS datasets mounted over the clone at runtime;
	# tracking them makes the mounted data shadow tracked files, dirtying the
	# tree and blocking the update rebase. Base var content still reaches
	# containers/systems via the data-lake copy, not via git.
	if ! $DRY_RUN; then
		cat > "${workspace}/.gitignore" <<-'GITIGNORE'
		var/
		usr/local/
		home/
		tmp/
		dev/
		GITIGNORE
	fi
	run git -C "$workspace" add .gitignore
	run git -C "$workspace" add .

	# Generate mtree baseline into the foundation's config dir (tracked)
	progress "Generating mtree baseline"
	if ! $DRY_RUN; then
		generate_mtree "$workspace" "$fdir" "${PARASA_DIR}/etc/mtree.ignore"
	else
		printf "  [dry] generate_mtree %s %s %s\n" "$workspace" "$fdir" "${PARASA_DIR}/etc/mtree.ignore" >&2
	fi

	# Build artifact name
	if ! $DRY_RUN; then
		ARTIFACT_NAME=$(get_artifact_name /zshemot/src.git "$FOUNDATION_NAME")
	else
		ARTIFACT_NAME="[dry-run-artifact]"
	fi
	progress "Artifact: ${ARTIFACT_NAME}"

	# Commit
	run git -C "$workspace" commit -m "$ARTIFACT_NAME"

	# Push
	run git -C "$workspace" push origin "${FOUNDATION_NAME}"
}

archive_to_zbamidbar() {
	local workspace="zshemot/foundations/${FOUNDATION_NAME}/build"
	local dest="zbamidbar/foundation.zfs/foundations/${FOUNDATION_NAME}"

	progress "Archiving to zbamidbar"

	# Ensure foundation.zfs is mounted
	run zmount zbamidbar/foundation.zfs /zbamidbar/foundation.zfs

	# Snapshot the build
	run zfs snapshot -r "${workspace}@${ARTIFACT_NAME}"

	# Create destination and send
	run ztouch "$dest" -p -o mountpoint=none -o canmount=noauto
	progress "ZFS send → ${dest}"
	if ! $DRY_RUN; then
		zfs send -R "${workspace}@${ARTIFACT_NAME}" | \
			zfs recv -F -o mountpoint=none -o canmount=noauto "$dest"
	else
		printf "  [dry] zfs send -R %s@%s | zfs recv -F %s\n" \
			"$workspace" "$ARTIFACT_NAME" "$dest" >&2
	fi
}

wipe_workspace() {
	local build_dir="${PARASA_DIR}/foundations/${FOUNDATION_NAME}/build"
	progress "Destroying transient workspace"
	if zfs_dataset_exists "zshemot/foundations/${FOUNDATION_NAME}"; then
		# Clear schg flags before destroy
		if [ -d "$build_dir" ] && ! $DRY_RUN; then
			clear_mtree "$build_dir"
		fi
		# Destroy the whole per-foundation container (build + var); build.cfg
		# and mtree.dist live outside it as tracked files and are kept.
		run zfs destroy -r "zshemot/foundations/${FOUNDATION_NAME}"
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
	create_foundation_config
	ensure_src_tree
	prepare_workspace
	prepare_workspace_git

	# Phase 3: Build
	run_build
	BUILD_COMPLETE=true

	# Phase 4: Track
	commit_build
	archive_to_zbamidbar
	wipe_workspace

	# Cleanup: unmount working datasets
	run zunmount zbamidbar/foundation.git
	run zunmount zbamidbar/foundation.zfs
	run zunmount zshemot/src.git

	progress "Foundation '${FOUNDATION_NAME}' created successfully."
	printf "  Artifact: %s\n" "$ARTIFACT_NAME" >&2
	printf "  Branch:   %s\n" "$FOUNDATION_NAME" >&2
	printf "  Archive:  zbamidbar/foundation.zfs/foundations/%s\n" "$FOUNDATION_NAME" >&2
}

main
