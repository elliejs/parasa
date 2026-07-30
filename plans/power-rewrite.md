# Research: Language alternatives for parasa

## Context

Parasa is ~6200 lines of POSIX sh managing FreeBSD jails, ZFS datasets, git repos, and packages. The sh implementation works but is painful — fragile error handling, no data structures, quoting hell, subprocess overhead, and untestable code. This document evaluates alternatives.

**Hard constraints:**
- Must run on FreeBSD 15.0
- No dependency hell — one language or a handful of packages, not a tree
- Must call system executables fluently (zfs, jail, git, pkg, mount, sysrc)
- Must handle their text output naturally
- Interactive prompts (read, select) must work

## What hurts in sh (concrete examples from parasa)

### The big ones

| Pain | Example | Impact |
|------|---------|--------|
| **No data structures** | Deduplication via `case "$seen" in *" ${name} "*` string matching; IFS save/restore to split comma lists; newline-delimited "arrays" with `${var:+\n}` | Every script reinvents collections poorly |
| **Error handling** | `\|\| true` everywhere masks real failures; pipe errors invisible (no `pipefail`); `set -e` has 20+ documented gotchas | Silent data loss, hard-to-debug failures |
| **Pipe subshell trap** | `... \| while read` loses variable assignments; must use temp files or `< file` workarounds | Causes bugs in cleanup traps, counters |
| **Return values** | Functions return via stdout + exit code; can't return structured data; caller must `val=$(func) \|\| ...` | Every function is awkward to compose |
| **String parsing** | `${origin%%@*}` + `basename` to extract a name from a ZFS origin; `ver_ge()` is 12 lines for version comparison | Simple operations become puzzles |
| **Config handling** | 5 separate `sysrc` subprocess calls to read one config file | Each call forks a process |
| **Argument parsing** | 20+ line `getopts` boilerplate repeated in 6+ scripts; no long options | Pure duplication |
| **Quoting** | Nested sed with variable interpolation; heredoc quoting rules; `eval` for dynamic variable names | Injection risks, silent corruption |
| **Testing** | Cleanup traps depend on global flags; interactive prompts can't be mocked; no function isolation | Effectively untestable |
| **Namespace** | 40+ functions in helpers.sh all global; variable collision risk across sourced files | Fragile at scale |

### Specific code smells

- `destroy_container.sh:78-112` — rescans ZFS 3 times to resolve a numeric menu choice because there are no arrays
- `new_container.sh:832-835` — pipe+while+umount loses error state in subshell
- `new_foundation.sh:448` — `zfs send | zfs recv` silently loses send-side errors
- `helpers.sh:330-336` — appending to a "list" requires embedding a literal newline in parameter expansion
- `diff.sh:183-185` — tries BSD `sed -i ''` then falls back to GNU `sed -i`; both have injection risk from interpolated variables

## Candidates

### 1. Lua (flua) — already in FreeBSD base

**Deps:** zero. `/usr/libexec/flua` ships in base since FreeBSD 11.

**What it gives you:**
- **Tables** — one data structure that covers arrays, maps, objects, and nested combinations
- **pcall/xpcall** — proper error handling (try/catch equivalent)
- **String patterns** — lighter than regex but handles `origin:match("([^@]+)$")` cleanly
- **Real return values** — functions return multiple values: `local name, err = get_foundation(ds)`
- **Modules** — `require("helpers")` gives namespacing
- **Coroutines** — can model interactive prompts cleanly

**What it doesn't give you:**
- Not a shell — calling system commands needs `os.execute()` or `io.popen()`, not just typing the command
- Pattern language is simpler than PCRE (no lookahead, alternation is limited)
- Standard library is intentionally minimal — no built-in path manipulation, JSON, etc.
- Would need a small "run command and capture output" helper (5-10 lines)

**Ecosystem for this use case:**
- EuroBSDCon 2024 talk: "Building an open native FreeBSD CI system from scratch with lua, C, jails & zfs"
- FreeBSD bootloader is written in Lua
- `flua` includes `lfs` (filesystem), `ucl` (config parsing), and FreeBSD-specific modules

**Migration path:** Gradual. Rewrite helpers.sh as a Lua module, then convert scripts one at a time. sh scripts can call `flua script.lua` and Lua can call sh commands.

**Example — what `get_foundation()` looks like in Lua vs sh:**

```sh
# sh (current)
get_foundation() {
    local ds="${1:?get_foundation: dataset required}"
    local origin
    origin=$(zfs get -H -o value origin "$ds" 2>/dev/null) || \
        die "get_foundation: cannot read origin of ${ds}"
    [ -n "$origin" ] && [ "$origin" != "-" ] || \
        die "get_foundation: ${ds} is not a clone (no origin)"
    local without_snap="${origin%%@*}"
    basename "$without_snap"
}
```

```lua
-- lua
function get_foundation(ds)
    local origin = cmd("zfs", "get", "-H", "-o", "value", "origin", ds)
    if not origin or origin == "-" then
        die("not a clone: " .. ds)
    end
    return origin:match("([^/]+)@")  -- capture name between last / and @
end
```

---

### 2. Oil Shell (YSH) — modern shell, sh-compatible

**Deps:** `pkg install oil` (single package, no dependency tree — it's a self-contained C++ binary).

**What it gives you:**
- **Drop-in sh compatibility** — OSH mode runs existing scripts unchanged
- **YSH mode** adds: typed variables, arrays, dicts, `try/catch`, `proc` with typed args
- **Native shell semantics** — commands are still first-class, `$()` works, pipelines work
- **Real arrays and dicts** — `var files = []`, `var config = {branch: "stable/15"}`
- **Proper error handling** — `try { cmd } catch { ... }` replaces `set -e` hacks
- **String interpolation** — `"hello $name"` but also `"count = $[len(items)]"` for expressions

**What it doesn't give you:**
- Younger project (stabilizing but not ancient like sh/Perl)
- Not in FreeBSD base (needs pkg)
- Fewer people know it (but sh people pick it up instantly)
- No module/namespace system yet (still file-sourcing like sh)

**Migration path:** Zero-cost start. Rename `#!/bin/sh` to `#!/usr/local/bin/osh` and everything works. Then incrementally adopt YSH features (`var`, `proc`, `try`) in new code.

**Example — the same function in YSH:**

```ysh
proc get_foundation (ds) {
    var origin = $(zfs get -H -o value origin $ds)
    if (origin === '' or origin === '-') {
        die "not a clone: $ds"
    }
    var parts = origin.split('@')
    var name = parts[0].split('/')[-1]
    echo $name
}
```

---

### 3. Perl — the sysadmin standard

**Deps:** `pkg install perl5` (single package, ~30MB installed, no dependency tree for core use).

**What it gives you:**
- **Hashes and arrays** — native, first-class, nested
- **Regex** — the most powerful regex engine outside of PCRE itself
- **Backticks/system/qx** — `my $origin = \`zfs get -H -o value origin $ds\``
- **die/eval** — proper exception handling
- **CPAN** — massive ecosystem (though you said no dependency hell, so: core modules only)
- **One-liners** — can replace sed/awk entirely

**What it doesn't give you:**
- Not in FreeBSD base (removed years ago)
- "More than one way to do it" makes code style inconsistent
- Startup is slower than Lua/sh for trivial scripts
- The syntax can be write-only (but parasa would use clean modern Perl)

**Migration path:** Rewrite. Perl and sh don't interop as smoothly as Lua/YSH. But a Perl rewrite would be shorter — probably 3000-4000 lines for the same functionality.

---

### 4. Janet — modern Lisp for system scripting

**Deps:** `pkg install janet` or compile from source (single C file, no deps).

**What it gives you:**
- **Tables, structs, arrays, buffers** — rich data types
- **PEG parsing** — built-in parser combinators for structured text
- **try/catch** — proper error handling
- **Janetsh** — shell integration layer specifically for system scripting
- **Fibers** — lightweight concurrency for complex workflows
- **Under 1MB** — tiny footprint

**What it doesn't give you:**
- Lisp syntax is unfamiliar (`(zfs/get "origin" ds)` vs `zfs get origin $ds`)
- Smaller community than any of the above
- Fewer battle-tested sysadmin examples
- Learning curve is real for non-Lisp developers

**Migration path:** Full rewrite with new idioms. High ceiling but steep ramp.

---

### Not recommended

| Language | Why not |
|----------|---------|
| **Python** | Not in FreeBSD base. Large dependency tree for anything useful. Startup overhead. |
| **Ruby** | Not in base. Heavy runtime. Few sysadmin users on BSD. |
| **Go** | Great for compiled tools, wrong for scripting. Compilation step kills iteration speed. |
| **Raku** | No FreeBSD package. Must compile from source. Heavy runtime. |
| **Nim** | Compilation step. Small ecosystem for sysadmin. |
| **TCL** | Not in base. Adequate but no clear advantage over Lua. |

## Comparison matrix

| | sh (current) | Lua (flua) | Oil (YSH) | Perl |
|---|---|---|---|---|
| **In base** | yes | yes | no (1 pkg) | no (1 pkg) |
| **Deps** | 0 | 0 | 0 | 0 |
| **Data structures** | none | tables | arrays, dicts | arrays, hashes |
| **Error handling** | set -e + prayer | pcall/xpcall | try/catch | die/eval |
| **System commands** | native | io.popen helper | native | backticks/system |
| **String ops** | parameter expansion | patterns + methods | sh + expressions | regex king |
| **Return values** | stdout hack | multiple returns | stdout (improved) | return values |
| **Namespacing** | none | require/modules | source (like sh) | packages |
| **Testability** | very hard | good | moderate | excellent |
| **Learning curve** | known | 1-2 days | 0 days (sh compat) | 3-5 days |
| **Migration effort** | n/a | gradual | zero-cost start | full rewrite |
| **Community proof** | everywhere | FreeBSD CI/bootloader | growing | decades of BSD |
| **Lines for parasa** | ~6200 | ~3500 est. | ~5000 est. | ~3500 est. |

## My take

**If portability is king:** stay with sh but adopt strict conventions — a "parasa sh style guide" that avoids the worst patterns (no bare pipes to while-read, always use temp files, etc.). You'll still hit the walls but at least consistently.

**If "zero deps" is the priority:** Lua/flua. It's already on every FreeBSD box. The EuroBSDCon CI talk proves it works for exactly this use case (jails + ZFS automation). The command-calling ergonomics need a small wrapper but after that it's dramatically better than sh for everything parasa does.

**If "lowest switching cost" wins:** Oil Shell (YSH). Existing scripts work day one. You adopt modern features incrementally. One `pkg install`. The risk is project maturity — it's good but younger than the alternatives.

**If you want the proven sysadmin workhorse:** Perl. One `pkg install`, zero CPAN deps needed for parasa's use case (core modules cover files, processes, regex, data structures). The ecosystem is battle-tested for decades of BSD administration. The cost is a full rewrite.

**The wildcard:** Lua for the framework core + sh for recipes (compose.sh). Recipes are simple "install this, configure that" scripts where sh's verbosity doesn't hurt. The framework (helpers, lifecycle, ZFS management) is where the complexity lives and where Lua shines.
