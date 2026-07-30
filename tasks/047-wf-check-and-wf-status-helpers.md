# Task 047 — Bake wf-check (workflow-script validation) and wf-status (run introspection) helpers

## Why this task exists

Iterating on Workflow scripts inside a container is currently hand-rolled in two places, both observed costing multiple turns in a scribz `wf-address-tasks` run:

1. **No syntax check.** Workflow scripts are plain JS whose body the runtime wraps in an async function, so a top-level `return` is legal — but `node --check` rejects it with `SyntaxError: Illegal return statement`, a misleading error. Validating an edit required a throwaway python script to strip the `meta` export and re-wrap the body before `node --check` would accept it. Without a checker, a typo surfaces only after stopping a live run — which kills in-flight subagents and forces a resume cycle.
2. **No run introspection.** Answering "how far along is this run?" took a `jq` pass over the session's `journal.jsonl` plus parsing a stringified wave plan out of a result blob; the per-agent `*.meta.json` files carry only `{"agentType","spawnDepth"}` — no label, phase, or status — so agent transcripts correlate only by opaque ID.

Both are small read-only tools over formats powbox already ships workflows for, and they make the seeded `wf-*` workflows (and any user-authored ones) debuggable.

## Scope

Included:

- `wf-check <script.js>`: apply the runtime's exact execution model — validate `export const meta = {...}` exists, is a pure object literal, and carries required fields (`name`, `description`; `phases` entries shaped `{title, detail?}`); then wrap the remaining body as `async function __body(agent, parallel, pipeline, log, phase, args, budget, workflow) { … }` and syntax-check it (`node --check` on the transformed source). Exit non-zero with the real error location (adjust line offsets so reported lines map back to the original file).
- `wf-status <runId-or-transcript-dir>`: read the run's `journal.jsonl` and agent files and print a compact human summary — phases seen, per-agent label/status where derivable, counts of completed/failed/pending `agent()` calls, and the final return value if present. Degrade gracefully on missing/partial journals (a killed run) rather than erroring.
- Bake both to `/usr/local/bin` in the agent image; add to the tooling table in `docker/shared/container-agent.md.tmpl` with one-line descriptions.
- A pure-shell/node test for `wf-check` (valid script passes; top-level return passes; missing meta fails; computed meta fails; body syntax error fails with mapped line number). `wf-status` gets a fixture-journal test.

Out of scope:

- Changing the Workflow runtime, journal format, or `*.meta.json` content (label/phase/status enrichment there is a harness-side ask, not powbox's).
- A live "drain mode" for running workflows (harness-side).

## Context and references

- The Workflow tool contract (script body wrapped async; `meta` must be a pure literal; hooks `agent/parallel/pipeline/log/phase/args/budget/workflow`; journal at `<transcriptDir>/journal.jsonl`; per-agent `agent-<id>.jsonl` + `*.meta.json`) — mirror exactly what the installed harness version does; verify against a real session directory under `/home/node/.claude/projects/...` before hardcoding shapes.
- `docker/claude/agent-container/workflows/*.js` — realistic inputs for `wf-check` fixtures.

## Target files or areas

- `docker/shared/wf-check`, `docker/shared/wf-status` (new)
- `docker/agent/Dockerfile` or the existing shared-helper bake path (follow how `gitcat`/`wt-*` are installed)
- `docker/shared/container-agent.md.tmpl`
- `scripts/test-wf-check.sh`, `scripts/test-wf-status.sh` (new, pure in-container)

## Implementation notes

- `wf-check`'s transform must not be smarter than the runtime: it validates *syntax* and *meta shape* only — do not lint semantics (e.g. barrier-vs-pipeline choices).
- Journal/meta formats are harness-owned and may drift between Claude Code versions; `wf-status` should be defensive (unknown fields ignored, missing fields shown as `?`) and clearly labeled best-effort in its `--help`.
- Node is guaranteed in the image; implement in whichever of bash+node is cleaner (a node script with a bash shim is fine).

## Acceptance criteria

- `wf-check` accepts every seeded workflow under `docker/claude/agent-container/workflows/` unmodified, and fails with a correct original-file line number on an injected syntax error.
- `wf-check` rejects a meta that is not a pure literal (e.g. `name: NAME_CONST`) with a message naming the rule.
- `wf-status` renders a useful summary from a real (fixture) journal, including a partial one.
- Both are on `PATH` in a rebuilt image and listed in the tooling table.

## Validation

- New tests pass in-container; `shellcheck`/`shfmt` clean on shell parts.
- Host rebuild + image smoke asserts both binaries exist (extend `scripts/smoke-test-image.sh`).

## Review plan

Reviewer checks the wrapper transform against the documented runtime contract, the line-offset mapping, and that `wf-status` never throws on truncated journals.
