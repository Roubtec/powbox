# Task 029: Provide a bidirectional, provider-neutral peer-review runner

## Why this task exists

Peer reviews currently require substantial hand-written process supervision, prompt quoting, artifact management, polling, output parsing, and cleanup.

The direction must be symmetric: a Claude-led workflow needs to review with Codex, and a Codex-led workflow needs to review with Claude.

The providers are not identical: Codex can expose structured/live progress, while Claude may buffer its final result. The runner must preserve those differences behind one reliable outcome contract rather than pretending they have equal observability.

## Scope

- Add an image-baked `peer-review-run` helper usable by either primary agent.
- Support at least `--provider claude` and `--provider codex`, with one normalized machine-readable result contract and retained provider-native artifacts.
- Own private artifact creation, literal prompt handling, read-only execution, process supervision, timeout/retry policy, result parsing, and exact-path cleanup.
- Document the helper for Powbox workflows and provide an adoption contract for the shared `agent-skills` repository.

Out of scope: changing Claude or Codex themselves, requiring either peer opinion for publication, replacing a fresh reviewer subagent, or implementing a general-purpose task runner.

## Context and references

- The previous Jabko review loop manually created a prompt/artifact directory, launched `claude -p` under `setsid`, verified PID handoff, polled output, parsed JSON, and performed scoped cleanup for every round.
- The shared `agent-skills` copies of review skills currently contain provider-specific launch guidance. This helper's stable invocation/result contract is the downstream adoption boundary; do not make that adoption depend on a temporary report.
- `docs/architecture.md` states that helpers consumed by agent-layer skills/workflows belong in `docker/shared/` and are baked by `docker/agent/Dockerfile`.
- Existing safe building blocks include `gh-review-threads`; do not duplicate it or couple this helper to GitHub review-thread fetching.

## Target files or areas

- `docker/shared/peer-review-run` and any narrowly scoped companion library
- `docker/agent/Dockerfile` and any source-file manifest used for image/cache invalidation
- Focused tests under `scripts/` using fake provider executables
- `README.md`, `docs/architecture.md`, and/or `docs/entrypoint-and-runtime.md`
- `docker/claude/agent-container/workflows/` only where a Powbox-owned workflow can safely adopt the helper without changing its review policy

## Implementation notes

- Define a versioned JSON result on stdout. It must include provider, outcome (`passed`, `issues`, `unavailable`, `timeout`, `forfeited`, or `failed`), elapsed time, exit status where known, normalized verdict, artifact directory, and a concise diagnostic reason. Never report success because an output file is absent or empty.
- Accept a literal prompt file, absolute worktree path, base/reference metadata, timeout, and caller-selected artifact root. Validate every path; create a fresh owner-only attempt directory outside the worktree and never reuse it for retries.
- Preserve original stdout/stderr and, where available, structured provider events in that attempt directory. The helper may emit normalized progress events while running, but its final stdout must remain parseable by a caller. Codex progress/events should be surfaced when the installed CLI supports them; Claude's buffered-final behavior must be represented honestly as limited/no live progress rather than simulated heartbeats.
- Use provider adapters rather than one command string. The Claude adapter must preserve safe-mode/read-only tool restrictions and robust process-group lifecycle. The Codex adapter must use its supported read-only sandbox/working-directory controls and avoid leaking MCP/server state into an untrusted review run.
- Never interpolate the prompt through shell evaluation. Do not use `pkill -f`; supervise a validated PID/process group and reap it on every success, failure, and timeout path.
- A missing binary, unavailable login, usage exhaustion, timeout, or malformed provider response is an explicit non-blocking peer outcome for the caller to decide on, not a false pass. Retry only transient execution failures once and give the retry a new artifact directory.
- Keep generic process mechanics in Powbox. Do not copy the external `agent-skills` skill files into this repository; instead document the stable invocation/result contract they should consume after this task lands.

## Acceptance criteria

- Claude can invoke a Codex peer review and Codex can invoke a Claude peer review through the same command interface and result schema.
- Each provider runs only with read-only permissions appropriate to its CLI, receives the intended worktree and literal prompt, and cannot read a sibling attempt's artifacts by default.
- A successful provider result, an issues result, unavailable/auth failure, timeout, malformed output, and retry exhaustion produce distinct normalized outcomes covered by tests.
- Codex's available progress is preserved/forwarded, while a buffered Claude response is explicitly identified as such; consumers do not rely on identical event timing.
- Timeout and failure paths terminate/reap the correct provider process tree and leave no live peer process; retained artifacts are scoped to the exact invocation.
- Documentation explains that a peer result supplements, but does not replace, the fresh reviewer gate and records the agent-skills adoption boundary.

## Validation

- Add hermetic tests with fake `claude` and `codex` binaries for argument construction, literal prompt handling, JSON normalization, progress forwarding, timeout/retry, and process cleanup.
- Run `shellcheck`, `shfmt -d`, and the new tests in-container.
- This is agent-image behavior: request a host/CI rebuild and manually smoke both provider directions in a disposable worktree before handoff.

## Review plan

Review the result schema, provider adapters, permission flags, path containment, process-group ownership, and failure semantics. Verify the tests prove both directions and do not merely mock a single common happy path.
