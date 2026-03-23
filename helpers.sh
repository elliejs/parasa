#! /bin/bash
set -euo pipefail

function error() {
	printf "$@" >&2
	return 1
}

# Use `-R` to remove the flag options time, nlink, and flags
# because git clobbers hardlinks and I can't ever fix that,
# so why cache it, flags are used by zfs to let us know there's
# a snapshot and we can't control that on the git-clone side,
# and because time modified is not something I care about tracking.
# Use `-K` to add the sha512 hash to the file to determine file
# integrity. Finally, use `-c` to print a config.

# TODO: hardlinks
function generate-mtree() {
	local TREE="${1:-}"
	[[ -n "${TREE}" ]] || error "no dir for mtree provided\n";
	[[ -d "${TREE}/etc" ]] || error "no etc/ directory within ${TREE}\n";
	mtree -c -R time,nlink,flags -K sha512 -p "${TREE}" \
	> "${TREE}/etc/mtree"
}

# TODO: hardlinks
function apply-mtree() {
	local TREE="${1:-}"
	[[ -n "${TREE}" ]] || error "no dir for mtree provided\n";
	[[ -f "${TREE}/etc/mtree" ]] || error "no etc/mtree file within ${TREE}\n";
	# `-i` == set schg etc bits
	# `-u` == update
	mtree -f "${TREE}/etc/mtree" -iu -p "${TREE}" 
}

function clear-mtree() {
	local TREE="${1:-}"
	[[ -n "${TREE}" ]] || error "no dir for mtree provided\n";

	chflags -R noschg "${TREE}"
}

function get-artifact-name() {
	local ARTIFACT_NAME="$(git rev-parse --abbrev-ref HEAD)"
	ARTIFACT_NAME+="-$(git rev-parse --short HEAD)"
	ARTIFACT_NAME+="-$(date -I)"
	echo "${ARTIFACT_NAME}"
}

function get-current-artifact() {
	local dataset="${1:-}"
	[[ -n "${dataset}" ]] || error "no dataset provided"
	if ! zfs get name "${dataset}" > /dev/null 2>&1; then
		error "dataset: ${dataset} does not exist\n"
		return 1
	fi
	snapshot=$(zfs list -H -t snapshot -r "${dataset}" -o name -S creation -d 1 \
	| head -n 1 | cut -d '@' -f 2)
	[[ -n "${snapshot}" ]] || {
		error "dataset has no snapshots\n"
		return "MISSINGNO"
	}
	# TODO: test if there's written since snapshot
	# zfs get -o written "${dataset}"
	echo "${snapshot}"
}

