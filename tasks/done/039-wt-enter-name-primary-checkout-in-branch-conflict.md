# Task 039 — wt-enter: say explicitly when the blocking worktree is the primary checkout

## Why this task exists

When `wt-enter <slug> <branch>` fails because the branch is checked out elsewhere, git's underlying error reads `fatal: '<branch>' is already used by worktree at '/workspace/<slug>'`.
When that path is the **primary checkout** (a human or peer switched the main working tree onto the branch mid-session), the message is accurate but routinely misread as a stale-worktree problem: an agent in a long scribz session burned a diagnostic detour confirming via `git reflog` that nothing had been lost, before realizing the main checkout itself was sitting on the branch.

The failure needs to name the situation: "the branch you want is checked out in the **main working tree**, which is shared with humans and peer agents — do not detach it blindly."

## Scope

Included:

- In `wt-enter`, when resolving/attaching/creating fails because the branch is in use by another worktree, detect whether the blocking worktree is the repository's primary checkout (compare against the main working tree path, e.g. via `git worktree list --porcelain` first entry / the common dir's parent).
- Emit a tailored error for that case: state that the branch is checked out in the shared main checkout, that a human or peer may be using it, and that the caller should either pick a different branch, or coordinate before switching the main checkout off the branch. Do not auto-detach or auto-switch anything.
- For the ordinary case (blocked by a sibling task worktree), keep the current behavior but include the blocking path prominently (it already appears in git's message; ensure `wt-enter` surfaces it rather than swallowing it).
- Cover both cases in `scripts/test-wt-orphan-safety.sh` or a sibling pure-shell test if that suite's fixtures don't fit.

Out of scope:

- Any automatic remediation (detaching the main checkout, force-moving branches).
- Changes to `wt-bootstrap` / `wt-remove`.

## Context and references

- `docker/shared/wt-enter` — the resolve/attach/create logic; the error currently propagates from `git worktree add`.
- `docker/shared/wt-common.sh` — shared helpers, likely home for a "primary checkout path" resolver.
- `docker/shared/container-agent.md.tmpl` "Shared vs. isolated surfaces" — the doc note this error message should reinforce.

## Target files or areas

- `docker/shared/wt-enter`, possibly `docker/shared/wt-common.sh`
- `scripts/test-wt-orphan-safety.sh` (or a new focused test file following its conventions)

## Implementation notes

- `git worktree list --porcelain` lists the main working tree first; match the blocking path from git's error (or pre-check with `git branch --list --format` / `git for-each-ref` + worktree list) rather than parsing the fatal message if a pre-check is cleaner.
- Keep stdout discipline: `wt-enter` prints ONLY the worktree path on stdout; all new messaging goes to stderr.
- Preserve exit codes and the rerun-safe contract documented in the helper header.

## Acceptance criteria

- Blocking-by-primary-checkout produces an error that names the main checkout, warns it is shared, and suggests coordination — verified by test.
- Blocking-by-sibling-worktree keeps the existing semantics and shows the blocking path — verified by test.
- stdout still carries only the path on success; nothing on failure.

## Validation

- The pure-shell test(s) pass in-container.
- `shellcheck` / `shfmt -d` clean.
- Manual: create a scratch repo, check a branch out in the main tree, run `wt-enter x <that-branch> main`, observe the new message.

## Review plan

Reviewer verifies the primary-checkout detection is robust (porcelain parsing, no locale-dependent message matching), no behavior change on the success path, and stderr/stdout discipline holds.
