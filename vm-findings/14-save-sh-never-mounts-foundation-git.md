# `save.sh` never mounts `zbamidbar/foundation.git` before pushing to it

**File:** `scripts/save.sh`
**Severity:** Bug — 100% reproducible on a clean environment; the final,
most important step of `save.sh` (pushing the state commit) fails.

## The bug

`save.sh`'s `main()` runs `git -C "$TREE_ROOT" push origin
"${WS_KIND}s/${WS_NAME}"` (step 5) — the container/system's git remote
`origin` is `/zbamidbar/foundation.git` (set up back when the workspace
was created, in `workspace.sh`'s `ws_begin()`). But `save.sh` itself never
mounts `zbamidbar/foundation.git` anywhere — grepping the whole script for
`zmount` finds zero hits. Every other script that pushes to
`foundation.git` (`new_foundation.sh`, `workspace.sh`,
`deploy_system.sh`, `deploy_container.sh`) explicitly `zmount`s it first;
`save.sh` is the one place that assumes it's already mounted.

On a clean environment (nothing else currently has it mounted), this
fails immediately:

```
==> Committing state...
[containers/demo1 8c323e65] ... install and enable nginx
 11 files changed, ...
fatal: '/zbamidbar/foundation.git' does not appear to be a git repository
fatal: Could not read from remote repository.
```

The state commit itself succeeds (it's a local `git commit`, no mount
needed) — only the `push` fails, because `/zbamidbar/foundation.git`
resolves to an empty, unmounted directory rather than the bare repo.

## How we hit it

Ran `save.sh -s demo1 -k container -q -m "install and enable nginx"`
against `demo1` after fixing [12](12-diff-sh-piped-while-loop-subshell-breaks-everything.md)
(diff check) and [13](13-save-sh-pkg-info-missing-a-flag.md) (package
list) — got past both, past mtree regeneration, past the local commit,
and died on the very next command, `git push`. Confirmed via
`zfs list -o name,mounted zbamidbar/foundation.git` showing `no`.

## Suggested fix

Mount `zbamidbar/foundation.git` at the start of `main()`, matching the
pattern every other script in this repo already uses, and unmount it on
the way out:

```sh
main() {
	run zmount zbamidbar/foundation.git /zbamidbar/foundation.git
	...
	run git -C "$TREE_ROOT" push origin "${WS_KIND}s/${WS_NAME}"
	...
	run zunmount zbamidbar/foundation.git
}
```
