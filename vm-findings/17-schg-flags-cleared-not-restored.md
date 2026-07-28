# `schg` flags cleared for the rebase but never restored — update silently drops immutability

**Files:** `scripts/update.sh`, `scripts/helpers.sh` (`clear_mtree`/`apply_mtree`)
**Severity:** Bug — a security-hardening regression on every update.

## The gap

FreeBSD's `installworld` sets `schg` (system-immutable) on critical binaries
(`sbin/init`, `libexec/ld-elf.so.1`, `lib/libc.so.7`, setuid `passwd`/`su`/…).
git cannot modify `schg` files, so `update.sh` (correctly) runs
`clear_mtree` (`chflags -R noschg`) on the `-new` tree before the rebase.

But **nothing ever re-applies the flags.** parasa ships `apply_mtree`
(restore perms/flags from a recipe's `mtree.dist`) precisely for this —
the mtree model is "strip flags so git can work, *restore after*" — yet
neither `update.sh` nor `finalize_update.sh` calls it. So after an update
the container/system runs with **no `schg` on its base binaries**.

Confirmed on this VM after the demo1 → 15.0releng update:
`ls -lo /containers/demo1/sbin/init` shows no `schg` flag.

## Impact

Every updated workspace loses base-binary immutability (a real hardening
property). The mtree derivation model is only half round-tripping: the
strip half runs, the restore half doesn't.

## Suggested fix

After the rebase + recipe (and before finalize, or in finalize), run
`apply_mtree "$new_root" "$RECIPE_DIR" ...` (or regenerate + apply) to
restore flags from the recipe's `mtree.dist`. New deploys have the same
latent gap — `deploy_*` clone a foundation (whose flags are preserved by
ZFS) but any git checkout over it would hit the same wall; ensure flags
are restored wherever git mutates a tree.
