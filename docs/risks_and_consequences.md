# Risks & Consequences

An honest assessment of where parasa stands, what could go wrong, and what
the design commits us to. Written from the perspective of the person who
will be running this on real hardware with real data.

---

## 1. The creation-maintenance gap

Parasa can create foundations, systems, containers, and deploy them. It
cannot yet save, diff, or rebase any of them. This is the entire reason
the project exists — tracking the distance between pristine and
customized — and the feature that closes that loop is unbuilt.

**Consequences:**

- Deploying a system today means maintaining it by hand until `parasa_save`
  and `parasa_update` exist. Every manual change drifts further from the
  model.
- The longer a deployed system runs without save/rebase tooling, the harder
  the eventual first rebase becomes. Untracked drift accumulates and the
  classification burden on first save grows proportionally.
- There is a temptation to treat the creation side as "done" and deploy.
  But deploying without the update path locks you into the old maintenance
  model — the one parasa was built to replace.

**The hard choice:** either delay real deployment until the rebase pipeline
works end-to-end, or accept that the first deployed systems will need a
painful manual migration when the tooling catches up.

---

## 2. The rebase cliff

The rebase feature is the most complex part of the system and it touches
every subsystem simultaneously: git branching, ZFS send/recv, mtree
comparison, derivation regeneration, compose.sh replay, and package
management. It is also the feature with:

- Zero implementation
- Zero tests
- The highest stakes (operating on live, customized systems)
- The most open design questions (conflict resolution strategy, compose/git
  ordering, package upgrade interactivity)

Building rebase last means building the hardest thing with the least room
for iteration. Every design decision made in the creation scripts
constrains the rebase implementation — foundation naming, .foundation file
semantics, git branch topology, recipes directory layout. If any of those
turn out to be wrong for rebase, they'll need to be reworked across
multiple already-tested scripts.

---

## 3. Mock-only testing

All 2,500+ lines of tests mock ZFS, git, and filesystem operations. They
validate shell logic, argument parsing, and control flow — but they cannot
catch:

- Real ZFS send/recv failures (partial receives, interrupted streams)
- Git merge conflicts on actual file content
- mtree mismatches caused by real permission/flag differences
- Timing issues between mount/unmount and dataset operations
- GELI interaction failures

The first real run on hardware will exercise a fundamentally different code
path than the test suite does. Mock-based tests give confidence in the
logic layer but zero confidence in the integration layer. This is fine for
scripts that are simple wrappers around system calls, but it is dangerous
for scripts that orchestrate multi-step ZFS/git transactions.

**Risk:** a test suite that passes provides false confidence that the
system works. The actual failure surface is in the seams between mocked
components.

---

## 4. No operation is atomic

Every multi-step operation can leave the system in a half-finished state if
interrupted:

| Operation | Failure point | Broken state |
|-----------|--------------|--------------|
| `new_foundation` | Interrupted during `zfs send` to sinai.zfs | Partial snapshot in archive pool |
| `new_system` | Interrupted after dataset creation, before git commit | Orphaned datasets with no tracking branch |
| `new_container` | Interrupted after jail.conf write, before git push | Jail config references nonexistent container |
| `deploy_system` | Interrupted between `zfs recv` and git checkout | Foundation code on disk, system deltas missing |
| `save` (planned) | Commit 1 succeeds, commit 2 fails | State recorded but recipe lost — next rebase uses stale recipe |

No script has rollback logic. Cleanup traps exist for some operations
(workspace teardown) but not for the data-level operations that matter
most. Recovery from a half-finished operation is manual.

**Consequence:** every destructive operation is a small bet that nothing
will go wrong mid-execution. Over years of operation, that bet will
eventually lose.

---

## 5. GELI encryption with no backup keys

`stage0-bootstrap.sh` uses `geli init -B none` for all three pools. The
docs note "add to datalake later" but this creates a circular dependency:
the datalake (zbamidbar) is itself GELI-encrypted with no backup key.

If the GELI metadata sector on any disk is corrupted — bad sector, firmware
bug, interrupted write during resize — the entire pool becomes
unrecoverable. For zbamidbar, this means losing all foundation archives,
git repositories, and package databases. For zshemot, this means losing the
FreeBSD source tree and the parasa repository itself.

The backup key procedure needs to happen immediately after bootstrap, not
"later." And the backup keys need to be stored off-machine (USB drive,
paper, separate host) since storing them on another GELI pool creates a
key-dependency chain where one disk failure can cascade.

---

## 6. zbamidbar is a single point of failure

zbamidbar holds:
- `sinai.git` — all foundation, system, and container git branches
- `sinai.zfs` — all foundation ZFS archives
- `parasa.git` — the parasa repository (recipes, recipes, compose scripts)
- Per-system and per-container data datasets

There is no documented backup strategy. If zbamidbar is lost, the entire
rebuild path is gone — you have running systems on zbereshit but no way to
reproduce, update, or rebase them. The zshemot pool (source tree + parasa
working copy) can rebuild foundations, but all system/container deltas,
compose scripts, and package lists are gone.

This is architecturally fragile for a system whose core value proposition
is reproducibility.

---

## 7. The .git accumulation problem

Every foundation archive includes `.git` from the build workspace. Every
system and container cloned from that foundation inherits it. Over time:

- Each clone carries an independent `.git` that grows with each local
  commit
- ZFS deduplication across clones doesn't apply to `.git` (different
  object hashes per clone)
- `git gc` must run independently in each deployed system/container
- Foundation updates create new `.git` ancestry that doesn't share objects
  with the old one

This is a slow leak, not an emergency. But it means disk usage grows
non-linearly with the number of deployed targets, and the problem gets
harder to fix the longer it runs. The design docs acknowledge this but
defer it. Every deferred cycle makes the eventual fix more disruptive —
more deployed systems carry the embedded `.git`, and any fix requires
touching all of them.

**Options (each with tradeoffs):**
- Strip `.git` from archives → lose the ability to diff against foundation
  in-place
- Move `.git` to a separate dataset → complicates the mount topology
- Accept and gc periodically → operational burden that scales with targets
- Use a shared bare repo with worktrees → changes the branching model

---

## 8. Workspace mount contention

The workspace system (`workspace.sh`) mounts and unmounts shared datasets
(`sinai.git`, `sinai.zfs`, `torah`) without coordination. There is no
reference counting, locking, or mount broker.

As a single operator, this feels safe — you run one operation at a time.
But even solo operation has race windows:

- Kick off a foundation build (long-running), then create a container
  while waiting
- Foundation build finishes first, unmounts sinai.git
- Container creation fails mid-push because sinai.git disappeared

The `zwith` helper in `helpers.sh` partially addresses this (it checks
`mounted` before unmounting), but workspace.sh doesn't consistently use
`zwith` for all shared dataset access. Some mounts go through `zmount`/
`zunmount` directly.

**Consequence:** the system is safe for strictly sequential single-operator
use. Any deviation from that — including the natural human behavior of
multitasking during a long build — can cause failures that are hard to
diagnose (the error message will be about a git push failure, not about a
dataset that was unmounted out from under you).

---

## 9. The classification burden on first save

The first time `parasa_save` runs against a system that has been manually
maintained, `parasa-diff` will flag every change since the foundation was
laid down. For a system that has been running for weeks or months, this
could mean:

- Dozens of modified text configs (auto-classified, manageable)
- Several derived binaries (auto-classified if in derivations.db)
- An unknown number of environment state files (SSH keys, certs, local
  scripts, downloaded tools, build artifacts)
- An unknown number of opaque binaries from package post-install scripts

Every unclassified binary requires a manual decision: derived, environment,
or command. Every "command" classification requires the admin to remember
or reconstruct the command that produced it. Every "skip" blocks future
rebase.

This is a one-time cost per system, but it is front-loaded and painful. A
system with heavy customization could require an hour of interactive
classification work before the first save completes. And if the admin gets
a classification wrong, the error compounds silently through every future
rebase.

---

## 10. compose.sh as root-privileged replay

During rebase, `compose.sh` is sourced and executed as root. This is
necessary — the commands it records (custom binary generation, proprietary
tool invocation) genuinely need root. But it means:

- A typo in compose.sh during initial classification gets replayed on every
  future rebase
- There is no sandbox, no dry-run for compose commands, no rollback if a
  compose command fails
- If a compose command's behavior changes between FreeBSD versions (flag
  renamed, binary moved), the rebase silently produces wrong output or
  fails
- Compose scripts accumulate entries over the system's lifetime but are
  never pruned — dead entries (for software that's been removed) still run

The risk isn't malice — it's human error compounded by automated replay.
A bad compose entry is the kind of bug that hides for months and surfaces
during an upgrade, which is exactly when you want the fewest surprises.

---

## 11. Deploy is a one-way door without nextboot

`deploy_system` sends a foundation to zbereshit and applies the system's
git branch on top. If the deployed system doesn't boot:

- With `-n` (nextboot): the system automatically reverts to the previous
  boot environment on next reboot. This is the safe path.
- Without `-n`: the system boots into the new environment permanently. If
  it doesn't come up (kernel panic, misconfigured rc.conf, broken fstab),
  recovery requires physical console access or a rescue boot.

The `-n` flag is optional, not default. The safe behavior should be the
default behavior, with a `-f` (force/permanent) flag for the dangerous
case. As designed, the most common invocation (`deploy_system -s myhost`)
takes the riskier path.

---

## 12. Dry-run gives false confidence

Dry-run mode (`-d`) wraps commands in a `run()` helper that prints instead
of executing. But:

- Real filesystem checks happen outside the dry-run guard
  (`get_artifact_name` checks `[ -d /zshemot/torah/.git ]` regardless of
  mode — known bug, noted in test comments)
- Dry-run can't simulate ZFS dataset state, so operations that branch on
  "does this dataset exist?" follow different paths in dry-run vs. real
  execution
- Dry-run doesn't exercise error paths or cleanup traps

The result: dry-run shows you what *would* happen assuming everything
exists and succeeds. It doesn't show you what happens when things don't
exist or when commands fail. For a complex multi-step operation, this is
the difference between "here are the commands" and "here is what will
actually happen to your system."

---

## 13. Dataset proliferation over time

Each system/container creates datasets on zbamidbar for var, usr/local,
home (optionally per-user), tmp, and any custom mounts. Each foundation
creates datasets on both zbamidbar/sinai.zfs and zbereshit/foundations.

Over the lifetime of a machine:
- Destroyed containers leave datasets on zbamidbar unless explicitly cleaned
  (destroy logic is unimplemented)
- Old foundation snapshots accumulate on zbereshit/foundations (cleanup
  logic described but unimplemented)
- Shared datasets (`# shared` in mount.fstab) have no reference counting —
  it's a comment-based convention with no enforcement

There is no `parasa_gc` or `parasa_status` command that shows orphaned
datasets, unused foundation snapshots, or dangling shared dataset
references. The admin must manually audit `zfs list` output.

---

## 14. The gap between docs and implementation

The documentation describes a complete system: bootstrap through save
through rebase through destroy. The implementation covers bootstrap
through deploy. This gap creates two risks:

1. **Design drift:** decisions made in docs months ago may not survive
   contact with implementation. The save workflow doc is 31 lines; the
   actual implementation will be hundreds. Undocumented edge cases will
   force design changes that retroactively invalidate earlier decisions.

2. **Scope pressure:** the docs describe features (destroy, edit, list,
   garbage collection, status) that are necessary for a complete system but
   not for the core rebase loop. The temptation to build these before
   rebase is strong — they're simpler, more satisfying, and produce visible
   progress. But they don't close the creation-maintenance gap.

---

## 15. FreeBSD version coupling

parasa is tightly coupled to FreeBSD's specific tools and conventions:

- `sysrc` for config file parsing
- `mtree` for filesystem manifests
- `geli` for encryption
- `jail(8)` for containers
- `pwd_mkdb`, `cap_mkdb`, `newaliases` for derivations
- FreeBSD's specific `/etc` layout and file ownership conventions

A FreeBSD major version upgrade could change any of these. The
derivations.db is version-pinned (`15.0.db`), which helps, but the
scripts themselves embed assumptions about tool flags, file paths, and
command behavior. There is no version compatibility matrix and no
mechanism to detect "you're running parasa scripts designed for 15.x
against a 16.x system."

This isn't a bug — parasa is explicitly a FreeBSD tool. But it means major
FreeBSD upgrades may require parasa itself to be updated before it can
perform the rebase, creating a chicken-and-egg problem: you need parasa to
rebase, but parasa needs updating to work with the new version.

---

## Summary: what to do about all this

The risks above fall into three categories:

**Blocking (must address before relying on parasa for real systems):**
- GELI backup keys (risk 5) — one hardware event away from total loss
- zbamidbar backup strategy (risk 6) — same, at the pool level
- Implement save + rebase before deploying (risks 1, 2) — or accept that
  deployed systems will need manual migration

**Important (should address before the system matures):**
- Atomicity / rollback for multi-step operations (risk 4)
- Workspace mount coordination (risk 8)
- Make nextboot the default for deploy (risk 11)
- Fix dry-run to not leak real filesystem checks (risk 12)
- Build integration tests on real ZFS/git (risk 3)

**Long-term (architectural debt that compounds):**
- The .git accumulation problem (risk 7)
- Dataset proliferation and garbage collection (risk 13)
- compose.sh auditing and pruning (risk 10)
- FreeBSD version compatibility detection (risk 15)
- Close the docs-implementation gap by building rebase next (risk 14)
