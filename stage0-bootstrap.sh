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
geli init -B none -bg -l 256 -s 4096 nda0
geli attach nda0
# zshemot
geli init -B none -l 256 -s 4096 ada0
geli attach ada0
# zbamidbar
geli init -B none -l 256 -s 4096 ada1
geli attach ada1

##
# GLABEL
##
# zbereshit
glabel label grue nda0.eli
# zshemot
glabel label wumpus ada0.eli
# zbamidbar
glabel label spiff ada1.eli

##
# ZPOOL
##
local ZPOOL_SETTINGS="-o ashift=12"
ZPOOL_SETTINGS+=" -o autotrim=on"
zpool create ${POOL_SETTINGS} zbereshit label/grue
zpool create ${POOL_SETTINGS} zshemot label/wumpus
zpool create ${POOL_SETTINGS} zbamidbar label/spiff

local DATASET_SETTINGS="atime=off"
DATASET_SETTINGS+=" compression=zstd"
DATASET_SETTINGS+=" aclmode=passthrough"
DATASET_SETTINGS+=" mountpoint=none"
DATASET_SETTINGS+=" canmount=noauto"

zfs set ${DATASET_SETTINGS} zbereshit
zfs set ${DATASET_SETTINGS} zshemot
zfs set ${DATASET_SETTINGS} zbamidbar

##
# ZFS
##
zfs create zbereshit/system # running systems (1 + available)
zfs create zbereshit/containers # running containers
zfs create zshemot/torah # FreeBSD src
zfs create zshemot/minhagim # build environment configs
zfs create zshemot/sinai # Build artifacts
zfs create zbamidbar/systems # mount data-lakes for systems
zfs create zbamidbar/containers # mount data-lakes for containers
