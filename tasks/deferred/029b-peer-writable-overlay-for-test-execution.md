# 029b (deferred) — Let read-only peer reviewers execute the test suite via a writable overlay

## Why this task exists (and why it is deferred)

Read-only peer reviews systematically cannot **execute** tests: build tooling must write caches inside the tree (Vite/SvelteKit's `node_modules/.vite` and `.svelte-kit`, `tsc --incremental` metadata, Go's per-tree artifacts), and the provider's read-only sandbox rejects those writes.
Every Scribz peer review hit this and said so; the consequence is that every peer claim of the form "this test would fail without the fix" is a static judgement — a systematic weakening of the second opinion on exactly the claim that decides whether a fix is genuinely covered, across every repo we run daily.

The peer needs "cannot modify the branch", which is not the same as "cannot write anywhere".
An overlay gives both: the provider sees a **writable view** of the worktree while every write lands in a throwaway upper layer outside it — the real tree is untouched by construction, stronger than the current permission-based read-only promise.

**Deferred because:** it is a larger `peer-review-run` change with a real feasibility unknown (unprivileged overlay support inside our containers), and the current setup is honest about the limitation (agent-skills task 015 makes peers state executed-vs-static explicitly).
Action it after the feasibility spike below says yes.

## Trigger to action this

The spike succeeding, plus the next occasion where a static-only peer verdict materially weakens a review we care about (or spare capacity).

## Scope

**Phase 1 — feasibility spike (timeboxed, throwaway):** in a standard agent container, verify that `bwrap` can present a copy-on-write view of a worktree to a child process. Candidate mechanisms, in order of preference:

1. `bwrap --overlay-src <worktree> --tmp-overlay <worktree>` (bubblewrap ≥0.8 has native overlay options; requires kernel userns overlayfs, mainline since 5.11 — the baked bubblewrap's version and the host-kernel dependency are exactly what the spike must pin down);
2. `fuse-overlayfs` inside a `bwrap --unshare-user` mount namespace (works where `/dev/fuse` is exposed — the same condition rootless Podman already keys on);
3. fallback finding: neither works under our seccomp/caps profile → record why, close as infeasible, keep the honest-static posture.

The spike's acceptance question: inside the overlay, does `pnpm vitest run` (a SvelteKit project) and `go test ./...` (a Go repo) pass while `git -C <real-worktree> status` stays clean and the upper layer captures all writes? Mind pnpm-store symlinks/hardlinks resolving through the read-only lower layer.

**Phase 2 — productize (only after a green spike):**

- `peer-review-run` grows an opt-in `--exec-overlay` mode: wrap the provider invocation in the overlay so the worktree appears writable; relax the provider's own sandbox accordingly (Codex: `--sandbox workspace-write` scoped inside the namespace; Claude: the read-only tool restriction can stay, or gain a Bash-with-tests profile — decide then) — the **overlay**, not provider configuration, becomes the no-branch-mutation guarantee.
- Keep the existing read-only mode as the default; `--exec-overlay` is for callers that want executed verdicts.
- Surface `executedTests: true|false|unknown` (or an equivalent field) in the result JSON so orchestrators and skills can report the verdict's strength honestly.
- Document generically (README/architecture): this is useful to anyone running untrusted-ish reviewers or parallel agents over worktrees, not just our peer loop — writes land in a discardable upper layer, the tree is untouched by construction.
- Hermetic tests in `scripts/test-peer-review-run.sh` style (fake provider writes into the tree; assert the real tree is untouched and the write landed in the upper layer), plus a smoke case on a rebuilt image.

Out of scope: network policy changes, provider CLI changes, per-repo cache relocation (that cheaper repo-side alternative is already in the Scribz handoff and remains valid independently).

## Context and references

- `docker/shared/peer-review-run` — the runner this extends; its header documents the current isolation posture and the same-UID traversal residual (the overlay improves on both for the worktree surface).
- `docs/architecture.md` peer-review-run bullet — the result contract to extend (`executedTests` field) and where the mode gets documented.
- `docs/rootless-podman.md` — the existing `/dev/fuse`-vs-`vfs` detection precedent for mechanism 2.
- Task 029 (`tasks/done/`) — the runner this family extends. Its sibling 029a (peer `VERDICT: PASS` notes) was re-homed to `Roubtec/agent-skills` as its task 015a when powbox forfeited the workflows (see task 051), since every peer-prompt constructor now lives there.
- The agent-skills peer-protocol task (015 there) — its executed-vs-static honesty rule is what the new result field feeds.

## Implementation notes

- The overlay must mount at the worktree's **real path** inside the namespace so relative tooling paths and embedded absolute paths keep working.
- `.git` in linked worktrees is a file pointing at `.git/worktrees/...` in the shared volume — the commondir must be readable through the lower layer; test that `git diff`/`log` work inside the overlay.
- Watch interaction with the artifact-dir privacy model: the provider's output file still lives OUTSIDE the overlayed worktree; only the worktree view changes.
- Concurrency: upper layers are per-invocation tmpfs — size them (or make size configurable) so a full `node_modules` copy-up cannot OOM the container; most test runs copy up only caches, but a stray `pnpm install` inside the overlay would balloon.

## Acceptance criteria

- Phase 1: a written spike result (works via mechanism 1/2 with exact versions and caveats, or infeasible-with-reasons) committed as a short doc or task update.
- Phase 2: `--exec-overlay` runs a real suite green inside the overlay with the real tree provably untouched; result JSON reports execution strength; default behavior unchanged; hermetic tests cover the untouched-tree invariant.

## Validation

- Hermetic suite passes in-container; live smoke on a rebuilt image runs vitest in an overlayed SvelteKit worktree and asserts `git status --porcelain` empty afterwards.

## Review plan

Reviewer attacks the no-mutation guarantee (can any provider write path reach the lower layer? symlink/hardlink escape through the pnpm store?), checks the executed-vs-static reporting cannot claim more than what ran, and confirms the default path is byte-identical to today.
