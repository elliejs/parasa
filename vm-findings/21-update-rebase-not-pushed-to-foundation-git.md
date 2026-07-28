# `update.sh` replays the delta locally but never pushes it — foundation.git lags the update

**Files:** `scripts/update.sh`, `scripts/finalize_update.sh`, `scripts/save.sh`
**Severity:** Consistency gap — the git mirror falls out of sync with the running tree.

## The gap

`update.sh` rebases the workspace's delta branch (`<kind>s/<name>`) onto
the target foundation commit **in the `-new` tree's local git**, but never
pushes it to `foundation.git`. The only thing that pushes is
`finalize_update` → `save.sh` (step 6). So between `update` and a
successful `finalize` — or if finalize's save step doesn't run — the
authoritative `foundation.git` branch does **not** reflect the update.

Confirmed after the demo1 → 15.0releng cycle: `foundation.git`'s
`containers/demo1` branch tip still reads the pre-rebase
`stable-15_..._stable15 set hostname` commit, even though the running
container is now the rebased-onto-15.0releng tree. The rebased delta lives
only in the deployed container's local `.git`.

(In this proof-out, finalize's swap was completed by hand and its `save`
step was skipped, which is why the branch is stale — but the deeper point
stands: `update.sh` producing a validated `-new` without persisting its
git state means the mirror is only made consistent as a side effect of
finalize's save, which is fragile.)

## Impact

The "content branch in foundation.git" plane of the mirror lags reality
between update and finalize. If `-new` is discarded, no harm; but if it's
finalized via a path that doesn't run `save` (or `save` fails), the
deployed tree and its tracked branch diverge silently.

## Suggested fix

Have `update.sh` push the rebased branch to `foundation.git` as part of
building `-new` (or to a `<kind>s/<name>-new` ref), so the git mirror
reflects the update independently of finalize. Make finalize's `save`
non-optional / robust, and reconcile the branch name on swap.
