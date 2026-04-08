. "${MISHKAN_SCRIPT_DIR}/helpers.sh"

stage1-build-upgrade() {
	sh "${MISHKAN_SCRIPT_DIR}/stage1-build-upgrade.sh" "$@"
}

stage2-rebase-containers() {
	sh "${MISHKAN_SCRIPT_DIR}/stage2-rebase-containers.sh" "$@"
}

stage3-reflash-system() {
	sh "${MISHKAN_SCRIPT_DIR}/stage3-reflash-system.sh" "$@"
}
