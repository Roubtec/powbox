# Agent Session Learnings - 2026-10-01 18:50 UTC

Repository: Roubtec/powbox
Agent: Claude
Session focus: `address-review` on PR #161 (reject `ONBUILD` in layer sets), six fresh-reviewer + codex-peer verification rounds
Transport: Temporary branch `learnings/session-20261001-185010` (no PR)

## Summary

- A hand-rolled background `codex exec` peer review hung on an open stdin for about 28 minutes, and nobody noticed until the user asked whether the peer was still alive. The documented one-shot form omits `</dev/null`, and the baked `peer-review-run` helper that already solves this (prompt on stdin, timeout, reaping) was never used.

## Issues and Opportunities

### 1. `codex exec` blocks on an open stdin when run in the background

- Type: agent-instructions
- Severity: high
- Evidence: in round 3, `codex exec --sandbox read-only -o <file> "<prompt>" > peer.log 2>&1` was launched as a background Bash command without a stdin redirect. Its log held only `Reading additional input from stdin...` (39 bytes) from launch until it was killed about 28 minutes later. Rounds 1 and 2 used the same invocation and completed. Rounds 4 to 6 added `</dev/null`, and those runs began emitting reasoning within seconds and finished normally.
- Impact: the round's peer opinion was forfeited and roughly half an hour of wall-clock was lost. The orchestrator was waiting on a completion notification that only comes when the process exits, so the hang was invisible until the user noticed the peer was silent.
- Suggested improvement:
  - Add `</dev/null` to the one-shot form in the "Delegating to another agent" text, which `docker/shared/entrypoint-agent.sh` seeds through `AGENT_ONESHOT`, and to the `codex review` form beside it. Say why: `codex exec` reads extra prompt input from any non-TTY stdin.
  - In the same text, point peer reviews at the baked `peer-review-run`. It feeds the prompt on stdin, supervises with a timeout and reaps the process tree, so neither the hang nor its invisibility can happen.
- Repro/trigger: run `codex exec … "<prompt>"` from a harness whose stdin is an open pipe, for example the Bash tool with `run_in_background: true`. Whether it blocks seems to depend on the harness's stdin at that moment, which would explain why identical invocations sometimes completed (inferred).
- Confidence: observed (hang and fix); inferred (why the earlier rounds escaped)

### 2. `address-review` defers peer mechanics to `review-cycle`, which was never loaded

- Type: workflow
- Severity: medium
- Evidence: `address-review` says the peer step's rules come from `review-cycle` ("The peer step") and restates none of them. The orchestrator never invoked `review-cycle`, so it improvised the peer call from the CLAUDE.md one-shot line instead of using `peer-review-run`.
- Impact: the hand-rolled call missed the timeout, supervision and stdin handling the helper provides. Item 1 is the direct consequence.
- Suggested improvement: name `peer-review-run` (with its required flags) at `address-review`'s peer step itself, or tell the skill to load `review-cycle` before the first verification round. Either way the helper becomes the default path, not something only discoverable from the other skill.
- Repro/trigger: any `address-review` run where the agent follows the skill text alone.
- Confidence: observed

### 3. `pkill -f <pattern>` killed the agent's own shell

- Type: tooling
- Severity: low
- Evidence: stopping the stalled peer with `pkill -f '<codex command line>'` returned exit 144. The pattern also appeared in the Bash tool's own command line, so `pkill` signalled the wrapper shell running it.
- Impact: one confusing failed tool call and a follow-up check that the peer was actually gone.
- Suggested improvement: with `peer-review-run`, use its own reaping and timeout instead. Otherwise record the peer's PID or process group when launching it, and kill that rather than pattern-matching.
- Repro/trigger: `pkill -f` with a pattern that also appears in the invoking command line.
- Confidence: observed

### 4. Verification rounds had no proportionality stop for adversarial-only findings

- Type: workflow
- Severity: medium
- Evidence: both threads were closed by round 3 through an authoritative image-config check. Rounds 3 to 5 still each failed on a new parser-divergence case:
  - a zero-width character read differently by PowerShell's culture-aware comparison
  - invalid UTF-8 in a heredoc name
  - encoded surrogates accepted by older libiconv

  Every case needed a deliberately malformed Dockerfile in a maintainer-owned file. The user asked why such edge bytes mattered.
- Impact: three extra fix and review rounds, each costing roughly 10 to 20 minutes of reviewer time. The fixes were real, but the review cycle had no rule for when to hand such findings to a follow-up task instead.
- Suggested improvement: let `review-cycle` carry a threat-model or proportionality note in the Reviewer brief, for example "block only on accidental-input failures or a parity break on a supported host; queue adversarial-only hardening as a follow-up", so the orchestrator can apply it without improvising.
- Repro/trigger: review cycles on parsers or validators that face trusted input but are checked against a reference implementation.
- Confidence: inferred (judgment about where the line should sit)

## Follow-Up Candidates

- Add `</dev/null` to the peer one-shot forms that `docker/shared/entrypoint-agent.sh` seeds, and mention `peer-review-run` there.
- Make `peer-review-run` the named default at the `address-review` / `review-cycle` peer step in the dev-skills plugin.
