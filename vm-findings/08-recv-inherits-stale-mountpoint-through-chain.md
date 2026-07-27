# Workspace receives inherit the *foundation's* literal mountpoint instead of their own

**Status: fix proposed in commit `58f3b08`** (not yet reviewed/merged
upstream) — `ws_begin()`'s recv now passes explicit `-o mountpoint`/`-o
canmount`. Verified on this VM: `new_container.sh` now completes
end-to-end with the fix applied. `archive_to_zbamidbar()`'s equivalent
recv was patched the same way but not independently re-verified (would
require rebuilding a foundation from scratch).

**Files:** `scripts/new_foundation.sh` (`archive_to_zbamidbar`),
`scripts/workspace.sh` (`ws_begin`)
**Severity:** Bug — reproducible on any container/system creation, once
you get past findings [05](05-zmount-not-idempotent-breaks-retries.md)
and [07](07-ws-begin-explicit-mount-collides-with-recv-automount.md).

## The mechanism

None of the `zfs send -R | zfs recv` calls in this pipeline pass an
explicit `-o mountpoint=...` override on receive. `zfs recv` without one
inherits the **literal mountpoint string carried in the send stream**,
not a fresh path derived from the receiving dataset's own name.

Trace the chain:

1. `new_foundation.sh`'s `prepare_workspace()` creates
   `zshemot/buildspace/<foundation>` with an explicit
   `-o mountpoint=/zshemot/buildspace/<foundation> -o canmount=on`.
2. `archive_to_zbamidbar()` does `zfs send -R ...@snap | zfs recv -F
   zbamidbar/foundation.zfs/foundations/<foundation>`. The `-F` (force)
   receive overwrites whatever `ztouch` pre-set (`mountpoint=none
   canmount=noauto`) with the stream's actual properties — so the
   archived foundation dataset ends up with `mountpoint=/zshemot/
   buildspace/<foundation>` (the *build-time* path), not `none` as the
   pre-touch suggested.
3. `workspace.sh`'s `ws_begin()` (used by both `new_container.sh` and
   `new_system.sh`) does `zfs send -R "${foundation_archive}@${snap}" |
   zfs recv "zshemot/buildspace/${WS_NAME}"` — receiving into a dataset
   named after the *new* container/system (e.g. `demo1`), but the stream
   still carries `mountpoint=/zshemot/buildspace/<foundation-name>` (e.g.
   `stable15`) from step 2. The received `zshemot/buildspace/demo1`
   dataset inherits that exact literal string, **not**
   `/zshemot/buildspace/demo1`.

`ws_begin()` then computes `WS_PATH="/zshemot/buildspace/${WS_NAME}"`
(`/zshemot/buildspace/demo1`) purely textually and uses it directly:

```sh
git -C "$WS_PATH" checkout -b "${WS_KIND}s/${WS_NAME}" "${FOUNDATION_NAME}"
```

Since the dataset actually mounted itself at the *foundation's* path
(`/zshemot/buildspace/stable15`, which happened to be free since the
foundation's original build workspace had already been torn down) rather
than `/zshemot/buildspace/demo1`, this fails:

```
==> Setting up container branch
fatal: cannot change to '/zshemot/buildspace/demo1': No such file or directory
```

If the foundation's original path *weren't* free (e.g. two containers
created from the same foundation without intervening cleanup, or the
foundation's own workspace still existing for some reason), this would be
worse than a clean "not found" error — two datasets would be fighting
over the same literal mountpoint string.

## How we hit it

Confirmed on this VM creating container `demo1` from the correctly
archived `stable15` foundation, after clearing findings 05 and 07. Not an
artifact of any manual intervention on our part this time — traced
through the actual `zfs send/recv` property-inheritance semantics
(standard, documented ZFS behavior) to confirm this is inherent to the
scripts as written, not VM-specific.

## Suggested fix

Every `zfs recv` in this chain that's meant to land at a path derived
from the *new* dataset's own name should say so explicitly, rather than
relying on inherited properties from the stream:

```sh
zfs send -R "${foundation_archive}@${snap}" \
  | zfs recv -o mountpoint="/zshemot/buildspace/${WS_NAME}" -o canmount=on \
      "zshemot/buildspace/${WS_NAME}"
```

and similarly for `archive_to_zbamidbar()`'s receive, if the intent there
really is `mountpoint=none canmount=noauto` (matching the `ztouch`
pre-set that `-F` currently clobbers):

```sh
zfs send -R "${workspace}@${ARTIFACT_NAME}" \
  | zfs recv -F -o mountpoint=none -o canmount=noauto "$dest"
```
