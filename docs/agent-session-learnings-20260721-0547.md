# Agent Session Learnings - 2026-07-21 05:47 UTC

Repository: powbox
Agent: Claude
Session focus: Parallel worktree-isolated implementation of four pre-planned tasks (025, 027, 029, 031) via the `address-tasks` skill — implement→review→fix loop with a Codex peer each round, then PRs + a local review-stack.
Status: Uncommitted retrospective note

## Summary

- The Codex peer was genuinely valuable (caught real bugs three fresh own-reviewers had missed) but became **unreliable under sustained concurrency** — on late rounds it did the review yet exited without emitting its `-o` verdict, forcing retries and forfeits.
- Several orchestration footguns cost turns: a `pkill -f` pattern that matched the killer's own command line, and an implementer subagent that spawned its own background `codex` review which orphaned and had to be hunted down.
- Repeated per-round friction re-deriving the same `shfmt`/extensionless-file exception suggests a one-time normalization or a documented exception would pay for itself.
- This batch is itself strong validation of task 029 (`peer-review-run`): almost all the manual peer-launch scaffolding I hand-rolled is exactly what that helper is meant to own.

## Issues and Opportunities

### 1. Codex `codex exec` peer drops its final output under sustained concurrency

- Type: tooling
- Severity: high
- Evidence: Early/mid review rounds returned clean `VERDICT:` output. On the final rounds of tasks 027 and 029, `codex exec --sandbox read-only --cd <wt> -o <file>` exited with an **empty `-o` file** despite stderr showing it actively reviewing (reading the right files; one run even executed a unit test and ran `gh pr view`). A single retry died in ~10 s. `codex login status` still reported logged-in throughout, so it was not an auth drop. Peak concurrency was ~4–6 simultaneous `codex exec` peers across rounds.
- Impact: Two final-round peers forfeited after retries; extra diagnosis turns; reduced peer coverage on the last (small) changes. Not fatal — best-effort policy handled it — but it eroded the second-opinion signal exactly when convergence mattered.
- Suggested improvement: (a) Cap concurrent `codex exec` peers (e.g. 2–3) and/or add small startup jitter when an orchestrator fans out peers; (b) treat an empty `-o` with non-empty progress stderr as a distinct "incomplete/among transient" outcome and retry with backoff rather than one fast retry; (c) confirm whether this is a Codex soft rate-limit vs. an `--output-last-message`/`-o` write bug — capture `codex exec`'s own exit status and any rate-limit stderr signature. Task 029's `peer-review-run` already normalizes most of this and should be the standard path once baked.
- Repro/trigger: Fan out many concurrent `codex exec` read-only reviews over an extended session; watch the last waves.
- Confidence: observed (symptom); inferred (root cause — rate-limit vs. output-file bug not confirmed)

### 2. `pkill -f <pattern>` self-matches the killing command's own argv

- Type: workflow
- Severity: medium
- Evidence: To reap an orphaned background `codex` writing to `scratchpad/codex-review.md`, I ran `pkill -f "scratchpad/codex-review.md"`. Because that literal string was in the running shell's own command line, `pkill -f` matched and killed the command itself (exit 144); the intended targets survived and the peer I meant to launch in the same block never started.
- Impact: One wasted turn plus a re-do with a self-excluding loop (`for p in $(pgrep -f ...); do [ "$p" = "$$" ] && continue; kill "$p"; done`).
- Suggested improvement: Document the footgun in orchestration guidance (or ship a tiny `safe-pkill` helper that excludes `$$` and its ancestors by default). For agents: prefer `pgrep` → filter `$$` → `kill` by PID, or match on a string that cannot appear in the reaping command (e.g. an absolute binary path), never a token you just typed.
- Repro/trigger: Any `pkill -f`/`pgrep -f` whose pattern text also appears in the invoking command.
- Confidence: observed

### 3. Implementer subagent spawned its own background `codex` review that orphaned and gave an incomplete final report

- Type: agent-instructions
- Severity: medium
- Evidence: The 025 round-4 implementer committed and pushed its work, then launched its own `codex` self-review under `setsid` with a "monitor," and returned a final message of only "Waiting for the codex review monitor to fire before finalizing." The actual work was already committed/pushed cleanly, but its `codex` child kept running (now reviewing an empty diff, since the changes had been committed) and had to be detected and killed by the orchestrator. Separately, that self-review — launched without a tight `--cd` — wandered into an unrelated sibling worktree.
- Impact: Orchestrator spent turns verifying the branch state (it was fine), hunting the orphaned process, and reconstructing the implementer's report from its commit + the leftover codex prompt.
- Suggested improvement: (a) In implementer/reviewer subagent prompts, explicitly forbid launching background review processes that can outlive the subagent (or require they be reaped before returning). (b) The orchestrator's own peer step is the sanctioned place for a peer opinion; subagents needn't run their own. (c) If the harness can reap a subagent's background children on completion, that would remove the orphan class entirely.
- Repro/trigger: A delegated implementer decides to self-review via a detached tool and returns before it finishes.
- Confidence: observed

### 4. Repeated re-derivation of the `shfmt` / extensionless-`pg-dev-up` exception

- Type: docs
- Severity: low
- Evidence: Across many 027 review rounds, every reviewer independently re-explained that `shfmt -d` shows pre-existing indented-`case` diffs on the extensionless `docker/shared/pg-dev-up`, that `main`'s copy shows the identical diff, and that CI's `shfmt` step is advisory and only globs `*.sh` (so the file is not even checked). Correct each time, but re-litigated repeatedly.
- Impact: Reviewer tokens/turns spent rediscovering a known, benign exception; mild risk of a reviewer treating it as a finding.
- Suggested improvement: Either normalize `docker/shared/pg-dev-up` (and peers) to the shfmt default once, or add an `.editorconfig`/`.shfmt`/documented note (e.g. in AGENTS.md "Validating Changes") stating the indented-`case` house style and that `shfmt` is advisory and `*.sh`-scoped. A one-line pointer would stop the re-derivation.
- Repro/trigger: Any review touching an extensionless shell helper in `docker/shared/`.
- Confidence: observed

### 5. Peer-review orchestration was hand-rolled many times (validates task 029)

- Type: automation
- Severity: medium
- Evidence: For every peer round I manually built the same scaffolding: per-round artifact dirs, a prompt file, `setsid codex exec --sandbox read-only --cd <wt> -o … -c mcp_servers={} -c model_reasoning_effort=high`, separate stderr, then polling/watchers for completion and empty-output classification. This is precisely the surface task 029's `peer-review-run` is designed to own (scoped `--cd`, literal prompt on stdin, timeout/retry, normalized outcomes, cleanup).
- Impact: Significant repeated boilerplate and the exact failure modes (unscoped wander, empty-output ambiguity, manual retry) that a supervised runner prevents.
- Suggested improvement: Once `peer-review-run` is baked, adopt it in the `address-tasks`/`address-review` skills and workflows for the delegated-peer step, replacing hand-rolled `codex exec` launches. This session is a concrete case study for that adoption.
- Repro/trigger: Any multi-round delegated review loop that wants a peer second opinion.
- Confidence: observed

## Follow-Up Candidates

- Add an orchestration note (or `safe-pkill` helper) covering the `pkill -f` self-match footgun.
- Decide on task 029's recommended bubblewrap/mount-namespace follow-up (raised in PR #113) to close the documented same-UID artifact-traversal residual — and, relatedly, give `peer-review-run` a concurrency cap + backoff for the empty-`-o` failure mode in #1.
- Normalize or document the extensionless-shell-helper `shfmt` exception so reviewers stop re-deriving it.
- After `peer-review-run` (029) is baked, wire it into the peer step of the `address-tasks`/`address-review` skills/workflows.
