# `diff.sh`'s classification loop is broken by piping into `while read` (subshell)

**File:** `scripts/diff.sh`
**Severity:** Critical — the save pipeline cannot function at all as
shipped. `save.sh` unconditionally calls `diff.sh -q` as its first step
and treats any nonzero exit as fatal; see below for why that call can
essentially never succeed.

## Root cause

```sh
printf "%s\n" "$changed_files" | while IFS= read -r relpath; do
	...
	total=$((total + 1))
	classification=$(classify_file "$relpath") || true
	case "$classification" in
		exempt) ;;
		text|derivation|preserve)
			classified=$((classified + 1))
			[ "$QUIET" -lt 1 ] && printf "  [%s] %s\n" "$classification" "$relpath" >&2
			;;
		unclassified) ... ;;
	esac
done

if [ "$unclassified" -gt 0 ]; then
	...
```

Piping into a `while` loop (`cmd | while ...; done`) runs the loop in a
**subshell** in FreeBSD's `/bin/sh` (and POSIX sh generally, apart from
bash's non-default `lastpipe`). This causes two independent, compounding
failures:

### 1. Variable updates never escape the loop (breaks in *every* mode)

`total`, `classified`, and `unclassified` are all incremented *inside*
the piped subshell. Once the pipe completes, those increments are gone —
the parent script's copies are still whatever they were initialized to
(`0`). Confirmed directly on this VM:

```sh
$ /bin/sh -c 'count=0; printf "a\nb\nc\n" | while IFS= read -r x; do count=$((count+1)); done; echo "count after loop: $count"'
count after loop: 0
```

So `if [ "$unclassified" -gt 0 ]` at the end of `diff.sh` **always** sees
`0`, no matter how many files were actually unclassified. The entire
point of `diff.sh` — blocking a rebase/save when there's an unclassified
file — cannot work, in interactive or quiet mode, ever.

### 2. In quiet mode specifically, the script dies silently before reaching that check anyway

The `text|derivation|preserve` branch's last statement is:

```sh
[ "$QUIET" -lt 1 ] && printf "  [%s] %s\n" "$classification" "$relpath" >&2
```

In quiet mode (`QUIET=1`, exactly what `save.sh` passes via `diff.sh -q`),
this test is always false, so this statement always "fails" (exit 1) —
by design, the `printf` is only meant to be skipped, not to signal an
error. But because it's the **last command executed in the loop body**,
the `while` loop's own exit status becomes 1 whenever the *last processed
file* in the run classifies as text/derivation/preserve while quiet —
which is the normal, expected, everything-is-fine case. Since
`printf ... | while ...; done` is a bare top-level statement under
`set -eu`, that nonzero exit status kills the whole script immediately —
before reaching the `if [ unclassified -gt 0 ]` check, before printing
"All changes classified.", before printing anything at all. Confirmed via
`-x` trace: execution stops dead right after the loop's last `read`, with
zero further output, `$? = 1`.

Verified precisely with a minimal, faithful repro (failing test as the
literal last statement of the loop body, matching the real code path):

```sh
$ /bin/sh -c 'set -e; QUIET=1
printf "a\n" | while IFS= read -r x; do
  [ "$QUIET" -lt 1 ] && printf "should not print\n"
done
echo "REACHED AFTER LOOP"'
outer exit: 1
```

`"REACHED AFTER LOOP"` never prints. Exactly matches `diff.sh -q`'s
observed behavior.

## Impact

`save.sh`'s very first step is:

```sh
"${SCRIPT_DIR}/diff.sh" -s "$WS_NAME" -k "$WS_KIND" -q || \
	die "Unsaved drift detected. Run diff.sh interactively first."
```

Because of bug #2, `diff.sh -q` returns exit 1 whenever there is **at
least one** changed file that classifies successfully (text, derivation,
or preserve) — which will be true for essentially any real save scenario,
since that's the entire point of running `save`. So `save.sh` reports
"Unsaved drift detected" and refuses to proceed, **even when the actual
drift is 100% cleanly classified and there is nothing wrong at all.**
Running `diff.sh` interactively first (as the error message suggests)
doesn't help either — bug #1 means the unclassified-count tracking is
broken in interactive mode too, so there's no way to get a trustworthy
signal out of this script as written.

## How we hit it

Installed and configured nginx inside a real container (`demo1`,
deployed from the `stable15` foundation, jail running), producing two
legitimate, cleanly-classifiable text-file changes (`/etc/resolv.conf`
added, `/etc/rc.conf` modified via `sysrc nginx_enable=YES`) plus
exempt-path package-install noise (`/usr/local`, `/var`). Ran `save.sh
-s demo1 -k container -m "install nginx"`, which calls `diff.sh -q`
internally and immediately failed with "Unsaved drift detected" — traced
it down to the mechanism above via `-x` and targeted minimal repros.

## Suggested fix

Avoid piping into the `while` loop — read from a here-string/file instead
so the loop runs in the current shell, not a subshell. Since POSIX sh
doesn't have bash's `<<<`, redirect from a temp file or process
substitution isn't available either; the standard portable fix is
redirecting from a file:

```sh
tmpfile=$(mktemp)
printf "%s\n" "$changed_files" > "$tmpfile"
while IFS= read -r relpath; do
	...
done < "$tmpfile"
rm -f "$tmpfile"
```

This alone fixes both bugs: the loop no longer runs in a subshell, so
`total`/`classified`/`unclassified` updates persist, *and* the loop's own
exit status no longer matters for `set -e` purposes since it's not part
of a pipeline anymore (a `while...done < file` construct's exit status
doesn't propagate to kill the script the same way — and even if it did,
the counts would now be correct for the check that follows).

Also worth fixing while touching this: the `[ "$QUIET" -lt 1 ] && printf`
idiom is a `set -e` trap in general, independent of the subshell issue —
any bare `test && action` statement whose test can legitimately be false
should be written `if ...; then ...; fi` instead, not relied upon to
"just happen" to not be the last command in its block.

**Caveat on the fix:** redirecting from a file instead of a pipe doesn't
fix a related, pre-existing issue — `prompt_classification()`'s own
`read -r resp` calls (used for interactive `[d/p/c/s]` classification)
share the *same* stdin as the outer `while IFS= read -r relpath` loop,
whether that stdin is a pipe (original) or a redirected file (this fix).
Nested reads competing for the same stdin stream is a separate, classic
shell pitfall. This VM's testing never exercised interactive
classification (only quiet mode, which is what `save.sh` uses and what
this finding is about), so it's flagged here but not fixed — worth a
follow-up finding if interactive `diff.sh` is exercised directly.
