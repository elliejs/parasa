# `cleanup()` trap destroys a fully-built foundation if the final git commit fails

**File:** `scripts/new_foundation.sh`
**Severity:** Bug — a late, trivial failure (no git identity configured)
destroys hours of `buildworld`/`buildkernel`/install work with no recovery
path.

## What happened

On this VM, `new_foundation.sh -s stable15 -q -o make_jobs=2` ran for
~2.5 hours and successfully completed `buildworld`, `buildkernel`,
`installkernel`, `installworld`, and `distribution` into
`zshemot/buildspace/stable15`. It then reached `commit_build()`:

```sh
run git -C "$workspace" commit "$@" -m "$ARTIFACT_NAME"
```

This failed because no git identity (`user.name`/`user.email`) was
configured anywhere reachable by that workspace's git repo — a completely
mundane environment gap, unrelated to anything the build itself did:

```
Author identity unknown

*** Please tell me who you are.
...
fatal: unable to auto-detect email address (got 'root@PARASA-TESTING.(none)')
```

Under `set -eu`, that non-zero exit immediately unwound the script. The
top-level trap —

```sh
cleanup() {
	if [ -n "$FOUNDATION_NAME" ] && zfs_dataset_exists "zshemot/buildspace/${FOUNDATION_NAME}"; then
		printf "Cleaning up transient zshemot/buildspace/%s...\n" "$FOUNDATION_NAME" >&2
		zfs destroy -r "zshemot/buildspace/${FOUNDATION_NAME}" 2>/dev/null || true
	fi
}
trap cleanup EXIT
```

— fires unconditionally on *any* exit, success or failure, and unlinks
the entire `zshemot/buildspace/${FOUNDATION_NAME}` dataset. It doesn't
distinguish "died early, nothing valuable here yet" from "died after a
multi-hour build, with a fully installed world+kernel sitting right
there." Confirmed on this VM: `zfs list -r zshemot/buildspace` was empty
afterward, and neither `zbamidbar/foundation.zfs` nor
`zbamidbar/foundation.git` got the archive (`commit_build` runs before
`archive_to_zbamidbar`, so nothing had been pushed yet either). The
`recipes/foundations/stable15/build.conf` + `mtree.dist` were the only
surviving trace that a build had ever happened.

Net effect: a fully successful, expensive build was silently thrown away
by a one-line, instantly-fixable config problem in a step that runs
*after* all the expensive work is already done.

## Why this matters beyond "misconfigured VM"

Not requiring git identity as a pre-flight check is a real gap on its own
— `new_foundation.sh` already validates plenty of preconditions up front
(`check_foundation_available`, name validation, etc.) but never checks
`git config user.email`/`user.name` before committing 2+ hours of CPU to
a build whose last step needs it. But even independent of that: *any*
late failure in `commit_build`/`archive_to_zbamidbar` (git push
rejected, `zfs send | zfs recv` failing due to a full pool, a network
blip during push) hits the exact same trap and loses the build the same
way. The cleanup trap has no "was this a successful build that just
failed to be archived" distinction at all.

## Suggested fix

- Add a pre-flight check (fail fast, before `run_build`) that git
  commits will actually be possible — e.g. `git config user.email`
  resolves to something, or at minimum warn loudly.
- Make the cleanup trap conditional on how far execution got: skip
  destroying `zshemot/buildspace/<name>` if `run_build` completed, and
  instead leave it in place with a clear message telling the operator how
  to resume (re-run just the commit/archive phase) or clean up manually.
  Even a blunt "only auto-destroy if we die before `run_build` returns"
  would have saved this run.
