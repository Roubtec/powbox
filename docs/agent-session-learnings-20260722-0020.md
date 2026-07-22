# Agent Session Learnings - 2026-07-22 00:20 UTC

Repository: powbox
Agent: Claude
Session focus: address-review on PR #113 (task/029 peer-review-run) — three codex findings on `docker/shared/peer-review-run` (zombie liveness P1, probe-inclusive timing P2, setup-token auth P2)
Status: Uncommitted retrospective note (pushed to a throwaway branch at the user's explicit request; not part of the PR)

## Summary

- The in-container hermetic suite **masks reap-sensitive bugs** because the agent container's PID 1 is a reaping `docker-init`. The reported P1 (zombie process burning the reap grace) did not reproduce in-container even with the buggy code, yet it is real in a non-reaping environment (the reviewer's, and the host/CI smoke). An agent that trusts the in-container run gets a false "pass" for this class of bug.
- Iterating with `git commit --amend` between fresh review rounds misled a reviewer into a false "diff too large / unrelated changes" blocking finding, because `git diff HEAD~1 HEAD` no longer isolates the round's delta.
- A terminology change (renaming the "ANTHROPIC_API_KEY fallback" to the three-credential "env-credential fallback") needed a full same-pattern sweep across code + comments + test names + docs; sweeping only the code the first time left comment/wording residuals that cost two extra review rounds.

## Issues and Opportunities

### 1. In-container hermetic tests mask process-reaping bugs (reaping PID 1)

- Type: sandbox
- Severity: medium
- Evidence: With the P1 fix reverted, `bash scripts/test-peer-review-run.sh` still reported "passed (234 checks)" in this agent container; case 10i (the exact repro) stayed well under its 5s bound. The reviewer independently observed 7.40s with `--timeout 2` in their environment. Root cause: powbox agent containers launch with `init: true` (`compose.shared.yml`), so PID 1 is `docker-init`, which promptly reaps orphaned/zombie descendants — so a leaked/zombie process never lingers long enough for `reap_tree`'s liveness loop to spin. In a non-reaping PID-1 context (the reviewer's harness, and the intended host/CI smoke Stage 0f), the same code hangs the grace.
- Impact: A reap-grace regression passes the in-container suite, so an agent developing entirely in-container cannot catch it locally — it only surfaces in host/CI smoke or an external reviewer. I had to hand-write Python `fork`/`setpgid` zombie-group tests to confirm both the bug and the fix, because the suite itself could not demonstrate the failure.
- Suggested improvement: Add a reap-sensitive test path that forces a lingering zombie independent of the host's PID-1 reaping — e.g. run the reap-oriented cases under a private PID namespace where the test process is *not* a reaping init (`unshare --pid --fork --mount-proc`, or `bwrap --unshare-pid`), or add a bespoke case that creates a zombie process-group leader (fork + setpgid + exit, parent doesn't wait) and asserts `reap_tree`/`group_alive` reports it not-alive and returns fast. That would let the in-container suite catch the class of bug the reaping init currently hides.
- Repro/trigger: any change to `group_alive` / `reap_tree` / the descendant liveness logic; the in-container run will pass on reap-grace regressions that a non-reaping environment fails.
- Confidence: observed

### 2. `git commit --amend` between review rounds misleads reviewers on the diff base

- Type: workflow
- Severity: low
- Evidence: I amended the single "address codex review" commit across fix rounds. In round 2 the codex peer returned a `blocking` finding: "`git diff HEAD~1 HEAD` contains 178 insertions … not only the ATT_REASON change." That was purely an amend artifact — `HEAD~1` became the fix commit's parent, so the diff was the whole (already-reviewed) fix set. The fresh reviewer separately confirmed it was "a git-mechanics note, not a scope problem."
- Impact: One wasted (false) blocking finding, plus I had to add explicit commit-structure guidance to the round-3 reviewer/peer prompts ("HEAD is one amended commit; its parent is <sha>; diff `<parent> HEAD` for the full fix") to prevent a repeat.
- Suggested improvement: In the address-review flow, when a fix is amended between rounds, always tell the re-reviewer the correct comparison base (the fix commit's parent, or the prior-round SHA) rather than relying on `HEAD~1`. Alternatively, prefer separate fixup commits between rounds and squash only at the end, so each round's delta is a clean `HEAD~1` diff.
- Repro/trigger: any multi-round address-review that amends the fix commit and then hands a reviewer a "diff HEAD~1" instruction.
- Confidence: observed

### 3. Terminology renames need a same-pattern sweep across comments/test-names/docs, not just code

- Type: workflow
- Severity: low
- Evidence: Generalizing "ANTHROPIC_API_KEY fallback" → three-credential "env-credential fallback" — I updated the code paths and the primary comments/docs in the first pass, but missed a `reason` string's annotating comment, the test's `10j` section-header comment, and one internal comment. The peer surfaced these one per round (line 1472, then 786, then the 1469 local mismatch), turning what could have been one fix pass into three review rounds.
- Impact: Two extra reviewer+peer rounds for purely cosmetic wording residuals.
- Suggested improvement: When a fix changes user-facing terminology, `grep` every occurrence of the old term across code, comments, test descriptions, and docs in the same pass (the address-review "preclude repeat comments" step should be read to include descriptive wording, not only the offending code pattern).
- Repro/trigger: any review fix that renames a concept the codebase describes in multiple prose locations.
- Confidence: observed

### 4. Claude Code CLI credential precedence is not in the baked `claude-api` skill

- Type: docs
- Severity: low
- Evidence: The decisive fact for the P2 auth finding was Claude Code's credential order (`CLAUDE_CODE_OAUTH_TOKEN` is checked *ahead* of the stored `.credentials.json` login, with no fall-through in one invocation). The baked `claude-api` skill documents SDK / `ant` CLI credential resolution but not the `claude` **CLI**'s order, so I had to look it up externally (via a `claude-code-guide` agent → code.claude.com/docs). Peer-review-run is powbox's own use of the `claude` CLI's auth, so this gap is directly in scope.
- Impact: One extra verification hop before the auth finding could be triaged as actionable vs. a push-back.
- Suggested improvement: Capture the Claude Code CLI credential precedence chain where powbox agents will find it — e.g. a short note in the powbox docs alongside the "Cross-Agent Delegation" section. (This session already added it to the `peer-review-run` helper header and `docs/architecture.md`, so the helper-specific case is covered; the general note would still help other CLI-auth work.)
- Repro/trigger: any powbox work reasoning about how the headless `claude` CLI picks its credentials.
- Confidence: observed

### 5. The `peer-review-run` source file is not executable in the repo; direct invocation fails

- Type: tooling
- Severity: low
- Evidence: Manually smoke-testing the helper with `./docker/shared/peer-review-run …` returned `Permission denied` (exit 126) because the repo file lacks the `+x` bit (it is `chmod +x`'d only when baked to `/usr/local/bin`). The hermetic harness sidesteps this by invoking `bash "$HELPER"`.
- Impact: A brief detour (one failed invocation) when reproducing behavior outside the test harness.
- Suggested improvement: Minor — either a one-line note in the helper header / test file ("the repo source is not executable; run via `bash`"), or leave as-is since the harness already does the right thing.
- Repro/trigger: invoking the repo source directly rather than via `bash` or the baked path.
- Confidence: observed

## Follow-Up Candidates

- Add a non-reaping-PID-1 (or bespoke zombie-leader) test path to `scripts/test-peer-review-run.sh` so reap-grace regressions are caught in-container (Issue 1).
- Adopt a convention for multi-round address-review: hand re-reviewers the fix commit's parent as the diff base when amending (Issue 2).
- Consider a short "Claude Code CLI credential precedence" note in powbox docs near Cross-Agent Delegation (Issue 4).
