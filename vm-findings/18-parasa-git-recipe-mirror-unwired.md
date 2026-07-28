# The `parasa.git` recipe mirror is never wired — the parallel config git stream is a stub

**Files:** `scripts/stage0-bootstrap.sh`, all recipe-touching scripts
**Severity:** Missing feature / ideological gap.

## The gap

The intended architecture (per the "everything mirrors everything" model):
foundations are mirrored across zshemot (build) / zbamidbar (zfs archive +
`foundation.git` branch) / zbereshit (available); **recipes roll into their
OWN git in parallel — `zbamidbar/parasa.git`.**

`stage0-bootstrap.sh` dutifully creates the bare `zbamidbar/parasa.git`
dataset. But **nothing ever pushes the parasa repo (scripts +
`recipes/` + `foundations/<name>/build.cfg`) to it.** A grep of the
scripts for `parasa.git` finds zero push/remote/clone wiring. So the
config/recipe mirror plane exists as an empty bare repo and is never
populated.

## Impact

The four-plane *foundation* mirror is real and consistent. The *recipe/
config* mirror — the parallel git stream that's supposed to track
foundation `build.cfg`, per-system/container recipes (`jail.conf`,
`mount.fstab`, `pkg.list`, `derivations.local`, `mtree.dist`), and
`.foundation` pointers — is not implemented. There's no on-box source of
truth/history for config independent of the working checkout.

## Suggested fix

Wire `zshemot/parasa`'s git remote to `zbamidbar/parasa.git` (init/clone
against it in bootstrap or first run), and push after the operations that
change recipes: `new_foundation` (build.cfg), `new_system`/`new_container`
(recipe dir), `save`/`finalize_update` (recipe updates). Then the recipe
stream mirrors alongside the `foundation.git` content stream as intended.
