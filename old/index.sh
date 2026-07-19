. "${PARASA_SCRIPT_DIR}/helpers.sh"

stage1-build-upgrade() {
	sh "${PARASA_SCRIPT_DIR}/stage1-build-upgrade.sh" "$@"
}

stage2-rebase-containers() {
	sh "${PARASA_SCRIPT_DIR}/stage2-rebase-containers.sh" "$@"
}

stage3-reflash-system() {
	sh "${PARASA_SCRIPT_DIR}/stage3-reflash-system.sh" "$@"
}

composer0-appropriate() {
	sh "${PARASA_SCRIPT_DIR}/composer/0-appropriate.sh" "$@"
}

composer1-run-compose() {
	sh "${PARASA_SCRIPT_DIR}/composer/1-run-composition.sh" "$@"
}

