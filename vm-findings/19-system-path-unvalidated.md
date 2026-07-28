# The system half of the mirror is code-complete-by-analogy but never run

**Files:** `scripts/new_system.sh`, `scripts/deploy_system.sh`, `scripts/update.sh` (system branch), `scripts/finalize_update.sh` (system branch)
**Severity:** Untested — a whole symmetric half of the design has zero evidence.

## The gap

Container/system symmetry is core to the ideology. This proof-out
exercised the **container** path exhaustively: `new_container` →
`deploy_container` (clone) → `update` (clone target foundation + replay) →
run/test `-new` → `finalize_update` (swap). demo1 was driven all the way
from a stable/15 base to a 15.0-RELEASE base, live, serving.

The **system** path received the identical rework — clone-from-
`zbereshit/foundations`, data-lake cloning, rebase-onto-target, swap — but
**nothing in it has been run once.** It differs from containers in
non-trivial ways that the container tests did not cover:

- `chroot` instead of `jail`/`jexec` for recipe steps (pre_pkg / pkg
  install / post_pkg / derivation regen).
- Mount tree at `/zbereshit/systems/<name>` (not `/containers/<name>`).
- `nextboot` instead of `jail -c` to activate.
- No devfs/jail lifecycle — different busy/unmount behavior at finalize.

The finalize ZFS-busy bugs (promote-before-destroy, unmount submounts
before destroy/rename) were only found and fixed against the container
path; the system branch has the analogous code but was never stressed.

## Suggested fix

Run a system end-to-end: `new_system` on a foundation → `deploy_system`
→ `update -f <other foundation>` → `finalize_update`, and fix whatever the
untested chroot/nextboot/mount differences surface (they will).
