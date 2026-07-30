#!/bin/sh
# menu.sh -- Interactive launcher for parasa commands.
#
# Shows all available scripts grouped by lifecycle phase, describes when
# to use each, and runs the selected one (passing through to its own
# interactive mode or help).

set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

print_menu() {
	cat >&2 <<'MENU'

  ┌─────────────────────────────────────────────────┐
  │               p a r a s a                       │
  └─────────────────────────────────────────────────┘

  Bootstrap
    1)  stage0-bootstrap    Initialize disks, GELI, ZFS pools, dataset hierarchy
                            Run once on a fresh machine. Destructive to target disks.

  Build
    2)  new_foundation      Build FreeBSD world+kernel, archive as a foundation
                            Run when you need a new base image (new release, patch level).
    3)  update_foundation   Check for upstream changes and rebuild a foundation

  Create
    4)  new_container       Create a container (jail) on top of a foundation
    5)  new_system          Create a system recipe on top of a foundation

  Deploy
    6)  deploy_container    Send a foundation archive to zbereshit, apply container branch
    7)  deploy_system       Send a foundation archive to zbereshit, apply system branch

  Operate
    8)  diff                Detect drift between a live workspace and its recipe
    9)  save                Capture packages, mtree, and commit workspace state
   10)  update              Rebase a workspace onto a new foundation (non-destructive)
   11)  finalize_update     Swap the -new clone into place (destructive, completes update)

  Destroy
   12)  destroy_container   Remove all traces of a container (partial or full)
   13)  destroy_foundation  Remove all traces of a foundation (refuses if in use)

  Maintain
   14)  doctor              Check and repair the parasa system layout

   h)  Help — show this menu again
   q)  Quit

MENU
}

run_script() {
	printf "\n" >&2
	exec sh "$@"
}

print_menu

while true; do
	printf "  parasa> " >&2
	read -r choice || exit 0

	case "$choice" in
		1)  run_script "${SCRIPT_DIR}/stage0-bootstrap.sh" ;;
		2)  run_script "${SCRIPT_DIR}/new_foundation.sh" ;;
		3)  run_script "${SCRIPT_DIR}/update_foundation.sh" ;;
		4)  run_script "${SCRIPT_DIR}/new_container.sh" ;;
		5)  run_script "${SCRIPT_DIR}/new_system.sh" ;;
		6)  run_script "${SCRIPT_DIR}/deploy_container.sh" ;;
		7)  run_script "${SCRIPT_DIR}/deploy_system.sh" ;;
		8)  run_script "${SCRIPT_DIR}/diff.sh" ;;
		9)  run_script "${SCRIPT_DIR}/save.sh" ;;
		10) run_script "${SCRIPT_DIR}/update.sh" ;;
		11) run_script "${SCRIPT_DIR}/finalize_update.sh" ;;
		12) run_script "${SCRIPT_DIR}/destroy_container.sh" ;;
		13) run_script "${SCRIPT_DIR}/destroy_foundation.sh" ;;
		14) run_script "${SCRIPT_DIR}/doctor.sh" ;;
		h|H|help) print_menu ;;
		q|Q|quit|exit) exit 0 ;;
		"") ;;
		*)  printf "  Unknown choice: %s (type h for menu, q to quit)\n" "$choice" >&2 ;;
	esac
done
