#!/bin/sh
# new_foundation -- Build a FreeBSD world+kernel and archive as a foundation.
#
# A foundation is a pristine build that systems and containers branch from.
# Build config (SRC_BRANCH, KERNCONF, MAKE_JOBS) is collected interactively
# or via flags and stored in recipes/foundations/<name>.conf.
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
  new_foundation -s 15stable -d             Dry-run with name pre-set
  new_foundation -s 15stable -qq            Fully silent build
  new_foundation -s custom -o kernconf=MYKERNEL -o make_jobs=8

Execution flow:
  1. Collect foundation name and build config
  2. Create recipes/foundations/<name>.conf
  3. Ensure FreeBSD source tree is ready (zshemot/src.git)
  4. Create transient build workspace (zshemot/buildspace/<name>)
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
	if [ -n "$FOUNDATION_NAME" ] && zfs_dataset_exists "zshemot/buildspace/${FOUNDATION_NAME}"; then
		if $BUILD_COMPLETE; then
			printf "\nWARNING: Build completed but a later step failed.\n" >&2
			printf "Workspace preserved at zshemot/buildspace/%s for manual recovery.\n" >&2
			printf "To retry the commit/archive phase, re-run with the same name.\n" >&2
			printf "To discard: zfs destroy -r zshemot/buildspace/%s\n" "$FOUNDATION_NAME" >&2
		else
			printf "Cleaning up transient zshemot/buildspace/%s...\n" "$FOUNDATION_NAME" >&2
			zfs destroy -r "zshemot/buildspace/${FOUNDATION_NAME}" 2>/dev/null || true
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

	# List existing foundation recipes that haven't been built yet
	local recipes_dir="${RECIPES_DIR}/foundations"
	local idx=0 name
	for f in "$recipes_dir"/*.conf; do
		[ -f "$f" ] || continue
		name=$(basename "$f" .conf)
		# Skip already-archived foundations
		zfs_dataset_exists "zbamidbar/foundation.zfs/foundations/${name}" && continue
		idx=$((idx + 1))
		[ "$idx" -eq 1 ] && printf "Unbuilt foundation recipes:\n" >&2
		printf "  %d) %s\n" "$idx" "$name" >&2
	done

	local resp
	while true; do
		printf "Foundation name or number: " >&2
		read -r resp || die "EOF reading foundation name"
		# If numeric, resolve to unbuilt recipe name
		case "$resp" in
			[0-9]|[0-9][0-9])
				local cur=0
				for f in "$recipes_dir"/*.conf; do
					[ -f "$f" ] || continue
					name=$(basename "$f" .conf)
					zfs_dataset_exists "zbamidbar/foundation.zfs/foundations/${name}" && continue
					cur=$((cur + 1))
					if [ "$cur" -eq "$resp" ]; then
						FOUNDATION_NAME="$name"
						return
					fi
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

check_foundation_available() {
	# Recipe dir may already exist (pre-created build.conf) — that's fine.
	# Only block if the foundation has already been built.
	if zfs_dataset_exists "zbamidbar/foundation.zfs/foundations/${FOUNDATION_NAME}"; then
		die "Foundation '${FOUNDATION_NAME}' already archived in zbamidbar/foundation.zfs. Use destroy_foundation (future) or pick a new name."
	fi
	# foundation.git is mounted by main() before we get here
	if git_branch_exists /zbamidbar/foundation.git "${FOUNDATION_NAME}"; then
		die "Branch '${FOUNDATION_NAME}' already exists in foundation.git."
	fi
}

resolve_build_config() {
	local build_conf="${RECIPES_DIR}/foundations/${FOUNDATION_NAME}.conf"
	local default_jobs
	default_jobs=$(sysctl -n hw.ncpu 2>/dev/null || printf "4")

	# Record original values from existing recipe (for change detection)
	local orig_branch="" orig_kernconf=""
	if [ -f "$build_conf" ]; then
		orig_branch=$(msysrc "$build_conf" SRC_BRANCH "")
		orig_kernconf=$(msysrc "$build_conf" KERNCONF "")
	fi

	# Determine defaults: -o overrides > build.conf > parasa.conf > hardcoded
	local def_branch="${OPT_SRC_BRANCH}"
	local def_kernconf="${OPT_KERNCONF}"
	local def_jobs="${OPT_MAKE_JOBS}"

	[ -n "$def_branch" ] || def_branch=$(msysrc "$build_conf" SRC_BRANCH "stable/15")
	[ -n "$def_kernconf" ] || def_kernconf=$(msysrc "$build_conf" KERNCONF "GENERIC")
	[ -n "$def_jobs" ] || def_jobs=$(msysrc "$build_conf" MAKE_JOBS "$default_jobs")

	# Build validation lists (gracefully empty if src not populated yet)
	local branch_list="" kernconf_list=""
	if [ -d "/zshemot/src.git/.git" ]; then
		branch_list=$(list_src_branches /zshemot/src.git)
		kernconf_list=$(list_kernconfs /zshemot/src.git)
	fi

	SRC_BRANCH=$(prompt_from_list "Source branch" "$def_branch" "$QUIET" "$branch_list")
	KERNCONF=$(prompt_from_list "Kernel config" "$def_kernconf" "$QUIET" "$kernconf_list")
	MAKE_JOBS=$(prompt_or_default "Parallel jobs" "$def_jobs" "$QUIET")

	# Recipe change detection: if an existing recipe's key values changed,
	# prompt the user to rename or confirm overwrite.
	if [ -n "$orig_branch" ] && [ "$QUIET" -eq 0 ]; then
		local changed=false
		[ "$SRC_BRANCH" != "$orig_branch" ] && changed=true
		[ -n "$orig_kernconf" ] && [ "$KERNCONF" != "$orig_kernconf" ] && changed=true

		if $changed; then
			printf "\nWARNING: Build config differs from existing recipe '%s'.\n" "$FOUNDATION_NAME" >&2
			printf "  Original: SRC_BRANCH=%s  KERNCONF=%s\n" "$orig_branch" "${orig_kernconf:-GENERIC}" >&2
			printf "  New:      SRC_BRANCH=%s  KERNCONF=%s\n" "$SRC_BRANCH" "$KERNCONF" >&2
			printf "Enter a new foundation name (or 'keep' to overwrite): " >&2
			local resp
			read -r resp || resp="keep"
			if [ "$resp" != "keep" ] && [ -n "$resp" ]; then
				validate_name "$resp" "Foundation name" || die "Invalid name."
				FOUNDATION_NAME="$resp"
				check_foundation_available
			fi
		fi
	fi
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

create_recipe_conf() {
	local conf="${RECIPES_DIR}/foundations/${FOUNDATION_NAME}.conf"
	progress "Writing recipe: ${conf}"

	if ! $DRY_RUN; then
		cat > "$conf" <<-EOF
		SRC_BRANCH="${SRC_BRANCH}"
		KERNCONF="${KERNCONF}"
		MAKE_JOBS="${MAKE_JOBS}"
		EOF
	else
		printf "  [dry] write %s\n" "$conf" >&2
	fi

	# Offer $EDITOR in interactive mode
	if [ "$QUIET" -eq 0 ] && [ -n "${EDITOR:-}" ]; then
		if confirm "Open recipe in \$EDITOR before building?"; then
			"$EDITOR" "$conf"
			# Re-read config in case user changed it
			SRC_BRANCH=$(msysrc "$conf" SRC_BRANCH "$SRC_BRANCH")
			KERNCONF=$(msysrc "$conf" KERNCONF "$KERNCONF")
			MAKE_JOBS=$(msysrc "$conf" MAKE_JOBS "$MAKE_JOBS")
		fi
	fi
}

ensure_src_tree() {
	progress "Preparing source tree (zshemot/src.git)"
	# src.git is already mounted by main() for early branch validation.

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
	progress "Creating transient build workspace (zshemot/buildspace/${FOUNDATION_NAME})"

	# Destroy any leftover workspace from a failed run
	if zfs_dataset_exists "zshemot/buildspace/${FOUNDATION_NAME}"; then
		progress "Destroying leftover zshemot/buildspace/${FOUNDATION_NAME}"
		run zfs destroy -r "zshemot/buildspace/${FOUNDATION_NAME}"
	fi

	zfs_dataset_exists "zshemot/buildspace" || \
		die "Dataset zshemot/buildspace not found. Run doctor.sh to repair."

	run zfs create -o mountpoint="/zshemot/buildspace/${FOUNDATION_NAME}" -o canmount=on "zshemot/buildspace/${FOUNDATION_NAME}"
	run zfs create -o mountpoint="/zshemot/buildspace/${FOUNDATION_NAME}/var" -o canmount=on "zshemot/buildspace/${FOUNDATION_NAME}/var"
	run zfs create -o mountpoint="/zshemot/buildspace/${FOUNDATION_NAME}/.git" -o canmount=on "zshemot/buildspace/${FOUNDATION_NAME}/.git"
}

prepare_workspace_git() {
	progress "Initializing git in workspace"
	local workspace="/zshemot/buildspace/${FOUNDATION_NAME}"

	# Pre-flight: verify git can commit (user.name/user.email must resolve).
	# Fail fast here rather than after hours of buildworld/buildkernel.
	if ! $DRY_RUN; then
		if ! git config user.email >/dev/null 2>&1; then
			die "No git user.email configured. Set it with: git config --global user.email 'you@example.com' && git config --global user.name 'Your Name'"
		fi
	fi

	# foundation.git is mounted by main(); .git child dataset is already mounted by prepare_workspace()
	run git -C "$workspace" init -b main
	run git -C "$workspace" remote add origin /zbamidbar/foundation.git

	if ! $DRY_RUN; then
		git -C "$workspace" fetch origin 2>/dev/null || true
	fi

	run git -C "$workspace" checkout --orphan "${FOUNDATION_NAME}"

	if ! $DRY_RUN; then
		git -C "$workspace" rm -rf --cached . >/dev/null 2>&1 || true
	fi
}

# ── Phase 3: Build ──────────────────────────────────────────────────────────

run_build() {
	local srcdir="/zshemot/src.git"
	local destdir="/zshemot/buildspace/${FOUNDATION_NAME}"
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
	local workspace="/zshemot/buildspace/${FOUNDATION_NAME}"

	# Re-mount foundation.git — may have been lost during long build
	run zmount zbamidbar/foundation.git /zbamidbar/foundation.git

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
	local workspace="zshemot/buildspace/${FOUNDATION_NAME}"
	local dest="zbamidbar/foundation.zfs/foundations/${FOUNDATION_NAME}"

	progress "Archiving to zbamidbar"

	# Ensure foundation.zfs is mounted
	run zmount zbamidbar/foundation.zfs /zbamidbar/foundation.zfs

	# Snapshot parent and var only — .git is a child dataset deliberately
	# excluded from the archive (git state lives in foundation.git).
	run zfs snapshot "${workspace}@${ARTIFACT_NAME}"
	run zfs snapshot "${workspace}/var@${ARTIFACT_NAME}"

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
	progress "Destroying transient workspace"
	if zfs_dataset_exists "zshemot/buildspace/${FOUNDATION_NAME}"; then
		# Clear schg flags before destroy
		if [ -d "/zshemot/buildspace/${FOUNDATION_NAME}" ] && ! $DRY_RUN; then
			clear_mtree "/zshemot/buildspace/${FOUNDATION_NAME}"
		fi
		run zfs destroy -r "zshemot/buildspace/${FOUNDATION_NAME}"
	fi
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	root_only
	trap cleanup EXIT

	run zmount zbamidbar/foundation.git /zbamidbar/foundation.git
	run zmount zshemot/src.git /zshemot/src.git

	# Phase 1: Input
	collect_foundation_name
	check_foundation_available
	resolve_build_config
	print_summary
	if [ "$QUIET" -eq 0 ]; then
		confirm "Proceed with foundation build?" || exit 0
	fi

	# Phase 2: Preparation
	create_recipe_conf
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

	if [ "$QUIET" -eq 0 ] && [ -t 0 ]; then
		printf "\nCreate a workspace from this foundation?\n" >&2
		printf "  1) Container (jail)\n" >&2
		printf "  2) System\n" >&2
		printf "  q) Quit\n" >&2
		printf "  > " >&2
		local resp
		read -r resp || resp=""
		case "$resp" in
			1) exec sh "${SCRIPT_DIR}/new_container.sh" -f "$FOUNDATION_NAME" ;;
			2) exec sh "${SCRIPT_DIR}/new_system.sh" -f "$FOUNDATION_NAME" ;;
		esac
	fi
}

main
