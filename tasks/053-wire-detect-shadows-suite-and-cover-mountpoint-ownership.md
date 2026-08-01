# Task 053 — Run the detect-shadows unit suite automatically, and cover the shadow-mounts mountpoint chown

## Why this task exists

`scripts/test-detect-shadows.sh` is now the largest pure-shell unit suite in the repo (93 assertions after PR #121) and it guards genuinely load-bearing security properties: the under-workspace-root validation, the symlink skip, the Git-tracked-content veto, the newline rejection, and the workspace-glob containment.
Every one of those cases was verified to fail against the pre-fix script — they are real regression tests.
And **nothing runs them**: Tier 0 CI (`.github/workflows/native-linux-ci.yml`) runs only exec-bits, shellcheck, shfmt, and PSScriptAnalyzer, and `commands/smoke-test.sh` does not invoke the suite the way it invokes `test-sensitive-host-path.sh` (Stage 0/0a), `test-gh-review-threads.sh` (Stage 0b), `test-wt-orphan-safety.sh` (Stage 0c/0d), and `test-peer-review-run.sh`.
So a future edit to `detect-shadows.sh` can silently reopen any of those holes, and only a reviewer who happens to run the script by hand would notice.

Separately, the mountpoint-ownership `chown` added to `docker/shared/shadow-mounts.sh` in PR #121 (see its thread on "Create absent artifact mountpoints as the workspace owner") has **no automated coverage at all**.
It cannot be unit-tested from inside an agent container — the script must run as root and mount tmpfs, and the container's scoped sudoers only permits the *baked* `/usr/local/bin/shadow-mounts.sh`, not a repo copy — so the coverage has to live in the host/CI smoke tier, where a real image and root are available.
It was reviewed by hand (with instrumented `chown`/`mount` shims) rather than by a test, which is exactly the state this task ends.

Raised by the independent reviewer during the PR #121 review round; deferred out of that PR because wiring a new smoke stage cannot be executed or validated from inside an agent container, and shipping an unrunnable harness edit blind is worse than queueing it.

## Scope

1. **Wire `scripts/test-detect-shadows.sh` into `commands/smoke-test.sh`** as a new hermetic Stage 0-family entry, following the shape of the existing ones.
   Prefer the **in-image** invocation (`docker run --rm -v "${ROOT_DIR}:/repo:ro" --entrypoint /bin/bash "$IMAGE" /repo/scripts/test-detect-shadows.sh`) with a recorded skip when the image is absent, rather than a bare host run: the suite needs `yq`, `jq`, and `git`, which the image guarantees and an arbitrary host does not.
   Record the skip in the `skipped+=(...)` array like Stage 0a does.
2. **Cover the mountpoint-ownership chown** in the smoke tier. `scripts/smoke-test-worktree-metadata.sh` already invokes `/usr/local/bin/shadow-mounts.sh` directly against a real workspace, so it is the natural host: after a mount whose target did **not** exist beforehand, assert the underlying mountpoint directory is owned by the workspace tree's owner and not root.
   Asserting on the *underlying* directory means checking it before the mount, or unmounting and re-`stat`ing — pick whichever keeps that script's existing flow simplest and say which in the PR.
   At minimum cover: a single created component (`<proj>/bin`, parent exists), and a multi-component creation (`<ws>/.claude/worktrees`, where two levels are created).
3. Decide whether the detect-shadows suite also belongs in **Tier 0 CI** (`native-linux-ci.yml`) rather than only the smoke tier. It is hermetic apart from `yq`/`jq`/`git`, and Tier 0 already installs tools it needs — a Tier 0 run would give the fastest feedback on a `detect-shadows.sh` edit. State the choice either way.

Out of scope:

- Changing any behavior in `detect-shadows.sh` or `shadow-mounts.sh`.
- Adding new assertions to `test-detect-shadows.sh` itself (it is current as of PR #121).
- Reworking how `commands/smoke-test.sh` stages are numbered.

## Context and references

- PR #121 — https://github.com/Roubtec/powbox/pull/121 (the .NET `bin`/`obj` shadow scan; adds the tests and the chown).
- `commands/smoke-test.sh` — Stage 0 / 0a (`test-sensitive-host-path.sh`, host then in-image), Stage 0b, 0c/0d for the established pattern, including the `skipped+=(...)` bookkeeping.
- `scripts/smoke-test-worktree-metadata.sh:142`, `:224` — existing direct `/usr/local/bin/shadow-mounts.sh` invocations under root.
- `docker/shared/shadow-mounts.sh` — the `new_dirs` / `deepest_existing` walk, the per-directory symlink and containment re-validation, and the once-per-run warning.
- `AGENTS.md` → "Validating Changes" — why image builds and smoke runs are host/CI-only and cannot be executed from an agent container.

## Target files or areas

- `commands/smoke-test.sh` (new stage)
- `scripts/smoke-test-worktree-metadata.sh` (ownership assertions)
- possibly `.github/workflows/native-linux-ci.yml` (item 3)

## Implementation notes

- This task **must be validated on the host** (`./build.sh all`, then `commands/smoke-test.sh`), not in an agent container — that constraint is the reason it was queued rather than folded into PR #121.
- Keep the new stage hermetic and unconditional-when-possible so it cannot silently degrade into a permanent skip.
- The ownership assertion must tolerate a Windows/FUSE bind mount where `chown` is a no-op — gate it on the native-Linux path the surrounding smoke script already branches on, or assert only that ownership is not *root* when the tree's owner is not root.

## Acceptance criteria

- A `commands/smoke-test.sh` run executes `scripts/test-detect-shadows.sh` and fails the smoke if any assertion fails.
- A regression that removes the `chown` from `shadow-mounts.sh` is caught by an automated smoke assertion rather than by review.
- Item 3's decision (Tier 0 or not) is recorded in the PR description.
