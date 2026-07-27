# `archive_to_zbamidbar()` always fails: missing `foundations` parent dataset

**Files:** `scripts/stage0-bootstrap.sh`, `scripts/new_foundation.sh`,
`scripts/helpers.sh` (`ztouch`)
**Severity:** Bug — 100% reproducible, breaks every foundation build on
every freshly-bootstrapped system.

## The bug

`stage0-bootstrap.sh`'s `create_datasets()` creates `zbamidbar/foundation.zfs`
directly but never creates a `zbamidbar/foundation.zfs/foundations` child:

```sh
# -- zbamidbar --
run zfs create -o mountpoint=none -o canmount=noauto  zbamidbar/container-data
run zfs create -o mountpoint=none -o canmount=noauto  zbamidbar/system-data
run zfs create -o mountpoint=none -o canmount=noauto  zbamidbar/foundation.git
run zfs create -o mountpoint=none -o canmount=noauto  zbamidbar/foundation.zfs
run zfs create -o mountpoint=none -o canmount=noauto  zbamidbar/parasa.git
```

`new_foundation.sh`'s `archive_to_zbamidbar()` then tries to create the
foundation's archive dataset two levels below that:

```sh
archive_to_zbamidbar() {
	local workspace="zshemot/buildspace/${FOUNDATION_NAME}"
	local dest="zbamidbar/foundation.zfs/foundations/${FOUNDATION_NAME}"
	...
	run ztouch "$dest" -o mountpoint=none -o canmount=noauto
```

and `ztouch` (in `helpers.sh`) calls plain `zfs create` with no `-p`:

```sh
ztouch() {
	local dataset="${1:?ztouch: dataset required}"
	shift
	zfs list -H -o name "$dataset" >/dev/null 2>&1 || zfs create "$@" "$dataset"
}
```

`zfs create` (without `-p`) requires every ancestor dataset to already
exist. `zbamidbar/foundation.zfs/foundations` is never created by anything
— not by `stage0-bootstrap.sh`, not by `new_foundation.sh` itself before
this call — so this fails on a completely fresh, correctly-bootstrapped
system every single time a foundation build reaches this step:

```
==> Archiving to zbamidbar
cannot create 'zbamidbar/foundation.zfs/foundations/stable15': parent does not exist
```

Combined with the [04](04-cleanup-trap-destroys-completed-build-on-late-failure.md)
issue, this failure is also `set -eu`-fatal and triggers the same
unconditional `cleanup()` trap — meaning a from-scratch `new_foundation.sh`
run can *never* successfully reach the end of `main()` as written, because
the very step meant to preserve the build's output is the one guaranteed
to blow up.

## How we hit it

On this VM, a full `buildworld`/`buildkernel`/install/`distribution` +
`commit_build` (git commit and push to `zbamidbar/foundation.git`) all
completed successfully — confirmed via `git -C /zbamidbar/foundation.git
log -1 --format='%s' stable15` matching the artifact name from the run's
own log. The very next step, `archive_to_zbamidbar`, failed immediately
with the "parent does not exist" error above.

This time the transient workspace (`zshemot/buildspace/stable15`,
1.83G) survived the cleanup trap intact (likely because `zfs destroy -r`
hit a busy/mounted child dataset and silently failed under the trap's
`2>/dev/null || true`) — but the recursive snapshot the script had just
taken (`zshemot/buildspace/stable15@<artifact>`) did *not* survive,
so recovery still required manually re-snapshotting before completing the
send by hand.

## Suggested fix

Either:
- Add `-p` to the `ztouch` call in `archive_to_zbamidbar` (simplest, and
  arguably what `ztouch` should always do, since its whole purpose is
  "create if missing" — a missing parent is just a deeper case of
  "missing"), or
- Have `stage0-bootstrap.sh`'s `create_datasets()` create
  `zbamidbar/foundation.zfs/foundations` explicitly, matching the
  `zbamidbar/container-data` / `zbamidbar/system-data` pattern used for the
  other per-name parent datasets.

Either fix alone resolves it; doing both would be the most consistent with
how the rest of the dataset hierarchy is defined up front in
`stage0-bootstrap.sh`.
