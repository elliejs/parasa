#!/bin/sh
# index.sh -- Source this file to make parasa commands available.
#
# Usage: . /zshemot/parasa/index.sh
#    or: . /path/to/project-parasa/index.sh
#
# Provides wrapper functions that call the actual scripts in scripts/.

PARASA_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

. "${PARASA_DIR}/scripts/helpers.sh"

parasa_bootstrap() {
	sh "${PARASA_DIR}/scripts/stage0-bootstrap.sh" "$@"
}

parasa_new_foundation() {
	sh "${PARASA_DIR}/scripts/new_foundation.sh" "$@"
}

parasa_new_system() {
	sh "${PARASA_DIR}/scripts/new_system.sh" "$@"
}

parasa_new_container() {
	sh "${PARASA_DIR}/scripts/new_container.sh" "$@"
}

parasa_deploy_system() {
	sh "${PARASA_DIR}/scripts/deploy_system.sh" "$@"
}
