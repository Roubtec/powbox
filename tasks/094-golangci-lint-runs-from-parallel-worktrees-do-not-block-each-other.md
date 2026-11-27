# 094 — `golangci-lint` runs from parallel worktrees do not block each other

**Relates to:** `docker/layers/full/golangci-lint-wrapper.sh`, `docs/architecture.md` → "Bundled Go toolchain", and the Go row of the `full` set's agent notes.

## Why this task exists

The wrapper already gives each worktree its own analysis cache, so one worktree's run never reads another's stale results. It does nothing about the linter's own guard against concurrent runs. That guard is a single lock for the whole container, so when several worktrees lint at the same moment, all but one fail or wait, and the failure reads as a lint error on a branch whose code is fine.

Parallel worktrees are how the batch skills work, and each of them lints before delivery, so the collision is the ordinary case for a Go project and not a coincidence. An agent that meets it has no signal that the cause is a sibling: it re-runs, or worse, starts "fixing" lint.

## Goal

A `golangci-lint` run in one worktree neither blocks nor is blocked by a run in another, with no flag for the caller to remember. Two runs in the same worktree may still exclude each other; that is what the guard is for.

## Direction and landmines

- **Establish where the lock lives first.** Its location was inferred from the binary, not observed. Reproduce the collision with two worktrees before changing anything, and write down what was found, since the fix depends on it.
- If the lock sits in a temporary directory, scoping that directory per worktree in the wrapper is the natural fix and mirrors what the wrapper already does for the cache. Whatever is scoped must not also redirect files that other tools in the same run expect at the shared location.
- The linter has its own switch for permitting parallel runs. Prefer scoping the lock over turning the guard off: the guard is right within one worktree, and a switch that disables it everywhere trades a visible failure for possible cache corruption.
- The wrapper is deliberately transparent and must stay so: an explicit setting from the caller or the project still wins, and no failure of the wrapper's own setup may stop the lint from running.
- Outside a Git worktree the wrapper has nothing to scope by and should behave as it does today.
- The `full` set is not built in CI, so this needs the maintainer's host build to validate end to end. Anything about the wrapper that can be pinned without the real binary belongs in a pure-shell suite, as the cache scoping is.

## Acceptance

- Concurrent lint runs in separate worktrees of one repository all complete on their own merits.
- Two concurrent runs in a single worktree still behave as the linter intends.
- A caller's own explicit configuration of the affected setting is honoured.
- The architecture chapter says how the lock is scoped and why the guard was kept.
