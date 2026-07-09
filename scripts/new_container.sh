#!/bin/sh
# new_container -- Create a new container (jail) on top of a foundation.
#
# Mirrors new_system but for containers: creates a minhag directory with
# jail.conf, data datasets on zbamidbar/container-data, and an inaugural
# commit on a container/<name> branch in sinai.git. Containers are started
# by jail(8), not the boot loader.
#
# See plans/build_system.md and docs/idea.md Concept 2 for design context.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
MISHKAN_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
new_container -- Create a new container (jail) on top of a foundation.

Usage:
  new_container [-h] [-d] [-s NAME] [-f FOUNDATION] [-o K=V ...] [-q [-q]]

Options:
  -h        Show this help and exit
  -d        Dry run: print commands without executing them
  -s NAME   Container name (skips the name prompt)
  -f FOUND  Foundation to base on (prompted if omitted)
  -o K=V    Property override (repeatable). Keys:
              home_dataset     Create /home dataset (default: yes)
              tmp_dataset      Create /tmp dataset  (default: yes)
              user_homes       Comma-separated user names for home datasets
              mount_map        Custom mount: dataset:mountpoint (repeatable)
  -q        Quiet: suppress prompts, use defaults.
  -qq       Silent: suppress prompts AND progress output.

Unlike new_system, there is no -b (deploy/nextboot) flag. Containers are
deployed to zbereshit/containers/ and started via jail(8). Use
deploy_container (future) or jail(8) directly.

Modes:
  Interactive      No -s flag. All questions asked.
  Semi-interactive -s without -q. Questions asked, -o values as defaults.
  Quiet            -s with -q.  No prompts; -o values + defaults only.

Data-lake mounts (var, usr/local) are always created. Home and tmp are
optional. Datasets live under zbamidbar/container-data/<name>/.

A skeleton jail.conf is created in the minhag directory. Edit it before
starting the container.

Examples:
  new_container                                  Interactive
  new_container -s nginx -f stable15             Semi-interactive
  new_container -s postgres -f stable15 -qq      Fully silent
  new_container -s myapp -f stable15 -o user_homes=app

Execution flow:
  1. Collect container name and foundation
  2. Ask dataset/mount questions
  3. Create minhag/containers/<name>/ with .foundation, jail.conf, etc.
  4. Create data datasets on zbamidbar/container-data/<name>/
  5. Create inaugural commit on container/<name> branch (writes /etc/fstab)
EOF
	exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────

DRY_RUN=false
QUIET=0
CONTAINER_NAME=""
FOUNDATION_NAME=""
OPT_HOME="yes"
OPT_TMP="yes"
OPT_USER_HOMES=""
OPT_MOUNT_MAP=""

while getopts ":hds:f:o:q" opt; do
	case "$opt" in
		h) print_help ;;
		d) DRY_RUN=true ;;
		s) CONTAINER_NAME="$OPTARG" ;;
		f) FOUNDATION_NAME="$OPTARG" ;;
		o)
			case "$OPTARG" in
				home_dataset=*)     OPT_HOME="${OPTARG#home_dataset=}" ;;
				tmp_dataset=*)      OPT_TMP="${OPTARG#tmp_dataset=}" ;;
				user_homes=*)       OPT_USER_HOMES="${OPTARG#user_homes=}" ;;
				mount_map=*)        OPT_MOUNT_MAP="${OPT_MOUNT_MAP}${OPT_MOUNT_MAP:+ }${OPTARG#mount_map=}" ;;
				*) die "Unknown -o key: ${OPTARG%%=*}. Use -h for valid keys." ;;
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

# ── Cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
	if zfs_dataset_exists zshemot/tablets; then
		printf "Cleaning up transient zshemot/tablets...\n" >&2
		zfs destroy -r zshemot/tablets 2>/dev/null || true
	fi
}

# ── Phase 1: Input ──────────────────────────────────────────────────────────

collect_container_name() {
	if [ -n "$CONTAINER_NAME" ]; then
		validate_name "$CONTAINER_NAME" "Container name" || exit 1
		return
	fi
	if [ "$QUIET" -gt 0 ]; then
		die "Container name required in quiet mode (-s NAME)."
	fi
	local resp
	while true; do
		printf "Container name: " >&2
		read -r resp || die "EOF reading container name"
		if validate_name "$resp" "Container name"; then
			CONTAINER_NAME="$resp"
			return
		fi
	done
}

check_container_available() {
	local minhag="${MISHKAN_DIR}/minhag/containers/${CONTAINER_NAME}"
	if [ -d "$minhag" ]; then
		die "Container '${CONTAINER_NAME}' already exists in minhag. Use destroy_container (future) or pick a new name."
	fi
	if zfs_dataset_exists "zbereshit/containers/${CONTAINER_NAME}"; then
		die "Container '${CONTAINER_NAME}' already deployed on zbereshit."
	fi
}

collect_foundation() {
	if [ -n "$FOUNDATION_NAME" ]; then
		local fminhag="${MISHKAN_DIR}/minhag/foundations/${FOUNDATION_NAME}"
		[ -d "$fminhag" ] || die "Foundation '${FOUNDATION_NAME}' not found in minhag."
		zfs_dataset_exists "zbamidbar/sinai.zfs/foundations/${FOUNDATION_NAME}" || \
			die "Foundation '${FOUNDATION_NAME}' not archived in zbamidbar/sinai.zfs."
		return
	fi
	FOUNDATION_NAME=$(select_foundation "$QUIET")
}

collect_build_options() {
	local data_root="zbamidbar/container-data/${CONTAINER_NAME}"

	WANT_HOME=$(prompt_yesno "Create /home dataset?" "$OPT_HOME" "$QUIET" && echo yes || echo no)
	WANT_TMP=$(prompt_yesno "Create /tmp dataset?" "$OPT_TMP" "$QUIET" && echo yes || echo no)

	USER_HOMES="$OPT_USER_HOMES"
	if [ "$QUIET" -eq 0 ] && [ -z "$USER_HOMES" ]; then
		printf "Additional user home datasets (comma-separated, Enter for none): " >&2
		read -r USER_HOMES || USER_HOMES=""
	fi

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
				SYSTEM_MOUNTS="${SYSTEM_MOUNTS}${SYSTEM_MOUNTS:+
}${dataset}	${mountpoint}	zfs	rw,late	0	0"
			fi
		done
	fi
}

print_summary() {
	local data_root="zbamidbar/container-data/${CONTAINER_NAME}"
	cat >&2 <<-EOF

	Container: ${CONTAINER_NAME}
	  Foundation:  ${FOUNDATION_NAME}
	  var:         ${data_root}/var (always)
	  usr/local:   ${data_root}/usr-local (always)
	  home:        $(yesish "$WANT_HOME" && echo "${data_root}/home" || echo "no")
	  tmp:         $(yesish "$WANT_TMP" && echo "${data_root}/tmp" || echo "no")
	  user homes:  ${USER_HOMES:-none}
	EOF
}

# ── Phase 2: Setup ─────────────────────────────────────────────────────────

create_minhag_dir() {
	local minhag="${MISHKAN_DIR}/minhag/containers/${CONTAINER_NAME}"

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

		# Recipe-only mounts
		if [ -n "$RECIPE_MOUNTS" ]; then
			printf "# Recipe-only mounts (container deps, shared data-pools)\n" > "${minhag}/fstab.local"
			printf "%s\n" "$RECIPE_MOUNTS" >> "${minhag}/fstab.local"
		else
			: > "${minhag}/fstab.local"
		fi

		# Skeleton jail.conf
		cat > "${minhag}/jail.conf" <<-JAILCONF
		# jail.conf for container: ${CONTAINER_NAME}
		# See jail(8) and jail.conf(5) for options.
		#
		# This file is included by the main jail.conf via jail.conf.d/.

		${CONTAINER_NAME} {
		    host.hostname = "${CONTAINER_NAME}";
		    path = "/containers/${CONTAINER_NAME}";

		    mount.devfs;
		    devfs_ruleset = 4;

		    exec.start = "/bin/sh /etc/rc";
		    exec.stop  = "/bin/sh /etc/rc.shutdown";
		    exec.clean;
		}
		JAILCONF
	else
		printf "  [dry] create %s/{%s.foundation,compose.sh,derivations.local,pkg.list,mtree.dist,fstab.local,jail.conf}\n" \
			"$minhag" "$FOUNDATION_NAME" >&2
	fi
}

create_container_datasets() {
	local data_root="zbamidbar/container-data/${CONTAINER_NAME}"
	local foundation_var="zbamidbar/sinai.zfs/foundations/${FOUNDATION_NAME}/var"

	progress "Creating data datasets"

	run ztouch "$data_root" -o mountpoint=none -o canmount=noauto

	# var: copy pristine var from foundation
	progress "Copying pristine var from foundation"
	run zmount zbamidbar/sinai.zfs /zbamidbar/sinai.zfs
	if ! $DRY_RUN; then
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

	# usr-local
	run ztouch "${data_root}/usr-local" -o mountpoint=none -o canmount=noauto

	if yesish "$WANT_HOME"; then
		run ztouch "${data_root}/home" -o mountpoint=none -o canmount=noauto
	fi
	if yesish "$WANT_TMP"; then
		run ztouch "${data_root}/tmp" -o mountpoint=none -o canmount=noauto
	fi

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

create_inaugural_commit() {
	local sinai_git="/zbamidbar/sinai.git"
	local foundation_archive="zbamidbar/sinai.zfs/foundations/${FOUNDATION_NAME}"
	local tablets="/zshemot/tablets"
	local data_root="zbamidbar/container-data/${CONTAINER_NAME}"

	progress "Creating inaugural commit"

	run zmount zbamidbar/sinai.git "$sinai_git"
	run zmount zbamidbar/sinai.zfs /zbamidbar/sinai.zfs

	if zfs_dataset_exists zshemot/tablets; then
		run zfs destroy -r zshemot/tablets
	fi

	# Recv foundation to tablets
	progress "Receiving foundation to tablets workspace"
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

	# Git setup
	progress "Setting up container branch"
	if ! $DRY_RUN; then
		local current_remote
		current_remote=$(git -C "$tablets" config remote.origin.url 2>/dev/null || echo "")
		if [ "$current_remote" != "$sinai_git" ]; then
			git -C "$tablets" remote set-url origin "$sinai_git" 2>/dev/null || \
				git -C "$tablets" remote add origin "$sinai_git"
		fi
		git -C "$tablets" fetch origin

		git -C "$tablets" checkout -b "container/${CONTAINER_NAME}" \
			"foundation/${FOUNDATION_NAME}"
	else
		printf "  [dry] git -C %s checkout -b container/%s foundation/%s\n" \
			"$tablets" "$CONTAINER_NAME" "$FOUNDATION_NAME" >&2
	fi

	# Build fstab lines
	progress "Writing /etc/fstab entries"
	if ! $DRY_RUN; then
		{
			printf "# Container data-lake mounts (generated by new_container)\n"
			printf "# device\tmountpoint\ttype\toptions\tdump\tpass\n"
			# Always-included
			printf "%s/var\t/var\tzfs\trw,late\t0\t0\n" "$data_root"
			printf "%s/usr-local\t/usr/local\tzfs\trw,late\t0\t0\n" "$data_root"
			# Optional
			if yesish "$WANT_HOME"; then
				printf "%s/home\t/home\tzfs\trw,late\t0\t0\n" "$data_root"
			fi
			if yesish "$WANT_TMP"; then
				printf "%s/tmp\t/tmp\tzfs\trw,late\t0\t0\n" "$data_root"
			fi
			# User homes
			if [ -n "$USER_HOMES" ]; then
				local old_ifs="$IFS" user
				IFS=','
				for user in $USER_HOMES; do
					IFS="$old_ifs"
					user=$(printf "%s" "$user" | tr -d '[:space:]')
					[ -n "$user" ] || continue
					printf "%s/home/%s\t/home/%s\tzfs\trw,late\t0\t0\n" \
						"$data_root" "$user" "$user"
				done
				IFS="$old_ifs"
			fi
			# Custom mounts
			[ -n "$SYSTEM_MOUNTS" ] && printf "%s\n" "$SYSTEM_MOUNTS"
			[ -n "$RECIPE_MOUNTS" ] && printf "%s\n" "$RECIPE_MOUNTS"
		} >> "${tablets}/etc/fstab"
	else
		printf "  [dry] append fstab entries to %s/etc/fstab\n" "$tablets" >&2
	fi

	# Commit and push
	run git -C "$tablets" add etc/fstab
	run git -C "$tablets" commit -m "container/${CONTAINER_NAME} inaugural"
	run git -C "$tablets" push origin "container/${CONTAINER_NAME}"

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
	collect_container_name
	check_container_available
	collect_foundation
	collect_build_options
	print_summary
	if [ "$QUIET" -eq 0 ]; then
		confirm "Proceed with container creation?" || exit 0
	fi

	# Phase 2: Setup
	create_minhag_dir
	create_container_datasets

	# Phase 3: Inaugural commit
	create_inaugural_commit

	# Cleanup working mounts
	run zunmount zbamidbar/sinai.git
	run zunmount zbamidbar/sinai.zfs

	progress "Container '${CONTAINER_NAME}' created successfully."
	printf "  Foundation: %s\n" "$FOUNDATION_NAME" >&2
	printf "  Minhag:     minhag/containers/%s/\n" "$CONTAINER_NAME" >&2
	printf "  Branch:     container/%s\n" "$CONTAINER_NAME" >&2
	printf "  jail.conf:  minhag/containers/%s/jail.conf\n" "$CONTAINER_NAME" >&2
	printf "\nEdit jail.conf and use jail(8) to start the container.\n" >&2
}

main
