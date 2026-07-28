# VM environment quirks (not parasa bugs)

**Severity:** Informational only. None of this is a defect in parasa's
scripts — it's friction specific to how this particular test VM is set up,
recorded so it doesn't get mistaken for a parasa problem if someone else
hits the same symptom while testing on a similar box.

## The default shell/coreutils on this VM are Linux-ABI binaries

This VM's interactive shell and most coreutils (`bash`, `ls`, `cp`,
`mkdir`, `truncate`, `cat`, `stat`, `git`, etc.) run as **Linux-ABI ELF
binaries under FreeBSD's linuxulator**, not as native FreeBSD binaries —
confirmed by `uname -a` printing a hybrid `Linux ... FreeBSD 15.1-RELEASE
...` string, and by dmesg lines like
`linux: jid 0 pid N (bash) unsupported prctl option`.

FreeBSD's linuxulator transparently redirects a Linux-branded process's
absolute path lookups to try `/compat/linux/<path>` first, falling back to
the true root only if the translated candidate doesn't exist. This is
per-*process* ABI branding (decided by the ELF's OS/ABI note at exec time),
not inherited from the parent shell — so native FreeBSD tools this VM
needs anyway (`mdconfig`, `gpart`, `geli`, `glabel`, `zpool`, `zfs`,
`newfs_msdos`) are **not** translated: they resolve the literal path with
no `/compat/linux` prefix trial.

Symptom this caused early on: creating a file via the Linux-emulated shell
at what looked like `/var/tmp/x.img` — `ls`/`cat`/`stat` from that same
shell see it fine — actually placed it at `/compat/linux/var/tmp/x.img`.
A native tool given the bare `/var/tmp/x.img` path failed with ENOENT
(`mdconfig: realpath: No such file or directory`) even though the file
"obviously" existed. Confirmed via `truss -f` showing `__realpathat`/
`fstatat` failing on paths the Linux-emulated shell resolved fine.

**Not related to:** jails (`security.jail.jailed` is 0 the whole time),
freshly-created files/dirs specifically, or ZFS flakiness — it is
consistently and solely this ABI/path-translation split. It also, usefully,
does *not* affect `parasa`'s own runtime paths (`/zshemot`, `/zbamidbar`,
`/containers`) since those directory names have no mirrored counterpart
under `/compat/linux` — translation only bites on paths that exist in
*both* trees (`/root`, `/var`, `/tmp`, `/usr`, `/etc`, `/home`, `/dev`).

**Workaround used throughout this proof-out:** hand native tools
fully-qualified `/compat/linux/...` paths for anything under a mirrored
top-level directory, and run whole multi-step parasa scripts through
`/rescue/sh <real-path-to-script>` (statically linked, guaranteed native)
rather than the default shell, so every path check inside the script
stays consistent with the native tools it shells out to. Verified that
`git`, `make`, `zfs`, `geli`, `gpart`, `sysrc`, `mtree`, `cc`/`clang`,
`jail`, and `service` all resolve to genuine native binaries at their
usual FreeBSD paths regardless of which shell looks them up, so this
approach is safe for the rest of the pipeline (foundation build, container
creation, jail start).

## No PTY automation tooling available

No `expect`, `python3`, or `tclsh` on this VM. `geli init`/`geli attach`'s
interactive passphrase prompts read from `/dev/tty` directly, which can't
be driven by a plain piped stdin. Worked around by patching a **scratch
copy** of `stage0-bootstrap.sh` (not the git clone) to accept a
`PARASA_TEST_PASSFILE` env var and pass geli's own documented `-J`/`-j`
passphrase-file flags — same underlying commands, just no TTY prompt. Real
interactive passphrase entry (a human typing at an actual terminal) was
never exercised by this proof-out.
