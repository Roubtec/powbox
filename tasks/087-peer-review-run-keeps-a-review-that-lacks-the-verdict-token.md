# 087 — `peer-review-run` keeps a complete review that lacks the verdict token

**Relates to:** `docker/shared/peer-review-run` (`detect_verdict`, `write_review_file`, the `powbox.peer-review-run/v1` result contract), its suite `scripts/test-peer-review-run.sh`, and README "Relaying the peer's prose".

## Why this task exists

When a provider exits cleanly with a non-empty final message in which `detect_verdict` finds no verdict token, the helper reports `forfeited` with `reviewFile: null`. That is the same result shape as an empty or malformed response. The review itself survives only in the provider-native artifacts, which the README tells callers not to open.

Callers have lost substantive reviews this way: numbered findings and a clear conclusion, from a peer that phrased its last line differently or left it out. The caller then either throws the review away or goes digging through provider artifacts against the contract. Being strict about the verdict is right, since a pass must never be inferred. That strictness should not cost the prose.

## Goal

A substantive review is never lost to formatting. From the result alone, a caller can tell "a review was produced, but its verdict could not be read" from "nothing usable was produced". In the first case it gets the prose through the same provider-neutral surface it uses for a parsed verdict.

## Direction and constraints

- Never a pass. No verdict is inferred from prose, and `detect_verdict`'s conservative rules stay as they are. This task changes what happens to the text, not how a verdict is recognised.
- No content judgment is needed to decide what is "substantive". Empty and malformed responses keep their current handling; any other non-empty message is prose worth handing back, and the caller weighs it.
- Callers written against today's contract branch on `outcome` and may assume that a non-null `reviewFile` implies a parsed verdict. Choose how the new case is expressed (a new outcome value, an existing one with the file populated, or an additive field) by what breaks least for such a caller, and state the choice in the header and the README.
- The review file's fail-closed guarantees apply to the new case unchanged.
- Asking the same peer once to restate its verdict in the required form could recover the verdict itself. It costs another launch, so it has to respect the attempt budget, the reap-confirmation precondition and the wait-budget arithmetic in the header. Do it only if it stays cheap. Keeping the prose is the required part.
- An adjacent gap, to take only if it falls out naturally: a clean exit with an empty final message after visible progress looks transient under load, yet it is forfeited without a retry.
- The suite pins the outcome vocabulary, and the smoke test runs the same suite against the baked copy.
- How the skills react to the new result shape belongs to `Roubtec/agent-skills`.
