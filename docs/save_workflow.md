# Save workflow

Saving a system or container is a single interactive session that produces
two git commits:

## Commit 1: zbereshit (system tree -> zbamidbar/sinai.git)

1. Run `parasa-diff` against the live tree
2. Auto-classify changes:
   - Text files -> `git add` (automatic)
   - Known derived binaries -> verified, no action needed
   - Already git-tracked binaries -> environment state, no action needed
3. Prompt for unclassified binaries:
   - `[d]` derived -> writes to minhag target's `derivations.local`
   - `[e]` environment -> `git add` the binary file
   - `[c]` command -> appends to minhag target's `compose.sh` file
   - `[s]` skip -> will ask again next time (blocks rebase)
4. Regenerate `mtree.dist` in the target's minhag directory
5. Commit the delta to the zbereshit branch

## Commit 2: zshemot (parasa repo -> zbamidbar/parasa.git)

1. Collect changes produced by commit 1's classification:
   - Updated `derivations.local` (new `[d]` entries)
   - Updated `compose.sh` (new `[c]` entries)
   - Updated `pkg.list` (full package list from `pkg info`)
2. Commit to the parasa repo

The zbereshit commit records the *state*. The zshemot commit records the
*recipe*. Together they fully describe how to reproduce or rebase the
target.
