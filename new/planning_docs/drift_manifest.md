# Drift Manifest

## Problem

Git tracks text file deltas well. The composition file tracks intended steps well. Neither covers the case where the sysadmin made a change that produced a binary file delta — a new user added via `pw useradd`, a kerberos keytab generated, an SSL cert written in place — and either forgot to log it in the composition file, or hasn't gotten around to it yet.

Without a third layer, the system has no way to:
- Know a binary file changed at all (git ignores it or produces an unresolvable diff)
- Remember that it already asked the user about a specific change (to avoid asking every session)
- Block a rebase when a live system has unaccounted binary drift

## Solution: The Drift Manifest

A flat file, `var/db/mishkan/drift`, stored inside the var/ dataset for each system or container. It lives at:

- Systems:    `zbamidbar/system-data/[name]/var` → mounted at `/var` (or `/systems/[name]/var`)
- Containers: `zbamidbar/container-data/[name]/var` → mounted at `/containers/[name]/var`

Because var/ is already a gitignored ZFS dataset on zbamidbar, this is the correct home for operational runtime state. It survives reboots, survives system rebuilds, and is never accidentally committed.

## Manifest Format

One record per line, tab-separated:

```
<status> <sha512-hash> <filepath>
```

Where `<status>` is one of:
- `accounted`   — hash matches, a composition step covers this change
- `unaccounted` — hash matches, but no composition step has been written yet

Example:
```
accounted   abc123...  etc/master.passwd
accounted   def456...  etc/pwd.db
accounted   789abc...  etc/spwd.db
unaccounted 000fff...  etc/krb5.keytab
```

Filepaths are relative to the system/container root, consistent with how mtree(8) records them.

## Tool: mishkan-diff

A `mishkan-diff` command (or function, sourced on login like the other helpers) performs the drift scan. It:

1. Runs mtree against the live system root, generating a current mtree
2. Compares against the base mtree stored at build time (`etc/mtree/system.dist`)
3. For each changed file, classifies it:

```
is it in a gitignored mount (var/, usr/local/, home/)?
  yes → skip entirely, those datasets are managed separately

is it a text file?
  yes → git status knows about it, no further action

is it a binary file?
  check drift manifest:
    not present           → NEW: prompt user (see below)
    present, same hash    → already acknowledged, check status field
      accounted           → quiet skip
      unaccounted         → remind: "still no composition step for etc/krb5.keytab"
    present, hash changed → CHANGED AGAIN: re-prompt user
```

### Prompting the user

When a new or re-changed binary file is found:

```
Binary file changed: etc/master.passwd
Is this covered by a step in your composition file? [y/n/skip]
  y    → add/update manifest entry as 'accounted'
  n    → add/update manifest entry as 'unaccounted' (will block rebase)
  skip → do not record, ask again next time
```

## Rebase Integration (Phase 2)

Before a rebase begins, `mishkan-diff` is run and must exit clean. "Clean" means:
- No unrecorded binary changes (everything is in the manifest)
- No `unaccounted` entries

If any `unaccounted` entries exist, rebase stops with a clear message:

```
Cannot rebase: the following binary changes have no composition step:
  etc/krb5.keytab

Update your composition file's [cmd] section to reproduce this change,
then re-run mishkan-diff and mark it accounted.
```

This is the safety net that keeps the composition file honest. Git backstops
text files; the drift manifest backstops everything else.

## Manifest Lifecycle

- **Created**: on first `mishkan-diff` run after a system or container is stood up
- **Updated**: each time `mishkan-diff` is run and the user responds to a prompt
- **Reset**: when a new base artifact is beamed down (the base mtree changes, so all
  previous manifest entries are stale and should be cleared)
- **Preserved**: across reboots and `mishkan-diff` runs, since it lives on zbamidbar

## Relationship to mtree

The build phase already produces `etc/mtree/system.dist` (see Concept 1, Phase 1, step 9).
That file is the baseline. The drift manifest does not replace it — it extends it.
mtree answers "what changed from the build?"; the manifest answers "which of those changes
does the composition file know about?"
