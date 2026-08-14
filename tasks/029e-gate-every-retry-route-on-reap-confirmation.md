# Task 029e: Gate every `peer-review-run` retry route on reap confirmation

## Why this task exists

`peer-review-run` reaps a provider's process tree after every attempt, and `reap_tree` can report that a descendant survived SIGKILL.
Today that survivor only annotates the terminal `reason`: `REAP_WARN=1` is read once at result-emission time and gates nothing.
Every retry route therefore may start a second provider attempt while a process from the first is known to still be live — two peer providers running at once, which the retry's fresh-attempt-directory isolation does nothing to separate.
The helper's supervision contract does not speak to overlapping attempts; it promises that no live peer process is left behind and that a failed reap is reported honestly. Overlap is a hazard that contract simply does not cover, which is why it needs closing here rather than a violation of something already written down.

Task 029d closes this for the supervised-timeout retry it introduces, and deliberately stops there — it defines terminal semantics, reason normalization, and test coverage for that route only.
The same hazard remains on the two pre-existing routes that 029d leaves untouched:

- the non-timeout transient retry, which fires after a provider exited on its own and its post-exit sweep found a survivor;
- the Claude login-to-env-credential fallback, which starts attempt two after an `unavailable` first attempt regardless of that attempt's reap outcome.

This was raised in review of PR [#146](https://github.com/Roubtec/powbox/pull/146) while planning 029d.
Consolidating the gate across routes is not a mechanical extension of 029d: each route needs its own terminal outcome, its own reason normalization, and its own coverage, and one of them can turn a recoverable authentication failure into a terminal one.

## Scope

- Extend the reap-confirmation precondition to the two remaining retry routes — the non-timeout transient retry and the Claude login-to-env-credential fallback — reusing the attempt-scoped signal and the suppression vocabulary task 029d introduces rather than rebuilding either.
- Define the terminal result for each newly suppressed route, including which outcome it keeps and what its reason says.
- Normalize the optimistic per-attempt reason, and the stderr progress event that announces the retry, on every route where suppression prevents the retry they promised.
- Supersede one of the two boundary assertions task 029d leaves behind: after this task a non-timeout transient attempt with a survivor no longer retries. The probe-survivor assertion is *not* superseded — a capability-probe survivor must still suppress nothing, on any route.
- Extend `scripts/test-peer-review-run.sh` with a suppression case per route, and align the helper header, README, and architecture documentation with the consolidated rule.

Out of scope: changing the two-attempt cap, changing which failures are classified transient, changing provider authentication precedence, changing the result schema or outcome vocabulary, re-opening the supervised-timeout suppression that task 029d delivers, and any configured-model or review-payload work from task 029c.

## Context and references

- Task `tasks/029d-retry-supervised-timeouts-in-peer-review-run.md` introduces supervised-timeout retry and its survivor suppression, and names this task as the deliberate boundary of that work. **029d must land first**: it establishes the attempt-scoped reap signal and the suppression vocabulary this task generalizes.
- Completed task `tasks/done/029-provider-neutral-peer-review-runner.md` defines the retry-once contract and the transient allowlist.
- `docker/shared/peer-review-run` declares `REAP_WARN` once, never resets it, and sets it from three sites: the timeout reap, the normal/failed-exit reap, and the capability help probe. It is consumed once, at result emission, purely to append a survivor warning to `reason`.
- `run_attempt()` sets an optimistic transient reason of the form "provider hit a transient failure (exit N); retrying"; the only corrections to it live inside the retry branches, so a suppressed retry would leave the result announcing a retry that never happened.
- `provider_supports` is called from the `build_cmd_*` functions inside attempt one and caches after its first call, so the help probe's reap runs before any provider is launched — which is why the run-global flag cannot serve as an attempt-scoped gate.
- `scripts/test-peer-review-run.sh` has process-supervision fixtures that assert stubborn descendants *are* killed and that `reap_tree` does not falsely report a survivor; it has no reap-failure case, so this task depends on the test-only injection mechanism task 029d introduces.

## Required outcome semantics

- On every route, a confirmed survivor from the attempt that just ended suppresses any further attempt.
- The suppressed result keeps the outcome the completed attempt earned rather than being reclassified: a transient non-timeout failure stays `outcome:failed`, an `unavailable` first attempt stays `outcome:unavailable`, and the supervised-timeout route keeps the `timeout` semantics task 029d defines.
- Each suppressed result reports `attempts:1` and `retried:false`, and its reason states that the retry or fallback was suppressed because reaping could not confirm the tree was gone, alongside the existing survivor warning.
- No suppressed result may carry an optimistic "retrying" reason, and none may claim the process group was reaped.
- The same honesty applies to the streamed channel: the gate sits ahead of the stderr `{"event":"note",…"retrying"}` announcements the helper prints before launching attempt two, so a suppressed run never emits a machine-parseable claim of a retry it will not perform.
- The Claude fallback case is the one with a real cost: suppressing it turns a run that might have authenticated on the env credential into a terminal `unavailable`. State that trade explicitly in the reason so the caller can distinguish "both credentials failed" from "the fallback was never attempted".
- The gate reads an attempt-scoped signal. A survivor from the capability help probe annotates the reason as it does today but suppresses nothing, because no provider attempt produced it.

## Implementation notes

- Reuse task 029d's attempt-scoped reap-confirmation flag as-is: it is already set only at the attempt's own post-provider reap sites and cleared in `run_attempt()`'s per-attempt reset block. Do not introduce a second signal, and do not fall back to reading `REAP_WARN`, which is run-global and also raised by the help probe.
- Keep the gate as one shared decision covering all three routes rather than three copies, so a later route cannot be added without inheriting it.
- Place the gate ahead of each route's stderr announcement and ahead of the branch that increments the attempt count, so the suppressed result needs no after-the-fact correction of either.
- Per-route reason normalization is the fiddly part: the transient reason is set optimistically inside `run_attempt()` and corrected only in the retry branches today, so a suppressed route needs its own correction where the retry used to be.
- Task 029d's non-timeout-transient boundary assertion is expected to fail once this lands; update it in the same commit that changes the behavior rather than leaving a red test, and keep the probe-survivor assertion passing untouched.

## Target files or areas

- `docker/shared/peer-review-run`: the shared attempt-budget decision, per-route reason normalization, the attempt-scoped reap flag, and the helper header's retry contract.
- `scripts/test-peer-review-run.sh`: one suppression case per route plus a probe-survivor case proving it does *not* suppress.
- `README.md` "Cross-Agent Delegation" and `docs/architecture.md` "Rules the file map does not state": state the consolidated rule once, so the three routes are not documented as differing.

## Acceptance criteria

- A non-timeout transient first attempt whose post-exit reap reports a survivor starts no retry: `attempts:1`, `retried:false`, `outcome:failed`, a reason carrying the suppression statement and the survivor warning, and no second attempt directory.
- A Claude login-mode `unavailable` first attempt whose reap reports a survivor starts no env-credential fallback: `attempts:1`, `retried:false`, `outcome:unavailable`, and a reason that says the fallback was suppressed rather than that both credentials failed.
- The supervised-timeout suppression from task 029d still behaves exactly as that task specifies. The only assertion of 029d's this task changes is its non-timeout-transient boundary case, which the scope section above records as superseded; nothing about the timeout route itself moves.
- A capability-probe survivor does not suppress anything, proving the gate is attempt-scoped. Assert it on a **retry-eligible** attempt whose own reap succeeded — a supervised timeout, or a non-timeout transient failure — which then proceeds to attempt two normally while the terminal reason still carries the run-global survivor warning. A healthy attempt is no test at all here, since it enters no retry route to be suppressed.
- No suppressed result anywhere carries an optimistic "retrying" reason or a "was reaped" claim.
- Existing retry, fallback, deterministic-failure, missing-binary, elapsed-accounting, and artifact-selection behavior is unchanged when reaping succeeds, which is every existing test case.

## Validation

- Run `shellcheck docker/shared/peer-review-run scripts/test-peer-review-run.sh`.
- Run `shfmt -d docker/shared/peer-review-run scripts/test-peer-review-run.sh` and compare advisory output with the base branch under the repository's extensionless-helper formatting policy.
- Run `./scripts/test-peer-review-run.sh` and `./scripts/run-pure-shell-tests.sh`.
- Run `markdownlint-cli2 "**/*.md"` and compare findings with the base branch, because this repository documents existing advisory Markdown debt.
- This is baked agent-image behavior: rebuild the agent image on the host or in CI and relaunch before treating an in-container source run as proof the installed helper changed.

## Review plan

Confirm the gate is one shared decision rather than three copies, that each route's suppressed terminal result is defined and tested, and that the reason a caller receives never announces a retry that did not happen or a reap that did not succeed.
Check the attempt-scoped flag is cleared in the per-attempt reset block and that the probe survivor is proven not to suppress.
Weigh the Claude fallback trade deliberately: a suppressed fallback is a real loss of a recoverable path, and the review should agree that a known-live provider process is the worse of the two.
