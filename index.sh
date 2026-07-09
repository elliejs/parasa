#!/bin/sh
# index.sh -- Source this file to make mishkan commands available.
#
# Usage: . /zshemot/mishkan/index.sh
#    or: . /path/to/project-mishkan/index.sh
#
# Provides wrapper functions that call the actual scripts in scripts/.

MISHKAN_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

. "${MISHKAN_DIR}/scripts/helpers.sh"

mishkan_bootstrap() {
	sh "${MISHKAN_DIR}/scripts/stage0-bootstrap.sh" "$@"
}

mishkan_new_foundation() {
	sh "${MISHKAN_DIR}/scripts/new_foundation.sh" "$@"
}

mishkan_new_system() {
	sh "${MISHKAN_DIR}/scripts/new_system.sh" "$@"
}

mishkan_new_container() {
	sh "${MISHKAN_DIR}/scripts/new_container.sh" "$@"
}

mishkan_deploy_system() {
	sh "${MISHKAN_DIR}/scripts/deploy_system.sh" "$@"
}
