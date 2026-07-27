# VM findings

Notes from proving out `parasa` end-to-end on a scratch FreeBSD 15.1-RELEASE
VM (2 vCPU, 2G RAM, three `md(4)`-backed disks standing in for real ones).
Full control of the VM was available; the goal was to exercise the real
scripts (not just read them) through stage0 bootstrap, a foundation build,
a container, and starting that container.

Each file below is one finding. Severity/status is noted at the top of
each. This directory will grow as later stages (foundation build, container
deploy, jail start) are exercised — see the repo's own conversation history
for live status.

| # | Finding | Severity |
|---|---|---|
| [01](01-stage0-running-disk-check-is-dead-on-zfs-root.md) | `running_disk()` safety check never fires on ZFS-root systems | Bug (safety-relevant) — **FIXED** in `093c870` |
| [02](02-no-deploy-container.md) | No `deploy_container.sh` — containers never get a populated root | Gap (missing feature) — **FIXED** in `093c870` |
| [03](03-environment-notes-not-parasa-bugs.md) | VM environment quirks that look like parasa bugs but aren't | Informational |
| [04](04-cleanup-trap-destroys-completed-build-on-late-failure.md) | `cleanup()` trap destroys a fully-built foundation if the final git commit fails | Bug — open |
| [05](05-zmount-not-idempotent-breaks-retries.md) | `zmount()` isn't idempotent — breaks retries, and breaks a normal first run too | Bug — fix proposed |
| [06](06-missing-foundation-zfs-foundations-parent-dataset.md) | `archive_to_zbamidbar()` always fails: missing `foundations` parent dataset | Bug — fix proposed |
| [07](07-ws-begin-explicit-mount-collides-with-recv-automount.md) | `ws_begin()`'s explicit mount collides with `zfs recv`'s auto-mount | Bug — fix proposed |
| [08](08-recv-inherits-stale-mountpoint-through-chain.md) | Workspace receives inherit the foundation's literal mountpoint instead of their own | Bug — fix proposed |
| [09](09-jail-conf-include-path-typo.md) | `recipes/jail.conf`'s `.include` path points at the wrong dataset | Bug — **FIXED** in `16fdb58` |
| [10](10-container-home-mountpoint-never-created.md) | Container `mount.fstab` references `/home`, nothing creates it | Bug — **FIXED** in `16fdb58` |
| [11](11-jail-conf-no-networking-default.md) | Default `jail.conf` never enables networking — containers have no network access | Bug — fix proposed |
| [12](12-diff-sh-piped-while-loop-subshell-breaks-everything.md) | `diff.sh`'s piped `while read` loop breaks the entire save pipeline | Critical — fix proposed |
| [13](13-save-sh-pkg-info-missing-a-flag.md) | `save.sh`'s `pkg info` call is missing `-a`, fails immediately | Bug — fix proposed |
| [14](14-save-sh-never-mounts-foundation-git.md) | `save.sh` never mounts `zbamidbar/foundation.git` before pushing to it | Bug — fix proposed |

## What worked

Stage0 bootstrap (`stage0-bootstrap.sh`) ran cleanly end-to-end on real `md`
disks: correct GPT layout on the boot disk, GELI encryption on all three
pools, `zpool`/`zfs`/`geli`/`glabel` state exactly matching the documented
design in `docs/stage0_bootstrap.md`. No crashes, no `set -eu` aborts, no
partial state. See finding 03 for the one piece of test-harness friction
that was environmental, not a parasa defect.

## End-to-end result

With the fixes proposed alongside findings 05–09 applied (all in this
branch's history — see individual findings for exact commits) and manual
workarounds for 04, 06, and 10 where a fix wasn't a clean drop-in, the
full pipeline was proven out on this VM: `stage0-bootstrap.sh` →
`new_foundation.sh` (real `buildworld`/`buildkernel`/`installworld`/
`installkernel`/`distribution` against `stable/15`, ~2.5h on 2 vCPU/2G
RAM) → `new_container.sh` → `deploy_container.sh` → `jail(8)`. The
resulting jail (`demo1`) is genuinely running: correct hostname, `cron`
active, `.git` present in its root (the git-tracked customization layer
works), and its ZFS dataset properly mounted as `/` inside the jail —
confirmed via `jexec demo1 uname -a` / `id` / `ps aux`, not just `jls`
reporting ACTIVE.

Findings 04, 09, and 10 were fixed upstream directly (commit `16fdb58`).
Everything else (05–08, 11–14) has a proposed fix in this branch's
commit history, verified against real runs on this VM. Finding 04 is the
only one still fully open with no drop-in fix in this branch — its
upstream fix (preserve the workspace on late failure, pre-flight git
identity check) is a design-level change we didn't attempt to duplicate
locally.

## Save pipeline: also proven end-to-end

Installed and started `nginx` inside the running `demo1` jail as real
"drift" to test `diff.sh`/`save.sh` against (see findings 11 for the
networking fix that was needed just to get `pkg` working inside the jail
at all). This surfaced three more bugs (12, 13, 14) that, once fixed,
let `save.sh -s demo1 -k container -q -m "..."` complete cleanly in a
single pass: diff check → package-list capture → mtree regeneration →
state commit + push to `foundation.git` → recipe commit — confirmed with
a real change (`sysrc hostname=...`) captured end-to-end, `exit 0`.
Finding 12 in particular was save-pipeline-breaking: `diff.sh` could
never succeed in the exact mode `save.sh` uses it in, for any real save
scenario, regardless of whether there was anything to complain about.
