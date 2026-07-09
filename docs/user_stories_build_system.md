# User Stories: Foundation + System Creation

These stories illustrate how `new_foundation`, `new_system`, and
`deploy_system` work across interactive, semi-interactive, and quiet modes.

See `plans/build_system.md` for the full implementation plan.

---

## Story A: New foundation, interactive

Alice opens a pristine, post-bootstrap mishkan computer. She runs
`mishkan_new_foundation` with no arguments. The command detects no `-s`
flag and launches in interactive mode.

1. **Name**: The command asks for a foundation name. Alice types
   `generic-stable15`. The command checks that no
   `minhag/foundations/generic-stable15/` directory exists, no
   `zbamidbar/sinai.zfs/foundations/generic-stable15` dataset exists, and no
   `foundation/generic-stable15` branch exists in sinai.git. All clear.

2. **Build config**: The command asks for SRC_BRANCH (default: `stable/15`),
   KERNCONF (default: `GENERIC`), and MAKE_JOBS (default: `hw.ncpu` value).
   Alice accepts all defaults by pressing enter.

3. **Summary + confirm**: The command prints the foundation name and build
   config, asks to confirm.

4. **Minhag setup**: Creates `minhag/foundations/generic-stable15/build.conf`
   with the collected values. Since this is interactive mode, offers to open
   the foundation directory in `$EDITOR` before proceeding. Alice declines.

5. **Build**: The command creates the transient `zshemot/tablets` +
   `zshemot/tablets/var` datasets, checks out `stable/15` from
   `zshemot/torah`, and runs the five make targets (buildworld, buildkernel,
   installkernel, installworld, distribution) with DESTDIR=/zshemot/tablets.
   Progress is reported throughout.

6. **Track**: The command initializes git in `/zshemot/tablets`, adds the
   remote pointing to `zbamidbar/sinai.git`, creates orphan branch
   `foundation/generic-stable15`. It stages all files (`git add .`), creates
   `.gitignore` with `var/`, `usr/local/`, `tmp/` (NOT `home/`), stages the
   gitignore, generates mtree, and commits with the artifact name as the
   message. Pushes to sinai.git.

7. **Archive**: Snapshots `zshemot/tablets` recursively under the artifact
   name, creates `zbamidbar/sinai.zfs/foundations/generic-stable15`, and does
   a full `zfs send | recv` to archive it.

8. **Cleanup**: Destroys `zshemot/tablets` recursively. Done.

Alice now has a foundation she can use to create systems or containers.

---

## Story B: New foundation, quiet

Bob runs:
```
mishkan_new_foundation -s generic-stable15 -o src_branch=stable/15 -qq
```

`-s` provides the name, `-o` provides the build config, `-qq` suppresses
all prompts AND progress output. The command validates the name is
available, creates build.conf, builds, tracks, archives, and cleans up
without any interaction. If validation fails (name taken, src branch
doesn't exist), it dies with an error.

---

## Story C: New system, interactive

Alice has her `generic-stable15` foundation. She runs `mishkan_new_system`
with no arguments.

1. **System name**: Prompted. She types `wonderland`. The command checks
   `minhag/systems/wonderland/` and `zbereshit/systems/wonderland` don't
   exist.

2. **Foundation**: The command lists available foundations (reads from
   `minhag/foundations/`). Alice selects `generic-stable15`.

3. **Dataset questions**: The command asks the boilerplate questions:
   - Make a /home/ dataset? (default: yes) → `zbamidbar/system-data/wonderland/home`
   - Make /tmp/ its own dataset? (default: yes) → `zbamidbar/system-data/wonderland/tmp`
   - Make /home/root/ its own dataset? (default: no) → Alice says no
   - Any other user home datasets? → Alice types `alice` → creates
     `zbamidbar/system-data/wonderland/home/alice`
   - Any custom mount entries? → Alice adds
     `zbamidbar/alice-portable-home` at `/home/alice` and says it is NOT
     recipe-related (so it goes in /etc/fstab, not fstab.local).

   The standard data-lake mounts (var, tmp, usr/local) are always
   auto-included — these are not asked as questions.

4. **Summary + confirm**.

5. **Minhag setup**: Creates `minhag/systems/wonderland/` with:
   - `generic-stable15.foundation` (zero-byte file)
   - `compose.sh` (empty)
   - `derivations.local` (empty)
   - `pkg.list` (empty)
   - `fstab.local` (empty — no recipe-only mounts)
   - `mtree.dist` (empty, populated later by mishkan-diff)

6. **Create datasets**: On zbamidbar:
   - `zbamidbar/system-data/wonderland` (parent)
   - Full `zfs send | recv` from foundation's var to
     `zbamidbar/system-data/wonderland/var` (independent copy of pristine var)
   - `zbamidbar/system-data/wonderland/home`
   - `zbamidbar/system-data/wonderland/tmp`
   - `zbamidbar/system-data/wonderland/home/alice`

7. **Inaugural commit**: The core operation.
   - Recv foundation from `zbamidbar/sinai.zfs/foundations/generic-stable15`
     to `zshemot/tablets` (temporarily)
   - The recv'd dataset includes `.git` from the foundation build. Fetch
     from sinai.git.
   - `git checkout -b system/wonderland foundation/generic-stable15`
   - Write mount entries into `/etc/fstab` inside tablets:
     ```
     zbamidbar/system-data/wonderland/var        /var        zfs  rw,late  0  0
     zbamidbar/system-data/wonderland/home       /home       zfs  rw,late  0  0
     zbamidbar/system-data/wonderland/usr/local  /usr/local  zfs  rw,late  0  0
     zbamidbar/system-data/wonderland/tmp        /tmp        zfs  rw,late  0  0
     zbamidbar/alice-portable-home               /home/alice zfs  rw,late  0  0
     ```
   - `git add etc/fstab`, commit "system/wonderland inaugural", push to
     sinai.git
   - Destroy tablets

8. **Deploy prompt**: Since this is interactive and no `-b` flag was given,
   the command asks if Alice wants to deploy. She says yes, and it asks
   about nextboot. She says yes to that too. This calls `deploy_system`.

---

## Story D: New system, quiet with deploy + nextboot

Bob runs:
```
mishkan_new_system -s testbox -f generic-stable15 -o home_dataset=no -qbb
```

- `-s testbox` — system name
- `-f generic-stable15` — foundation
- `-o home_dataset=no` — no home dataset
- `-q` — quiet, no prompts
- `-bb` — deploy AND set nextboot

The command creates the system with default datasets (var, tmp, usr/local
are always auto-included; home skipped per `-o`), creates the inaugural
commit, deploys to `zbereshit/systems/testbox`, and sets nextboot. No
interaction.

---

## Story E: Standalone deploy

Carol has a system `wonderland` already created (via `new_system`) but not
yet deployed. She runs:
```
mishkan_deploy_system -s wonderland -n
```

1. **Resolve**: The command reads `minhag/systems/wonderland/*.foundation`
   to find the foundation name. In sinai.git, it finds the foundation
   commit that `system/wonderland` forks from and reads its commit message
   — that IS the artifact name / ZFS snapshot tag.

2. **Send**: Full `zfs send | recv` from
   `zbamidbar/sinai.zfs/foundations/generic-stable15@<artifact>` to
   `zbereshit/systems/wonderland`.

3. **Apply system branch**: The recv'd dataset includes `.git`. Fetch
   `system/wonderland` from sinai.git, `git checkout system/wonderland`.
   This applies the inaugural commit (fstab entries, etc.) on top of the
   foundation.

4. **Nextboot** (`-n`): Sets `mountpoint=/` on the dataset (via
   `zfs set -u`) and runs
   `nextboot -e vfs.root.mountfrom="zfs:zbereshit/systems/wonderland"`.
   Prompts to reboot (if interactive).

---

## Story F: Semi-interactive

Carol runs:
```
mishkan_new_system -s mybox -f generic-stable15 -o home_dataset=yes
```

No `-q` flag, so the command enters semi-interactive mode. Every question
is still asked, but `-o` values pre-fill the defaults. Carol sees:

```
Make a /home/ dataset? [YES]:
```

She presses enter to accept (pre-filled from `-o`). The rest of the
questions use their normal defaults. She can override any of them.

---

## Mode summary

| Flags | Mode | Behavior |
|-------|------|----------|
| (none) | Interactive | All questions asked, no defaults pre-filled |
| `-s` (no `-q`) | Semi-interactive | `-o` values pre-fill defaults, still prompt |
| `-s -q` | Quiet | No prompts, uses defaults + `-o` overrides |
| `-s -qq` | Silent | Quiet + suppress progress output |
