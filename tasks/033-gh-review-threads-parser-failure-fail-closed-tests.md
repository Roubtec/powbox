# Task 033 — Cover gh-review-threads parser failures as fail-closed cases in the hermetic suite

## Why this task exists

`gh-review-threads` exists to detect cross-PR contamination in concurrent GraphQL responses and fail closed (exit 3, nothing on stdout).
Its scope check has a shape blind spot: `scope_offenders()` extracts comment URLs via a process substitution (`done < <(jq -r '.[].comments.nodes[].url' <<<"$combined")`), and a `jq` failure inside a process substitution is not caught by `set -euo pipefail`.
With a thread whose `comments` is `null`, `{}`, or absent, `jq` errors, prints nothing, the offender list comes back empty, and the helper emits its payload with exit 0 — the guard fails **open** on exactly the malformed shapes a crossed or truncated response can produce.
This was reproduced deterministically during a kalm2 review batch, in the same session where a live `gh-review-threads 142` call returned PR #143's comments at exit 0.

The hermetic suite `scripts/test-gh-review-threads.sh` (396 lines, cases (a)–(g)) tests contamination only with **well-formed** JSON carrying wrong URLs — the one contamination shape the guard survives.
It never feeds the shape that fails open, so powbox Stage 0b validates the blind spot into the image.

The helper source itself is canonical in `Roubtec/agent-skills` (`plugins/dev-skills/bin/gh-review-threads`); the fix to the helper is tasked there (agent-skills task 013: replace the process substitution with a checked command substitution, and add a positive identity assertion via `repository { nameWithOwner }` / `pullRequest { number url }` in the same query).
powbox bakes that file verbatim (`docker/agent/Dockerfile:139` copies `.agent-skills-src/plugins/dev-skills/bin/gh-review-threads`; `scripts/build-image.sh:177-183` stages the clone), and this repo owns the test suite — so the **test-side** coverage lands here.

## Scope

Included:

- New cases in `scripts/test-gh-review-threads.sh` feeding malformed thread shapes through the fake `gh`:
  - a thread with `"comments": null`;
  - a thread with `"comments": {}` (no `nodes`);
  - a thread with `comments` absent entirely.
- Each case asserts the helper fails closed: exit code 3 (or the helper's documented fatal exit for extraction failure), **empty stdout**, and a diagnostic on stderr.
- A short comment in the suite recording the general principle: every fail-closed guard needs at least one case where the input **parser** fails, not only where the **validation** fails.

Out of scope:

- The helper fix itself (agent-skills task 013).
- Changing the well-formed contamination cases.

## Context and references

- `scripts/test-gh-review-threads.sh` — the hermetic suite with the fake-`gh` fixture machinery to extend.
- `docker/agent/Dockerfile:131-139`, `scripts/build-image.sh:177-183` — how the baked helper is staged from the agent-skills clone.
- Agent-skills task `tasks/013-gh-review-threads-fail-closed-on-parser-failure.md` (in `Roubtec/agent-skills`) — the paired helper fix.

## Target files or areas

- `scripts/test-gh-review-threads.sh`

## Implementation notes

- **Ordering:** against the current (unfixed) helper these cases FAIL — that is the point.
  Land this task together with (or after) the agent-skills helper fix being consumed by the image build; coordinate so Stage 0b does not go red on main in between.
  If the agent-skills fix is not yet merged when this is implemented, verify the new cases against a locally patched helper copy and note the dependency in the PR body.
- Follow the suite's existing case-naming and `assert_eq`-style conventions; keep fixtures small and inline like the existing ones.
- The malformed shape must appear in a response that would otherwise pass (correct URLs elsewhere), so the case proves the parser path alone forces fail-closed.

## Acceptance criteria

- The three malformed-shape cases exist and assert exit 3 + empty stdout + non-empty stderr.
- With the fixed helper, the whole suite passes; with the pre-fix helper, the new cases fail (verified once during development, stated in the PR body).
- The parser-failure-vs-validation-failure principle is recorded as a comment near the new cases.

## Validation

- `bash scripts/test-gh-review-threads.sh` against the fixed helper passes.
- Temporarily reverting the helper's extraction fix flips the new cases to FAIL (spot-check, not committed).
- `shellcheck` and `shfmt -d` clean on the suite.

## Review plan

Reviewer confirms the new fixtures are genuinely malformed (not just wrong-URL), that assertions check both exit code and empty stdout, and that the coordination note with the agent-skills fix is honored.
