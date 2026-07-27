# `running_disk()` safety check never fires on ZFS-root systems

**Status: FIXED** in commit `093c870` ("Fix running_disk() for ZFS-root,
add deploy_container.sh"). `running_disk()` now detects ZFS-root and
resolves the backing device(s) via `zpool status`, handling mirrors
(multi-line output). Verified on this VM: it now correctly resolves to
`vtbd0` (the real boot disk) instead of the dead literal
`zroot/ROOT/default`. The write-up below is kept as the original bug
report.

**File:** `scripts/stage0-bootstrap.sh`
**Severity:** Bug — a safety check that's supposed to prevent destroying the
running system disk is silently dead code on the exact kind of system this
script produces.

## The code

```sh
running_disk() {
	local dev
	dev=$(df / | tail -1 | awk '{print $1}')
	dev="${dev#/dev/}"
	dev="${dev%.eli}"
	printf "%s" "$dev" | sed -E 's/(p[0-9]+|s[0-9]+[a-z]?)$//'
}
```

`prompt_disk`, `prompt_disk_list`, and `assert_not_running` all compare a
candidate disk name against this function's output and refuse to proceed
if they match — the intended guardrail against `stage0-bootstrap`
partitioning the disk the operator is currently booted from.

## The problem

On a ZFS-root system, `df /` reports the **dataset name**, not a device
path:

```
$ df /
Filesystem          Size  Used Avail Use% Mounted on
zroot/ROOT/default  191G  1.7G  190G   1% /
```

`awk '{print $1}'` yields `zroot/ROOT/default`. The subsequent
`${dev#/dev/}` and `${dev%.eli}` are no-ops (no `/dev/` prefix, no `.eli`
suffix to strip), and the `sed` partition-suffix strip
(`s/(p[0-9]+|s[0-9]+[a-z]?)$//`) doesn't match a ZFS dataset name either.
So `running_disk()` returns the literal string `zroot/ROOT/default` — which
can never equal a real disk name like `ada0`, `nvd0`, or `vtbd0` that a
human would type at the prompt. The comparison in `prompt_disk` /
`prompt_disk_list` / `assert_not_running` therefore always evaluates false,
and the "don't touch the running disk" protection never triggers.

**stage0-bootstrap.sh itself only ever produces ZFS-root systems** (it
creates `zbereshit` as the boot pool and installs a UEFI loader against it),
so this isn't an edge case — it's the guaranteed end state of every
successful run of the script. Anyone re-running `stage0-bootstrap.sh` from
a live/rescue environment booted off the very disk they're about to
re-partition will get no protection from this check.

## How we found it

Confirmed on this VM: after bootstrapping, `df /` reports
`zroot/ROOT/default`; typing that system's real underlying disk (`vtbd0`)
back into a fresh `stage0-bootstrap.sh` run's disk prompt is accepted
without complaint (verified by tracing the logic, not by actually
destroying the running disk).

## Suggested fix

Resolve the true backing device for ZFS-root systems, e.g. via
`zpool status -P zroot` (or `bectl`/`zpool list -v`) to walk from the
dataset name to the actual GEOM provider(s), stripping GELI/partition
suffixes from *that*, rather than trying to pattern-match `df`'s output
for both UFS and ZFS in one regex.
