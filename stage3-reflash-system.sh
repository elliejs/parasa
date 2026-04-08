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
trap cleanup EXIT

system_name="${1:-}"
if [ -z "${system_name}" ]; then
	error "No system name provided\n" || exit
fi

confirm "Jumping to zannanim"
# Step 1: Jump to a ramdrive
MD_DEV=$(mdconfig -a -t swap -s 6g)
zpool create zannanim "${MD_DEV}"
zfs create zannanim/akeida

zmount zshemot/sinai
git clone /zshemot/sinai /zannanim/akeida
zunmount zshemot/sinai

cd /zannanim/akeida
git checkout "systems/${system_name}"
apply-mtree .
cd --

confirm "Created zannanim, setting kenv" 
kenv vfs.root.mountfrom='zfs:zannanim/akeida'
zfs set -u mountpoint=/ zannanim/${system_name}
SYSTEM="zbereshit/systems/${system_name}"
zfs set -u mountpoint="/${SYSTEM}" "${SYSTEM}"

reboot_msg="Reboot?\n"
reboot_msg="${reboot_msg}\tvfs.root.mountfrom=$(kenv vfs.root.mountfrom)\n"
reboot_msg="${reboot_msg}\tzannanim mountpoint:$(zfs get mountpoint zannanim${system_name})\n"
reboot_msg="${reboot_msg}\tzbereshit/systems/${system_name} mountpoint:$(zfs get mountpoint zbereshit/systems/${system_name})\n"
reboot -r

# TODO: zunmount the rest of zbereshit so they don't mount on top of zannanim

# Step 2: fast-forward zbereshit/system
# TODO: Warn if last looks like new (commit-hash)
cd "/${SYSTEM}"
zfs set mountpoint=/zshemot/sinai zshemot/sinai
clear-mtree .
git pull
apply-mtree .
zfs snapshot "${SYSTEM}@${NEW_SNAPSHOT}"
cd --

# Step 3: final reboot
kenv vfs.root.mountfrom='zfs:${SYSTEM}'
zpool set bootfs="${SYSTEM}" zbereshit

reboot

