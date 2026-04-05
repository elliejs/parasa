#! /bin/bash
set -euo pipefail

error() {
	printf "$@" >&2
	return 1
}

zmount() {
	local DATASET="${1:-}"
	local DEST="${2:-}"
	if [ -z "${DEST}" ]; then
		DEST="/${DATASET}"
	fi
	zfs set mountpoint="${DEST}" ${DATASET}
}

zunmount() {
	local DATASET="${1:-}"
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
	local IGNOREFILE="${2:-}"
	[ -n "${TREE}" ] || error "no dir for mtree provided\n";
	[ -d "${TREE}/etc/mtree" ] || error "no etc/mtree directory within ${TREE}\n";
	[ -f "${IGNOREFILE}" ] || echo "${IGNOREFILE} not supplied or does not exist. I hope this is what you wanted";
	mtree -c -x -R time,nlink,flags -K sha512 -p "${TREE}" -X "${IGNOREFILE}" > "${TREE}/etc/mtree/sinai.dist"
}

# TODO: hardlinks
# TODO: SINAI hardcode is mixing metaphors
apply-mtree() {
	local TREE="${1:-}"
	[ -n "${TREE}" ] || error "no dir for mtree provided\n";
	[ -d "${TREE}/etc/mtree" ] || error "no etc/mtree directory within ${TREE}\n";
	# `-i` == set schg etc bits
	# `-u` == update
	mtree -f "${TREE}/etc/mtree/sinai.dist" -iu -p "${TREE}" 
}

clear-mtree() {
	local TREE="${1:-}"
	[ -n "${TREE}" ] || error "no dir for mtree provided\n";
	[ -d "${TREE}/etc/mtree" ] || error "${TREE} does not exist\n";
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

get-current-artifact() {
	local dataset="${1:-}"
	[ -n "${dataset}" ] || error "no dataset provided"
	if ! zfs get name "${dataset}" > /dev/null 2>&1; then
		error "dataset: ${dataset} does not exist\n"
		return 1
	fi
	snapshot=$(zfs list -H -t snapshot -r "${dataset}" -o name -S creation -d 1 \
	| head -n 1 | cut -d '@' -f 2)
	[ -n "${snapshot}" ] || {
		error "dataset has no snapshots\n"
		return "MISSINGNO"
	}
	# TODO: test if there's written since snapshot
	# zfs get -o written "${dataset}"
	echo "${snapshot}"
}

sysgit() {
	mount -p | awk '$2 != "/" { print $2 "/" }' > /.git/info/exclude
	git "$@"
}
