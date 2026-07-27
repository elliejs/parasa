# Foundation builds share one `/usr/obj` tree → cross-branch stale-object link failures

**File:** `scripts/new_foundation.sh` (`run_build`, `ensure_src_tree`)
**Severity:** Bug — a foundation build's success depends on which *other*
foundations were built before it in the same environment. Directly
undermines the "foundations are segregated" guarantee.

## What happened

Building a second foundation `release150` (`src_branch=releng/15.0`),
purely via `new_foundation.sh`, on a VM where `stable15`
(`src_branch=stable/15`) had already been built earlier. The build ran
~1h40m through cross-tools and most of buildworld, then died at the link
step of `usr.bin/gh-bc`:

```
ld: error: bc_help.pieo: Invalid record
cc: error: linker command failed with exit code 1
*** [bc] Error code 1
make: stopped making "buildworld" in /zshemot/src.git
EXIT_CODE=2
```

## Root cause: shared object tree across foundations

`new_foundation.sh` uses a single FreeBSD source checkout at a fixed path
(`/zshemot/src.git`) for *every* foundation, switching branches in place
(`ensure_src_tree` → `git checkout "$SRC_BRANCH"`). It then runs
`make -C /zshemot/src.git buildworld` with no `MAKEOBJDIRPREFIX` override,
so the object tree is derived from that fixed source path —
`/usr/obj/zshemot/src.git/...` — and is therefore **shared by every
foundation**, regardless of branch.

The evidence is unambiguous. In
`/usr/obj/zshemot/src.git/amd64.amd64/usr.bin/gh-bc/`, the object
timestamps split cleanly into two build eras:

```
10:29  bc_help.pieo      <- stable15 build (this morning)
10:29  dc_help.pieo      <- stable15 build
10:29  lib.pieo          <- stable15 build
10:29  lib2.pieo         <- stable15 build
14:19  bc.pieo, num.pieo, lex.pieo, ... (everything else)  <- release150 build
```

The four stale 10:29 objects are exactly the ones compiled from
**generated** source files (`bc_help.c`, `dc_help.c`, `lib.c`, `lib2.c`,
produced by gh-bc's build-time `gen/strgen` tooling from embedded help
text). Because `bc`/`dc` didn't change between `stable/15` and
`releng/15.0`, those generated `.c` files came out byte-identical, so the
dependency system saw no reason to regenerate or recompile them — and
silently kept the objects the **stable15 toolchain** had emitted at 10:29.
The freshly rebuilt `releng/15.0` `lld` then rejected the stale
`bc_help.pieo` as `Invalid record` at link time.

In other words: `release150`'s build linked against an object file built
by `stable15`'s toolchain. A from-scratch build of `release150` on a
clean machine would have succeeded — it only failed because a *different*
foundation was built first in the same shared obj tree. That is precisely
the cross-foundation contamination parasa's whole model is supposed to
prevent.

## Why buildworld's own clean didn't save it

`run_build` invokes plain `make buildworld` (no `-DNO_CLEAN`), so one
might expect the standard clean stage to purge stale objects — but these
generated-source objects survived across a branch switch anyway (no
`.meta` files present; this isn't even meta-mode). Regardless of the exact
reason buildworld's incremental logic preserved them, the takeaway is that
**parasa cannot rely on buildworld's default clean to isolate foundations**,
because parasa's usage pattern (rapidly switching branches within a single
shared source+object tree) is exactly the scenario those incremental
assumptions don't cover. Object isolation is parasa's responsibility here,
not buildworld's.

## Bonus: finding 04's fix validated correct by this failure

This was a *genuine* build failure (buildworld itself failed, before
`run_build` returned), so `BUILD_COMPLETE` was still `false` and the
cleanup trap correctly **destroyed** `zshemot/buildspace/release150`
rather than preserving it. That's exactly the right behavior — nothing
salvageable existed — and confirms finding 04's fix distinguishes
"build finished but a later step failed" (preserve) from "the build
itself failed" (destroy) correctly. Verified: `zfs list -r
zshemot/buildspace` is empty afterward.

## Suggested fix

Give each foundation its own object tree by keying `MAKEOBJDIRPREFIX` on
the foundation name, so different foundations can never share objects while
rebuilds of the *same* foundation still get incremental speed:

```sh
run_build() {
	local srcdir="/zshemot/src.git"
	local destdir="/zshemot/buildspace/${FOUNDATION_NAME}"
	local jobs="$MAKE_JOBS"
	local objprefix="/usr/obj/parasa/${FOUNDATION_NAME}"
	# All five make targets must share the same MAKEOBJDIRPREFIX so the
	# install/distribution steps find the objects buildworld produced.
	local mk="env MAKEOBJDIRPREFIX=${objprefix} make -C ${srcdir} -j${jobs}"

	progress "Building world (make -j${jobs} buildworld)"
	run env MAKEOBJDIRPREFIX="$objprefix" make -C "$srcdir" -j"$jobs" buildworld
	# ...same MAKEOBJDIRPREFIX on buildkernel / installkernel / installworld / distribution
}
```

Alternatives: `rm -rf` the obj tree at the start of every build (simplest,
but loses same-foundation incremental reuse), or force a clean when the
checked-out branch differs from the last build. Per-foundation
`MAKEOBJDIRPREFIX` is the most aligned with parasa's segregation model and
is what the fix in this branch implements.
