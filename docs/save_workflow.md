# Save workflow

Saving a system or container is a single interactive session that produces
two git commits:

## Commit 1: tree state (tree root → zbamidbar/foundation.git)

1. Run `diff.sh` against the live tree
2. Auto-classify changes:
   - Text files → `git add` (automatic)
   - Known derived binaries → verified, no action needed
   - Already git-tracked binaries → preserve state, no action needed
3. Prompt for unclassified binaries:
   - `[d]` derivation → writes source/derived/command to `derivations.local`
   - `[p]` preserve → `git add` the binary file
   - `[c]` command → appends to `compose.sh` (pre_pkg or post_pkg)
   - `[s]` skip → will ask again next time (blocks rebase)
4. Capture package list: `pkg info -o` → `pkg.list`
5. Regenerate `mtree.dist` in the target's recipes directory
6. Commit the delta to the `{kind}s/{name}` branch in foundation.git
7. Push to origin

## Commit 2: recipe (parasa repo)

1. Collect changes produced by commit 1's classification:
   - Updated `derivations.local` (new `[d]` entries)
   - Updated `compose.sh` (new `[c]` entries with pre_pkg/post_pkg phase)
   - Updated `pkg.list` (full package origin list)
   - Updated `mtree.dist`
2. `git add recipes/{kind}s/{name}/`
3. Commit to the parasa repo

The tree commit records the *state*. The recipe commit records the
*recipe*. Together they fully describe how to reproduce or rebase the
target.

## compose.sh structure

```sh
pre_pkg() {
    # Before packages: create users, groups, base system prep
}

post_pkg() {
    # After packages: commands that depend on installed software
}
```

Both functions are called during creation (`new_system`/`new_container`)
and during update (`update.sh`). The split lets commands express their
dependency on installed packages.
