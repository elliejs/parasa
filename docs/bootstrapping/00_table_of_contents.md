# Parasa: Context Bootstrapping Guide

A from-scratch orientation for anyone reading this codebase for the first
time. Each document is self-contained but ordered for progressive
understanding.

## Table of Contents

1. [What is Parasa?](01_what_is_parasa.md) -- The problem, the solution,
   the name.

2. [Platform and Constraints](02_platform_and_constraints.md) -- FreeBSD,
   ZFS, GELI, /bin/sh. Why these matter and what to never assume.

3. [The Three Pools](03_the_three_pools.md) -- zbereshit, zshemot,
   zbamidbar. What lives where and why.

4. [Dataset Layout](04_dataset_layout.md) -- Every ZFS dataset, its
   purpose, mount policy, and naming convention.

5. [Git Topology](05_git_topology.md) -- foundation.git branch structure,
   how systems/containers fork from foundations, artifact naming.

6. [The Recipes System](06_recipes_system.md) -- Configuration and state
   tracking per target. The five file types. Two-tier config.

7. [Stratified Change Tracking](07_stratified_change_tracking.md) -- The
   five categories of admin changes and how each is detected/replayed.

8. [Command Reference](08_command_reference.md) -- Every parasa command,
   what it does, its flags, and where it fits in the lifecycle.

9. [Lifecycle Walkthrough](09_lifecycle_walkthrough.md) -- End-to-end:
   bootstrap, build foundation, create system, deploy, save, update,
   finalize.

10. [Code Map](10_code_map.md) -- Every file in the repo, what it does,
    key functions, and where to look for what.

11. [Known Risks and Open Questions](11_risks_and_open_questions.md) --
    What is unfinished, what is fragile, what to watch out for.

12. [Naming Conventions and Terminology](12_naming_and_terminology.md) --
    Glossary of project-specific terms and naming rules.
