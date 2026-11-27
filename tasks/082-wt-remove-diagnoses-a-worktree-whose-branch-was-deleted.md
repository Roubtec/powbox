# 082 — Make `wt-remove` diagnose a worktree whose branch was deleted

**Relates to:** `docker/shared/wt-remove` and its suite `scripts/test-wt-orphan-safety.sh`, the worktree helpers' "never discard work" contract (AGENTS.md and the container instructions, "Worktree helpers"), and `wt-bootstrap`'s orphan reaping.

## Why this task exists

A merged PR's branch is routinely deleted, often host-side or by a prune, while the task worktree that produced it is still registered. Its `HEAD` then names a branch that no longer exists: `git worktree list` shows `0000000`, and every tracked file reads as a staged addition. `wt-remove` reports this as "worktree has uncommitted changes". That is technically true, but it misleads: the tree usually holds nothing new. The agent then has to rediscover by hand what the worktree last pointed at, diff the tree against it, check that the commit reached the remote, and fall back to vanilla `git worktree remove --force`. That escape hatch is the very thing the helper exists to make unnecessary.

## Goal

`wt-remove` says what actually happened: the worktree's branch is gone, and the commit it was last on can be named. Optionally, it can then prove there is nothing to lose and remove the worktree without `--force`.

## Direction and constraints

- Unknown still means refuse. Removal without `--force` is acceptable only when the tree, index and untracked set are provably identical to a commit that is reachable from a remote-tracking ref. Anything weaker gets a precise refusal message, never a removal.
- A deleted branch does not erase what the worktree was on. That commit survives in the worktree's own `HEAD` reflog under its admin dir, which the helper already resolves without `git -C <wt>`.
- Landmine: if the branch was rebased or force-pushed elsewhere before deletion, the commit the worktree was on may no longer be reachable from any remote ref, even though equivalent commits were merged. Refusing with a clear diagnosis is the right answer there. A patch-equivalence proof is out of scope, unless it falls out cheaply and stays strict.
- The in-progress-operation checks keep their precedence. A deleted branch must not mask a rebase, merge or bisect left in the worktree.
- Consider whether `wt-bootstrap`'s orphan handling should recognise the same state. Keep its "quarantine rather than delete" behaviour for anything not proven safe.
