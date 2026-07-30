#!/bin/sh
# new_container -- Create a new container (jail) on top of a foundation.
#
# Sends the foundation to zbereshit, clones it to zbereshit/containers/<name>,
# runs the recipe (packages, compose.sh), generates derivations and mtree,
# then creates the inaugural commit on a containers/<name> branch in
# foundation.git.
#
# See plans/build_system.md and docs/idea.md Concept 2 for design context.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
. "${SCRIPT_DIR}/helpers.sh"

USING_RECIPE=false

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

Modes:
  Interactive      No -s flag. All questions asked.
  Semi-interactive -s without -q. Questions asked, -o values as defaults.
  Quiet            -s with -q.  No prompts; -o values + defaults only.

Data-lake mounts (var, usr/local) are always created. Home and tmp are
optional. Datasets live under zbamidbar/container-data/<name>/.

Execution flow:
  1. Collect container name and foundation (or pick existing recipe)
  2. Create recipe scaffold (or use existing)
  3. Send foundation to zbereshit/foundations (full or incremental)
  4. Clone foundation to zbereshit/containers/<name>
  5. Create data datasets, mount into container, start jail
  6. Run recipe: pre_pkg → packages → post_pkg
  7. Regenerate derivations
  8. Generate mtree
  9. Inaugural git commit on containers/<name> branch
 10. Stop jail, offer to start

Examples:
  new_container                                  Interactive
  new_container -s nginx -f 15.1releng           Semi-interactive
  new_container -s postgres -f 15.1releng -qq    Fully silent
  new_container -s myapp -f 15.1releng -o user_homes=app
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

# ── Cleanup trap ────────────────────────────────────────────────────────────

_JAIL_STARTED=""
_CLONE_CREATED=""

container_cleanup() {
	# Stop jail if we started one
	if [ -n "$_JAIL_STARTED" ]; then
		jail -r "$CONTAINER_NAME" 2>/dev/null || true
	fi
	# Destroy clone if we created one and didn't finish
	if [ -n "$_CLONE_CREATED" ]; then
		local cpath="/containers/${CONTAINER_NAME}"
		printf "Cleaning up partial zbereshit/containers/%s...\n" "$CONTAINER_NAME" >&2

		# Unmount everything under the container path (reverse order)
		if [ -d "$cpath" ]; then
			mount -p | awk -v prefix="$cpath/" '$2 == prefix || substr($2,1,length(prefix)) == prefix {print $2}' | \
				sort -r | while read -r mnt; do
				umount "$mnt" 2>/dev/null || umount -f "$mnt" 2>/dev/null || true
			done
		fi

		# Reset data dataset mountpoints and unmount
		if zfs_dataset_exists "zbamidbar/container-data/${CONTAINER_NAME}"; then
			zfs list -r -H -o name "zbamidbar/container-data/${CONTAINER_NAME}" 2>/dev/null | \
				sort -r | while read -r ds; do
				zfs unmount "$ds" 2>/dev/null || true
				zfs set mountpoint=none "$ds" 2>/dev/null || true
			done
			zfs destroy -r "zbamidbar/container-data/${CONTAINER_NAME}" 2>/dev/null || true
		fi

		# Clear schg flags before destroy
		if [ -d "$cpath" ]; then
			clear_mtree "$cpath" 2>/dev/null || true
		fi
		# .git child dataset must go first
		zfs destroy "zbereshit/containers/${CONTAINER_NAME}/.git" 2>/dev/null || true
		zfs destroy -r "zbereshit/containers/${CONTAINER_NAME}" 2>/dev/null || true
	fi
	zunmount zbamidbar/foundation.git 2>/dev/null || true
	zunmount zbamidbar/foundation.zfs 2>/dev/null || true
}

# ── Phase 1: Recipe crawling ──────────────────────────────────────────────

collect_container_name() {
	if [ -n "$CONTAINER_NAME" ]; then
		validate_name "$CONTAINER_NAME" "Container name" || exit 1
		if [ -d "${RECIPES_DIR}/containers/${CONTAINER_NAME}" ]; then
			USING_RECIPE=true
		fi
		return
	fi
	if [ "$QUIET" -gt 0 ]; then
		die "Container name required in quiet mode (-s NAME)."
	fi

	# List existing container recipes that haven't been deployed yet
	local recipes_dir="${RECIPES_DIR}/containers"
	local idx=0 name
	for d in "$recipes_dir"/*/; do
		[ -d "$d" ] || continue
		name=$(basename "$d")
		[ "$name" = "*" ] && continue
		# Skip already-deployed containers
		zfs_dataset_exists "zbereshit/containers/${name}" && continue
		idx=$((idx + 1))
		[ "$idx" -eq 1 ] && printf "Undeployed container recipes:\n" >&2
		printf "  %d) %s\n" "$idx" "$name" >&2
	done

	local resp
	while true; do
		printf "Container name or number: " >&2
		read -r resp || die "EOF reading container name"
		case "$resp" in
			[0-9]|[0-9][0-9])
				local cur=0
				for d in "$recipes_dir"/*/; do
					[ -d "$d" ] || continue
					name=$(basename "$d")
					[ "$name" = "*" ] && continue
					zfs_dataset_exists "zbereshit/containers/${name}" && continue
					cur=$((cur + 1))
					if [ "$cur" -eq "$resp" ]; then
						CONTAINER_NAME="$name"
						USING_RECIPE=true
						return
					fi
				done
				printf "  Invalid number.\n" >&2
				continue
				;;
		esac
		if validate_name "$resp" "Container name"; then
			CONTAINER_NAME="$resp"
			if [ -d "${RECIPES_DIR}/containers/${CONTAINER_NAME}" ]; then
				USING_RECIPE=true
			fi
			return
		fi
	done
}

# Derive dataset options from an existing recipe's mount.fstab.
# Sets WANT_HOME, WANT_TMP, USER_HOMES, FOREIGN_MOUNTS for create_data_datasets().
parse_recipe_datasets() {
	local fstab="${RECIPE_DIR}/mount.fstab"
	local data_root="zbamidbar/container-data/${CONTAINER_NAME}"

	WANT_HOME=no
	WANT_TMP=no
	USER_HOMES=""
	FOREIGN_MOUNTS=""

	[ -f "$fstab" ] || return

	local src dest fstype opts dump pass
	while IFS='	' read -r src dest fstype opts dump pass; do
		[ -n "$src" ] || continue
		case "$src" in \#*) continue ;; esac
		case "$src" in
			"${data_root}/home/"*)
				local user="${src#${data_root}/home/}"
				USER_HOMES="${USER_HOMES}${USER_HOMES:+,}${user}"
				;;
			"${data_root}/home")
				WANT_HOME=yes
				;;
			"${data_root}/tmp")
				WANT_TMP=yes
				;;
			"${data_root}/var"|"${data_root}/usr-local")
				: # always created
				;;
			*)
				# Foreign mount (nullfs or external ZFS)
				FOREIGN_MOUNTS="${FOREIGN_MOUNTS}${FOREIGN_MOUNTS:+
}${src}	${dest}	${fstype}"
				;;
		esac
	done < "$fstab"
}

collect_foundation() {
	if [ -n "$FOUNDATION_NAME" ]; then
		local frecipe="${RECIPES_DIR}/foundations/${FOUNDATION_NAME}.conf"
		[ -f "$frecipe" ] || die "Foundation '${FOUNDATION_NAME}' not found in recipes."
		zfs_dataset_exists "zbamidbar/foundation.zfs/${FOUNDATION_NAME}" || \
			die "Foundation '${FOUNDATION_NAME}' not archived in zbamidbar/foundation.zfs."
		return
	fi
	FOUNDATION_NAME=$(select_foundation "$QUIET")
}

# ── Phase 1b: Interactive dataset/mount options (new recipe only) ──────────

collect_container_options() {
	WANT_HOME=$(prompt_yesno "Create /home dataset?" "${OPT_HOME:-yes}" "$QUIET" && echo yes || echo no)
	WANT_TMP=$(prompt_yesno "Create /tmp dataset?" "${OPT_TMP:-yes}" "$QUIET" && echo yes || echo no)

	USER_HOMES="${OPT_USER_HOMES:-}"
	if [ "$QUIET" -eq 0 ] && [ -z "$USER_HOMES" ]; then
		printf "Additional user home datasets (comma-separated, Enter for none): " >&2
		read -r USER_HOMES || USER_HOMES=""
	fi

	CUSTOM_MOUNTS="${OPT_MOUNT_MAP:-}"
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

	# Build FOREIGN_MOUNTS for summary display
	FOREIGN_MOUNTS=""
	if [ -n "$CUSTOM_MOUNTS" ]; then
		local m dataset mountpoint fstype cpath="/containers/${CONTAINER_NAME}"
		for m in $CUSTOM_MOUNTS; do
			dataset="${m%%:*}"
			mountpoint="${m#*:}"
			case "$dataset" in
				/*) fstype="nullfs" ;;
				*)  fstype="zfs" ;;
			esac
			FOREIGN_MOUNTS="${FOREIGN_MOUNTS}${FOREIGN_MOUNTS:+
}${dataset}	${cpath}${mountpoint}	${fstype}"
		done
	fi
}

# ── Phase 2: Recipe creation (new recipe only) ────────────────────────────

create_recipe() {
	RECIPE_DIR="${RECIPES_DIR}/containers/${CONTAINER_NAME}"

	progress "Creating recipe: ${RECIPE_DIR}"
	run mkdir -p "$RECIPE_DIR"

	if ! $DRY_RUN; then
		# Boilerplate files
		cat > "${RECIPE_DIR}/compose.sh" <<'COMPOSE'
#!/bin/sh
# compose.sh -- recipe actions for this workspace.
# Called during creation and update. Source this file, then call
# pre_pkg (before package install) and post_pkg (after).

pre_pkg() {
	:
}

post_pkg() {
	:
}
COMPOSE
		: > "${RECIPE_DIR}/derivations.local"
		: > "${RECIPE_DIR}/pkg.list"

		# mount.fstab
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
			if [ -n "$CUSTOM_MOUNTS" ]; then
				local m dataset mountpoint fstype
				for m in $CUSTOM_MOUNTS; do
					dataset="${m%%:*}"
					mountpoint="${m#*:}"
					case "$dataset" in
						/*) fstype="nullfs" ;;
						*)  fstype="zfs" ;;
					esac
					printf "%s\t%s%s\t%s\trw\t0\t0\n" \
						"$dataset" "$cpath" "$mountpoint" "$fstype"
				done
			fi
		} > "${RECIPE_DIR}/mount.fstab"

		# jail.conf
		cat > "${RECIPE_DIR}/jail.conf" <<-JAILCONF
		# jail.conf for container: ${CONTAINER_NAME}
		# Included by the default recipes/jail.conf.
		# Shared defaults (exec.start, mount.devfs, etc.) are inherited.
		# See jail.conf(5) for options.

		${CONTAINER_NAME} {
		    host.hostname = "${CONTAINER_NAME}";
		    path = "/containers/${CONTAINER_NAME}";
		    mount.fstab = "${RECIPES_DIR}/containers/${CONTAINER_NAME}/mount.fstab";
		}
		JAILCONF
	else
		printf "  [dry] create %s/{compose.sh,derivations.local,pkg.list,mount.fstab,jail.conf}\n" \
			"$RECIPE_DIR" >&2
	fi
}

# ── Ensure foreign ZFS datasets exist ─────────────────────────────────────

ensure_foreign_datasets() {
	[ -n "${FOREIGN_MOUNTS:-}" ] || return 0

	# Write to temp file so the while-read loop doesn't steal stdin
	local _fm_tmp
	_fm_tmp=$(mktemp /tmp/parasa-fm-XXXXXX)
	printf "%s\n" "$FOREIGN_MOUNTS" > "$_fm_tmp"

	local src dest fstype ds_name
	while IFS='	' read -r src dest fstype <&3; do
		case "$fstype" in
			zfs)
				if ! zfs_dataset_exists "$src"; then
					printf "  ZFS dataset does not exist: %s\n" "$src" >&2
					if [ "$QUIET" -eq 0 ]; then
						if confirm "  Create dataset ${src}?"; then
							run ztouch "$src" -o mountpoint=none -o canmount=noauto
						else
							die "Required dataset '${src}' does not exist."
						fi
					else
						die "Required dataset '${src}' does not exist."
					fi
				fi
				;;
			nullfs)
				if [ ! -d "$src" ]; then
					printf "  Host path does not exist: %s\n" "$src" >&2
					if [ "$QUIET" -eq 0 ]; then
						printf "  Create a ZFS dataset mounted at %s?\n" "$src" >&2
						printf "  Dataset name: " >&2
						read -r ds_name || die "EOF reading dataset name"
						[ -n "$ds_name" ] || die "Dataset name required."
						run zfs create -o mountpoint="$src" "$ds_name"
					else
						die "Host path '${src}' does not exist."
					fi
				fi
				;;
		esac
	done 3< "$_fm_tmp"
	rm -f "$_fm_tmp"
}

# ── Phase 3: Send foundation to zbereshit ─────────────────────────────────

send_foundation() {
	local archive="zbamidbar/foundation.zfs/${FOUNDATION_NAME}"

	progress "Ensuring foundation on zbereshit"
	run zmount zbamidbar/foundation.zfs /zbamidbar/foundation.zfs

	if ! $DRY_RUN; then
		ARTIFACT_NAME=$(get_current_artifact "$archive")
		[ -n "$ARTIFACT_NAME" ] || die "No snapshots found on ${archive}"
	else
		ARTIFACT_NAME="[dry-run-artifact]"
	fi

	local dest="zbereshit/foundations/${FOUNDATION_NAME}"

	if ! $DRY_RUN; then
		if zfs_dataset_exists "$dest"; then
			# Check if we already have this artifact
			local current
			current=$(get_current_artifact "$dest" 2>/dev/null) || true
			if [ "$current" = "$ARTIFACT_NAME" ]; then
				progress "Foundation already current on zbereshit"
			else
				# Incremental send
				progress "Incremental send → zbereshit/foundations/${FOUNDATION_NAME}"
				zfs send -i "@${current}" "${archive}@${ARTIFACT_NAME}" | \
					zfs recv -F "$dest"
			fi
		else
			# Full send
			progress "Full send → zbereshit/foundations/${FOUNDATION_NAME}"
			zfs send "${archive}@${ARTIFACT_NAME}" | \
				zfs recv -o mountpoint=none -o canmount=noauto "$dest"
		fi
	else
		printf "  [dry] zfs send %s@%s → zbereshit/foundations/%s\n" \
			"$archive" "$ARTIFACT_NAME" "$FOUNDATION_NAME" >&2
	fi
}

# ── Phase 4: Clone foundation to container ────────────────────────────────

clone_to_container() {
	local src="zbereshit/foundations/${FOUNDATION_NAME}@${ARTIFACT_NAME}"
	local dest="zbereshit/containers/${CONTAINER_NAME}"

	progress "Cloning foundation → zbereshit/containers/${CONTAINER_NAME}"

	if ! $DRY_RUN; then
		zfs clone -o mountpoint="/containers/${CONTAINER_NAME}" -o canmount=on \
			"$src" "$dest"
		zfs mount "$dest" 2>/dev/null || true
	else
		printf "  [dry] zfs clone %s → %s\n" "$src" "$dest" >&2
	fi

	_CLONE_CREATED=true
}

# ── Phase 5: Data datasets + mount + start jail ──────────────────────────

create_data_datasets() {
	local data_root="zbamidbar/container-data/${CONTAINER_NAME}"
	local foundation_var="zbamidbar/foundation.zfs/${FOUNDATION_NAME}/var"
	local cpath="/containers/${CONTAINER_NAME}"

	progress "Creating data datasets"

	run ztouch "$data_root" -o mountpoint=none -o canmount=noauto

	# var: copy pristine var from foundation
	progress "Copying pristine var from foundation"
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

	# usr-local: always
	run ztouch "${data_root}/usr-local" -o mountpoint=none -o canmount=noauto

	# Optional datasets
	if yesish "$WANT_HOME"; then
		run ztouch "${data_root}/home" -o mountpoint=none -o canmount=noauto
	fi
	if yesish "$WANT_TMP"; then
		run ztouch "${data_root}/tmp" -o mountpoint=none -o canmount=noauto
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

mount_and_start() {
	local data_root="zbamidbar/container-data/${CONTAINER_NAME}"
	local cpath="/containers/${CONTAINER_NAME}"
	local fstab="${RECIPE_DIR}/mount.fstab"

	# Mount data-lake datasets
	progress "Mounting data datasets"
	run zfs set mountpoint="${cpath}/var" "${data_root}/var"
	run zfs mount "${data_root}/var"
	run zfs set mountpoint="${cpath}/usr/local" "${data_root}/usr-local"
	run zfs mount "${data_root}/usr-local"
	if zfs_dataset_exists "${data_root}/home"; then
		run zfs set mountpoint="${cpath}/home" "${data_root}/home"
		run zfs mount "${data_root}/home"
	fi
	if zfs_dataset_exists "${data_root}/tmp"; then
		run zfs set mountpoint="${cpath}/tmp" "${data_root}/tmp"
		run zfs mount "${data_root}/tmp"
	fi

	# Foreign mounts: create dirs (on now-mounted data datasets) and mount
	if [ -f "$fstab" ]; then
		local src dest fstype
		while IFS='	' read -r src dest fstype _; do
			[ -n "$src" ] || continue
			case "$src" in \#*) continue ;; esac
			case "$src" in "${data_root}/"*) continue ;; esac
			[ -d "$dest" ] || run mkdir -p "$dest"
			case "$fstype" in
				nullfs) run mount -t nullfs "$src" "$dest" ;;
				zfs)    run zfs set mountpoint="$dest" "$src"; run zfs mount "$src" ;;
			esac
		done < "$fstab"
	fi

	# Copy host resolv.conf so the jail has DNS
	if [ -f /etc/resolv.conf ]; then
		run cp /etc/resolv.conf "${cpath}/etc/resolv.conf"
	fi

	progress "Starting jail"
	run jail -c name="$CONTAINER_NAME" path="$cpath" \
		host.hostname="$CONTAINER_NAME" ip4=inherit ip6=inherit \
		mount.devfs devfs_ruleset=4 persist
	_JAIL_STARTED=true
}

# ── Phase 6: Run recipe ──────────────────────────────────────────────────

run_recipe() {
	local compose="${RECIPE_DIR}/compose.sh"
	local pkg_list="${RECIPE_DIR}/pkg.list"

	progress "Running recipe (pre_pkg)"
	if [ -f "$compose" ]; then
		run cp "$compose" "/containers/${CONTAINER_NAME}/tmp/_compose.sh"
		run jexec "$CONTAINER_NAME" sh -c '. /tmp/_compose.sh && pre_pkg'
	fi

	progress "Installing packages"
	if [ -f "$pkg_list" ] && [ -s "$pkg_list" ]; then
		run pkg -j "$CONTAINER_NAME" install -y $(cat "$pkg_list")
	fi

	progress "Running recipe (post_pkg)"
	if [ -f "$compose" ]; then
		run jexec "$CONTAINER_NAME" sh -c '. /tmp/_compose.sh && post_pkg'
		rm -f "/containers/${CONTAINER_NAME}/tmp/_compose.sh"
	fi
}

# ── Phase 7: Derivations ─────────────────────────────────────────────────

regen_derivations() {
	progress "Regenerating derivations"

	local fbsd_ver
	fbsd_ver=$(get_foundation_version "$FOUNDATION_NAME")
	local global_db
	global_db=$(resolve_derivations_db "$fbsd_ver") || \
		die "No derivations db found for FreeBSD ${fbsd_ver}"
	local local_db="${RECIPE_DIR}/derivations.local"

	# For inaugural, regenerate ALL derivations (not just changed ones)
	local src derived cmd
	for db in "$local_db" "$global_db"; do
		[ -f "$db" ] || continue
		while IFS='	' read -r src derived cmd; do
			[ -n "$src" ] || continue
			case "$src" in \#*) continue ;; esac
			if ! $DRY_RUN; then
				printf "  regen: %s → %s\n" "$src" "$derived" >&2
				jexec "$CONTAINER_NAME" sh -c "$cmd"
			else
				printf "  [dry] regen: %s → %s (%s)\n" "$src" "$derived" "$cmd" >&2
			fi
		done < "$db"
	done
}

# ── Phase 8: mtree ────────────────────────────────────────────────────────

gen_mtree() {
	progress "Generating mtree"
	local cpath="/containers/${CONTAINER_NAME}"
	local ignore="${PARASA_DIR}/etc/mtree.ignore"
	run generate_mtree "$cpath" "$RECIPE_DIR" "$ignore"
}

# ── Phase 9: Inaugural commit ────────────────────────────────────────────

inaugural_commit() {
	local cpath="/containers/${CONTAINER_NAME}"
	local dest="zbereshit/containers/${CONTAINER_NAME}"
	local foundation_git="/zbamidbar/foundation.git"

	progress "Committing inaugural"
	run zmount zbamidbar/foundation.git "$foundation_git"

	if ! $DRY_RUN; then
		# Clear schg before git can inspect/add files
		clear_mtree "$cpath"

		# .git as child dataset (excluded from future zfs sends)
		zfs create -o mountpoint="${cpath}/.git" -o canmount=on "${dest}/.git"
		git -C "$cpath" init -b main
		git -C "$cpath" remote add origin "$foundation_git"
		git -C "$cpath" fetch origin

		# Create branch from foundation commit
		git -C "$cpath" checkout -f -b "containers/${CONTAINER_NAME}" \
			"origin/${FOUNDATION_NAME}"

		# Append gitignore entries for foreign mounts outside standard paths
		local fstab="${RECIPE_DIR}/mount.fstab"
		if [ -f "$fstab" ]; then
			local src dest fstype relpath
			while IFS='	' read -r src dest fstype _; do
				[ -n "$src" ] || continue
				case "$src" in \#*) continue ;; esac
				# Skip standard data-lake datasets
				case "$src" in "zbamidbar/container-data/${CONTAINER_NAME}/"*) continue ;; esac
				# Convert absolute dest to path relative to container root
				relpath="${dest#${cpath}/}"
				# Skip if already covered by foundation .gitignore
				case "$relpath" in
					var|var/*|usr/local|usr/local/*|tmp|tmp/*|dev|dev/*) continue ;;
				esac
				# Append to .gitignore
				printf "%s/\n" "$relpath" >> "${cpath}/.gitignore"
			done < "$fstab"
		fi

		# Stage all changes from recipe replay
		git -C "$cpath" add -A
		git -C "$cpath" commit -m "containers/${CONTAINER_NAME} inaugural"
		git -C "$cpath" push origin "containers/${CONTAINER_NAME}"
	else
		printf "  [dry] git init + checkout -b containers/%s origin/%s + add -A + commit + push\n" \
			"$CONTAINER_NAME" "$FOUNDATION_NAME" >&2
	fi
}

# ── Container summary ────────────────────────────────────────────────────

print_summary() {
	local data_root="zbamidbar/container-data/${CONTAINER_NAME}"
	printf "\n" >&2
	printf "  Container:   %s\n" "$CONTAINER_NAME" >&2
	printf "  Foundation:  %s\n" "$FOUNDATION_NAME" >&2
	printf "  var:         %s/var (always)\n" "$data_root" >&2
	printf "  usr/local:   %s/usr-local (always)\n" "$data_root" >&2
	printf "  home:        %s\n" "$(yesish "$WANT_HOME" && echo "${data_root}/home" || echo "no")" >&2
	printf "  tmp:         %s\n" "$(yesish "$WANT_TMP" && echo "${data_root}/tmp" || echo "no")" >&2
	if [ -n "$USER_HOMES" ]; then
		printf "  user homes:  %s\n" "$USER_HOMES" >&2
	fi
	if [ -n "${FOREIGN_MOUNTS:-}" ]; then
		printf "  mounts:\n" >&2
		printf "%s\n" "$FOREIGN_MOUNTS" | while IFS='	' read -r src dest fstype; do
			printf "    %s → %s (%s)\n" "$src" "$dest" "$fstype" >&2
		done
	fi
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	root_only
	trap container_cleanup EXIT

	# Phase 1: Input — collect name, crawl recipes
	collect_container_name

	# Check deployment target is free
	zfs_dataset_exists "zbereshit/containers/${CONTAINER_NAME}" && \
		die "Container '${CONTAINER_NAME}' already deployed on zbereshit."

	if $USING_RECIPE; then
		RECIPE_DIR="${RECIPES_DIR}/containers/${CONTAINER_NAME}"
		collect_foundation
		parse_recipe_datasets
	else
		collect_foundation
		collect_container_options
	fi

	print_summary
	if [ "$QUIET" -eq 0 ]; then
		confirm "Proceed with container creation?" || exit 0
	fi

	# Phase 2: Recipe scaffold (new recipe only)
	if ! $USING_RECIPE; then
		create_recipe
	else
		RECIPE_DIR="${RECIPES_DIR}/containers/${CONTAINER_NAME}"
	fi

	# Phase 3: Send foundation to zbereshit
	send_foundation

	# Phase 4: Clone foundation to container
	clone_to_container

	# Phase 5: Data datasets + mount + start jail
	create_data_datasets

	# Create any foreign datasets (after data-lake parent exists)
	ensure_foreign_datasets
	mount_and_start

	# Phase 6: Run recipe
	run_recipe

	# Phase 7: Derivations
	regen_derivations

	# Phase 8: mtree
	gen_mtree

	# Phase 9: Inaugural commit
	inaugural_commit

	# Done — stop jail, tear down creation-time mounts so jail -f can remount
	progress "Stopping jail"
	run jail -r "$CONTAINER_NAME"
	_JAIL_STARTED=""
	_CLONE_CREATED=""
	trap - EXIT

	# Unmount everything under the container path (reverse order)
	local cpath="/containers/${CONTAINER_NAME}"
	if ! $DRY_RUN; then
		mount -p | awk -v prefix="$cpath/" '$2 == prefix || substr($2,1,length(prefix)) == prefix {print $2}' | \
			sort -r | while read -r mnt; do
			umount "$mnt" 2>/dev/null || umount -f "$mnt" 2>/dev/null || true
		done
	fi
	# Reset data dataset mountpoints to none
	local data_root="zbamidbar/container-data/${CONTAINER_NAME}"
	if ! $DRY_RUN && zfs_dataset_exists "$data_root"; then
		zfs list -r -H -o name "$data_root" 2>/dev/null | while read -r ds; do
			zfs set mountpoint=none "$ds" 2>/dev/null || true
		done
	fi

	# Cleanup parasa mounts
	run zunmount zbamidbar/foundation.git
	run zunmount zbamidbar/foundation.zfs

	progress "Container '${CONTAINER_NAME}' created successfully."
	printf "  Foundation: %s\n" "$FOUNDATION_NAME" >&2
	printf "  Artifact:   %s\n" "$ARTIFACT_NAME" >&2
	printf "  Recipe:     %s\n" "$RECIPE_DIR" >&2
	printf "  Branch:     containers/%s\n" "$CONTAINER_NAME" >&2
	printf "  Root:       /containers/%s\n" "$CONTAINER_NAME" >&2

	if [ "$QUIET" -eq 0 ] && [ -t 0 ]; then
		if confirm "Start jail ${CONTAINER_NAME} now?"; then
			exec jail -f "${RECIPES_DIR}/jail.conf" -c "$CONTAINER_NAME"
		else
			printf "Start with: jail -f %s -c %s\n" "${RECIPES_DIR}/jail.conf" "$CONTAINER_NAME" >&2
		fi
	else
		printf "\nStart with: jail -f %s -c %s\n" "${RECIPES_DIR}/jail.conf" "$CONTAINER_NAME" >&2
	fi
}

main
