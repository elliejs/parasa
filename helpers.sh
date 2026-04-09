#!/bin/sh
error() {
	printf "$@" >&2
	return 1
}

root-only() {
	# Ensure the script is being run as root
	if [ "$(id -u)" -ne 0 ]; then
		echo "Error: This script must be run as root." >&2
		exit 1
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
			printf "Invalid input '%s'. Please enter y or n.\n" "${RESPONSE}" >&2
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
	[ -n "${DATASET}" ] || {
		echo "no dataset to zmount"
		return
	}
	local DEST="${2:-}"
	if [ -z "${DEST}" ]; then
		DEST="/${DATASET}"
	fi
	zfs set mountpoint="${DEST}" ${DATASET}
}

zunmount() {
	local DATASET="${1:-}"
	[ -n "${DATASET}" ] || {
		echo "no dataset to zunmount"
		return
	}
	sync
	zfs unmount ${DATASET}
	zfs set mountpoint=none ${DATASET}
}

# Use `-R` to remove the flag options time, nlink, and flags
# because git clobbers hardlinks and I can't ever fix that,
# so why cache it, flags are used by zfs to let us know there's
# a snapshot and we can't control that on the git-clone side,
# and because time modified is not something I care about tracking.
# Use `-K` to add the sha512 hash to the file to determine file
# integrity. Finally, use `-c` to print a config.

# TODO: hardlinks
# TODO: SINAI hardcode is mixing metaphors
generate-mtree() {
	local TREE="${1:-}"
	local GIT_IGNORE_FILE="${2:-}"
	[ -n "${TREE}" ] || error "no dir for mtree provided\n";
	[ -d "${TREE}/etc/mtree" ] || error "no etc/mtree directory within ${TREE}\n";
	[ -f "${GIT_IGNORE_FILE}" ] || echo "${GIT_IGNORE_FILE} not supplied or does not exist. I hope this is what you wanted";
	mtree -c -x -R time,nlink,flags -K sha512 -p "${TREE}" -X "${GIT_IGNORE_FILE}" > "${TREE}/etc/mtree/sinai.dist"
}

# TODO: hardlinks
# TODO: SINAI hardcode is mixing metaphors
apply-mtree() {
	local TREE="${1:-}"
	[ -n "${TREE}" ] || error "no dir for mtree provided\n";
	[ -d "${TREE}/etc/mtree" ] || error "no etc/mtree directory within ${TREE}\n";
	# `-i` == set schg etc bits
	# `-u` == update
	# Duh, the spec is not going to match, that's why we run this?
	mtree -f "${TREE}/etc/mtree/sinai.dist" -iu -p "${TREE}" || true
}

clear-mtree() {
	local TREE="${1:-}"
	[ -n "${TREE}" ] || error "no dir for mtree provided\n";
	chflags -R noschg "${TREE}"
}

get-artifact-name() {
	local REPO="${1:-}"
	[ -d "${REPO}/.git" ] || error "${REPO} doesn't look like a git repo\n";
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

ignore-but-keep-torah() {
	local REPO="${1:-}"
	[ -d "${REPO}/.git" ] || error "${REPO} doesn't look like a git repo\n";
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
