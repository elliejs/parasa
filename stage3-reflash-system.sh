#! /bin/bash
set -euo pipefail

MISHKAN_SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
. "${MISHKAN_SCRIPT_DIR}/helpers.sh"

root-only

cleanup() {
	cd /
	zpool destroy zannanim
	mdconfig -du "${MD_DEV}"
	zunmount zshemot/minhagim || true
	zunmount zshemot/sinai || true
	zunmount zshemot/torah || true
	cd --
}
# trap cleanup EXIT

SYSTEM_NAME="${1:-}"
if [ -z "${SYSTEM_NAME}" ]; then
	error "No system name provided\n" || exit
fi

confirm "Jumping to zannanim"
# Step 1: Jump to a ramdrive
MD_DEV=$(mdconfig -a -t swap -s 12g)
zpool create zannanim "${MD_DEV}"
zfs create zannanim/akeida

zmount zshemot/sinai
confirm "Cloning zshemot/sinai to zannanim/akeida"
git clone /zshemot/sinai /zannanim/akeida

cd /zannanim/akeida
confirm "Checking out branch systems/${SYSTEM_NAME}"
git switch "systems/${SYSTEM_NAME}"
zunmount zshemot/sinai
confirm "Applying mtree"
apply-mtree .
cd --

confirm "Created zannanim, setting kenv and mountpoints"
kenv vfs.root.mountfrom='zfs:zannanim/akeida'
zfs set -u mountpoint=/ zannanim/akeida
SYSTEM_DATASET="zbereshit/systems/${SYSTEM_NAME}"
zfs set -u mountpoint="/${SYSTEM}" "${SYSTEM}"

reboot_msg="Reboot?\n"
reboot_msg="${reboot_msg}\tvfs.root.mountfrom=$(kenv vfs.root.mountfrom)\n"
reboot_msg="${reboot_msg}\tzannanim mountpoint:$(zfs get mountpoint zannanim/akeida)\n"
reboot_msg="${reboot_msg}\t${SYSTEM_DATASET} mountpoint:$(zfs get mountpoint ${SYSTEM_DATASET})\n"
confirm "${reboot_msg}"
reboot -r
# TODO: how do we get back here?

# TODO: zunmount the rest of zbereshit so they don't mount on top of zannanim

# Step 2: fast-forward zbereshit/system
# TODO: Warn if last looks like new (commit-hash)
cd "/${SYSTEM_DATASET}"
zmount zshemot/sinai
clear-mtree .
git pull
apply-mtree .
zfs snapshot "${SYSTEM_DATASET}@${NEW_SNAPSHOT}"
cd --

# Step 3: final reboot
kenv vfs.root.mountfrom='zfs:${SYSTEM}'
zpool set bootfs="${SYSTEM_DATASET}" zbereshit

reboot

