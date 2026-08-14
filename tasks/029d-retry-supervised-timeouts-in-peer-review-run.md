# Task 029d: Retry supervised timeouts in `peer-review-run`

## Why this task exists

`peer-review-run` documents explicit timeouts as transient failures that receive one retry, but the supervised deadline path in `run_attempt()` does not set `ATT_TRANSIENT=1`.

When the poll deadline expires, that path records `ATT_OUTCOME=timeout`, `ATT_EXIT=null`, `ATT_REASON`, and timeout metadata, then returns; the main retry loop therefore emits a one-attempt terminal timeout instead of starting the promised second attempt.

Repeated live Claude-peer runs exposed the mismatch.
One representative result was:

```json
{
  "schema": "powbox.peer-review-run/v1",
  "provider": "claude",
  "outcome": "timeout",
  "verdict": "none",
  "elapsedSeconds": 260.448,
  "exitStatus": null,
  "attempts": 1,
  "retried": false,
  "liveProgress": false,
  "model": "opus",
  "effort": "medium",
  "artifactDir": "/tmp/peer-035b-r1.rx20ku/prr-c6nN8B2qk4rc/peer-review-claude-TqD4Kl",
  "reason": "provider exceeded the 260s timeout and its process group was reaped"
}
```

An earlier run reported `elapsedSeconds:260.372` with the same `attempts:1` and `retried:false` mismatch.

Those `/tmp` paths are ephemeral session evidence only.
The implementation and its acceptance criteria must depend on the helper contract, named symbols, and hermetic tests rather than on the artifacts surviving.

## Scope

- Make a supervised provider deadline an explicitly transient attempt result that is eligible for the helper's one retry.
- Preserve the helper's total cap of two provider attempts across transient retries and Claude login-to-env-credential fallback.
- Preserve `timeout` as the terminal outcome when the final allowed attempt also exhausts its supervised deadline.
- Keep retry attempts isolated in fresh attempt directories while retaining both attempts under the existing per-invocation session directory.
- Keep total elapsed-time accounting, final-attempt artifact reporting, and process-tree reaping correct across timeout recovery and timeout exhaustion.
- Make a confirmed reap of the timed-out attempt's own process tree a precondition of that attempt's retry, so the new retry never starts over a provider process known to be live, and keep the resulting terminal reason honest about both the survivor and the un-reaped group.
- Update the helper header and durable documentation so the documented retry and terminal-timeout semantics agree with implementation and tests.

Out of scope: changing the default or caller-selected timeout duration, allowing more than two total attempts, retrying deterministic or unclassified failures, changing provider authentication precedence, changing the result schema or outcome vocabulary, gating the pre-existing non-timeout transient retry or the Claude env-credential fallback on reap confirmation (task 029e), implementing the writable review overlay from task 029b, implementing configured Codex model or provider-neutral prose work from task 029c, or changing review policy in `Roubtec/agent-skills`.

## Context and references

- Completed task `tasks/done/029-provider-neutral-peer-review-runner.md` defines explicit timeouts as transient and requires retry-once behavior with fresh attempt directories.
- Deferred task `tasks/deferred/029b-peer-writable-overlay-for-test-execution.md` is a separate execution-surface enhancement and must remain unchanged.
- Task `tasks/029c-preserve-configured-codex-model-in-peer-review-run.md` covers configured Codex model passthrough and the provider-neutral review payload; that model/prose work is separate from timeout retry behavior and must not be folded into this task.
- Powbox issue [#145](https://github.com/Roubtec/powbox/issues/145) is downstream adoption context only; do not mutate it as part of this task.
- Task `tasks/029e-gate-every-retry-route-on-reap-confirmation.md` generalizes this task's survivor suppression to the pre-existing non-timeout transient retry and the Claude env-credential fallback. It depends on this task landing first, which is what establishes the attempt-scoped reap signal and the suppression vocabulary; do not implement its routes here.
- Historical task 029a was re-homed to `Roubtec/agent-skills`, 029b already exists in this repository, and 029c lands alongside this task, so 029d is the intentional next suffix and 029e is the follow-up queued behind it.
- `docker/shared/peer-review-run` documents the transient allowlist in its header and `looks_transient()`, sets per-attempt state in `run_attempt()`, applies Claude authentication fallback and transient retry policy in the main attempt loop, accumulates `TOTAL_ELAPSED`, and emits the final `powbox.peer-review-run/v1` result.
- `scripts/test-peer-review-run.sh` has existing timeout, process-tree reaping, transient-retry, elapsed-time, attempt-directory, and Claude authentication-fallback coverage that should be extended rather than duplicated in a separate harness.
- `README.md` “Cross-Agent Delegation” and `docs/architecture.md` “Rules the file map does not state” are the durable public and architectural contracts for the helper.

## Required outcome semantics

- A first supervised timeout is transient and starts exactly one retry in a newly created attempt directory.
- If the retry returns a pass verdict, emit the retry's normal terminal result: `outcome:passed`, `verdict:pass`, `attempts:2`, and `retried:true`.
- If the retry returns an issues verdict, emit the retry's normal terminal result: `outcome:issues`, `verdict:issues`, `attempts:2`, and `retried:true`.
- If both attempts reach the supervised deadline, emit `outcome:timeout`, `verdict:none`, `attempts:2`, `retried:true`, and `exitStatus:null` with a reason that states the timeout retry was exhausted or the attempt cap was reached.
- Do not collapse two supervised timeouts into `outcome:failed`.
The outcome vocabulary already defines `timeout` as deadline exhaustion, so preserving the most specific final failure class is clearer than using generic `failed`; retry exhaustion is represented by `attempts`, `retried`, and `reason`.
- `elapsedSeconds` is the accumulated wall time across both attempts, including the first timed-out attempt, the second attempt, and the existing first-attempt capability-probe accounting.
- `artifactDir` points to the final attempt directory, while the first and second fresh attempt directories both remain retained as siblings under the invocation's session directory according to the current artifact model.
- Every timed-out attempt completes the existing TERM, bounded grace, KILL escalation, confirmation, and wait/cleanup path before another attempt begins or the helper returns.
The invariant is that the helper does not start *this task's timeout retry* while a provider process from the timed-out attempt is known to be live: a confirmed reap is that retry's precondition, and an unconfirmed one is the explicit terminal exception defined below rather than a state it may proceed over.
The other retry routes keep their current behavior here; the boundary is stated in Scope and again below, and it is deliberate rather than an oversight.
- Existing survivor-warning behavior remains honest: if reaping reports a survivor, the terminal reason still carries the warning rather than claiming a clean process-tree reap.
Today's timeout reason hard-codes "its process group was reaped" and merely appends the survivor warning after it, so the emitted sentence asserts a clean reap and a survivor at once.
Condition that clause on the attempt's actual reap result instead of annotating around it, so a survivor result never claims the group was reaped.
- A timed-out attempt whose reap confirmation reports a survivor suppresses this task's retry: attempt two does not start while a process from that timed-out attempt is known to be live.
Such a run stays terminal `outcome:timeout`, `verdict:none`, `exitStatus:null`, `attempts:1`, and `retried:false`, with a reason that states the retry was suppressed because reaping could not confirm the tree was gone, alongside the existing survivor warning and without the "was reaped" claim.
Launching attempt two on top of a known survivor is the one way timeout retry could put two peer attempts on the machine at once, and the retry's own fresh-directory isolation does nothing to separate two live providers.
- That suppression is scoped to the supervised-timeout route this task introduces, and to a survivor reported by the timed-out attempt's own reap.
The pre-existing non-timeout transient retry and the Claude env-credential fallback keep their current behavior here, unchanged and untouched, so this task adds no gate to a route it defines no terminal semantics or coverage for.
The same hazard does exist on those routes — `REAP_WARN` annotates the reason and gates nothing — but consolidating the gate across every route needs its own terminal outcomes, reason normalization, and tests; that is `tasks/029e-gate-every-retry-route-on-reap-confirmation.md`, deliberately not folded in here.

## Claude authentication fallback interaction

- Keep the total attempt cap at two; authentication fallback and transient-timeout retry are alternative routes through the same budget, never additive sources of a third attempt.
- A first login-mode timeout follows the transient-timeout route and consumes the second attempt without also switching to the env-credential fallback, because timeout is not an `unavailable` authentication result.
This assumes that attempt's reap was confirmed; where it reported a survivor, the suppression rule above applies and no second attempt is consumed at all.
- A first login-mode `unavailable` result may continue to use attempt two for the existing env-credential fallback.
- If that env-credential fallback attempt times out, do not start a third attempt; emit terminal `outcome:timeout`, `exitStatus:null`, `attempts:2`, `retried:true`, and a cap-exhausted reason that identifies the fallback attempt's timeout without leaving an optimistic “retrying” message.
- Keep missing-binary, authentication, usage, and quota behavior unchanged: those paths remain non-transient except for the already-defined one-time login-to-env-credential fallback.

## Target files or areas

- `docker/shared/peer-review-run`: supervised-timeout attempt classification, retry/cap finalization, Claude fallback interaction, reason normalization, helper header/result-contract prose, and `usage()`'s header range if the comment grows.
- `scripts/test-peer-review-run.sh`: focused fake-provider cases for timeout recovery, timeout exhaustion, fallback-attempt timeout, attempt isolation, elapsed accounting, artifact selection, and process-tree reaping.
- `README.md` “Cross-Agent Delegation”: make the retry-once statement explicit that supervised deadlines participate and that a final exhausted deadline remains `timeout`.
- `docs/architecture.md` “Rules the file map does not state”: align the transient allowlist, two-attempt cap, Claude fallback interaction, and terminal timeout semantics.
- The helper is already copied into the agent image and exercised by source and baked-helper smoke paths; change Dockerfiles or source manifests only if inspection finds a real delivery gap.

## Implementation notes

- Make timeout retryability explicit at the point where `run_attempt()` classifies a supervised deadline; do not rely on matching the human-readable timeout reason through `looks_transient()` after the fact.
- Preserve the distinction between per-attempt classification and terminal result finalization.
The first timeout needs to request a retry, while the second timeout needs to retain its `timeout` outcome and replace any optimistic per-attempt reason with a cap-exhausted terminal reason.
- Avoid special cases that can accidentally create a third attempt.
One shared attempt-budget decision should govern both the Claude auth fallback and transient retry routes.
- Gate the timeout retry on the reap confirmation as well as on the attempt's transient classification, and use an **attempt-scoped** signal to do it.
`REAP_WARN` is the wrong input read directly: it is declared once, is never reset, and is set from three sites — the timeout reap, the normal/failed-exit reap, and the capability help probe, which runs inside attempt one before the provider is launched at all.
Reading it would suppress the retry over a stray `--help` descendant that has nothing to do with the timed-out provider tree, which is a broader gate than the requirement above states.
Set a per-attempt reap-confirmation flag, cleared in `run_attempt()`'s existing per-attempt reset block alongside `ATT_VERDICT`, `ATT_EXIT`, and `ATT_TRANSIENT`, and set it **only** at the attempt's own post-provider reap sites — the timeout reap and the normal/failed-exit reap.
Do not simply set it wherever `REAP_WARN` is set. The help probe's reap runs inside attempt one and *after* that reset block, so a flag raised at all three `REAP_WARN` sites and cleared per attempt reproduces exactly the over-broad gate this note exists to prevent: an implementer could follow the instruction literally and still suppress the retry over a stray `--help` descendant.
Keep `REAP_WARN`'s existing run-global reason-annotation behavior intact — suppression is an additional consequence of a survivor in this attempt, not a replacement for the warning.
- Apply the gate to the retry decision itself, ahead of the stderr progress event that announces it. The helper prints a `{"event":"note",…"retrying"}` line before launching attempt two, so a gate placed inside the retry branch after that announcement would emit a machine-parseable claim of a retry that never happens — the same dishonesty on the streamed channel that the reason normalization removes from the result.
- Preserve the current fresh-directory behavior by invoking `run_attempt 2` normally rather than reusing or clearing the first attempt directory.
- Preserve `ATT_EXIT=null` for supervised timeouts; the provider was terminated by the helper's deadline, so a synthetic process exit code would be less accurate.
- Keep `ATT_VERDICT=none` for a terminal timeout, but allow the second attempt's parsed pass or issues verdict to replace the first timeout normally.
- Continue accumulating `ATT_ELAPSED` into `TOTAL_ELAPSED` once per executed attempt and continue returning the final `ATTEMPT_DIR` through `artifactDir`.
- Reuse the existing process-supervision fixtures and `still_live()` semantics to prove reaping on every timeout attempt, including retry recovery; do not weaken the process-tree assertions to check only the final attempt.
- Update comments and durable docs together with behavior so “explicit timeout is transient,” “retry once,” “two attempts total,” and “exhausted supervised deadline remains timeout” cannot drift again.

## Acceptance criteria

- A fake provider that reaches the supervised deadline on attempt one and passes on attempt two produces `outcome:passed`, `verdict:pass`, `attempts:2`, `retried:true`, and a final-attempt `artifactDir`.
- A timeout-then-issues fixture produces `outcome:issues` and `verdict:issues`; if a separate end-to-end case would add disproportionate runtime, extend the recovered-timeout fixture so verdict normalization is parameterized or otherwise prove that both recovered verdicts use the ordinary final-attempt normalization path.
- Two supervised timeouts produce terminal `outcome:timeout`, `verdict:none`, `exitStatus:null`, `attempts:2`, `retried:true`, and a reason that states retry exhaustion or the two-attempt cap without claiming another retry will occur.
- The timeout-then-recovery and two-timeout cases create two distinct attempt directories, retain both, and return only the second through `artifactDir`.
- Retried timeout results report total `elapsedSeconds` across both attempts rather than only the final attempt.
- Each timeout attempt reaps its provider process tree before the next attempt or final return; fixtures cover a provider leader and descendants, including TERM-to-KILL escalation or the existing captured group-escapee path where practical, and assert that no provider process remains live.
- A timed-out first attempt whose reap confirmation reports a survivor starts no second attempt: the result is `attempts:1`, `retried:false`, terminal `outcome:timeout`, and its reason carries the suppression statement and the existing survivor warning without claiming the group was reaped; the assertion proves no second attempt directory was created rather than only inspecting the final result.
This case needs a named test-only mechanism for forcing that failed confirmation, and the task is not complete until one is implemented and used.
A real post-SIGKILL survivor is not constructible from an unprivileged fixture, and `group_alive` deliberately reports zombie and dying states as dead, so the existing suite has no reap-failure case at all — `scripts/test-peer-review-run.sh` only ever asserts the stubborn descendant *is* killed and that `reap_tree` does *not* falsely report a survivor.
Choose either an env-gated injection point that makes `reap_tree` return failure, or a shim of the liveness probe's `/proc` reads under the harness's existing `PATH="$d/bin:…"` convention; whichever is chosen must be inert in normal operation and must not weaken the genuine reaping assertions that already exist.
Whichever form is chosen must be selectable per reap site, not merely per run: the probe-survivor case below needs the help probe's reap to fail while the attempt's own reaps succeed, so a blanket flag that fails every reap cannot express it.
Prefer the env-gated form, or a shim that discriminates on its arguments. A blanket `cat` shim also intercepts the help capture and the Codex final-message read, makes every reap in the run burn its full TERM/KILL grace, and — worst for this case — makes the help probe's reap fail too, which would let the survivor assertion pass for the wrong reason under exactly the over-broad gate the implementation notes forbid.
Do not satisfy this criterion by asserting on the reason string alone, and do not drop it as unconstructible.
- The narrowing to the timeout route is asserted, not assumed. Once a supervised timeout is classified transient, it shares the retry branch with the pre-existing non-timeout transient failure, so an implementer who gates that branch wholesale passes every criterion above while silently delivering task 029e's behavior. Two negative cases pin the boundary, and the injection mechanism required above makes both constructible:
  - A non-timeout transient first attempt whose post-exit reap reports a survivor **still retries**, exactly as it does today: `attempts:2`, `retried:true`, and a second attempt directory.
  - A capability-probe survivor does not suppress anything: a healthy provider attempt that times out still retries normally, while the terminal reason still carries the run-global survivor warning.
- A Claude login-unavailable first attempt followed by an env-credential-fallback timeout stops at two attempts and returns terminal `timeout` with `exitStatus:null`, `retried:true`, and a cap-exhausted reason; it never starts a third attempt.
- A first login-mode timeout does not also trigger env-credential fallback, while existing login-unavailable fallback, missing-binary, deterministic failure, and positively identified non-timeout transient behavior remain unchanged.
- The helper header, `--help` output, README, and architecture documentation agree with the implemented timeout retry and terminal outcome semantics.
- Existing schema `powbox.peer-review-run/v1`, outcome names, strength reporting, read-only provider arguments, artifact privacy, capability probing, verdict parsing, and retry-once behavior for non-timeout transients remain compatible.

## Validation

- Run `shellcheck docker/shared/peer-review-run scripts/test-peer-review-run.sh`.
- Run `shfmt -d docker/shared/peer-review-run scripts/test-peer-review-run.sh` and compare any advisory output with the base branch under the repository's extensionless-helper formatting policy.
- Run `./scripts/test-peer-review-run.sh` and confirm the targeted timeout cases cover timeout-then-pass, recovered issues normalization, two timeouts, fallback-attempt timeout, fresh attempt directories, total elapsed time, final `artifactDir`, process-tree reaping, and the survivor path that suppresses the retry.
- Run `./scripts/run-pure-shell-tests.sh` to catch interactions with the rest of the native-Linux helper surface.
- Run `markdownlint-cli2 "**/*.md"` and compare findings with the base branch because this repository documents existing advisory Markdown debt.
- Because `peer-review-run` is baked agent-image behavior, rebuild the agent image on the host or in CI, relaunch from that image, and perform a live smoke at the timeout boundary; do not treat an in-container source-only run as proof that the installed helper changed.
- In the rebuilt-image live smoke, use a disposable read-only review worktree and bounded fake or safely interruptible peer fixtures to observe a supervised timeout followed by a second attempt, then verify the final JSON fields, retained fresh attempt directories, accumulated elapsed time, final-attempt `artifactDir`, and absence of live provider processes.

## Review plan

Review the supervised-deadline classification in `run_attempt()`, the shared two-attempt budget, terminal reason normalization, and the final outcome after the second attempt.
Trace timeout-then-pass, timeout-then-issues, timeout-then-timeout, timeout-with-surviving-descendant, login-unavailable-then-fallback-timeout, and login-timeout-with-env-credential-present as separate state paths.
Confirm each executed attempt contributes elapsed time exactly once, the second attempt gets a fresh directory, `artifactDir` names that final directory, earlier artifacts remain retained, every process tree is reaped before progress continues, and documentation plus rebuilt-image smoke evidence match the hermetic behavior.
