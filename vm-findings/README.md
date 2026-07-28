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
| [01](01-stage0-running-disk-check-is-dead-on-zfs-root.md) | `running_disk()` safety check never fires on ZFS-root systems | Bug (safety-relevant) — **FIXED** |
| [02](02-no-deploy-container.md) | No `deploy_container.sh` — containers never get a populated root | Gap (missing feature) — **FIXED** |
| [03](03-environment-notes-not-parasa-bugs.md) | VM environment quirks that look like parasa bugs but aren't | Informational |
| [04](04-cleanup-trap-destroys-completed-build-on-late-failure.md) | `cleanup()` trap destroys a fully-built foundation if the final git commit fails | Bug — **FIXED** (`BUILD_COMPLETE` flag) |
| [05](05-zmount-not-idempotent-breaks-retries.md) | `zmount()` isn't idempotent — breaks retries, and breaks a normal first run too | Bug — **FIXED** (checks `mounted` property) |
| [06](06-missing-foundation-zfs-foundations-parent-dataset.md) | `archive_to_zbamidbar()` always fails: missing `foundations` parent dataset | Bug — **FIXED** (`ztouch -p` + doctor check) |
| [07](07-ws-begin-explicit-mount-collides-with-recv-automount.md) | `ws_begin()`'s explicit mount collides with `zfs recv`'s auto-mount | Bug — **FIXED** (tolerant mount after recv) |
| [08](08-recv-inherits-stale-mountpoint-through-chain.md) | Workspace receives inherit the foundation's literal mountpoint instead of their own | Bug — **FIXED** (explicit `-o mountpoint` on all recv calls) |
| [09](09-jail-conf-include-path-typo.md) | `recipes/jail.conf`'s `.include` path points at the wrong dataset | Bug — **FIXED** |
| [10](10-container-home-mountpoint-never-created.md) | Container `mount.fstab` references `/home`, nothing creates it | Bug — **FIXED** |
| [11](11-jail-conf-no-networking-default.md) | Default `jail.conf` never enables networking — containers have no network access | Bug — **FIXED** (`ip4/ip6 = inherit`) |
| [12](12-diff-sh-piped-while-loop-subshell-breaks-everything.md) | `diff.sh`'s piped `while read` loop breaks the entire save pipeline | Critical — **FIXED** (temp file redirect) |
| [13](13-save-sh-pkg-info-missing-a-flag.md) | `save.sh`'s `pkg info` call is missing `-a`, fails immediately | Bug — **FIXED** |
| [14](14-save-sh-never-mounts-foundation-git.md) | `save.sh` never mounts `zbamidbar/foundation.git` before pushing to it | Bug — **FIXED** |

## What worked

Stage0 bootstrap (`stage0-bootstrap.sh`) ran cleanly end-to-end on real `md`
disks: correct GPT layout on the boot disk, GELI encryption on all three
pools, `zpool`/`zfs`/`geli`/`glabel` state exactly matching the documented
design in `docs/stage0_bootstrap.md`. No crashes, no `set -eu` aborts, no
partial state. See finding 03 for the one piece of test-harness friction
that was environmental, not a parasa defect.

## End-to-end result

All 14 findings are now fixed in main. The full pipeline was proven
end-to-end on the VM: `stage0-bootstrap.sh` → `new_foundation.sh` (real
`buildworld`/`buildkernel`/`installworld`/`installkernel`/`distribution`
against `stable/15`, ~2.5h on 2 vCPU/2G RAM) → `new_container.sh` →
`deploy_container.sh` → `jail(8)`. The resulting jail (`demo1`) ran
correctly: proper hostname, `cron` active, git-tracked customization
layer working, ZFS dataset properly mounted as `/` inside the jail —
confirmed via `jexec demo1 uname -a` / `id` / `ps aux`.

## Save pipeline: also proven end-to-end

Installed and started `nginx` inside the running `demo1` jail as real
"drift" to test `diff.sh`/`save.sh` against (finding 11's networking
fix was needed just to get `pkg` working inside the jail). This surfaced
three more bugs (12, 13, 14) that, once fixed, let
`save.sh -s demo1 -k container -q -m "..."` complete cleanly in a
single pass: diff check → package-list capture → mtree regeneration →
state commit + push to `foundation.git` → recipe commit — confirmed with
a real change (`sysrc hostname=...`) captured end-to-end, `exit 0`.

## Post-VM architectural changes

After proving the pipeline, the following structural changes were made
(not yet re-verified on the VM):

- **`.git` as child ZFS dataset**: Foundation archives no longer include
  `.git`. During foundation builds, `.git` is a separate child dataset
  excluded from `zfs send -R` via selective snapshots. Deploy and update
  scripts create `.git` as a child dataset on `zbereshit` too, keeping
  git state out of ZFS send streams everywhere. Backward compat preserved
  for old archives via `[ ! -d .git ]` guard.
- **Mid-script infrastructure removal**: Scripts no longer defensively
  create infrastructure (buildspace dataset, bare repos). They die early
  with a doctor.sh pointer instead. `stage0-bootstrap.sh` and `doctor.sh`
  are the sole owners of infrastructure creation.
- **Fresh git init pattern**: All deploy/workspace/update scripts do
  `git init` + `remote add` + `fetch` after `zfs recv`, instead of
  relying on `.git` from the archive.
