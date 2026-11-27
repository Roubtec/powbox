# 087a — `peer-review-run` recovers a missing verdict and retries an empty reply after visible progress

**Relates to:** 087 (which this was split from: it made the two items below optional and left them out), `docker/shared/peer-review-run` (`detect_verdict`, the attempt loop and its reap confirmation, the "Budgeting the wait" header text), its suite `scripts/test-peer-review-run.sh`, and README "Relaying the peer's prose".

## Why this task exists

Task 087 stopped losing the prose of a review whose verdict cannot be read: such a result is still `forfeited` with `verdict: none`, and the text is now handed back as `proseFile`. Two adjacent improvements were in scope for 087 but optional, and it shipped without them.

- **The verdict itself is still lost.** A peer that wrote a full review but phrased its last line differently, or left it out, yields `forfeited`. The caller has the prose but no verdict, so it must either read the prose and decide by hand or treat the round as forfeited. Asking the same peer once to restate its verdict in the required form would usually recover it.
- **An empty reply after visible progress is forfeited at once.** A provider that streamed progress and then exited cleanly with an empty final message looks transient under load, yet the helper treats it like any other empty response and does not retry it.

## Goal

When a review was produced but its verdict could not be read, the helper makes one cheap attempt to get the verdict from the same peer before reporting `forfeited`. A clean exit with an empty final message after visible progress gets the same retry treatment as other transient failures. Neither change ever infers a verdict from prose.

## Direction and constraints

- **Never a pass by inference.** `detect_verdict`'s conservative rules stay as they are. A restated verdict counts only when the follow-up reply itself carries a recognized `VERDICT` line.
- **The restate request is a second launch.** It must fit the attempt budget, the reap-confirmation precondition (the first provider's tree is confirmed dead before anything new starts), and the wait-budget arithmetic the header documents, so a caller's documented foreground wait still covers the worst case. If it cannot be made cheap within those limits, keep 087's behaviour and say why.
- **Keep the prose either way.** `proseFile` from the original review stays the review of record; the restate reply only supplies the verdict.
- **Detecting "visible progress"** is provider-specific (only Codex streams progress events today, reported as `liveProgress`). An empty reply without progress keeps today's handling.
- **Result contract.** Any new field or `reason` text is additive within `powbox.peer-review-run/v1`, and the header and README state what changed. The suite pins the outcome vocabulary, and the smoke test runs the same suite against the baked copy.
- How the skills in `Roubtec/agent-skills` react to a recovered verdict belongs to that repository.
