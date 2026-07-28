# No teardown half — the lifecycle is create/forward only

**Files:** (absent) `scripts/destroy_foundation.sh`, `destroy_system.sh`, `destroy_container.sh`
**Severity:** Missing feature.

## The gap

Every verb in parasa is forward: `new_foundation`, `new_system`,
`new_container`, `deploy_*`, `update`, `finalize_update`. The scripts
repeatedly reference `destroy_foundation (future)` / `update_container
(future)` etc. in their error messages, but **no teardown scripts exist.**

A mirror you can only ever add to isn't a lifecycle. In particular, the
incremental-tree model *accumulates*:

- Foundations pile up on `zbereshit/foundations/<name>` (each new branch is
  a full send; each same-branch artifact an incremental) with no way to
  prune old ones.
- `zbamidbar/foundation.zfs/foundations/<name>` archives and
  `foundation.git` branches accumulate with no removal path.
- Containers/systems are CoW clones of foundation snapshots, so a
  foundation can't be freed while any clone depends on it — but there's no
  tool to enumerate/relocate those dependents.

## Impact

No way to retire a foundation, decommission a container/system, or reclaim
space. Over time the pools only grow, and clone dependencies make manual
cleanup error-prone (as seen finalizing demo1: destroying the old data
required promoting the `-new` clones first).

## Suggested fix

Implement `destroy_{foundation,system,container}` that unwind correctly:
stop jails, unmount, `zfs promote` any dependent clones off a
to-be-destroyed snapshot, destroy datasets, delete the `foundation.git`
branch + archive, and remove the recipe. A `destroy_foundation` must
refuse (or relocate) while clones depend on it.
