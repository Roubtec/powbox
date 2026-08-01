# 029a — Let a peer `VERDICT: PASS` carry brief, optionally-actionable notes without context sprawl

> **Relocation note (2026-07-30):** the `wf-*` workflow files named below moved to `Roubtec/agent-skills` (`plugins/dev-skills/workflows/`; see task 051), so the workflow-side prompt changes of this task now land there; the powbox side keeps only any caller of `peer-review-run` that remains in this repo.

## Why this task exists

`peer-review-run` (task 029) reduces a peer reviewer's output to a coarse `verdict` (`pass | issues | none`) plus an `artifactDir` pointer; the full review prose stays on disk and is not surfaced by default. Today's peer-prompt convention only asks for findings on `ISSUES`, so a `VERDICT: PASS` is a dead end — any nits the reviewer noticed are generated and then discarded. That wastes the tokens already spent and is mildly lossy: a "pass, but consider X" is more useful to a maintainer than a blunt pass.

The opportunity ("Lever 1" from the PR #113 review discussion) is to shape the peer's OUTPUT so a pass can carry a few terse, optionally-actionable notes when justified, while keeping the orchestrator's context lean. This is a prompt-convention refinement, not new machinery: no second LLM to parse the first, and no change to the deterministic, hermetic helper.

## Scope

In scope — refine the peer-prompt convention used by the CALLERS of `peer-review-run` so the peer is asked to:

- reason as much as it needs, but STRUCTURE its final message compactly;
- emit the `VERDICT:` line exactly as today (first line, unchanged token contract);
- THEN, when justified, list a few terse notes/nits as one-line bullets — `path:line — <=~15 words` — INCLUDING on a `PASS` (framed as "note, not necessarily fix");
- stay brief: cap the notes (a small handful), and OMIT the section entirely when there is nothing material to say.

Apply the convention in BOTH consumers (the accepted cross-repo scope — do not expand beyond these two repos):

- powbox: the Claude workflows that construct peer prompts — `docker/claude/agent-container/workflows/wf-address-review.js` and `wf-address-tasks.js` (plus any other site that spawns the peer);
- `Roubtec/agent-skills`: the `address-review` / `address-reviews` skills' peer-prompt sketches — the helper's documented downstream contract adopter.

Also: have the consuming skill/workflow surface a passing peer's notes COMPACTLY (e.g. one bullet each in the round summary), WITHOUT ingesting the full prose — a clean pass must stay a cheap one-line signal by default.

Out of scope (explicitly do NOT do):

- any change to `docker/shared/peer-review-run` itself — it stays prompt-neutral, deterministic, and hermetically testable (its offline unit suite, 198 checks at time of writing, must keep passing untouched). The `verdict` enum and the result schema do NOT change;
- a second LLM invocation to parse the peer's output;
- extracting or structuring findings INTO the result JSON — notes stay free text in `artifactDir`, read by the consumer only when it wants them;
- auto-acting on pass-notes — they are advisory; a clean pass must not be turned into a fix round.

## Context and references

- PR #113 (task 029 review-addressing) discussion: the verdict-parser hardening, and the "Lever 1 vs Lever 2" effort/cost analysis that motivated this task.
- `docs/architecture.md` → the `peer-review-run` bullet: the result contract (`verdict`/`outcome`, `artifactDir`) and the "agent-skills adoption boundary" that names `Roubtec/agent-skills` as the downstream consumer of the invocation/result contract.
- The helper already feeds the prompt to the provider on stdin from `--prompt-file` (never argv), so shaping output is purely a prompt-wording change in the callers; the input surface is already confined.

## Target files or areas

- powbox: `docker/claude/agent-container/workflows/wf-address-review.js`, `wf-address-tasks.js` (peer-prompt construction); a shared prompt snippet if one is introduced.
- `Roubtec/agent-skills`: the `address-review` / `address-reviews` skill docs' peer-prompt guidance (companion change, same effort).
- Optionally a short note in `docs/architecture.md` recording the peer-prompt convention next to the contract.

## Implementation notes

- Preserve the token contract: the `VERDICT:` line stays first and verbatim (`VERDICT: PASS` / `VERDICT: ISSUES`), so `detect_verdict` needs no change.
- Conserve OUTPUT tokens, not reasoning: tell the peer to think freely, then report tersely. Do NOT instruct it to reason less — that would weaken adversarial-review depth, which is the whole point of a second opinion.
- Guard context sprawl: bound the notes (a small cap), require `path:line` anchors and a hard per-note word budget, and instruct "omit the notes section when there is nothing material." The consumer surfaces pass-notes as a compact list and must not pull the full review prose into the orchestrator's main context on a pass.
- Frame pass-notes as advisory ("note, not necessarily fix") to avoid scope creep on an otherwise-clean pass.
- The two repos are the entire footprint; keep them in lockstep and do not expand scope (no new result fields, no helper changes).

## Acceptance criteria

- The peer prompts in both consumers ask for a compact, bounded notes/nits section that is populated (when justified) even on a `PASS`, with `path:line` anchors and a per-note word budget, and omitted when empty.
- A passing peer review with a nit results in the consumer surfacing that nit compactly (a short bullet), while a clean pass with nothing to say produces no notes and the usual one-line signal.
- `peer-review-run` and its test suite are unchanged and still green.
- The `Roubtec/agent-skills` review skills carry the same convention (companion PR/commit) so the powbox workflows and the external skills stay in lockstep on the peer-prompt shape.

## Validation

- powbox: `bash scripts/test-peer-review-run.sh` still passes unchanged (proves the helper/contract were not touched); lint the changed workflow JS/prose.
- Exercise one real review round (or a dry run) and confirm: a peer PASS with a nit surfaces it as a compact note; a clean PASS stays a one-line signal; the orchestrator context does not gain the full review prose on a pass.
- agent-skills: the companion change lands and its own checks (if any) pass.

## Review plan

- Confirm `docker/shared/peer-review-run` and its suite are untouched — the change is prompt/consumer-side only.
- Read the revised peer prompts in both repos: verdict token unchanged; notes bounded (cap + word budget + `path:line`); pass-notes framed advisory; "omit when nothing material" present.
- Verify context hygiene: a pass surfaces at most a short note list, never the full prose, by default.
- Confirm the two repos are consistent and no scope beyond them crept in.

## Deferred option (do not implement here)

"Lever 2" — an out-of-context subagent that reads `artifactDir` and returns a distilled digest — remains available if peer output ever balloons enough that even the terse notes are heavy. It fits the architecture (map-reduce over the artifact) but is a heavier tool for a marginal gain, and Lever 1 (short output at the source) should make it unnecessary. Recorded as an option only; not scheduled.
