#! /bin/bash
set -euo pipefail

PARASA_SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
. "${PARASA_SCRIPT_DIR}/helpers.sh"

zmount zshemot/sinai
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
zunmount zshemot/sinai
