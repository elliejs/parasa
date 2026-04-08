#! /bin/bash
set -euo pipefail

MISHKAN_SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
. "${MISHKAN_SCRIPT_DIR}/helpers.sh"

zfs set mountpoint=/zshemot/sinai zshemot/sinai
cd /zshemot/sinai

local TRUNK="trunk"
git for-each-ref --format='%(refname:short)' refs/heads/ \
| grep -v "^${TRUNK}$" \
| while read -r branch; do
	echo "-> Rebasing ${branch} onto ${TRUNK}"
	git checkout "${branch}"
	# WARN: mtree collision?
	git rebase "${TRUNK}"
done  
# Return to trunk when done 
git checkout "${TRUNK}"

cd --
zfs set mountpoint=none zshemot/sinai
