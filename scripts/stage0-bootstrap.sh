#!/bin/sh
# stage0-bootstrap -- One-time disk initialization for a new parasa system.
#
# Partitions the boot disk, GELI-encrypts all pool devices, creates ZFS pools,
# and builds the initial dataset hierarchy.
#
# DANGER: destroys all data on selected disks. Never run against the live root.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/helpers.sh"

# ── Help ──────────────────────────────────────────────────────────────────────

print_help() {
	cat <<'EOF'
stage0-bootstrap -- Initialize disk layout for a new parasa system.

Usage: stage0-bootstrap [-dh]

Options:
  -d    Dry run: print all commands without executing them
  -h    Show this help and exit

Performs, in order:
  1. Partition the boot disk (EFI 260m + swap + ZFS remainder)
  2. Format the EFI partition and install /boot/loader.efi
  3. GELI-encrypt all pool devices (one passphrase per pool, entered interactively)
  4. glabel each GELI provider with a user-chosen label
  5. Create ZFS pools zbereshit, zshemot, zbamidbar
  6. Build the parasa ZFS dataset hierarchy

DANGER: All data on selected disks will be destroyed.
EOF
	exit 0
}

# ── Args ──────────────────────────────────────────────────────────────────────

DRY_RUN=false
while getopts ":dh" opt; do
	case "$opt" in
		d) DRY_RUN=true ;;
		h) print_help ;;
		\?) die "Unknown option: -${OPTARG}. Use -h for help." ;;
	esac
done
shift $((OPTIND - 1))

# ── Dry-run wrapper ───────────────────────────────────────────────────────────

# Execute a command, or print it if in dry-run mode.
run() {
	if $DRY_RUN; then
		printf "  [dry] %s\n" "$*" >&2
	else
		"$@"
	fi
}

# ── Running-disk detection ────────────────────────────────────────────────────

# Return the base disk name(s) (no /dev/, no .eli, no partition suffix) that
# hold the currently running root filesystem.  On ZFS-root systems
# df(1) reports a dataset name, not a device path, so we resolve
# the backing provider(s) via zpool status instead.
# Prints one disk name per line (mirrors may have more than one).
running_disk() {
	local dev pool
	dev=$(df / | tail -1 | awk '{print $1}')

	case "$dev" in
		/dev/*)
			# UFS: strip /dev/, .eli suffix, and partition suffix
			dev="${dev#/dev/}"
			dev="${dev%.eli}"
			printf "%s\n" "$dev" | sed -E 's/(p[0-9]+|s[0-9]+[a-z]?)$//'
			;;
		*)
			# ZFS dataset (e.g. zroot/ROOT/default) — extract pool name
			pool="${dev%%/*}"
			# List ONLINE leaf vdevs from zpool status, strip GELI/partition
			# suffixes to recover the base disk name.
			zpool status "$pool" \
				| awk '/state:/ { found=1 } found && /ONLINE/ { print $1 }' \
				| grep -vE '^(pool:|state:|NAME|'"$pool"')$' \
				| sed -E 's/\.eli$//; s/(p[0-9]+|s[0-9]+[a-z]?)$//' \
				| sort -u
			;;
	esac
}

# Die if the given disk is the running system disk.
assert_not_running() {
	local running
	running=$(running_disk)
	printf "%s\n" "$running" | grep -qxF "$1" && \
		die "Disk '$1' is the running system disk. Refusing to continue."
}

# ── Input helpers ─────────────────────────────────────────────────────────────
#
# Every function here is called inside $(), so all user-facing output
# (prompts, errors, disk lists) goes to stderr. Only the final answer
# goes to stdout.

show_disks() {
	printf "Available disks:\n" >&2
	geom disk list | awk '/^Geom name:/ { printf "  %s\n", $3 }' >&2
}

# Prompt for a single disk device, validated.
# Prints the bare device name (e.g. "nda0") to stdout.
prompt_disk() {
	local desc="$1" disk
	while true; do
		show_disks
		printf "%s disk: " "$desc" >&2
		read -r disk
		disk="${disk#/dev/}"
		if [ ! -c "/dev/$disk" ]; then
			printf "  /dev/%s not found.\n" "$disk" >&2
			continue
		fi
		if running_disk | grep -qxF "$disk"; then
			printf "  /dev/%s is the running system disk.\n" "$disk" >&2
			continue
		fi
		printf "%s" "$disk"
		return
	done
}

# Prompt for a glabel name. Non-empty, no whitespace, no slashes.
# Prints the label to stdout.
prompt_label() {
	local desc="$1" label
	while true; do
		printf "  Label for %s: " "$desc" >&2
		read -r label
		case "$label" in
			"")                    printf "  Label cannot be empty.\n" >&2; continue ;;
			*[[:space:]]*|*"/"*)   printf "  No spaces or slashes.\n" >&2; continue ;;
		esac
		printf "%s" "$label"
		return
	done
}

# Prompt for disks+labels one at a time. Empty disk name = done.
# Prints space-separated "disk:label" pairs to stdout.
prompt_disk_list() {
	local pool_desc="$1" disk label pairs="" idx=1
	while true; do
		show_disks
		printf "%s disk %d (Enter when done): " "$pool_desc" "$idx" >&2
		read -r disk
		[ -n "$disk" ] || break
		disk="${disk#/dev/}"
		if [ ! -c "/dev/$disk" ]; then
			printf "  /dev/%s not found.\n" "$disk" >&2
			continue
		fi
		if running_disk | grep -qxF "$disk"; then
			printf "  /dev/%s is the running system disk.\n" "$disk" >&2
			continue
		fi
		label=$(prompt_label "/dev/$disk")
		pairs="${pairs} ${disk}:${label}"
		idx=$((idx + 1))
	done
	pairs="${pairs# }"
	[ -n "$pairs" ] || die "${pool_desc}: at least one disk is required."
	printf "%s" "$pairs"
}

# Prompt for an optional zpool topology keyword.
prompt_topology() {
	local desc="$1" topo
	printf "%s topology (e.g. mirror, raidz1; Enter for none): " "$desc" >&2
	read -r topo
	printf "%s" "$topo"
}

# Prompt for a swap size (e.g. 8g, 16g, 4096m).
prompt_swap_size() {
	local size
	while true; do
		printf "Swap partition size (e.g. 8g, 16g): " >&2
		read -r size
		case "$size" in
			[0-9]*[gGmMkKtT]) printf "%s" "$size"; return ;;
			*) printf "  Invalid format.\n" >&2 ;;
		esac
	done
}

# ── GELI / GLABEL ─────────────────────────────────────────────────────────────

# Track attached providers so we can detach on failure.
ATTACHED_GELI=""

cleanup() {
	[ -n "$ATTACHED_GELI" ] || return 0
	printf "\nCleaning up: detaching GELI providers...\n" >&2
	for p in $ATTACHED_GELI; do
		geli detach "/dev/$p" 2>/dev/null || true
	done
}
trap cleanup EXIT

# GELI-init, attach, and glabel one device.
# $1 = device (e.g. nda0p3)   $2 = geli flags (e.g. -bg)   $3 = label
geli_setup_one() {
	local dev="$1" flags="$2" label="$3"

	printf "\n--- GELI: /dev/%s  ->  label/%s ---\n" "$dev" "$label"
	printf "geli will prompt for a passphrase.\n"
	run geli init -B none "$flags" -l 256 -s 4096 "/dev/${dev}"

	printf "Re-enter the passphrase to attach.\n"
	run geli attach "/dev/${dev}"
	$DRY_RUN || ATTACHED_GELI="${ATTACHED_GELI} ${dev}.eli"

	run glabel label "$label" "${dev}.eli"
}

# GELI-setup every disk in a "disk:label disk:label ..." string.
geli_setup_pool() {
	local pairs="$1" flags="$2" pair
	for pair in $pairs; do
		geli_setup_one "${pair%%:*}" "$flags" "${pair##*:}"
	done
}

# ── vdev construction ─────────────────────────────────────────────────────────

# Build a zpool vdev string from disk:label pairs and an optional topology.
# e.g. "ada0:wumpus ada1:grue" + "mirror" -> "mirror label/wumpus label/grue"
build_vdev() {
	local pairs="$1" topo="$2" labels="" pair
	for pair in $pairs; do
		labels="${labels} label/${pair##*:}"
	done
	labels="${labels# }"
	if [ -n "$topo" ]; then
		printf "%s %s" "$topo" "$labels"
	else
		printf "%s" "$labels"
	fi
}

# Assert every device token in a vdev string is a label/ path.
assert_label_vdevs() {
	for token in $1; do
		case "$token" in
			mirror|raidz*|log|cache|spare) ;;
			label/*) ;;
			*) die "vdev member '${token}' is not a label/ device." ;;
		esac
	done
}

# ── Dataset hierarchy ─────────────────────────────────────────────────────────

create_datasets() {
	printf "\n=== Creating dataset hierarchy ===\n"

	# -- zbereshit --
	run zfs create -o mountpoint=none -o canmount=noauto  zbereshit/systems
	run zfs create -o mountpoint=/containers -o canmount=on  zbereshit/containers

	# -- zshemot --
	run zfs create -o mountpoint=none -o canmount=noauto  zshemot/buildspace
	run zfs create -o mountpoint=/zshemot/src.git   -o canmount=noauto  zshemot/src.git
	run zfs create -o mountpoint=/zshemot/parasa  -o canmount=noauto  zshemot/parasa

	# -- zbamidbar --
	run zfs create -o mountpoint=none -o canmount=noauto  zbamidbar/container-data
	run zfs create -o mountpoint=none -o canmount=noauto  zbamidbar/system-data
	run zfs create -o mountpoint=none -o canmount=noauto  zbamidbar/foundation.git
	run zfs create -o mountpoint=none -o canmount=noauto  zbamidbar/foundation.zfs
	run zfs create -o mountpoint=none -o canmount=noauto  zbamidbar/parasa.git
}

# ── EFI partition setup ──────────────────────────────────────────────────────

install_efi_loader() {
	local efi_part="$1"
	local efi_tmp
	efi_tmp=$(mktemp -d /tmp/parasa-efi-XXXXXX)

	run newfs_msdos -F 32 -c 1 "$efi_part"
	run mount -t msdosfs "$efi_part" "$efi_tmp"
	run mkdir -p "${efi_tmp}/EFI/BOOT"
	run cp /boot/loader.efi "${efi_tmp}/EFI/BOOT/BOOTX64.EFI"
	run umount "$efi_tmp"
	rmdir "$efi_tmp" 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

root_only

printf "\n=== PARASA STAGE 0: DISK BOOTSTRAP ===\n"
printf "WARNING: All data on selected disks will be DESTROYED.\n"
$DRY_RUN && printf "(dry-run mode: no changes will be made)\n"
printf "\n"

# ── Collect all input before touching anything ────────────────────────────────

printf "== Boot disk (zbereshit) ==\n"
BOOT_DISK=$(prompt_disk "Boot")
BOOT_LABEL=$(prompt_label "/dev/$BOOT_DISK")
SWAP_SIZE=$(prompt_swap_size)

printf "\n== Config pool (zshemot) ==\n"
ZSHEMOT_PAIRS=$(prompt_disk_list "zshemot")
ZSHEMOT_TOPO=$(prompt_topology "zshemot")

printf "\n== Data lake (zbamidbar) ==\n"
ZBAMIDBAR_PAIRS=$(prompt_disk_list "zbamidbar")
ZBAMIDBAR_TOPO=$(prompt_topology "zbamidbar")

# ── Summary + confirmation ────────────────────────────────────────────────────

print_pairs() {
	local pairs="$1" pair
	for pair in $pairs; do
		printf "  /dev/%s  ->  label/%s\n" "${pair%%:*}" "${pair##*:}"
	done
}

printf "\n=== Summary ===\n"
printf "Boot disk:   /dev/%s  ->  label/%s\n" "$BOOT_DISK" "$BOOT_LABEL"
printf "  p1  efi           260m\n"
printf "  p2  freebsd-swap  %s\n" "$SWAP_SIZE"
printf "  p3  freebsd-zfs   remainder\n"
printf "zshemot [%s]:\n" "${ZSHEMOT_TOPO:-stripe}"
print_pairs "$ZSHEMOT_PAIRS"
printf "zbamidbar [%s]:\n" "${ZBAMIDBAR_TOPO:-stripe}"
print_pairs "$ZBAMIDBAR_PAIRS"
printf "\n"

confirm "Proceed? This will destroy all data on the above disks." || exit 0

# ── Partition the boot disk ───────────────────────────────────────────────────

printf "\n=== Partitioning /dev/%s ===\n" "$BOOT_DISK"

run gpart create -s gpt "$BOOT_DISK"
run gpart add -t efi          -s 260m        -l efi         "$BOOT_DISK"
run gpart add -t freebsd-swap -s "$SWAP_SIZE" -l swap0      "$BOOT_DISK"
run gpart add -t freebsd-zfs                 -l "$BOOT_LABEL" "$BOOT_DISK"

# ── Format EFI and install loader ─────────────────────────────────────────────

printf "\n=== Installing EFI loader ===\n"
install_efi_loader "/dev/${BOOT_DISK}p1"

# ── GELI + GLABEL ─────────────────────────────────────────────────────────────

printf "\n=== GELI: zbereshit (boot pool) ===\n"
printf "This passphrase will be required on every boot.\n"
geli_setup_one "${BOOT_DISK}p3" "-bg" "$BOOT_LABEL"

printf "\n=== GELI: zshemot (config pool) ===\n"
printf "Enter the same passphrase for each disk in this pool.\n"
geli_setup_pool "$ZSHEMOT_PAIRS" "-b"

printf "\n=== GELI: zbamidbar (data lake) ===\n"
printf "Enter the same passphrase for each disk in this pool.\n"
geli_setup_pool "$ZBAMIDBAR_PAIRS" "-b"

# ── Create ZFS pools ──────────────────────────────────────────────────────────

printf "\n=== Creating ZFS pools ===\n"

# Pool and root-dataset properties shared by all three pools.
# Intentionally unquoted when passed to run() so the shell word-splits
# them into individual flags.
ZPOOL_FLAGS="-o ashift=12 -o autotrim=on"
ZPOOL_DS_FLAGS="-O atime=off -O compression=zstd -O aclmode=passthrough -O mountpoint=none -O canmount=noauto"

ZBERESHIT_VDEV="label/${BOOT_LABEL}"
assert_label_vdevs "$ZBERESHIT_VDEV"
# shellcheck disable=SC2086
run zpool create $ZPOOL_FLAGS $ZPOOL_DS_FLAGS zbereshit $ZBERESHIT_VDEV

ZSHEMOT_VDEV=$(build_vdev "$ZSHEMOT_PAIRS" "$ZSHEMOT_TOPO")
assert_label_vdevs "$ZSHEMOT_VDEV"
# shellcheck disable=SC2086
run zpool create $ZPOOL_FLAGS $ZPOOL_DS_FLAGS zshemot $ZSHEMOT_VDEV

ZBAMIDBAR_VDEV=$(build_vdev "$ZBAMIDBAR_PAIRS" "$ZBAMIDBAR_TOPO")
assert_label_vdevs "$ZBAMIDBAR_VDEV"
# shellcheck disable=SC2086
run zpool create $ZPOOL_FLAGS $ZPOOL_DS_FLAGS zbamidbar $ZBAMIDBAR_VDEV

# ── Dataset hierarchy ─────────────────────────────────────────────────────────

create_datasets

# ── Done ──────────────────────────────────────────────────────────────────────

# Success — clear the list so the EXIT trap leaves providers attached.
ATTACHED_GELI=""

printf "\n=== Stage 0 complete ===\n"
printf "Pools: zbereshit, zshemot, zbamidbar\n"
printf "Dataset hierarchy initialized.\n"

if [ -t 0 ] && confirm "Build a foundation now?"; then
	exec sh "${SCRIPT_DIR}/new_foundation.sh"
else
	printf "Next: new_foundation.sh\n"
fi
