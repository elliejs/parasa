#! /bin/bash
set -euo pipefail

. helpers.sh

# Step 1: Jump to a ramdrive
MD_DEV=$(mdconfig -a -t swap -s 6g)
zpool create zannanim "${MD_DEV}"
zfs create zannanim/akeida

zfs set mountpoint=/zshemot/sinai zshemot/sinai
git clone /zshemot/sinai /zannanim/akeida
zfs set mountpoint=none zshemot/sinai

cd /zannanim/akeida
git checkout systems/kidon
apply-mtree .
cd ~-

kenv vfs.root.mountfrom='zfs:zannanim/akeida'
zfs set -u mountpoint=/ zannanim/akeida
local SYSTEM="zbereshit/systems/kidon"
zfs set -u mountpoint="/${SYSTEM}" "${SYSTEM}"
reboot -r
# TODO: how to not mount zbereshit on top of zannanim?

# Step 2: fast-forward zbereshit/system
local LAST_SNAPSHOT="$(get-current-artifact "${SYSTEM}")"
local NEW_SNAPSHOT="$(get-artifact-name)"
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

