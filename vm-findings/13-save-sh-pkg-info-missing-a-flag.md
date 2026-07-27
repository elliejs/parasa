# `save.sh`'s package-list capture is missing `-a`, fails immediately

**File:** `scripts/save.sh`
**Severity:** Bug — 100% reproducible, second step of `save.sh` for both
systems and containers.

## The bug

```sh
case "$WS_KIND" in
	system)
		run chroot "$TREE_ROOT" pkg info -o > "${RECIPE_DIR}/pkg.list"
		;;
	container)
		run pkg -j "$WS_NAME" info -o > "${RECIPE_DIR}/pkg.list"
		;;
esac
```

`pkg info -o` alone means "show the origin of *this* package" and
requires a `<pkg-name>` argument (or `-a` for "all installed packages").
Without either, `pkg`'s own usage/argument validation rejects it outright
before doing anything:

```
$ pkg -j demo1 info -o
Usage: pkg info <pkg-name>
       pkg info -a
       pkg info [-AbBDdefIklOqRrs] [-Cgix] <pkg-name>
       pkg info [-AbBDdfIlqRrs] -F <pkg-file>
```

Adding `-a` (list all installed packages, matching what `save.sh` clearly
intends — capturing the full package list) fixes it immediately:

```
$ pkg -j demo1 info -a -o
nginx-1.30.4,3                 www/nginx
pcre2-10.47_1                  devel/pcre2
pkg-2.8.1                      ports-mgmt/pkg
```

Both the `system` and `container` branches have the identical missing
flag.

## How we hit it

Ran `save.sh -s demo1 -k container -q -m "install and enable nginx"`
against a real container with nginx installed and running — died at
step 2 (package-list capture), immediately after step 1 (the diff check,
now working after [finding 12](12-diff-sh-piped-while-loop-subshell-breaks-everything.md)'s
fix) passed cleanly.

## Suggested fix

Add `-a` to both invocations:

```sh
system)
	run chroot "$TREE_ROOT" pkg info -a -o > "${RECIPE_DIR}/pkg.list"
	;;
container)
	run pkg -j "$WS_NAME" info -a -o > "${RECIPE_DIR}/pkg.list"
	;;
```
