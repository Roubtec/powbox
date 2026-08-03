# Task 057 — wt-remove: guard an in-progress bisect (and audit the guard set against git's own operations)

## Why this task exists

`wt-remove` exists to remove a worktree but **never work** — its header promises it refuses even with `--force` when the tree holds unsaved work or an operation in progress.
It currently guards `git status --porcelain`, `rebase-merge`, `rebase-apply`, `MERGE_HEAD` and `CHERRY_PICK_HEAD` (`docker/shared/wt-remove:104-110`).
It does **not** guard a bisect, and `git status --porcelain` is **empty** during one — so every guard passes and `wt-remove <slug>` silently deletes the worktree together with its `BISECT_LOG`/`BISECT_START`.

This was reproduced end to end during task 039 (git 2.47.3): `git bisect start` in a sibling task worktree, then `wt-remove <slug>` → `wt-remove: removed …`, bisect state gone.
Plain `git worktree remove` behaves the same way, so the helper's stated contract is the only protection and it does not hold here.

Task 039 (PR #125) addressed the half it owned: `wt-enter` no longer *advises* removal at all. That is the braces. This task is the belt — the guard belongs in the helper that does the removing, so a caller who reaches for `wt-remove` directly is protected too.

Note the same review also found an interrupted `git revert` (`sequencer/` + `MERGE_MSG`, clean status) slipping through, which is why the scope below is an audit rather than a single `BISECT_LOG` check.

## Scope

Included:

- Add a bisect guard to `wt-remove`, keyed on the same state files git itself consults (`BISECT_LOG`, with `BISECT_START`), resolved via the worktree's own git dir rather than the enclosing repo's.
- **Audit the full guard set** against the operations git can leave in progress and close the gaps the audit finds — at minimum `sequencer/` (multi-commit `revert`/`cherry-pick`) and `REVERT_HEAD`, both of which leave `git status --porcelain` empty in the shapes observed during task 039.
- Preserve the existing contract exactly: the guard must hold **even with `--force`** (that is the documented inversion of vanilla `git worktree remove --force`), the branch is always kept, and `--force` still passes through only after the clean checks pass.
- Keep the refusal message actionable: name which operation is in flight and where, and point at inspection (`git -C <path> status`, `git -C <path> bisect log`) — **not** at a way to discard it. Task 039 removed destructive advice from `wt-enter`; do not reintroduce the class here.
- Cover every newly guarded state in `scripts/test-wt-orphan-safety.sh` (or a sibling pure-shell suite), including the `--force` path.

Out of scope:

- Changes to `wt-enter` or `wt-bootstrap`.
- Any auto-remediation (finishing or aborting an operation on the caller's behalf).
- Teaching `wt-remove` to remove a worktree that is genuinely mid-operation via some new escape hatch — if a maintainer truly wants that, vanilla `git worktree remove --force` is still available and is the honest way to ask for it.

## Context and references

- `docker/shared/wt-remove:104-110` — the current guard block.
- `docker/shared/wt-common.sh` — where task 039 put its state-file readers; a `wt-remove`-side guard should reuse or mirror that resolution rather than re-deriving the git dir. Note 039's readers resolve the worktree's git dir with `git -C <wt> rev-parse --absolute-git-dir` **and cross-check the resolved toplevel**, because task worktrees live inside the main working tree, so a worktree that lost its `.git` pointer otherwise resolves against the *enclosing* repo and would report the wrong state.
- `git`'s own `wt-status.c` (`wt_status_check_rebase` / `wt_status_check_bisect`) and `worktree.c` (`find_shared_symref`) — the authority for which state files mean "operation in progress", including the `rebase-apply` + `applying` marker that distinguishes `git am` from a rebase.
- `scripts/test-wt-orphan-safety.sh` — the suite to extend; it already has fixtures for interrupted rebase, bisect (detached and on-branch), and mid-revert, plus a `destructive_advice` detector.

## Target files or areas

- `docker/shared/wt-remove`, possibly `docker/shared/wt-common.sh`
- `scripts/test-wt-orphan-safety.sh`
- `docker/shared/container-agent.md.tmpl` — its `wt-remove` bullet enumerates what the helper refuses on; it must stay accurate.
- README "Worktree helpers" if it repeats the list.

## Implementation notes

- Prefer probing with existence semantics (`-e`, matching git's bare `stat()`) rather than `-d`: task 039 found real git *allows* a checkout when `rebase-apply` is a regular file beside a valid `rebase-merge`, because it stops at the first backend and gets no branch.
- A state file that cannot be read should refuse the removal (fail safe), not permit it. This is the opposite of `wt-enter`'s bias, and correctly so: there, an unknown degrades to git's own message; here, an unknown means we cannot prove the tree is safe to delete.
- Do not parse git's localizable output anywhere in the logic.
- `wt-remove` is also invoked by the batch skills after a PR is opened, so a false refusal has a real cost — make sure a clean, operation-free worktree is still removed without friction.

## Acceptance criteria

- A worktree with a bisect in progress is **not** removed, with or without `--force`, and the refusal names the bisect — verified by test.
- The same holds for every other state the audit identifies (at minimum a multi-commit `revert`/`cherry-pick` `sequencer/` and `REVERT_HEAD`).
- A clean worktree is still removed normally, and `--force` still works for ignored build artifacts after the clean checks pass — verified by test.
- The refusal message points at inspection only; the suite's `destructive_advice` detector passes on it.
- `wt-remove`'s header contract, `container-agent.md.tmpl`'s bullet, and any README mention all match the new behavior.

## Validation

- `bash scripts/test-wt-orphan-safety.sh` passes, with the new cases shown to be load-bearing (they must fail against the pre-change `wt-remove` via the suite's `POWBOX_WT_REMOVE` override).
- `shellcheck` / `shfmt -d` clean.
- Manual, in a throwaway scratch repo: start a bisect in a worktree, run `wt-remove <slug>` and `wt-remove <slug> --force`, confirm both refuse and the bisect state survives.

## Review plan

Reviewer verifies the guard set against git's own state-file semantics rather than against intuition — fabricating each state and asking real git what it considers in progress — confirms the fail-safe direction on an unreadable state file, confirms `--force` cannot bypass the guard, and confirms no refusal message suggests a way to discard the operation.
