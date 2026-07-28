# Untested branches + accumulated cruft (housekeeping)

**Severity:** Low — known-untested code paths and leftover state from the proof-out.

## Untested code paths

- **Rebase conflict handling** (`update.sh` Step 4). demo1's delta (a few
  `/etc` files) replayed onto 15.0releng with zero conflicts, so the
  interactive resolve loop and the `-q` "abort on conflict" path never
  ran. A real cross-version update with overlapping `/etc` edits will
  exercise it; it's unproven.
- **Incremental foundation send** (`helpers.sh ensure_foundation_on_zbereshit`,
  the `zfs send -i` branch). Only the first-artifact **full** send path was
  exercised (each foundation here has one artifact). The incremental path
  (a newer artifact of an already-materialized branch) has never run.
- **finding 16 (`zunmount` unguarded)** remains open and is the exact
  busy-unmount footgun that bit `finalize_update` repeatedly. Guarding
  `zunmount`'s `zfs set mountpoint=none` (like the explicit `zfs unmount`
  already is) would pre-empt a whole class of these failures.

## Leftover state on this VM (not code, but should be cleaned)

- `zbamidbar/foundation.git` carries `filter-branch` `refs/original/*`
  backups and unreferenced objects from the untrack migration — run
  `git -C /zbamidbar/foundation.git for-each-ref --format='%(refname)'
  refs/original | xargs -n1 git update-ref -d` then `git gc --prune=now`.
- `zbamidbar/foundation.git@pre-untrack-migration` (migration backup
  snapshot) can be destroyed once the rewrite is trusted.
- An `@update-<timestamp>` data snapshot survives on `container-data/demo1`
  after finalize (from the promoted `-new` data clone); harmless but cruft.

## Process note

The one-time untrack migration (removing `var/usr-local/tmp/home/dev` from
existing foundation + container branches) was done as manual
`git filter-branch` surgery. There is no in-repo `migrate`/`fsck` tool to
do it, so any other pre-fix foundation would need the same hand-work. A
small `parasa migrate` (or a check in `doctor.sh`) would make it
repeatable.
