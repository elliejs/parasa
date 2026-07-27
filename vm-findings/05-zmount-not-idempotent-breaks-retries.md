# `zmount()` isn't idempotent — retrying after a partial failure breaks immediately

**File:** `scripts/helpers.sh`
**Severity:** Bug — makes recovering from any partial/failed run needlessly
manual.

## The code

```sh
zmount() {
	local dataset="${1:?zmount: dataset required}"
	local dest="${2:-/${1}}"
	zfs set mountpoint="$dest" "$dataset"
	zfs mount "$dataset"
}
```

No check for whether `$dataset` is already mounted (at `$dest` or
elsewhere) before calling `zfs mount`. Compare `zwith()` a few lines
below in the same file, which *does* check the `mounted` property first —
`zmount` doesn't.

## How we hit it

After the run documented in [04](04-cleanup-trap-destroys-completed-build-on-late-failure.md)
died late (at the git-commit step) with `set -eu` active, the script's
`main()` never reached its final `zunmount` calls (those run only after
`wipe_workspace`, all downstream of the commit that failed). Datasets
`ensure_src_tree` and `prepare_workspace_git` had mounted —
`zshemot/src.git` and `zbamidbar/foundation.git` — were simply left
mounted when the process exited.

Re-running `new_foundation.sh -s stable15` immediately afterward failed
on the very first `zmount` call:

```
==> Preparing source tree (zshemot/src.git)
cannot mount 'zshemot/src.git': filesystem already mounted
```

— because `zshemot/src.git` was still mounted (at the *correct* path,
even) from the previous attempt, and `zfs mount` refuses to mount an
already-mounted filesystem. `set -eu` turns that into an immediate script
death. Had we not caught this manually and unmounted by hand
(`zfs unmount zshemot/src.git zbamidbar/foundation.git`), the same
`zmount` call would have failed identically on every subsequent retry —
there's no path to self-heal.

`zbamidbar/foundation.git` was in the same state for the same reason
(mounted by `prepare_workspace_git`, never unmounted because the script
died before reaching its cleanup).

## Suggested fix

Make `zmount()` check the `mounted` property first, the same way `zwith()`
already does, and no-op (or re-`zfs set mountpoint` + confirm, without
calling `zfs mount` again) if the dataset is already mounted at the
target path:

```sh
zmount() {
	local dataset="${1:?zmount: dataset required}"
	local dest="${2:-/${1}}"
	zfs set mountpoint="$dest" "$dataset"
	if ! yesish "$(zfs get -H -o value mounted "$dataset" 2>/dev/null)"; then
		zfs mount "$dataset"
	fi
}
```

More broadly: none of the stage1+ scripts unmount their working datasets
on failure (only on the success path, at the very end of `main()`), so
*any* mid-script death leaves state for the next run to trip over. A
shared "unmount everything this script might have mounted" step in the
`EXIT` traps (alongside the existing workspace-destroy cleanup) would
make retries self-healing instead of requiring manual `zfs unmount`
archaeology.
