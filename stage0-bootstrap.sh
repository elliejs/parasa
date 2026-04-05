#! /bin/bash
set -euo pipefail

##
# GELI
##
#  -l -- keylen 256 (AES-XTS)
#  -s -- 4k sectors
#  -B -- no backup files (add to datalake later)

# zbereshit
#  -b -- decrypt during boot
#  -g -- bootable, use interactive decrypt
geli init -B none -bg -l 256 -s 4096 nda0p4
geli attach nda0p4
# zshemot
geli init -B none -b -l 256 -s 4096 ada0
geli attach ada0
# zbamidbar
geli init -B none -b -l 256 -s 4096 ada1
geli attach ada1
# forgot to do this?
# geli configure -b [prov]

##
# GLABEL
##
# zbereshit
glabel label glados nda0.eli
# zshemot
glabel label wumpus ada0.eli
# zbamidbar
glabel label grue ada1.eli

##
# ZPOOL
##
ZPOOL_SETTINGS="-o ashift=12"
ZPOOL_SETTINGS="${ZPOOL_SETTINGS} -o autotrim=on"
zpool create ${POOL_SETTINGS} zbereshit label/glados
zpool create ${POOL_SETTINGS} zshemot label/wumpus
zpool create "${POOL_SETTINGS}" zbamidbar label/grue

DATASET_SETTINGS="atime=off"
DATASET_SETTINGS="${DATASET_SETTINGS} compression=zstd"
DATASET_SETTINGS="${DATASET_SETTINGS} aclmode=passthrough"
DATASET_SETTINGS="${DATASET_SETTINGS} mountpoint=none"
DATASET_SETTINGS="${DATASET_SETTINGS} canmount=noauto"

zfs set ${DATASET_SETTINGS} zbereshit
zfs set ${DATASET_SETTINGS} zshemot
zfs set ${DATASET_SETTINGS} zbamidbar

##
# ZFS
##
zfs create zbereshit/systems # running systems (1 + available)
zfs create zbereshit/containers # running containers
zfs create zshemot/torah # FreeBSD src
zfs create zshemot/minhagim # build environment configs
zfs set mountpoint=/zshemot/minhagim zshemot/minhagim
echo "./.git" > /zshemot/minhagim/sinai.mtreeignore
zfs set mountpoint=none zshemot/minhagim
zfs create zshemot/sinai # Build artifacts
zfs create zbamidbar/systems # mount data-lakes for systems
zfs create zbamidbar/containers # mount data-lakes for containers
