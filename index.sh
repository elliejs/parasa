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

parasa_deploy_container() {
	sh "${PARASA_DIR}/scripts/deploy_container.sh" "$@"
}

parasa_diff() {
	sh "${PARASA_DIR}/scripts/diff.sh" "$@"
}

parasa_save() {
	sh "${PARASA_DIR}/scripts/save.sh" "$@"
}

parasa_update() {
	sh "${PARASA_DIR}/scripts/update.sh" "$@"
}

parasa_finalize_update() {
	sh "${PARASA_DIR}/scripts/finalize_update.sh" "$@"
}

parasa_doctor() {
	sh "${PARASA_DIR}/scripts/doctor.sh" "$@"
}

parasa() {
	sh "${PARASA_DIR}/scripts/menu.sh" "$@"
}
