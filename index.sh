#!/bin/sh
# index.sh -- Source this file to make mishkan commands available.
#
# Usage: . /zshemot/mishkan/index.sh
#    or: . /path/to/project-mishkan/index.sh
#
# Provides wrapper functions that call the actual scripts in scripts/.

MISHKAN_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

. "${MISHKAN_DIR}/scripts/helpers.sh"

mishkan-bootstrap() {
	sh "${MISHKAN_DIR}/scripts/stage0-bootstrap.sh" "$@"
}
