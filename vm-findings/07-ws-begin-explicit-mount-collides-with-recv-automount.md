# `ws_begin()`'s explicit `zfs mount` collides with `zfs recv`'s auto-mount

**Status: fix proposed in commit `58f3b08`** (not yet reviewed/merged
upstream). Verified on this VM: `new_container.sh` now runs past this
point successfully with the fix applied.

**File:** `scripts/workspace.sh` (`ws_begin()`)
**Severity:** Bug — reproducible on any container/system creation once a
foundation has been correctly archived (mountpoint inherited as expected).

## The code

```sh
zfs send -R "${foundation_archive}@${snap}" | zfs recv "zshemot/buildspace/${WS_NAME}"
zfs mount "zshemot/buildspace/${WS_NAME}"
zfs mount "zshemot/buildspace/${WS_NAME}/var" 2>/dev/null || true
```

## The problem

`zfs recv` (without `-u`) auto-mounts the received filesystem when its
(inherited or local) `canmount`/`mountpoint` properties say it should —
which is exactly the case here: `zshemot/buildspace/<foundation>` was
originally created by `new_foundation.sh`'s `prepare_workspace()` with
`-o mountpoint=... -o canmount=on`, and `zfs send -R` propagates those
properties down through every subsequent replication (the foundation
archive in `zbamidbar/foundation.zfs/<name>`, and now this
receive into `zshemot/buildspace/<container-or-system-name>`). So the
`zfs recv` on line 253 already mounts the dataset as a side effect, and
the explicit `zfs mount` on line 254 immediately after collides with it:

```
==> Receiving foundation to workspace
cannot mount 'zshemot/buildspace/demo1': filesystem already mounted
```

Note the line right below it, mounting the `/var` child dataset, is
already defensively written as `zfs mount ".../var" 2>/dev/null || true`
— whoever wrote this clearly hit (or anticipated) this exact "already
mounted from the recv" collision for the child dataset, but the identical
issue on the parent dataset one line above was missed.

Under `set -eu`, the parent-mount failure is fatal, and (per
[04](04-cleanup-trap-destroys-completed-build-on-late-failure.md)'s
pattern) the `ws_cleanup` trap then destroys the just-received
`zshemot/buildspace/<name>` workspace, so this reliably kills
`new_container.sh`/`new_system.sh` at this step every time, on an
otherwise entirely correct foundation.

## How we hit it

Confirmed on this VM creating a container from a correctly-archived
`stable15` foundation (after fixing [05](05-zmount-not-idempotent-breaks-retries.md)'s
double-mount issue) — died at exactly this line, workspace destroyed by
the cleanup trap immediately after.

## Suggested fix

Apply the same defensive treatment already used for the `/var` line to
the parent mount too, for consistency:

```sh
zfs send -R "${foundation_archive}@${snap}" | zfs recv "zshemot/buildspace/${WS_NAME}"
zfs mount "zshemot/buildspace/${WS_NAME}" 2>/dev/null || true
zfs mount "zshemot/buildspace/${WS_NAME}/var" 2>/dev/null || true
```

(or, more precisely, check the `mounted` property first rather than
blanket-suppressing errors, the same way the `zmount()` fix in
[05](05-zmount-not-idempotent-breaks-retries.md) does — a blanket
`|| true` would also silently swallow a *real* mount failure here, not
just the "already mounted" case).
