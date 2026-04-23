#!/bin/sh

set -eu

. /home/miri/project-mishkan/helpers.sh

REPO_ROOT="$(git rev-parse --show-toplevel)/"
root-only
zmount zshemot/minhagim
generate-mtree "${REPO_ROOT}" /zshemot/minhagim/sinai.mtreeignore

git add "${REPO_ROOT}/etc/mtree/sinai.dist"
zunmount zshemot/minhagim
