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
| [01](01-stage0-running-disk-check-is-dead-on-zfs-root.md) | `running_disk()` safety check never fires on ZFS-root systems | Bug (safety-relevant) |
| [02](02-no-deploy-container.md) | No `deploy_container.sh` — containers never get a populated root | Gap (missing feature) |
| [03](03-environment-notes-not-parasa-bugs.md) | VM environment quirks that look like parasa bugs but aren't | Informational |

## What worked

Stage0 bootstrap (`stage0-bootstrap.sh`) ran cleanly end-to-end on real `md`
disks: correct GPT layout on the boot disk, GELI encryption on all three
pools, `zpool`/`zfs`/`geli`/`glabel` state exactly matching the documented
design in `docs/stage0_bootstrap.md`. No crashes, no `set -eu` aborts, no
partial state. See finding 03 for the one piece of test-harness friction
that was environmental, not a parasa defect.
