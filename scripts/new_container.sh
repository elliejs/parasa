#!/bin/sh
# new_container -- Create a new container (jail) on top of a foundation.
#
# Mirrors new_system but for containers: creates a recipes directory with
# jail.conf and mount.fstab, data datasets on zbamidbar/container-data,
# and an inaugural commit on a containers/<name> branch in foundation.git.
# Containers are started by jail(8), not the boot loader.
#
# See plans/build_system.md and docs/idea.md Concept 2 for design context.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
. "${SCRIPT_DIR}/helpers.sh"
. "${SCRIPT_DIR}/workspace.sh"

WS_KIND="container"
WS_DATA_POOL="container-data"

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
deploy_container to populate the container root, then jail(8) to start.

Modes:
  Interactive      No -s flag. All questions asked.
  Semi-interactive -s without -q. Questions asked, -o values as defaults.
  Quiet            -s with -q.  No prompts; -o values + defaults only.

Data-lake mounts (var, usr/local) are always created. Home and tmp are
optional. Datasets live under zbamidbar/container-data/<name>/.

A skeleton jail.conf is created in the recipes directory. Edit it before
starting the container.

Examples:
  new_container                                  Interactive
  new_container -s nginx -f 15stable              Semi-interactive
  new_container -s postgres -f 15stable -qq       Fully silent
  new_container -s myapp -f 15stable -o user_homes=app

Execution flow:
  1. Collect container name and foundation
  2. Ask dataset/mount questions
  3. Create recipes/containers/<name>/ with .foundation, jail.conf, mount.fstab, etc.
  4. Create data datasets on zbamidbar/container-data/<name>/
  5. Create inaugural commit on containers/<name> branch
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

# ── Container-specific options ─────────────────────────────────────────────

collect_container_options() {
	collect_build_options

	# Format custom mounts with container path prefix.
	# ZFS dataset paths use zfs type; absolute paths use nullfs (cross-mounts).
	CUSTOM_MOUNT_LINES=""
	if [ -n "$CUSTOM_MOUNTS" ]; then
		local m dataset mountpoint fstype
		for m in $CUSTOM_MOUNTS; do
			dataset="${m%%:*}"
			mountpoint="${m#*:}"
			case "$dataset" in
				/*) fstype="nullfs" ;;
				*)  fstype="zfs" ;;
			esac
			CUSTOM_MOUNT_LINES="${CUSTOM_MOUNT_LINES}${CUSTOM_MOUNT_LINES:+
}${dataset}	/containers/${CONTAINER_NAME}${mountpoint}	${fstype}	rw	0	0"
		done
	fi
}

# ── Container recipes extras ────────────────────────────────────────────────

# Write mount.fstab and jail.conf into the recipes dir.
# Called after create_recipe_boilerplate sets WS_RECIPE_DIR.
create_container_recipe_extras() {
	if ! $DRY_RUN; then
		# mount.fstab -- all container mounts (data-lake + custom)
		local data_root="zbamidbar/container-data/${CONTAINER_NAME}"
		local cpath="/containers/${CONTAINER_NAME}"
		{
			printf "# source\tdestination\tfstype\toptions\tdump\tpass\n"
			printf "%s/var\t%s/var\tzfs\trw\t0\t0\n" "$data_root" "$cpath"
			printf "%s/usr-local\t%s/usr/local\tzfs\trw\t0\t0\n" "$data_root" "$cpath"
			if yesish "$WANT_HOME"; then
				printf "%s/home\t%s/home\tzfs\trw\t0\t0\n" "$data_root" "$cpath"
			fi
			if yesish "$WANT_TMP"; then
				printf "%s/tmp\t%s/tmp\tzfs\trw\t0\t0\n" "$data_root" "$cpath"
			fi
			if [ -n "$USER_HOMES" ]; then
				local old_ifs="$IFS" user
				IFS=','
				for user in $USER_HOMES; do
					IFS="$old_ifs"
					user=$(printf "%s" "$user" | tr -d '[:space:]')
					[ -n "$user" ] || continue
					printf "%s/home/%s\t%s/home/%s\tzfs\trw\t0\t0\n" \
						"$data_root" "$user" "$cpath" "$user"
				done
				IFS="$old_ifs"
			fi
			if [ -n "$CUSTOM_MOUNT_LINES" ]; then
				printf "%s\n" "$CUSTOM_MOUNT_LINES"
			fi
		} > "${WS_RECIPE_DIR}/mount.fstab"

		# Per-container jail.conf (included by recipes/jail.conf)
		cat > "${WS_RECIPE_DIR}/jail.conf" <<-JAILCONF
		# jail.conf for container: ${CONTAINER_NAME}
		# Included by the default recipes/jail.conf.
		# Shared defaults (exec.start, mount.devfs, etc.) are inherited.
		# See jail.conf(5) for options.

		${CONTAINER_NAME} {
		    host.hostname = "${CONTAINER_NAME}";
		    path = "/containers/${CONTAINER_NAME}";
		    mount.fstab = "${PARASA_DIR}/recipes/containers/${CONTAINER_NAME}/mount.fstab";
		}
		JAILCONF
	else
		printf "  [dry] create %s/{mount.fstab,jail.conf}\n" "$WS_RECIPE_DIR" >&2
	fi
}

# ── Container summary ──────────────────────────────────────────────────────

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

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	root_only

	# Phase 1: Input
	CONTAINER_NAME=$(collect_name "$CONTAINER_NAME" "Container")
	WS_NAME="$CONTAINER_NAME"
	trap ws_cleanup EXIT
	check_available
	collect_foundation
	collect_container_options
	print_summary
	if [ "$QUIET" -eq 0 ]; then
		confirm "Proceed with container creation?" || exit 0
	fi

	# Phase 2: Setup
	create_recipe_boilerplate
	create_container_recipe_extras
	create_data_datasets

	# Phase 3: Inaugural commit (container: no content, allow-empty)
	ws_begin
	ws_commit --allow-empty
	ws_end

	progress "Container '${CONTAINER_NAME}' created successfully."
	printf "  Foundation: %s\n" "$FOUNDATION_NAME" >&2
	printf "  Recipe:     recipes/containers/%s/\n" "$CONTAINER_NAME" >&2
	printf "  Branch:     containers/%s\n" "$CONTAINER_NAME" >&2
	printf "  jail.conf:  recipes/containers/%s/jail.conf\n" "$CONTAINER_NAME" >&2
	printf "\nNext: deploy_container -s %s\n" "$CONTAINER_NAME" >&2
	printf "Then edit jail.conf and use jail(8) to start the container.\n" >&2
}

main
