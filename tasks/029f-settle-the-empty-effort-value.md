# 029f — Settle what `--effort ""` means in peer-review-run

## Why this task exists

PR #148 made an explicit empty `--model` a usage error, because both omission paths it would otherwise fall into — claude's `opus` default and codex's configured-model lookup — are paths the documented contract says an explicit `--model` bypasses, so an adopter forwarding an unset variable would have been silently reviewed with a model it did not choose, read out of shared mutable state some other container wrote through `/model`.

`--effort ""` was left as it was: it silently becomes `high` at `docker/shared/peer-review-run:897` (`[ -n "$EFFORT" ] || EFFORT=high`), with no emptiness check in its parse arm.

That asymmetry is **not** the same defect, and this task exists only because of a narrower point. An empty `--effort` lands on a documented *constant*: the helper header's `--effort` entry says "Default: high, for BOTH providers", and `README.md` and `docs/architecture.md` state that same default in their own words and further guarantee — the header does not — that a configured `model_reasoning_effort` never overrides the requested level. So the empty value can never resolve to shared mutable state, and the outcome is byte-identical to omitting the flag: the deliberate safe floor. The harm that justified the `--model` rejection provably does not exist here.

What is left is a divergence between the documented accepted set and the behavior. The header says `--effort` takes `low | medium | high | xhigh | max`; `docs/architecture.md` says it "accepts `low|medium|high|xhigh|max`". The empty string is not in that set, and `--effort bogus` exits 64 quoting exactly that set (test 14g), while `--effort ""` exits 0 and reviews at `high`. A caller reading the documented set predicts the 64.

The flag surface makes it the odd one out. Enumerated against the helper as of PR #148: `--provider ""`, `--worktree ""`, `--prompt-file ""` and `--artifact-root ""` each die as "required"; `--timeout ""` is rejected by its numeric guard; `--model ""` is rejected explicitly; `--base ""` is accepted, but there empty legitimately means "no base metadata"; `--effort ""` is the only flag with a validated value set that silently accepts a value outside it.

## Scope

Pick **one** of two resolutions — both are complete answers, and choosing (b) is not a failure of this task:

**(a) Reject it.** A parse-site emptiness check mirroring the `--model` one at `:855` (`[ -n "$MODEL" ] || die_usage "--model needs a non-empty value …"`, in the `--model)` parse arm), a sentence in the helper header beside the `--effort` documentation, the matching clause in the README and `docs/architecture.md` where the accepted set is stated, and test cases beside 14g's empty-model pair in `scripts/test-peer-review-run.sh`.

**(b) Document it.** One clause where the accepted set is stated, saying an empty value is treated as omission and resolves to the default. Cheaper, non-breaking, and defensible: the resolved value is the safe floor, so rejecting it buys strictness rather than safety.

**Out of scope:**

- The `high` default itself, and the reasoning behind defaulting rather than inheriting.
- Revisiting the `--model ""` rejection. It is deliberate, reviewed, and load-bearing for a reason that does not generalize to `--effort`.
- `--base`'s leniency, where an empty value is meaningful.
- Any change to how a *configured* value is validated — a flag-shaped configured codex model must keep degrading with a warning rather than becoming a usage error.

## Approach

If (a): sweep callers before changing the contract. Rejecting an empty value is a breaking change to a **baked image helper** — a caller writing `--effort "$LEVEL"` with `LEVEL` unset works today and would exit 64 afterwards. At the time of writing no in-repo caller passes `--effort` at all: the only invocations of `peer-review-run` outside its own test suite are the smoke drivers' Stage 0f, which runs the test suite, and a `command -v` presence probe. Re-verify with `grep -rn 'peer-review-run' --exclude-dir=.git .` before relying on that.

If (b): the change is documentation only, and the acceptance criterion is that a reader can predict the empty-value behavior from the accepted-set sentence alone.

## Acceptance criteria

- Reading the documented accepted set for `--effort` predicts what an empty value does, whichever resolution is taken.
- If (a): the rejection is at the parse site, not after the default has been applied, since the two are indistinguishable afterwards; the diagnostic distinguishes an explicit empty value from an omission the way the `--model` one does; and a test asserts both the exit 64 and that no provider ran.
- If (b): no behavior change, and the header, README and `docs/architecture.md` agree.
- Static gates and `./scripts/run-pure-shell-tests.sh` pass.

## Validation

`shellcheck`, `shfmt -d`, PSScriptAnalyzer, and `./scripts/run-pure-shell-tests.sh` (which includes `scripts/test-peer-review-run.sh`). Under (b) the pure-shell suite should be unchanged.

## Status

**Not started.** Queued as a contract-tidying follow-up, not a bug fix. Raised as a pass note during PR #148's review cycle and explicitly judged below the finding bar there; recorded here so the observation is not lost rather than because anything is broken. No prerequisites, and cheapest to land the next time `peer-review-run`'s flag parsing is open for another reason.
