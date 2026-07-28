#!/bin/sh
# workspace.sh -- shared workspace lifecycle for system and container creation.
# Source this file after helpers.sh; do not execute it directly.
#
# Required variables (set by caller before sourcing):
#   PARASA_DIR       repo root
#   SCRIPT_DIR       scripts directory
#
# Required variables (set by caller before calling ws_ functions):
#   WS_NAME          workspace name (system or container name)
#   WS_KIND          "system" or "container"
#   WS_DATA_POOL     "system-data" or "container-data"
#   FOUNDATION_NAME  foundation this workspace is based on
#   DRY_RUN          true/false
#   QUIET            0/1/2
#
# Variables set by workspace functions (available to caller after call):
#   WS_RECIPE_DIR        full path to recipes/${WS_KIND}s/$WS_NAME
#   WS_DATA_ROOT     zbamidbar/$WS_DATA_POOL/$WS_NAME
#   WS_PATH          /zshemot/buildspace/$WS_NAME (workspace mount path)

# ── Dry-run wrapper ──────────────────────────────────────────────────────────

run() {
	if $DRY_RUN; then
		printf "  [dry] %s\n" "$*" >&2
	else
		"$@"
	fi
}

# ── Progress output ──────────────────────────────────────────────────────────

progress() {
	[ "$QUIET" -lt 2 ] && printf "\n==> %s\n" "$1" >&2
	return 0
}

# ── Cleanup trap ─────────────────────────────────────────────────────────────

ws_cleanup() {
	if [ -n "${WS_NAME:-}" ] && zfs_dataset_exists "zshemot/buildspace/${WS_NAME}"; then
		printf "Cleaning up transient zshemot/buildspace/%s workspace...\n" "$WS_NAME" >&2
		zfs destroy -r "zshemot/buildspace/${WS_NAME}" 2>/dev/null || true
	fi
}

# ── Phase 1: Input ───────────────────────────────────────────────────────────

# Validate or interactively prompt for a workspace name.
# $1 = current name value (may be empty)
# $2 = label ("System" or "Container")
# Prints validated name to stdout.
collect_name() {
	local current="$1" label="$2"
	if [ -n "$current" ]; then
		validate_name "$current" "$label name" || exit 1
		printf "%s" "$current"
		return
	fi
	if [ "$QUIET" -gt 0 ]; then
		die "${label} name required in quiet mode (-s NAME)."
	fi
	local resp
	while true; do
		printf "%s name: " "$label" >&2
		read -r resp || die "EOF reading ${label} name"
		if validate_name "$resp" "$label name"; then
			printf "%s" "$resp"
			return
		fi
	done
}

# Verify no recipes dir or zbereshit dataset exists for this name.
check_available() {
	local label
	case "$WS_KIND" in
		system)    label="System" ;;
		container) label="Container" ;;
		*)         label="$WS_KIND" ;;
	esac
	local recipes="${PARASA_DIR}/recipes/${WS_KIND}s/${WS_NAME}"
	if [ -d "$recipes" ]; then
		die "${label} '${WS_NAME}' already exists in recipes. Use destroy_${WS_KIND} (future) or pick a new name."
	fi
	if zfs_dataset_exists "zbereshit/${WS_KIND}s/${WS_NAME}"; then
		die "${label} '${WS_NAME}' already deployed on zbereshit."
	fi
}

# Validate or prompt for foundation name.
# Sets FOUNDATION_NAME.
collect_foundation() {
	if [ -n "$FOUNDATION_NAME" ]; then
		local frecipes="${PARASA_DIR}/recipes/foundations/${FOUNDATION_NAME}"
		[ -d "$frecipes" ] || die "Foundation '${FOUNDATION_NAME}' not found in recipes."
		zfs_dataset_exists "zbamidbar/foundation.zfs/foundations/${FOUNDATION_NAME}" || \
			die "Foundation '${FOUNDATION_NAME}' not archived in zbamidbar/foundation.zfs."
		return
	fi
	FOUNDATION_NAME=$(select_foundation "$QUIET")
}

# Prompt for common dataset options.
# Sets: WANT_HOME, WANT_TMP, USER_HOMES, CUSTOM_MOUNTS
# Does NOT handle WANT_ROOTHOME (system-specific) or format mount lines.
# Reads: OPT_HOME, OPT_TMP, OPT_USER_HOMES, OPT_MOUNT_MAP, QUIET
collect_build_options() {
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
}

# ── Phase 2: Setup ───────────────────────────────────────────────────────────

# Create the recipes dir with the five common boilerplate files.
# Sets WS_RECIPE_DIR.
create_recipe_boilerplate() {
	WS_RECIPE_DIR="${PARASA_DIR}/recipes/${WS_KIND}s/${WS_NAME}"

	progress "Creating recipes dir: ${WS_RECIPE_DIR}"
	run mkdir -p "$WS_RECIPE_DIR"

	if ! $DRY_RUN; then
		: > "${WS_RECIPE_DIR}/${FOUNDATION_NAME}.foundation"  # artifact written by ws_begin
		cat > "${WS_RECIPE_DIR}/compose.sh" <<'COMPOSE'
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
		: > "${WS_RECIPE_DIR}/derivations.local"
		: > "${WS_RECIPE_DIR}/pkg.list"
		: > "${WS_RECIPE_DIR}/mtree.dist"
	else
		printf "  [dry] create %s/{%s.foundation,compose.sh,derivations.local,pkg.list,mtree.dist}\n" \
			"$WS_RECIPE_DIR" "$FOUNDATION_NAME" >&2
	fi
}

# Create data datasets on zbamidbar.
# Creates: parent, var (copied from foundation), usr-local, optional home/tmp/roothome,
# and per-user home datasets.
# Sets WS_DATA_ROOT.
create_data_datasets() {
	WS_DATA_ROOT="zbamidbar/${WS_DATA_POOL}/${WS_NAME}"
	local foundation_var="zbamidbar/foundation.zfs/foundations/${FOUNDATION_NAME}/var"

	progress "Creating data datasets"

	run ztouch "$WS_DATA_ROOT" -o mountpoint=none -o canmount=noauto

	# var: copy pristine var from foundation
	progress "Copying pristine var from foundation"
	run zmount zbamidbar/foundation.zfs /zbamidbar/foundation.zfs
	if ! $DRY_RUN; then
		local snap
		snap=$(get_current_artifact "$foundation_var")
		if [ -n "$snap" ]; then
			zfs send "${foundation_var}@${snap}" | \
				zfs recv -o mountpoint=none -o canmount=noauto "${WS_DATA_ROOT}/var"
		else
			ztouch "${WS_DATA_ROOT}/var" -o mountpoint=none -o canmount=noauto
		fi
	else
		printf "  [dry] zfs send %s@<snap> | zfs recv %s/var\n" \
			"$foundation_var" "$WS_DATA_ROOT" >&2
	fi

	# usr-local: always created
	run ztouch "${WS_DATA_ROOT}/usr-local" -o mountpoint=none -o canmount=noauto

	# Optional datasets
	if yesish "$WANT_HOME"; then
		run ztouch "${WS_DATA_ROOT}/home" -o mountpoint=none -o canmount=noauto
	fi
	if yesish "$WANT_TMP"; then
		run ztouch "${WS_DATA_ROOT}/tmp" -o mountpoint=none -o canmount=noauto
	fi
	if yesish "${WANT_ROOTHOME:-no}"; then
		run ztouch "${WS_DATA_ROOT}/home/root" -o mountpoint=none -o canmount=noauto
	fi

	# User home datasets
	if [ -n "$USER_HOMES" ]; then
		local old_ifs="$IFS" user
		IFS=','
		for user in $USER_HOMES; do
			IFS="$old_ifs"
			user=$(printf "%s" "$user" | tr -d '[:space:]')
			[ -n "$user" ] || continue
			run ztouch "${WS_DATA_ROOT}/home/${user}" -o mountpoint=none -o canmount=noauto
		done
		IFS="$old_ifs"
	fi
}

# ── Phase 3: Inaugural commit lifecycle ──────────────────────────────────────

# Set up the transient workspace for the inaugural commit.
# Mounts foundation.git/foundation.zfs, recvs foundation to buildspace, sets up git branch.
# Sets WS_PATH.
ws_begin() {
	local foundation_git="/zbamidbar/foundation.git"
	local foundation_archive="zbamidbar/foundation.zfs/foundations/${FOUNDATION_NAME}"
	WS_PATH="/zshemot/buildspace/${WS_NAME}"

	progress "Creating inaugural commit"

	run zmount zbamidbar/foundation.git "$foundation_git"
	run zmount zbamidbar/foundation.zfs /zbamidbar/foundation.zfs

	# Ensure buildspace parent dataset exists
	run ztouch zshemot/buildspace -o mountpoint=none -o canmount=noauto

	# Destroy any leftover workspace
	if zfs_dataset_exists "zshemot/buildspace/${WS_NAME}"; then
		run zfs destroy -r "zshemot/buildspace/${WS_NAME}"
	fi

	# Recv foundation to workspace
	progress "Receiving foundation to workspace"
	if ! $DRY_RUN; then
		local snap
		snap=$(get_current_artifact "$foundation_archive")
		[ -n "$snap" ] || die "No snapshots found on ${foundation_archive}"
		zfs send -R "${foundation_archive}@${snap}" | \
			zfs recv -o mountpoint="/zshemot/buildspace/${WS_NAME}" -o canmount=on \
				"zshemot/buildspace/${WS_NAME}"
		zfs mount "zshemot/buildspace/${WS_NAME}" 2>/dev/null || true
		zfs mount "zshemot/buildspace/${WS_NAME}/var" 2>/dev/null || true
		# Record artifact name in .foundation file
		printf "%s\n" "$snap" > "${WS_RECIPE_DIR}/${FOUNDATION_NAME}.foundation"
	else
		printf "  [dry] zfs send -R %s@<snap> | zfs recv zshemot/buildspace/%s\n" \
			"$foundation_archive" "$WS_NAME" >&2
	fi

	# Git setup
	progress "Setting up ${WS_KIND} branch"
	if ! $DRY_RUN; then
		local current_remote
		current_remote=$(git -C "$WS_PATH" config remote.origin.url 2>/dev/null || echo "")
		if [ "$current_remote" != "$foundation_git" ]; then
			git -C "$WS_PATH" remote set-url origin "$foundation_git" 2>/dev/null || \
				git -C "$WS_PATH" remote add origin "$foundation_git"
		fi
		git -C "$WS_PATH" fetch origin

		git -C "$WS_PATH" checkout -b "${WS_KIND}s/${WS_NAME}" \
			"${FOUNDATION_NAME}"
	else
		printf "  [dry] git -C %s checkout -b %ss/%s %s\n" \
			"$WS_PATH" "$WS_KIND" "$WS_NAME" "$FOUNDATION_NAME" >&2
	fi
}

# Commit and push the inaugural branch.
# Extra args (e.g. --allow-empty) are passed to git commit before -m.
ws_commit() {
	progress "Committing inaugural"
	run git -C "$WS_PATH" commit "$@" -m "${WS_KIND}s/${WS_NAME} inaugural"
	run git -C "$WS_PATH" push origin "${WS_KIND}s/${WS_NAME}"
}

# Destroy the transient workspace and unmount working datasets.
ws_end() {
	progress "Destroying workspace"
	if [ -d "$WS_PATH" ] && ! $DRY_RUN; then
		clear_mtree "$WS_PATH"
	fi
	if zfs_dataset_exists "zshemot/buildspace/${WS_NAME}"; then
		run zfs destroy -r "zshemot/buildspace/${WS_NAME}"
	fi

	run zunmount zbamidbar/foundation.git
	run zunmount zbamidbar/foundation.zfs
}
