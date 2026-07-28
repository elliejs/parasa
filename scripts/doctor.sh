#!/bin/sh
# doctor.sh -- Check if the system layout is acceptable for running parasa.
#
# Verifies pools, datasets, git repos, required tools, and parasa repo
# integrity. Interactively offers to repair what it can.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PARASA_DIR="${PARASA_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
doctor -- Check and repair the parasa system layout.

Usage:
  doctor.sh [-h] [-q] [-f]

Options:
  -h        Show this help and exit
  -q        Quiet mode: only report problems, no interactive repair
  -f        Fix mode: attempt all repairs without prompting

Checks:
  1. Required tools (zfs, git, mtree, pkg, file, jail, sysrc, chroot)
  2. ZFS pools (zbereshit, zshemot, zbamidbar)
  3. Required datasets under each pool
  4. Git bare repos on zbamidbar (foundation.git, parasa.git)
  5. Parasa repo integrity (etc/, recipes/, required files)
  6. Dataset properties (mountpoint=none, canmount=noauto where expected)

Exit codes:
  0  All checks pass (or all repaired)
  1  Problems found (quiet mode) or repair declined/failed

Examples:
  doctor.sh              Interactive check and repair
  doctor.sh -q           Report-only, no repairs
  doctor.sh -f           Fix everything possible without asking
EOF
	exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────

QUIET=0
FIX=false

while getopts ":hqf" opt; do
	case "$opt" in
		h) print_help ;;
		q) QUIET=1 ;;
		f) FIX=true ;;
		\?) die "Unknown option: -${OPTARG}. Use -h for help." ;;
	esac
done

# ── State tracking ──────────────────────────────────────────────────────────

_PASS=0
_FAIL=0
_FIXED=0
_WARN=0

pass() {
	_PASS=$((_PASS + 1))
	[ "$QUIET" -gt 0 ] || printf "  ✓ %s\n" "$1" >&2
}

fail() {
	_FAIL=$((_FAIL + 1))
	printf "  ✗ %s\n" "$1" >&2
}

warn() {
	_WARN=$((_WARN + 1))
	printf "  ! %s\n" "$1" >&2
}

fixed() {
	_FIXED=$((_FIXED + 1))
	_FAIL=$((_FAIL - 1))
	printf "  → fixed: %s\n" "$1" >&2
}

# Prompt for repair. Returns 0 if should repair, 1 if skip.
offer_fix() {
	local desc="$1"
	if $FIX; then
		return 0
	fi
	if [ "$QUIET" -gt 0 ]; then
		return 1
	fi
	printf "    Repair: %s? [Y/n]: " "$desc" >&2
	local resp
	read -r resp || return 1
	case "$resp" in
		""|[Yy]|[Yy][Ee][Ss]) return 0 ;;
		*) return 1 ;;
	esac
}

# ── Check: Required tools ───────────────────────────────────────────────────

check_tools() {
	printf "\n==> Checking required tools...\n" >&2
	local tool missing=""
	for tool in zfs zpool git mtree pkg file jail jexec sysrc chroot chflags nextboot; do
		if command -v "$tool" >/dev/null 2>&1; then
			pass "$tool"
		else
			fail "$tool not found in PATH"
			missing="${missing} ${tool}"
		fi
	done
	if [ -n "$missing" ]; then
		warn "Missing tools cannot be auto-repaired. Install them manually."
	fi
}

# ── Check: ZFS pools ───────────────────────────────────────────────────────

check_pools() {
	printf "\n==> Checking ZFS pools...\n" >&2
	local pool
	for pool in zbereshit zshemot zbamidbar; do
		if zpool list -H -o name "$pool" >/dev/null 2>&1; then
			pass "pool $pool exists"
		else
			fail "pool $pool not found"
			warn "Pools cannot be auto-created. Run bootstrap or import manually."
		fi
	done
}

# ── Check: Required datasets ───────────────────────────────────────────────

check_dataset() {
	local ds="$1" desc="${2:-$1}"
	if zfs_dataset_exists "$ds"; then
		pass "$desc"
	else
		fail "$desc missing"
		if offer_fix "create $ds"; then
			if zfs create -o mountpoint=none -o canmount=noauto "$ds"; then
				fixed "$desc"
			else
				warn "Failed to create $ds"
			fi
		fi
	fi
}

check_datasets() {
	printf "\n==> Checking required datasets...\n" >&2

	# zbereshit
	check_dataset "zbereshit/foundations" "zbereshit/foundations"
	check_dataset "zbereshit/systems" "zbereshit/systems"
	check_dataset "zbereshit/containers" "zbereshit/containers"

	# zshemot
	check_dataset "zshemot/buildspace" "zshemot/buildspace"

	# zbamidbar
	check_dataset "zbamidbar/foundation.zfs" "zbamidbar/foundation.zfs"
	check_dataset "zbamidbar/foundation.zfs/foundations" "zbamidbar/foundation.zfs/foundations"
	check_dataset "zbamidbar/system-data" "zbamidbar/system-data"
	check_dataset "zbamidbar/container-data" "zbamidbar/container-data"
}

# ── Check: Git bare repos ──────────────────────────────────────────────────

check_bare_repo() {
	local ds="$1" mnt="$2" desc="$3"

	if ! zfs_dataset_exists "$ds"; then
		fail "$desc dataset missing"
		if offer_fix "create $ds and init bare git repo"; then
			zfs create -o mountpoint=none -o canmount=noauto "$ds" || { warn "Failed to create $ds"; return; }
			zfs set mountpoint="$mnt" "$ds"
			zfs mount "$ds"
			git init --bare "$mnt" || { warn "Failed to init bare repo at $mnt"; return; }
			zfs set mountpoint=none "$ds"
			zfs unmount "$ds" 2>/dev/null || true
			fixed "$desc"
		fi
		return
	fi

	# Dataset exists — verify it's a git repo when mounted
	pass "$desc dataset exists"
}

check_git_repos() {
	printf "\n==> Checking git bare repos...\n" >&2
	check_bare_repo "zbamidbar/foundation.git" "/zbamidbar/foundation.git" "zbamidbar/foundation.git"
	check_bare_repo "zbamidbar/parasa.git" "/zbamidbar/parasa.git" "zbamidbar/parasa.git"
}

# ── Check: FreeBSD src tree ────────────────────────────────────────────────

check_src_tree() {
	printf "\n==> Checking FreeBSD src tree...\n" >&2

	if ! zfs_dataset_exists "zshemot/src.git"; then
		fail "zshemot/src.git dataset missing"
		if offer_fix "create zshemot/src.git"; then
			zfs create -o mountpoint=none -o canmount=noauto "zshemot/src.git" || \
				{ warn "Failed to create zshemot/src.git"; return; }
			fixed "zshemot/src.git dataset"
		fi
	else
		pass "zshemot/src.git dataset exists"
	fi

	# Check if src.git is mountable and has a git repo
	# (don't mount it here — just verify dataset exists)
}

# ── Check: Parasa repo integrity ───────────────────────────────────────────

check_parasa_repo() {
	printf "\n==> Checking parasa repo integrity...\n" >&2

	# The repo itself
	if [ -d "${PARASA_DIR}/.git" ]; then
		pass "parasa repo is a git repository"
	else
		fail "parasa repo at ${PARASA_DIR} is not a git repository"
		warn "Cannot auto-repair. Clone parasa to ${PARASA_DIR}."
		return
	fi

	# etc/ directory
	if [ -d "${PARASA_DIR}/etc" ]; then
		pass "etc/ directory exists"
	else
		fail "etc/ directory missing"
		if offer_fix "create etc/"; then
			mkdir -p "${PARASA_DIR}/etc"
			fixed "etc/ directory"
		fi
	fi

	# etc/mtree.ignore
	if [ -f "${PARASA_DIR}/etc/mtree.ignore" ]; then
		pass "etc/mtree.ignore exists"
	else
		fail "etc/mtree.ignore missing"
		if offer_fix "create etc/mtree.ignore with .git entry"; then
			mkdir -p "${PARASA_DIR}/etc"
			printf ".git\n" > "${PARASA_DIR}/etc/mtree.ignore"
			fixed "etc/mtree.ignore"
		fi
	fi

	# etc/derivations/ with at least one .db
	if [ -d "${PARASA_DIR}/etc/derivations" ]; then
		local db_count=0 f
		for f in "${PARASA_DIR}/etc/derivations"/*.db; do
			[ -f "$f" ] && db_count=$((db_count + 1))
		done
		if [ "$db_count" -gt 0 ]; then
			pass "etc/derivations/ has ${db_count} db file(s)"
		else
			fail "etc/derivations/ exists but has no .db files"
			warn "At least one derivation db (e.g. 15.0.db) is needed."
		fi
	else
		fail "etc/derivations/ directory missing"
		if offer_fix "create etc/derivations/"; then
			mkdir -p "${PARASA_DIR}/etc/derivations"
			fixed "etc/derivations/ directory"
			warn "You still need a derivation db file (e.g. 15.0.db)."
		fi
	fi

	# recipes/ directory structure
	local dir
	for dir in recipes recipes/foundations recipes/systems recipes/containers; do
		if [ -d "${PARASA_DIR}/${dir}" ]; then
			pass "${dir}/ exists"
		else
			fail "${dir}/ missing"
			if offer_fix "create ${dir}/"; then
				mkdir -p "${PARASA_DIR}/${dir}"
				fixed "${dir}/"
			fi
		fi
	done

	# recipes/jail.conf
	if [ -f "${PARASA_DIR}/recipes/jail.conf" ]; then
		pass "recipes/jail.conf exists"
	else
		fail "recipes/jail.conf missing"
		if offer_fix "create default recipes/jail.conf"; then
			cat > "${PARASA_DIR}/recipes/jail.conf" <<'JAILCONF'
# jail.conf -- Default jail configuration for parasa containers.
exec.start = "/bin/sh /etc/rc";
exec.stop  = "/bin/sh /etc/rc.shutdown";
exec.clean;
mount.devfs;
devfs_ruleset = 4;
ip4 = inherit;
ip6 = inherit;

.include "/zshemot/parasa/recipes/containers/*/jail.conf";
JAILCONF
			fixed "recipes/jail.conf"
		fi
	fi

	# parasa.conf
	if [ -f "${PARASA_DIR}/parasa.conf" ]; then
		pass "parasa.conf exists"
	else
		fail "parasa.conf missing"
		if offer_fix "create minimal parasa.conf"; then
			cat > "${PARASA_DIR}/parasa.conf" <<'CONF'
# parasa.conf -- Parasa-wide build defaults.
# SRC_BRANCH=stable/15
# KERNCONF=GENERIC
CONF
			fixed "parasa.conf"
		fi
	fi

	# scripts/ directory with key scripts
	local script
	for script in helpers.sh workspace.sh new_foundation.sh new_system.sh new_container.sh deploy_system.sh diff.sh save.sh update.sh finalize_update.sh; do
		if [ -f "${PARASA_DIR}/scripts/${script}" ]; then
			pass "scripts/${script}"
		else
			fail "scripts/${script} missing"
			warn "Cannot auto-repair missing scripts. Re-clone the repo."
		fi
	done
}

# ── Check: Dataset properties ──────────────────────────────────────────────

check_dataset_props() {
	printf "\n==> Checking dataset properties...\n" >&2

	local ds prop expected actual
	# These datasets should have mountpoint=none and canmount=noauto
	for ds in \
		zbereshit/foundations \
		zbereshit/systems \
		zbamidbar/foundation.zfs \
		zbamidbar/foundation.zfs/foundations \
		zbamidbar/system-data \
		zbamidbar/container-data \
		zshemot/buildspace; do

		zfs_dataset_exists "$ds" || continue

		actual=$(zfs get -H -o value mountpoint "$ds" 2>/dev/null) || continue
		if [ "$actual" = "none" ]; then
			pass "$ds mountpoint=none"
		else
			warn "$ds has mountpoint=$actual (expected none)"
			if offer_fix "set $ds mountpoint=none"; then
				zfs set mountpoint=none "$ds" && fixed "$ds mountpoint" || \
					warn "Failed to set mountpoint on $ds"
			fi
		fi
	done

	# zbereshit/containers should be mounted at /containers
	if zfs_dataset_exists "zbereshit/containers"; then
		actual=$(zfs get -H -o value mountpoint "zbereshit/containers" 2>/dev/null) || true
		if [ "$actual" = "/containers" ]; then
			pass "zbereshit/containers mountpoint=/containers"
		elif [ "$actual" = "none" ]; then
			warn "zbereshit/containers has mountpoint=none (expected /containers)"
			if offer_fix "set zbereshit/containers mountpoint=/containers"; then
				zfs set mountpoint=/containers "zbereshit/containers" && \
					fixed "zbereshit/containers mountpoint" || \
					warn "Failed to set mountpoint"
			fi
		else
			pass "zbereshit/containers mountpoint=$actual"
		fi
	fi
}

# ── Check: OS ──────────────────────────────────────────────────────────────

check_os() {
	printf "\n==> Checking operating system...\n" >&2
	local os
	os=$(uname -s)
	if [ "$os" = "FreeBSD" ]; then
		pass "Running FreeBSD $(uname -r)"
	else
		fail "Not running FreeBSD (detected: $os)"
		warn "Parasa is designed for FreeBSD. Many features will not work."
	fi
}

# ── Summary ─────────────────────────────────────────────────────────────────

print_summary() {
	printf "\n" >&2
	printf "══════════════════════════════════════════\n" >&2
	printf "  Doctor summary\n" >&2
	printf "══════════════════════════════════════════\n" >&2
	printf "  Passed:  %d\n" "$_PASS" >&2
	printf "  Failed:  %d\n" "$_FAIL" >&2
	printf "  Fixed:   %d\n" "$_FIXED" >&2
	printf "  Warnings:%d\n" "$_WARN" >&2
	printf "══════════════════════════════════════════\n" >&2

	if [ "$_FAIL" -eq 0 ]; then
		printf "\n  System layout is ready for parasa.\n" >&2
		return 0
	else
		printf "\n  %d problem(s) remain. Fix them before using parasa.\n" "$_FAIL" >&2
		return 1
	fi
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
	printf "Parasa Doctor\n" >&2
	printf "Checking system layout at: %s\n" "$PARASA_DIR" >&2

	check_os
	check_tools
	check_pools
	check_datasets
	check_git_repos
	check_src_tree
	check_parasa_repo
	check_dataset_props

	print_summary
}

main
