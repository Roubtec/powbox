# Task 041 — Port the peer-review stage into wf-address-tasks.js and wf-address-review.js via peer-review-run

> **Relocation note (2026-07-30):** powbox forfeited the `wf-*` workflow sources to `Roubtec/agent-skills` (`plugins/dev-skills/workflows/`; see task 051). The file paths below refer to the pre-forfeit in-tree copies; this task must now be executed against the agent-skills repo (re-home it there), with powbox contributing only the baked `peer-review-run` contract the stage consumes.

## Why this task exists

The seeded Claude workflows `wf-address-tasks.js` and `wf-address-review.js` are ports of the `dev-skills` prose skills `address-tasks` / `address-review`, but they dropped the cross-harness peer-reviewer stage the prose versions carry (Codex preflight, read-only `codex exec` beside the fresh reviewer, grounded-findings gating, `peer-opinions=off` escape hatch).
`wf-address-tasks.js` contains no peer logic at all; `wf-address-review.js` mentions codex only as the `@codex` GitHub bot to re-ping.
In a scribz run this was discovered only after six tasks had opened PRs with single-harness review — the user had to ask "is this using peer reviews too?", and nothing in the workflow's name, description, or phases signals the difference.
The gap matters: across kalm2, scribz, and powbox sessions the peer repeatedly caught grounded defects the own-harness fresh reviewer had passed (false runbook claims, a duplicate-safety hole, unguarded timeout paths).

powbox now ships `peer-review-run` (`docker/shared/peer-review-run`, baked to `/usr/local/bin`), which owns exactly the mechanics a workflow stage needs: literal prompt handling, read-only provider execution, process-group supervision + timeout, transient-only retry, normalized JSON result contract (`powbox.peer-review-run/v1`), and reaping. The workflows should consume it rather than re-implementing `codex exec` supervision in prompt text.

## Scope

Included:

- Add a peer-review stage to both workflow scripts, mirroring the prose skills' protocol:
  - one-time availability preflight (delegate to `peer-review-run`'s own `unavailable` outcome rather than scripting `codex login status` by hand where possible);
  - after (or concurrently with — both are read-only) the fresh reviewer of each round, run the peer against the task/PR worktree via `peer-review-run --provider codex --worktree <wt> --prompt-file <f> --artifact-root <outside-worktree>`;
  - gate rounds on grounded peer findings (blocking AND minor) after a cheap `file:line` spot-check, exactly like the prose skill; `unavailable`/`timeout`/`forfeited` outcomes are explicit non-blocking results, never errors;
  - honour a `peer-opinions=off` argument passed through workflow `args`;
  - pass reviewer and peer findings to fixers verbatim as separately labeled blocks.
- Update both scripts' `meta.description`/`whenToUse` to mention the peer gate (and, until this task lands, see the interim note below).
- Keep concurrency modest: cap simultaneous peer invocations across the batch (2–3), since sustained fan-outs of many concurrent `codex exec` runs have been observed to degrade (empty final outputs needing retries).

Interim (commit first if the full port is delayed): a one-line honesty amendment to both `meta.description` fields stating review is single-harness — so the gap is visible before launch. If this task is implemented in one go, fold the honest description into the final wording instead.

Out of scope:

- Changes to `peer-review-run` itself.
- The prose skills in `Roubtec/agent-skills` (their adoption of `peer-review-run` is tasked there).

## Context and references

- `docker/claude/agent-container/workflows/wf-address-tasks.js` (~1010 lines), `wf-address-review.js` (~578 lines) — the scripts to extend; the review-round loop is the insertion point.
- `docker/shared/peer-review-run` header — invocation and result contract (`outcome ∈ passed | issues | unavailable | timeout | forfeited | failed`, final stdout line is one JSON object; exit 0 for any produced outcome).
- `docs/architecture.md` peer-review-run bullet — documents the contract and names the adoption boundary for external consumers.
- `Roubtec/agent-skills` `plugins/dev-skills/skills/address-review/SKILL.md` (peer protocol, gating rules, `peer-opinions=off`) — the semantics to mirror.

## Target files or areas

- `docker/claude/agent-container/workflows/wf-address-tasks.js`
- `docker/claude/agent-container/workflows/wf-address-review.js`

## Implementation notes

- Workflow scripts cannot shell out; the peer invocation happens **inside subagent prompts** — the stage's `agent()` prompt instructs the subagent to run `peer-review-run` (a single supervised foreground call is now safe: the helper owns timeout/retry/reaping, so the historical "backgrounded codex + polling" pattern and its footguns do not apply) and to return the parsed JSON result plus the verdict/notes from the artifact file.
- Never let a peer subagent's failure fail the pipeline stage: map helper `unavailable`/`timeout`/`forfeited` to a non-blocking outcome recorded in the round result.
- Peer prompts must tell the reviewer not to fetch PR state over the network (read-only sandboxes have no GitHub egress) and to judge from the committed tree/diff supplied.
- Mind `meta.phases` — add a matching phase entry (with the exact title used in `phase()`/`opts.phase`) for progress grouping.
- These files are image-seeded; validating the full loop needs a rebuilt image, but the scripts can be reviewed and syntax-validated in-container (strip the top-level `return` wrapper caveat — see task 047's `wf-check` if it has landed).

## Acceptance criteria

- Both workflows run a peer stage per review round with the gating semantics above, honour `peer-opinions=off`, and cap peer concurrency.
- Descriptions/phases disclose the peer gate.
- A dry read-through against the prose skill's protocol finds no dropped rule (grounding spot-check, verbatim finding relay, non-blocking unavailability).

## Validation

- Script syntax validated with the runtime wrapper (or `wf-check` if available).
- Host/CI: a smoke or manual `/wf-address-review` run on a disposable PR exercises one peer round end to end (needs a rebuilt image; ask the maintainer per AGENTS.md "Validating Changes").

## Review plan

Reviewer diffs the ported protocol against `address-review/SKILL.md`'s peer section rule by rule, and checks that no helper outcome can abort a batch.
