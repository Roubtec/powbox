# Learnings handoff — kalm2

Improvements for the `Roubtec/kalm2` repo, distilled from agent-session retrospectives run there between 2026-07-11 and 2026-07-29.
This document is self-contained and is the basis for writing kalm2 task files; the original learnings branches are being deleted.
Items that surfaced in kalm2 sessions but belong to powbox or agent-skills are only summarized at the end so nothing looks dropped.

## 1. `make test-edge-bootstrap` needs filters and machine-readable progress

The focused edge suite routinely runs >1 minute, prints intentional `Killed` diagnostics from crash-injection, and has no phase indicator, so agents debugging a late assertion re-run the whole suite and cannot distinguish a hang, an expected failpoint, fixture pollution, and a real failure.

Adopt: named test sections with a `TEST_FILTER` env var, per-section timestamps, TAP or JUnit output, a quiet mode that labels expected crash diagnostics as expected, and a final process-leak check.

## 2. `tests/gate/test-artifact-pack.sh` fails silently on pin mismatch

The script cross-checks the replay pin between `deploy/rollback/release.env` and `tests/gate/replay-version.env`; a single-sided edit makes a bare `[[ ]]` fail under `set -e` with **zero output**, costing a debugging round to even find the second pin file.

Adopt: an `ERR` trap printing `$LINENO`/`$BASH_COMMAND` (or assertion helpers that echo expected vs actual), plus a one-line comment in each pin file pointing at its lockstep sibling and the cross-check script.
Related, already tracked in kalm2 as task 081b: make the pins rebase-robust; additionally consider a CI check that any pinned SHA is an ancestor of the branch tip, which catches a stale pin before merge.

## 3. Per-branch roadmap-inventory rule for `tasks/AGENTS.md`

With two task-bearing PRs open, `tasks/task-roadmap.md` carried divergent per-branch inventories and it was ambiguous which branch "owns" roadmap updates.
The resolution that worked: a branch's roadmap inventory must match **that branch's own tree**; cross-branch reconciliation happens at restack, not by writing entries for files another branch carries (anything else trips the roadmap drift guard, task 002b).

Adopt: state this rule explicitly in kalm2's `tasks/AGENTS.md`.

## 4. Pin markdownlint-cli2 behind a repo wrapper

Bare `npx markdownlint-cli2` pulls the latest version, which disagrees with CI's 0.18.1 pin and raises MD060 false alarms on pre-existing files; every subagent had to be told the pin.

Adopt: a repo-local `md-lint` wrapper (script or npm script) that invokes `markdownlint-cli2@0.18.1` (or whatever CI pins), so the pin lives in one place.
Note: powbox is baking `markdownlint-cli2` into the agent image (a default, not an override) — the repo pin remains authoritative and the wrapper is still the right interface.

## 5. Security-task intake: design gate before implementation

Task 109 grew to ~9,800 added lines and converged only after many serial review rounds, each discovering another implicit invariant (crash consistency, lock ordering, audit idempotency, ownership boundaries).
Separately, durable security transactions implemented in >2,000-line Bash scripts repeatedly produced shell-specific failure-semantics findings (command-substitution process identity, guard clearing, journal phase persistence).

Adopt (product/process decision for the maintainer):

- Require security tasks that mutate external state to start with a short ADR: state diagram, durable phases, lock ordering, ownership proof, idempotency keys, crash points, compensation rules — then split implementation into independently reviewable tasks.
- Move durable transaction engines toward a typed helper or small Go command with explicit state types; keep Bash as the operator-facing wrapper. Interim: reusable journal/stable-audit/secure-lock/failpoint shell libraries with property tests.

## 6. SPIRE compose profile: Podman health-check translation

The bundled `podman-compose` 1.3 rewrites exec-form health checks (`test: ["CMD", ...]`) into shell-wrapped form, which can never run on the distroless SPIRE server image — the container sits at `health: starting` forever.
The root fix is in powbox (task 025a upgrades/replaces the compose provider; task 025's smoke already reproduces the break).
Until that ships, kalm2 can carry a Podman-compatible health-check override (or a documented "expect `starting`, verify via direct command" note) in the SPIRE compose profile so live validation doesn't stall.

## 7. Report the GitHub GraphQL cross-PR contamination upstream

Concurrent `gh api graphql` calls against the same repo have repeatedly returned **another PR's** review threads (observed pairs: #142 receiving #143's comments; earlier #10/#11 receiving #9's).
This is server-side and can only be detected, not fixed, locally.
Worth an upstream report to GitHub with the observed pairs; kalm2 is where the concrete evidence lives.

## Routed elsewhere (no kalm2 action needed)

- `pg-dev-up` DSN missing `sslmode=disable` (breaks `lib/pq`) → powbox task 035.
- `gh-review-threads` scope check failing open on malformed shapes; test-suite blind spot → agent-skills task 013 + powbox task 033.
- Peer-launch mechanics (backgrounded `codex exec` snippets, nohup, liveness by unique token, `-o`-file completion semantics) → superseded by powbox's `peer-review-run`; skill adoption is agent-skills task 015.
- `actionlint` / `markdownlint-cli2` not on PATH → powbox task 037.
- Review-loop guidance (bound-the-claim heuristic, severity-split framing, enumeration-not-assertion, provenance marking of orchestrator claims, stale-SHA delegation, stacked-PR rebase rules, GitHub read-after-write lags, re-homing orphaned nits) → agent-skills tasks.
- Container docs claiming `/workspace` is always a host bind mount (wrong for `--isolated`) → powbox task 045.
