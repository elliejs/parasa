# A transient busy-unmount at the end of `new_foundation.sh` masks a fully-successful build (exit 255)

**Files:** `scripts/helpers.sh` (`zunmount`), `scripts/new_foundation.sh` (`main` tail)
**Severity:** Bug — a completely successful foundation build+archive reports
failure (exit 255) and suppresses its success message.

## What happened

`release150` (releng/15.0) built and archived successfully — world built,
committed to `foundation.git` as the `release150` orphan branch, ZFS
archive + snapshot created at
`zbamidbar/foundation.zfs/foundations/release150`, transient workspace
destroyed. Then the very last cleanup died:

```
==> Destroying transient workspace
cannot unmount '/zbamidbar/foundation.git': pool or dataset is busy
EXIT_CODE=255
```

`main()`'s tail is:
```sh
wipe_workspace
run zunmount zbamidbar/foundation.git   # <- dies here
run zunmount zbamidbar/foundation.zfs
run zunmount zshemot/src.git
progress "Foundation '${FOUNDATION_NAME}' created successfully."
```

and `zunmount` is:
```sh
zunmount() {
	local dataset="${1:?zunmount: dataset required}"
	sync
	zfs unmount "$dataset" 2>/dev/null || true   # explicit unmount: failure swallowed
	zfs set mountpoint=none "$dataset"           # NOT guarded
}
```

The explicit `zfs unmount` failure is swallowed by `|| true`, but the
subsequent `zfs set mountpoint=none` *also* has to unmount the dataset to
change its mountpoint — and that hit the same "busy" condition, returned
nonzero, and under `set -eu` killed the whole script with zfs's 255. So:

- The build was 100% successful (verified: archive dataset + snapshot
  exist, `release150` is a proper disjoint orphan branch in
  foundation.git).
- But the script exited 255 and never printed "created successfully",
  and left `foundation.git` (and the following `foundation.zfs`,
  `src.git`) mounted.

## Why was it busy?

Not definitively pinned, but the likely causes are (a) git's post-push
housekeeping (`git gc --auto` / quarantine cleanup) briefly holding the
bare repo right after `commit_build` pushed to it, or (b) this VM's known
flaky VFS. Either way it's transient and, importantly, *harmless* — it's a
cleanup unmount after all real work is done.

## Impact

A green build looks red. Anything scripting `new_foundation.sh` and
checking its exit code would treat a perfect build as a failure, and a
user sees no success message. It also leaves working datasets mounted.

## Suggested fix

1. Guard the mountpoint reset in `zunmount` the same way the explicit
   unmount is guarded (cleanup should never be fatal):
   ```sh
   zunmount() {
       local dataset="${1:?zunmount: dataset required}"
       sync
       zfs unmount "$dataset" 2>/dev/null || true
       zfs set mountpoint=none "$dataset" 2>/dev/null || true
   }
   ```
2. Optionally retry the unmount briefly (a transient post-push git-gc
   reference clears in a second or two), and/or move the final working-set
   unmounts so a cleanup failure can't discard the success signal — the
   "created successfully" message and exit status should reflect that the
   build+archive+commit all succeeded, independent of whether an unmount
   raced.
