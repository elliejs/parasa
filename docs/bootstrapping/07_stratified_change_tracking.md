# Stratified Change Tracking

The core insight of parasa: different kinds of admin changes need
different replay strategies. Trying to force everything through one
mechanism (pure git OR pure compose.sh) is where the burden comes from.

## The five categories

### 1. Text config edits

**Examples**: `rc.conf`, `sysctl.conf`, `pf.conf`, `login.conf`, crontab

- Detection: git diff (automatic)
- Replay: git rebase / three-way merge (automatic)
- Admin burden: none

### 2. Package installations

**Examples**: `pkg install nginx`, `pkg install vim-console`

- Detection: diff `pkg info` output against base (automatic)
- Replay: `pkg install <list>` on new base (automatic)
- Admin burden: none

Packages live under `usr/local/`, which is a separate zbamidbar dataset.
Package files are never in the git tree.

### 3. Derived binaries

**Examples**: `pwd.db` (from `master.passwd` via `pwd_mkdb`),
`login.conf.db` (from `login.conf` via `cap_mkdb`),
`aliases.db` (from `aliases` via `newaliases`)

- Detection: mtree hash change (automatic)
- Replay: merge the text source (category 1), then run the known
  regeneration command if the source changed
- Admin burden: none -- derivation relationships ship with parasa

The derivation database at `etc/derivations/15.0.db` contains:

```
etc/master.passwd	etc/pwd.db	pwd_mkdb -p -d /etc /etc/master.passwd
etc/master.passwd	etc/spwd.db	pwd_mkdb -p -d /etc /etc/master.passwd
etc/login.conf	etc/login.conf.db	cap_mkdb /etc/login.conf
etc/mail/aliases	etc/mail/aliases.db	newaliases
```

### 4. Preserve (semi-static binaries)

**Examples**: SSH host keys, SSL certificates, Kerberos keytabs

- Detection: mtree hash change (automatic)
- Replay: none needed -- preserved as-is
- Admin burden: one-time classification via `diff.sh` prompt

These files are **git-tracked**. They're small, rarely change, and on
conflict the resolution is always "keep ours." When `diff.sh` encounters
a new binary and the admin classifies it as preserve, it runs `git add`.

### 5. Opaque command output

**Examples**: compiled config blobs, database init, proprietary tool output

- Detection: mtree hash change (automatic)
- Replay: re-run the command on the new base
- Admin burden: must provide the command at classification time

This is the **only** category that requires a compose.sh entry. And it
is the smallest category for most systems.

## Detection mechanism: mtree

The build phase produces `mtree.dist` with sha512 content hashes (no
time, nlink, or flags -- those are git-incompatible). The `diff.sh` tool
compares the live filesystem against this baseline.

For each changed file, `diff.sh` auto-classifies:

```
exempt mount? (var/, usr/local/, home/, tmp/) --> skip
text file? --> git handles it
in derivations db? --> auto-classified
already git-tracked binary? --> preserve
none of the above? --> prompt admin
```

## Classification prompt

When `diff.sh` encounters an unclassified binary:

```
Unclassified: etc/krb5.keytab
  [d] Derivation (text source -> binary regeneration)
  [p] Preserve (keep as-is across rebases)
  [c] Command (produced from scratch, no text source)
  [s] Skip (ask again next time)
```

- `[d]` adds to `derivations.local`
- `[p]` runs `git add`
- `[c]` appends to `compose.sh` (pre_pkg or post_pkg)
- `[s]` does nothing -- mtree will flag it again

## Pre-rebase gate

Before rebase, `diff.sh` must exit clean (no unclassified files). If
unclassified files remain, rebase is blocked.

## Rebase order

1. Beam down new foundation artifact (ZFS send/recv)
2. Clone to `${NAME}-new`
3. Mount + start (jail for containers, chroot for systems)
4. Run `compose.sh`: `pre_pkg()`
5. Install packages from `pkg.list`
6. Run `compose.sh`: `post_pkg()`
7. Git rebase (text files + environment state)
8. Regenerate derived binaries (only those whose text source changed)
9. Validate with `diff.sh`

Steps 4-8 are automatic. Only category 5 commands (in compose.sh) were
written by the admin; everything else is auto-detected and auto-replayed.

## What we don't need

- **A separate drift manifest file** -- mtree IS the detection mechanism,
  and the classification destinations (derivations.local, git-tracked,
  compose.sh) ARE the memory. No separate ledger needed.
- **etcupdate(8)** -- parasa handles the same problem (text source merge
  + binary regen) within its own rebase flow.
