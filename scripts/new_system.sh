#!/bin/sh
# new_system -- Create a new system on top of a foundation.
#
# Takes an existing foundation and creates a system: minhag directory,
# data datasets on zbamidbar, and an inaugural commit on a system/<name>
# branch in sinai.git. Optionally deploys to zbereshit.
#
# See plans/build_system.md Part 2 for the full design.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
MISHKAN_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
new_system -- Create a new system on top of a foundation.

Usage:
  new_system [-h] [-d] [-s NAME] [-f FOUNDATION] [-o K=V ...] [-q [-q]] [-b [-b]]

Options:
  -h        Show this help and exit
  -d        Dry run: print commands without executing them
  -s NAME   System name (skips the name prompt)
  -f FOUND  Foundation to base on (prompted if omitted)
  -o K=V    Property override (repeatable). Keys:
              home_dataset     Create /home dataset (default: yes)
              tmp_dataset      Create /tmp dataset  (default: yes)
              roothome_dataset Create /home/root dataset (default: no)
              user_homes       Comma-separated user names for home datasets
              mount_map        Custom mount: dataset:mountpoint (repeatable)
  -q        Quiet: suppress prompts, use defaults.
  -qq       Silent: suppress prompts AND progress output.
  -b        Deploy after creation (calls deploy_system).
  -bb       Deploy and set nextboot.

Modes:
  Interactive      No -s flag. All questions asked.
  Semi-interactive -s without -q. Questions asked, -o values as defaults.
  Quiet            -s with -q.  No prompts; -o values + defaults only.

The standard data-lake mounts (var, usr/local) are always created.
Home and tmp are optional (asked in interactive mode).

Examples:
  new_system                                     Interactive
  new_system -s wonderland -f stable15           Semi-interactive
  new_system -s testbox -f stable15 -qbb         Quiet, deploy + nextboot
  new_system -s dev -f stable15 -o home_dataset=no -o user_homes=alice,bob

Execution flow:
  1. Collect system name and foundation
  2. Ask dataset/mount questions
  3. Create minhag/systems/<name>/ with .foundation, boilerplate files
  4. Create data datasets on zbamidbar/system-data/<name>/
  5. Create inaugural commit on system/<name> branch (writes /etc/fstab)
  6. Optionally deploy to zbereshit (via deploy_system)
EOF
	exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────

DRY_RUN=false
QUIET=0
BOOT=0
SYSTEM_NAME=""
FOUNDATION_NAME=""
OPT_HOME="yes"
OPT_TMP="yes"
OPT_ROOTHOME="no"
OPT_USER_HOMES=""
OPT_MOUNT_MAP=""

while getopts ":hds:f:o:qb" opt; do
	case "$opt" in
		h) print_help ;;
		d) DRY_RUN=true ;;
		s) SYSTEM_NAME="$OPTARG" ;;
		f) FOUNDATION_NAME="$OPTARG" ;;
		o)
			case "$OPTARG" in
				home_dataset=*)     OPT_HOME="${OPTARG#home_dataset=}" ;;
				tmp_dataset=*)      OPT_TMP="${OPTARG#tmp_dataset=}" ;;
				roothome_dataset=*) OPT_ROOTHOME="${OPTARG#roothome_dataset=}" ;;
				user_homes=*)       OPT_USER_HOMES="${OPTARG#user_homes=}" ;;
				mount_map=*)        OPT_MOUNT_MAP="${OPT_MOUNT_MAP}${OPT_MOUNT_MAP:+ }${OPTARG#mount_map=}" ;;
				*) die "Unknown -o key: ${OPTARG%%=*}. Use -h for valid keys." ;;
			esac
			;;
		q) QUIET=$((QUIET + 1)) ;;
		b) BOOT=$((BOOT + 1)) ;;
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

# ── Cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
	if zfs_dataset_exists zshemot/tablets; then
		printf "Cleaning up transient zshemot/tablets...\n" >&2
		zfs destroy -r zshemot/tablets 2>/dev/null || true
	fi
}

# ── Phase 1: Input ──────────────────────────────────────────────────────────

collect_system_name() {
	if [ -n "$SYSTEM_NAME" ]; then
		validate_name "$SYSTEM_NAME" "System name" || exit 1
		return
	fi
	if [ "$QUIET" -gt 0 ]; then
		die "System name required in quiet mode (-s NAME)."
	fi
	local resp
	while true; do
		printf "System name: " >&2
		read -r resp || die "EOF reading system name"
		if validate_name "$resp" "System name"; then
			SYSTEM_NAME="$resp"
			return
		fi
	done
}

check_system_available() {
	local minhag="${MISHKAN_DIR}/minhag/systems/${SYSTEM_NAME}"
	if [ -d "$minhag" ]; then
		die "System '${SYSTEM_NAME}' already exists in minhag. Use destroy_system (future) or pick a new name."
	fi
	if zfs_dataset_exists "zbereshit/systems/${SYSTEM_NAME}"; then
		die "System '${SYSTEM_NAME}' already deployed on zbereshit."
	fi
}

collect_foundation() {
	if [ -n "$FOUNDATION_NAME" ]; then
		# Validate the named foundation exists
		local fminhag="${MISHKAN_DIR}/minhag/foundations/${FOUNDATION_NAME}"
		[ -d "$fminhag" ] || die "Foundation '${FOUNDATION_NAME}' not found in minhag."
		zfs_dataset_exists "zbamidbar/sinai.zfs/foundations/${FOUNDATION_NAME}" || \
			die "Foundation '${FOUNDATION_NAME}' not archived in zbamidbar/sinai.zfs."
		return
	fi
	FOUNDATION_NAME=$(select_foundation "$QUIET")
}

collect_build_options() {
	# Optional datasets (var and usr/local are always created, not asked)
	WANT_HOME=$(prompt_yesno "Create /home dataset?" "$OPT_HOME" "$QUIET" && echo yes || echo no)
	WANT_TMP=$(prompt_yesno "Create /tmp dataset?" "$OPT_TMP" "$QUIET" && echo yes || echo no)

	WANT_ROOTHOME="no"
	if yesish "$WANT_HOME"; then
		WANT_ROOTHOME=$(prompt_yesno "Create separate /home/root dataset?" "$OPT_ROOTHOME" "$QUIET" && echo yes || echo no)
	fi

	# User home datasets
	USER_HOMES="$OPT_USER_HOMES"
	if [ "$QUIET" -eq 0 ] && [ -z "$USER_HOMES" ]; then
		printf "Additional user home datasets (comma-separated, Enter for none): " >&2
		read -r USER_HOMES || USER_HOMES=""
	fi

	# Custom mount entries
	CUSTOM_MOUNTS="$OPT_MOUNT_MAP"
	if [ "$QUIET" -eq 0 ] && [ -z "$CUSTOM_MOUNTS" ]; then
		printf "\nCustom mount entries (dataset:mountpoint, one per line, Enter when done):\n" >&2
		local entry
		while true; do
			printf "  mount> " >&2
			read -r entry || break
			[ -n "$entry" ] || break
			CUSTOM_MOUNTS="${CUSTOM_MOUNTS}${CUSTOM_MOUNTS:+ }${entry}"
		done
	fi

	# For each custom mount, ask if recipe-related (interactive only)
	RECIPE_MOUNTS=""
	SYSTEM_MOUNTS=""
	if [ -n "$CUSTOM_MOUNTS" ]; then
		local m dataset mountpoint
		for m in $CUSTOM_MOUNTS; do
			dataset="${m%%:*}"
			mountpoint="${m#*:}"
			if [ "$QUIET" -eq 0 ]; then
				if prompt_yesno "  ${dataset} → ${mountpoint}: recipe-related mount?" "no" 0; then
					RECIPE_MOUNTS="${RECIPE_MOUNTS}${RECIPE_MOUNTS:+
}${dataset}	${mountpoint}	zfs	rw,late	0	0"
				else
					SYSTEM_MOUNTS="${SYSTEM_MOUNTS}${SYSTEM_MOUNTS:+
}${dataset}	${mountpoint}	zfs	rw,late	0	0"
				fi
			else
				# In quiet mode, all custom mounts are system mounts
				SYSTEM_MOUNTS="${SYSTEM_MOUNTS}${SYSTEM_MOUNTS:+
}${dataset}	${mountpoint}	zfs	rw,late	0	0"
			fi
		done
	fi
}

print_summary() {
	local data_root="zbamidbar/system-data/${SYSTEM_NAME}"
	cat >&2 <<-EOF

	System: ${SYSTEM_NAME}
	  Foundation:  ${FOUNDATION_NAME}
	  var:         ${data_root}/var (always)
	  usr/local:   ${data_root}/usr-local (always)
	  home:        $(yesish "$WANT_HOME" && echo "${data_root}/home" || echo "no")
	  tmp:         $(yesish "$WANT_TMP" && echo "${data_root}/tmp" || echo "no")
	  home/root:   $(yesish "$WANT_ROOTHOME" && echo "${data_root}/home/root" || echo "no")
	  user homes:  ${USER_HOMES:-none}
	  deploy:      $([ "$BOOT" -gt 0 ] && echo "yes" || echo "no")
	  nextboot:    $([ "$BOOT" -gt 1 ] && echo "yes" || echo "no")
	EOF
	if [ -n "$SYSTEM_MOUNTS" ]; then
		printf "  System fstab mounts:\n" >&2
		printf "%s\n" "$SYSTEM_MOUNTS" | while IFS= read -r line; do
			printf "    %s\n" "$line" >&2
		done
	fi
	if [ -n "$RECIPE_MOUNTS" ]; then
		printf "  Recipe fstab mounts (fstab.local):\n" >&2
		printf "%s\n" "$RECIPE_MOUNTS" | while IFS= read -r line; do
			printf "    %s\n" "$line" >&2
		done
	fi
}

# ── Phase 2: Setup ─────────────────────────────────────────────────────────

create_minhag_dir() {
	local minhag="${MISHKAN_DIR}/minhag/systems/${SYSTEM_NAME}"

	progress "Creating minhag dir: ${minhag}"
	run mkdir -p "$minhag"

	if ! $DRY_RUN; then
		# Zero-byte foundation file
		: > "${minhag}/${FOUNDATION_NAME}.foundation"

		# Boilerplate files
		: > "${minhag}/compose.sh"
		: > "${minhag}/derivations.local"
		: > "${minhag}/pkg.list"
		: > "${minhag}/mtree.dist"

		# Recipe-only mounts (or empty)
		if [ -n "$RECIPE_MOUNTS" ]; then
			printf "# Recipe-only mounts (container deps, shared data-pools)\n" > "${minhag}/fstab.local"
			printf "%s\n" "$RECIPE_MOUNTS" >> "${minhag}/fstab.local"
		else
			: > "${minhag}/fstab.local"
		fi
	else
		printf "  [dry] create %s/{%s.foundation,compose.sh,derivations.local,pkg.list,mtree.dist,fstab.local}\n" \
			"$minhag" "$FOUNDATION_NAME" >&2
	fi
}

create_system_datasets() {
	local data_root="zbamidbar/system-data/${SYSTEM_NAME}"
	local foundation_var="zbamidbar/sinai.zfs/foundations/${FOUNDATION_NAME}/var"

	progress "Creating data datasets"

	# Parent
	run ztouch "$data_root" -o mountpoint=none -o canmount=noauto

	# var: copy pristine var from foundation
	progress "Copying pristine var from foundation"
	run zmount zbamidbar/sinai.zfs /zbamidbar/sinai.zfs
	if ! $DRY_RUN; then
		# Get the latest snapshot on the foundation var dataset
		local snap
		snap=$(get_current_artifact "$foundation_var")
		if [ -n "$snap" ]; then
			zfs send "${foundation_var}@${snap}" | \
				zfs recv -o mountpoint=none -o canmount=noauto "${data_root}/var"
		else
			ztouch "${data_root}/var" -o mountpoint=none -o canmount=noauto
		fi
	else
		printf "  [dry] zfs send %s@<snap> | zfs recv %s/var\n" \
			"$foundation_var" "$data_root" >&2
	fi

	# usr-local: always created, empty
	run ztouch "${data_root}/usr-local" -o mountpoint=none -o canmount=noauto

	# Optional datasets
	if yesish "$WANT_HOME"; then
		run ztouch "${data_root}/home" -o mountpoint=none -o canmount=noauto
	fi
	if yesish "$WANT_TMP"; then
		run ztouch "${data_root}/tmp" -o mountpoint=none -o canmount=noauto
	fi
	if yesish "$WANT_ROOTHOME"; then
		run ztouch "${data_root}/home/root" -o mountpoint=none -o canmount=noauto
	fi

	# User home datasets
	if [ -n "$USER_HOMES" ]; then
		local old_ifs="$IFS" user
		IFS=','
		for user in $USER_HOMES; do
			IFS="$old_ifs"
			user=$(printf "%s" "$user" | tr -d '[:space:]')
			[ -n "$user" ] || continue
			run ztouch "${data_root}/home/${user}" -o mountpoint=none -o canmount=noauto
		done
		IFS="$old_ifs"
	fi
}

# ── Phase 3: Inaugural commit ──────────────────────────────────────────────

build_fstab_lines() {
	local data_root="zbamidbar/system-data/${SYSTEM_NAME}"

	# Always-included mounts
	FSTAB_LINES="${data_root}/var	/var	zfs	rw,late	0	0
${data_root}/usr-local	/usr/local	zfs	rw,late	0	0"

	# Optional standard mounts
	if yesish "$WANT_HOME"; then
		FSTAB_LINES="${FSTAB_LINES}
${data_root}/home	/home	zfs	rw,late	0	0"
	fi
	if yesish "$WANT_TMP"; then
		FSTAB_LINES="${FSTAB_LINES}
${data_root}/tmp	/tmp	zfs	rw,late	0	0"
	fi
	if yesish "$WANT_ROOTHOME"; then
		FSTAB_LINES="${FSTAB_LINES}
${data_root}/home/root	/root	zfs	rw,late	0	0"
	fi

	# User home datasets
	if [ -n "$USER_HOMES" ]; then
		local old_ifs="$IFS" user
		IFS=','
		for user in $USER_HOMES; do
			IFS="$old_ifs"
			user=$(printf "%s" "$user" | tr -d '[:space:]')
			[ -n "$user" ] || continue
			FSTAB_LINES="${FSTAB_LINES}
${data_root}/home/${user}	/home/${user}	zfs	rw,late	0	0"
		done
		IFS="$old_ifs"
	fi

	# Custom system mounts
	if [ -n "$SYSTEM_MOUNTS" ]; then
		FSTAB_LINES="${FSTAB_LINES}
${SYSTEM_MOUNTS}"
	fi

	# Recipe mounts also go into /etc/fstab
	if [ -n "$RECIPE_MOUNTS" ]; then
		FSTAB_LINES="${FSTAB_LINES}
${RECIPE_MOUNTS}"
	fi
}

create_inaugural_commit() {
	local sinai_git="/zbamidbar/sinai.git"
	local foundation_archive="zbamidbar/sinai.zfs/foundations/${FOUNDATION_NAME}"
	local tablets="/zshemot/tablets"

	progress "Creating inaugural commit"

	# Ensure sinai.git is mounted
	run zmount zbamidbar/sinai.git "$sinai_git"

	# Recv foundation to transient tablets
	progress "Receiving foundation to tablets workspace"
	run zmount zbamidbar/sinai.zfs /zbamidbar/sinai.zfs

	if zfs_dataset_exists zshemot/tablets; then
		run zfs destroy -r zshemot/tablets
	fi

	if ! $DRY_RUN; then
		local snap
		snap=$(get_current_artifact "$foundation_archive")
		[ -n "$snap" ] || die "No snapshots found on ${foundation_archive}"
		zfs send -R "${foundation_archive}@${snap}" | zfs recv zshemot/tablets
		zfs mount zshemot/tablets
		zfs mount zshemot/tablets/var 2>/dev/null || true
	else
		printf "  [dry] zfs send -R %s@<snap> | zfs recv zshemot/tablets\n" \
			"$foundation_archive" >&2
	fi

	# Git setup: the recv'd dataset includes .git from foundation build
	progress "Setting up system branch"
	if ! $DRY_RUN; then
		# Verify remote points to sinai.git
		local current_remote
		current_remote=$(git -C "$tablets" config remote.origin.url 2>/dev/null || echo "")
		if [ "$current_remote" != "$sinai_git" ]; then
			git -C "$tablets" remote set-url origin "$sinai_git" 2>/dev/null || \
				git -C "$tablets" remote add origin "$sinai_git"
		fi
		git -C "$tablets" fetch origin

		# Create system branch from foundation
		git -C "$tablets" checkout -b "system/${SYSTEM_NAME}" \
			"foundation/${FOUNDATION_NAME}"
	else
		printf "  [dry] git -C %s checkout -b system/%s foundation/%s\n" \
			"$tablets" "$SYSTEM_NAME" "$FOUNDATION_NAME" >&2
	fi

	# Write fstab entries
	build_fstab_lines
	progress "Writing /etc/fstab entries"
	if ! $DRY_RUN; then
		{
			printf "# System data-lake mounts (generated by new_system)\n"
			printf "# device\tmountpoint\ttype\toptions\tdump\tpass\n"
			printf "%s\n" "$FSTAB_LINES"
		} >> "${tablets}/etc/fstab"
	else
		printf "  [dry] append fstab entries to %s/etc/fstab\n" "$tablets" >&2
	fi

	# Commit and push
	run git -C "$tablets" add etc/fstab
	run git -C "$tablets" commit -m "system/${SYSTEM_NAME} inaugural"
	run git -C "$tablets" push origin "system/${SYSTEM_NAME}"

	# Wipe tablets
	progress "Destroying tablets workspace"
	if [ -d "$tablets" ] && ! $DRY_RUN; then
		clear_mtree "$tablets"
	fi
	if zfs_dataset_exists zshemot/tablets; then
		run zfs destroy -r zshemot/tablets
	fi
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	root_only
	trap cleanup EXIT

	# Phase 1: Input
	collect_system_name
	check_system_available
	collect_foundation
	collect_build_options
	print_summary
	if [ "$QUIET" -eq 0 ]; then
		confirm "Proceed with system creation?" || exit 0
	fi

	# Phase 2: Setup
	create_minhag_dir
	create_system_datasets

	# Phase 3: Inaugural commit
	create_inaugural_commit

	# Cleanup working mounts
	run zunmount zbamidbar/sinai.git
	run zunmount zbamidbar/sinai.zfs

	progress "System '${SYSTEM_NAME}' created successfully."
	printf "  Foundation: %s\n" "$FOUNDATION_NAME" >&2
	printf "  Minhag:     minhag/systems/%s/\n" "$SYSTEM_NAME" >&2
	printf "  Branch:     system/%s\n" "$SYSTEM_NAME" >&2

	# Phase 4: Deploy (optional)
	if [ "$BOOT" -gt 0 ] || { [ "$QUIET" -eq 0 ] && confirm "Deploy system now?"; }; then
		local deploy_flags="-s ${SYSTEM_NAME}"
		$DRY_RUN && deploy_flags="${deploy_flags} -d"
		[ "$BOOT" -gt 1 ] && deploy_flags="${deploy_flags} -n"
		sh "${SCRIPT_DIR}/deploy_system.sh" $deploy_flags
	fi
}

main
