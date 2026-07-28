#!/bin/sh
# new_system -- Create a new system on top of a foundation.
#
# Takes an existing foundation and creates a system: recipes directory,
# data datasets on zbamidbar, and an inaugural commit on a system/<name>
# branch in foundation.git. Optionally deploys to zbereshit.
#
# See plans/build_system.md Part 2 for the full design.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
. "${SCRIPT_DIR}/helpers.sh"
. "${SCRIPT_DIR}/workspace.sh"

WS_KIND="system"
WS_DATA_POOL="system-data"

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
  new_system -s wonderland -f 15stable            Semi-interactive
  new_system -s testbox -f 15stable -qbb          Quiet, deploy + nextboot
  new_system -s dev -f 15stable -o home_dataset=no -o user_homes=alice,bob

Execution flow:
  1. Collect system name and foundation
  2. Ask dataset/mount questions
  3. Create recipes/systems/<name>/ with .foundation, boilerplate files
  4. Create data datasets on zbamidbar/system-data/<name>/
  5. Create inaugural commit on systems/<name> branch (writes /etc/fstab)
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

# ── System-specific options ─────────────────────────────────────────────────

collect_system_options() {
	collect_build_options

	# System-specific: roothome dataset
	WANT_ROOTHOME="no"
	if yesish "$WANT_HOME"; then
		WANT_ROOTHOME=$(prompt_yesno "Create separate /home/root dataset?" "$OPT_ROOTHOME" "$QUIET" && echo yes || echo no)
	fi

	# Format custom mounts as system fstab lines (zfs, rw,late)
	SYSTEM_MOUNTS=""
	if [ -n "$CUSTOM_MOUNTS" ]; then
		local m dataset mountpoint
		for m in $CUSTOM_MOUNTS; do
			dataset="${m%%:*}"
			mountpoint="${m#*:}"
			SYSTEM_MOUNTS="${SYSTEM_MOUNTS}${SYSTEM_MOUNTS:+
}${dataset}	${mountpoint}	zfs	rw,late	0	0"
		done
	fi
}

# ── System fstab generation ────────────────────────────────────────────────

build_fstab_lines() {
	local data_root="zbamidbar/system-data/${SYSTEM_NAME}"

	FSTAB_LINES="${data_root}/var	/var	zfs	rw,late	0	0
${data_root}/usr-local	/usr/local	zfs	rw,late	0	0"

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

	if [ -n "$SYSTEM_MOUNTS" ]; then
		FSTAB_LINES="${FSTAB_LINES}
${SYSTEM_MOUNTS}"
	fi
}

# ── System summary ─────────────────────────────────────────────────────────

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
		printf "  Custom fstab mounts:\n" >&2
		printf "%s\n" "$SYSTEM_MOUNTS" | while IFS= read -r line; do
			printf "    %s\n" "$line" >&2
		done
	fi
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	root_only

	# Phase 1: Input
	SYSTEM_NAME=$(collect_name "$SYSTEM_NAME" "System")
	WS_NAME="$SYSTEM_NAME"
	trap ws_cleanup EXIT
	check_available
	collect_foundation
	collect_system_options
	print_summary
	if [ "$QUIET" -eq 0 ]; then
		confirm "Proceed with system creation?" || exit 0
	fi

	# Phase 2: Setup
	create_recipe_boilerplate
	create_data_datasets

	# Phase 3: Inaugural commit
	ws_begin

	# System-specific: write /etc/fstab into workspace
	build_fstab_lines
	progress "Writing /etc/fstab entries"
	if ! $DRY_RUN; then
		{
			printf "# System data-lake mounts (generated by new_system)\n"
			printf "# device\tmountpoint\ttype\toptions\tdump\tpass\n"
			printf "%s\n" "$FSTAB_LINES"
		} >> "${WS_PATH}/etc/fstab"
	else
		printf "  [dry] append fstab entries to %s/etc/fstab\n" "$WS_PATH" >&2
	fi
	run git -C "$WS_PATH" add etc/fstab

	ws_commit
	ws_end

	progress "System '${SYSTEM_NAME}' created successfully."
	printf "  Foundation: %s\n" "$FOUNDATION_NAME" >&2
	printf "  Recipe:     recipes/systems/%s/\n" "$SYSTEM_NAME" >&2
	printf "  Branch:     systems/%s\n" "$SYSTEM_NAME" >&2

	# Phase 4: Deploy (optional)
	if [ "$BOOT" -gt 0 ] || { [ "$QUIET" -eq 0 ] && [ -t 0 ] && confirm "Deploy system now?"; }; then
		local deploy_flags="-s ${SYSTEM_NAME}"
		$DRY_RUN && deploy_flags="${deploy_flags} -d"
		[ "$BOOT" -gt 1 ] && deploy_flags="${deploy_flags} -n"
		exec sh "${SCRIPT_DIR}/deploy_system.sh" $deploy_flags
	elif [ "$QUIET" -eq 0 ]; then
		printf "When ready: deploy_system -s %s\n" "$SYSTEM_NAME" >&2
	fi
}

main
