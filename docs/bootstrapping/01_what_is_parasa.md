# What is Parasa?

## The name

A parasa (parasang) is an ancient unit of distance. The project measures
and manages the distance between a pristine FreeBSD build and your running
system. The epigraph references the Talmudic story of Ashmedai throwing
Solomon "a distance of four hundred parasangs" (Gittin 68b).

The repo is codenamed "project-mishkan" locally; the public name is
**Parasa**.

## The problem

You build FreeBSD from source and customize it. Over time, customizations
accumulate: config edits, user accounts, packages, certificates, cron
jobs. When you upgrade the base system, you need to replay all those
customizations onto the new base. Some merge cleanly (text config edits),
some can't be merged at all (binary files like `pwd.db`), and some you've
forgotten about entirely.

The traditional approaches each cover part of the problem:

- **Git** tracks text diffs beautifully but produces garbage on binary
  three-way merges.
- **Composition scripts** (`compose.sh`) can replay commands, but
  require you to remember everything you did.
- **etcupdate(8)** handles `/etc` merges but is being deprecated in favor
  of pkgbase and doesn't cover the full system.

None covers the complete picture.

## The solution

Parasa introduces **stratified change tracking**: different types of
changes get different replay strategies, and the framework automates
the classification and replay for all but a small residual.

The five categories:

| Category | Example | Detection | Replay | Admin burden |
|----------|---------|-----------|--------|--------------|
| Text config edits | rc.conf, pf.conf | git diff | git rebase | None |
| Packages | nginx, vim | pkg info | pkg install | None |
| Derived binaries | pwd.db, login.conf.db | mtree hash | Merge text source, regen binary | None |
| Environment state | SSH host keys, certs | mtree hash | Preserve as-is (git-tracked) | One-time classify |
| Opaque commands | proprietary tool output | mtree hash | Re-run command | Must provide command |

Only the last category requires the admin to remember anything. Everything
else is automatic.

## How it works at a high level

1. Build a pristine FreeBSD system from source (**foundation**)
2. Create systems or containers on top of that foundation
3. Track every change the admin makes via git + mtree + derivation
   databases + package lists + compose scripts
4. When the foundation is rebuilt (new FreeBSD version), **rebase** all
   customizations onto the new base automatically
5. Validate with `diff.sh` -- should find zero unclassified changes

## Project status

The creation pipeline is fully implemented: bootstrap, build foundation,
create system, create container, deploy system. The maintenance pipeline
(diff, save, update, finalize) is implemented but less battle-tested.
Destroy, clone, edit, and garbage collection commands are planned but
unimplemented.

## License

BSD 2-Clause. Copyright 2026, eidelbyte.
