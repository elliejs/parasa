# Known Risks and Open Questions

Summary of architectural risks and unresolved design questions. For the
full analysis, see [risks_and_consequences.md](../risks_and_consequences.md).

## Critical (address before relying on parasa for real systems)

### GELI backup keys

`stage0-bootstrap.sh` uses `geli init -B none` for all pools. No backup
keys are created. One hardware event (bad sector, firmware bug, interrupted
write) on any disk makes the entire pool unrecoverable. Backup keys need
to happen immediately after bootstrap and be stored off-machine.

### zbamidbar is a single point of failure

zbamidbar holds all git branches, all ZFS archives, all recipes, and all
data datasets. No backup strategy is documented. If zbamidbar is lost,
running systems on zbereshit exist but can't be reproduced, updated, or
rebased.

### Mock-only testing

All tests mock ZFS, git, and filesystem operations. They validate shell
logic but cannot catch real ZFS send/recv failures, git merge conflicts
on actual content, mtree mismatches, or timing issues. The first real
run on hardware exercises fundamentally different code paths.

## Important (address before the system matures)

### No operation is atomic

Every multi-step operation can leave half-finished state if interrupted.
No script has rollback logic beyond cleanup traps for workspace teardown.
Recovery from a half-finished operation is manual.

### Workspace mount contention

Scripts mount/unmount shared datasets (foundation.git, foundation.zfs)
without coordination. There is no reference counting or locking. Safe for
strictly sequential single-operator use. Concurrent operations (e.g.,
building a foundation while creating a container) can cause failures.

### Deploy defaults to the riskier path

`deploy_system` without `-n` deploys permanently. With `-n`, it uses
nextboot (one-shot with auto-revert). The safe behavior (nextboot) should
arguably be the default.

## Long-term architectural debt

### The .git accumulation problem

Every foundation archive includes `.git` from the build workspace. Every
clone inherits it. Over time, each clone carries an independent `.git`
that grows. ZFS dedup doesn't help (different object hashes). Options:
strip from archives, move to separate dataset, accept and gc periodically,
or use shared bare repo with worktrees.

### Dataset proliferation

Destroyed containers/systems leave datasets on zbamidbar unless explicitly
cleaned. Old foundation snapshots accumulate. Shared datasets have no
reference counting (comment-based convention only). No `parasa_gc` or
`parasa_status` command exists.

### compose.sh as root-privileged replay

compose.sh is sourced and executed as root during every rebase. Typos
during classification get replayed forever. No sandbox, no dry-run, no
rollback. Dead entries for removed software still run. The risk is human
error compounded by automated replay.

### FreeBSD version coupling

Scripts embed assumptions about FreeBSD tool flags, file paths, and
command behavior. A FreeBSD major upgrade could break parasa before parasa
can perform the rebase -- chicken-and-egg.

## Unimplemented features

| Feature | Status |
|---------|--------|
| `destroy_system` / `destroy_container` | Planned, not started |
| `clone_container` | Planned, not started |
| `edit_system` / `edit_container` | Planned, not started |
| `deploy_container` | Planned, not started |
| `parasa_gc` (garbage collection) | Planned, not started |
| `parasa_status` (system overview) | Planned, not started |
| Cross-foundation updates (15.0 -> 15.1) | Out of scope for current update.sh |
| Reference-counted mounts / mount broker | Known need, no implementation |
| Integration tests on real ZFS/git | Known need, no implementation |

## Open design questions

1. **The .git problem**: No decision on how to solve the embedded .git in
   foundation archives. See options above.

2. **mount.fstab ZFS backing**: The exact mechanism for getting ZFS
   datasets mounted at their zbamidbar paths so that nullfs can overlay
   them into containers.

3. **Foundation replication trigger**: When should
   `zbereshit/foundations/${NAME}@${ARTIFACT}` be created? During
   `new_foundation` (eager)? During first deploy that needs it (lazy)?

4. **System update execution context**: Using chroot + ZFS mounts for v1.
   Whether to support temporary-jail mode or kenv+reboot mode for more
   realistic testing is deferred to v2.
