#!/bin/sh
error() {
	set -- "ERROR: $1" "${@:2}"
	printf "$@" >&2
	return 1
}

root-only() {
	# Ensure the script is being run as root
	if [ "$(id -u)" -ne 0 ]; then
		error "This script must be run as root.\n" || return
	fi
}

confirm() {
	local PROMPT="${1:-Are you sure?}"
	local RESPONSE="${2:-}"

	while true; do
		# Use printf for the prompt to keep the cursor on the same line
		printf "${PROMPT} [Y/n]: " 

		# Read user input from standard input
		if [ -z "${RESPONSE}" ]; then
			if ! read -r RESPONSE; then
				# If read fails (e.g., Ctrl+D/EOF), assume 'no' and exit loop
				echo ""
				return 1
			fi
		else
			echo "${RESPONSE}"
		fi

		if yesish "${RESPONSE}"; then
			return 0
		elif noish "${RESPONSE}"; then
			return 1
		else
			error "Invalid input '%s'. Please enter y or n.\n" "${RESPONSE}" || true
			RESPONSE=""
		fi
    done
}

yesish() {
	case "$1" in
		[Yy][Ee][Ss]|[Yy]|[Tt][Rr][Uu][Ee]|1|"") return 0 ;;
		*) return 1 ;;
	esac
}

noish() {
	case "$1" in
		[Nn][Oo]|[Nn]|0|[Ff][Aa][Ll][Ss][Ee]) return 0 ;;
		*) return 1 ;;
	esac
}

zmount() {
	local DATASET="${1:-}"
	[ -n "${DATASET}" ] || error "No dataset to zmount\n" || return
	local DEST="${2:-}"
	if [ -z "${DEST}" ]; then
		DEST="/${DATASET}"
	fi
	zfs set mountpoint="${DEST}" ${DATASET}
}

zunmount() {
	local DATASET="${1:-}"
	[ -n "${DATASET}" ] || error "No dataset to zunmount\n" || return
	sync
	zfs unmount ${DATASET}
	zfs set mountpoint=none ${DATASET}
}

# Use `-R` to remove the flag options time, nlink, and flags
# because git clobbers hardlinks and I can't ever fix that,
# so why cache it, flags are used by zfs to let us know there's
# a snapshot and we can't control that on the git-clone side,
# and because time modified is not something I care about tracking.
# User -x to not descend below mountpoints. Use `-K` to add the
# sha512 hash to the file to determine file integrity. Finally,
# use `-c` to print a config.

# TODO: hardlinks
generate-mtree() {
	local TREE_PATH="${1:-}"
	local MTREE_IGNORE_FILE="${2:-}"
	[ -n "${TREE_PATH}" ] || error "no path for mtree to scan provided\n" || return
	[ -d "${TREE_PATH}/etc/mtree" ] || {
		error "no etc/mtree directory within ${TREE_PATH}\n" || return
	}
	[ -f "${MTREE_IGNORE_FILE}" ] || {
		confirm "WARNING: .mtreeignore '%s' does not exist. Continue?" "${MTREE_IGNORE_FILE}" || return
	}
	mtree -c -x -R time,nlink,flags -K sha512 -p "${TREE_PATH}" \
		-X "${MTREE_IGNORE_FILE}" > "${TREE_PATH}/etc/mtree/sinai.dist"
}

# TODO: hardlinks
apply-mtree() {
	local TREE_PATH="${1:-}"
	if [ "${TREE_PATH}" = "-h" ]; then
		echo "apply-mtree [tree-path]"
	fi
	[ -d "${TREE_PATH}" ] || error "no path for mtree to scan provided\n" || return
	local MTREE_FILE_PATH="${TREE_PATH}/etc/mtree/sinai.dist"
	[ -f "${MTREE_FILE_PATH}" ] || {
		error "mtree file: '%s' does not exist. Cannot apply.\n" "${MTREE_FILE_PATH}" || return
	}
	# `-i` == set schg etc bits
	# `-u` == update
	# || true == Duh, the spec is not going to match, that's why we run this
	mtree -f "${MTREE_FILE_PATH}" -iu -p "${TREE_PATH}" || true
}

clear-mtree() {
	local TREE_PATH="${1:-}"
	[ -d "${TREE_PATH}" ] || error "Dir: '%s' does not exist\n" "${TREE_PATH}" || return
	chflags -R noschg "${TREE_PATH}"
}

get-artifact-name() {
	local REPO="${1:-}"
	[ -d "${REPO}/.git" ] || error "${REPO} doesn't look like a git repo\n" || return
	local ARTIFACT_NAME="$(git -C "${REPO}" rev-parse --abbrev-ref HEAD)"
	ARTIFACT_NAME="${ARTIFACT_NAME}-$(date -I)"
	ARTIFACT_NAME="${ARTIFACT_NAME}-$(git -C "${REPO}" rev-parse --short HEAD)"
	echo "${ARTIFACT_NAME}"
}

# get-current-artifact() {
#	local dataset="${1:-}"
#	[ -n "${dataset}" ] || error "no dataset provided"
#	if ! zfs get name "${dataset}" > /dev/null 2>&1; then
#		error "dataset: ${dataset} does not exist\n"
#		return 1
#	fi
# 	snapshot=$(zfs list -H -t snapshot -r "${dataset}" -o name -S creation -d 1 \
# 	| head -n 1 | cut -d '@' -f 2)
# 	[ -n "${snapshot}" ] || {
# 		error "dataset has no snapshots\n"
# 		return "MISSINGNO"
# 	}
# 	# TODO: test if there's written since snapshot
# 	# zfs get -o written "${dataset}"
# 	echo "${snapshot}"
# }

# TODO: de-AI-weirdness this function
ignore-but-keep-torah() {
	local REPO="${1:-}"
	[ -d "${REPO}/.git" ] || error "${REPO} doesn't look like a git repo\n" || return
	local GIT_IGNORE_FILE="${REPO}/.gitignore"
	local TORAH_IGNORE_FILE="${2:-}"
	while read -r _location || [ -n "${_location}" ]; do
		local FULL_PATH="${REPO}/${_location}"

		# If a file exists AND a directory exists with the same name
		if [ -f "${FULL_PATH}" ] && [ -d "${FULL_PATH}" ]; then
			printf "Notice: Collision detected. Both file and directory named '%s' exist.\n" "${_location}"
			printf "        Applying negation rule '!%s/' to .gitignore to protect the directory.\n" "${_location}"

			if ! grep -qxF "!${_location}/" "${GIT_IGNORE_FILE}" 2>/dev/null; then
				printf "!%s/\n" "${_location}" >> "${GIT_IGNORE_FILE}"
			fi
    			# We do NOT auto-fix the slash here because we want to target the FILE specifically
		
		# If no collision, check if it's a directory missing a slash
		elif [ -d "${FULL_PATH}" ]; then
			case "${_location}" in
				*/) ;; # Already has a slash, do nothing
				*) 
					printf "Auto-fixing: Adding trailing slash to directory '%s' for .gitignore consistency.\n" "${_location}"
					_location="${_location}/" 
					;;
			esac
		fi

		# -q: quiet, -x: exact, -F: fixed string
		if ! grep -qxF "${_location}" "${GIT_IGNORE_FILE}" 2>/dev/null; then
			[ -f "${GIT_IGNORE_FILE}" ] && [ -n "$(tail -c 1 "${GIT_IGNORE_FILE}" 2>/dev/null)" ] && printf "\n" >> "${GIT_IGNORE_FILE}"
			printf "%s\n" "${_location}" >> "${GIT_IGNORE_FILE}"
			echo "Excluding ${_location}..."
		fi

		if [ -e "${FULL_PATH}" ]; then
			(
				cd "${REPO}" || exit 1
				git add -f "${_location}"
				echo "Tracking existing files therein..."
			)
		fi
	done < "${TORAH_IGNORE_FILE}"
}

sysgit() {
	mount -p | awk '$2 != "/" { print $2 "/" }' > /.git/info/exclude
	git "$@"
}

clone-sinai() {
	BRANCH_NAME="${1:-trunk}"
	TREE="${2:-.}"
	zmount zshemot/sinai
	(
		cd "${TREE}"
		git init
		# TODO: ssh sinai so jails can hit it
		git remote add origin /zshemot/sinai
		git fetch
		git reset --hard "origin/${BRANCH_NAME}"
	)
	zunmount zshemot/sinai
}
