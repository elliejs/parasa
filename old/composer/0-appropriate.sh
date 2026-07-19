#!/bin/sh

set -eu

THIS_SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
. "${THIS_SCRIPT_DIR}/../helpers.sh"

root-only

JAIL_NAME="${1:-}"

if [ -z "${JAIL_NAME}" ] || [ "-h" = "${JAIL_NAME}" ]; then {
	echo "Appropriate and bootstrap jail resources"
	echo "0-appropriate [JAIL_NAME]"
}

ztouch "zbamidbar/container-data"

zunmount "zbamidbar/container-data/${JAIL_NAME}/home"
zunmount "zbamidbar/container-data/${JAIL_NAME}/usr-local"
zunmount "zbamidbar/container-data/${JAIL_NAME}/var"

jail_dataset="zbereshit/containers/${JAIL_NAME}"
if zfs list -t filesystem "${jail_dataset}" >/dev/null 2>&1; then
    zfs destroy "${jail_dataset}"
fi

latest_snapshot="$(get-current-artifact zbereshit/parasa)"
zfs clone "zbereshit/parasa@${latest_snapshot}" "${jail_dataset}"
zfs clone "zbereshit/parasa/var@${latest_snapshot}" "${jail_dataset}/var"
ztouch "zbamidbar/container-data/${JAIL_NAME}"
ztouch "zbamidbar/container-data/${JAIL_NAME}/home" -o mountpoint="/containers/${JAIL_NAME}/home"
ztouch "zbamidbar/container-data/${JAIL_NAME}/home/plonit"
ztouch "zbereshit/container-compose/${JAIL_NAME}"

# Configuration
TEMPLATE_SRC="/etc/jail.conf.d/template.nonconf"
TEMPLATE_DEST="/etc/jail.conf.d/${JAIL_NAME}.conf"
if [ ! -e "$TEMPLATE_DEST" ]; then
	cp "$TEMPLATE_SRC" "$TEMPLATE_DEST"
	sed -i '' "s/%%JAIL_NAME%%/${JAIL_NAME}/" "$TEMPLATE_DEST"
fi

(
	cd "/containers/${JAIL_NAME}"
	gswitch "containers/${JAIL_NAME}"
)

