Story A:
1: also make sure zbamidbar/container-data/webserver doesn't exist

2: We need to do a little work on foundations before we veer into implementing this story. the foundation should include the minor version of FreeBSD too, like 15.0 or 15.1. Then, within that file, we should write the patch version (which on parasa is the artifact name) --> it's possible we should go from git commit to patch, but I don't know how those are determined / how to get it, and I do know how to get the git commit.

7: We should do this a separate place from tablets, in case someone else is building a foundation. Perhaps you can suggest a few names

Story B:
1: And check the patch-level for that foundation

2: this was never properly explained, so we'll need to explain this here and then add it to the necessary docs around the repo:

each foundation has a canonical dataset under zbamidbar/sinai.zfs/foundations/<kernel-streamMajor.Minor>@artifact-name (patch-level). We will actually want to make a parallel stream in zbereshit: zbereshit/foundations/<kernel-streamMajor.Minor>@artifact-name. This is because we will then use this duplicated source as clone origin for the system. eg we will clone the zbereshit dataset snap as the container's base image, and apply the deltas from parasa on top of that. This means that if two containers are at the same patch level, we only have one copy of that patch on disk (minus deltas). Even if we have two containers at different patch levels, they're still mostly the same underlying data, with only the incremental diffs in between. Then, when updating containers (through complete destroy and rebase, since zfs can't fast-forward, I don't think), if we ever end up with snapshots which are older than anything we use, we can delete them from zbereshit.

3: we should figure out what we want to do about the foundations having .git. This implies that they get more and more git cruft in them over time. Ideologically, they shouldn't have .git in them at all. I don't know how to solve this conundrum however.

4: research jails and fstab. We shouldn't be needing to take over this at all. there IS a way to do fstab in jails, and we should be doing that.

5: or, during bootstrap, we can set etc/jail.conf to
```
include ${minhag_dir}/containers/*/jail.conf
include ${minhag_dir}/systems/*/jail.conf
```

Story D:
3: the commit message should be "artifact-name"<newline>"admin message"

4: duplicate above message

Story E:

1: This should be interactive too. All of parasa should be interactive where possible. If the container is still running, ask to shut it down. Do this only after verifying there are no other blockers, like foundation exists, no unsaved diffs. Why do you need to read the current foundation?

3: see above notes on this, but we'll just clone from zbereshit if it exists, or send-recv an increment between zbamidbar and zbereshit, and then clone that.

3.5: we need to restart the jail, right?

4: ask to upgrade pkgs, this might be breaking and the admin may want to do it in two stages

5/6: how does compose.sh interact with the git diffs, shouldn't we do compose.sh, then git pull, then derivations.local? because git diff is really good at deferring same-same changes, whereas compose.sh may not be.

8: this is true of a breaking <kernel-streamMajor.Minor> change. on a patchlevel change, rewrite the contents. (no longer zero-byte)

Story F:

we'll want to re-workshop all the fstab stuff once we understand how to get it hooked up to jail start-stop natively.

RE: Why this matters for updates:

well, we wouldn't destroy any foreign mount at any time anyway, would we? that seems wrong to do. So it's moot to call out here. Mostly it's important because who cares if somebody set up their container to have home/webmaster as a dataset. we don't need that in the repo. what we do need are things like you call out, a foreign postgres-data mount, that's provided by one app and demanded by another. that must be coordinated across containers, so is worth logging into the recipes.

Ah, ok, yes destroy container would be a time to destroy a foreign dataset, and is a good callout to not let shared datasets be destroyed without permission.

Story G:

1: see above on interactivity

2: interactive on all listed out items. user may want to keep the git branch, for example, or the zshemot recipe


