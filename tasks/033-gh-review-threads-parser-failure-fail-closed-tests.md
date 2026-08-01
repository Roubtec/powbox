# Task 033 — Cover gh-review-threads parser failures as fail-closed cases in the hermetic suite

## Why this task exists

`gh-review-threads` exists to detect cross-PR contamination in concurrent GraphQL responses and fail closed (exit 3, nothing on stdout).
Its scope check has a shape blind spot: `scope_offenders()` extracts comment URLs via a process substitution (`done < <(jq -r '.[].comments.nodes[].url' <<<"$combined")`), and a `jq` failure inside a process substitution is not caught by `set -euo pipefail`.
With a thread whose `comments` is `null`, `{}`, or absent, `jq` errors, prints nothing, the offender list comes back empty, and the helper emits its payload with exit 0 — the guard fails **open** on exactly the malformed shapes a crossed or truncated response can produce.
This was reproduced deterministically during a kalm2 review batch, in the same session where a live `gh-review-threads 142` call returned PR #143's comments at exit 0.

When this task was written, the hermetic suite `scripts/test-gh-review-threads.sh` (then 396 lines, cases (a)–(g)) tested contamination only with **well-formed** JSON carrying wrong URLs — the one contamination shape the guard survived.
It never fed the shape that fails open, so powbox Stage 0b validated the blind spot into the image.

The helper source itself is canonical in `Roubtec/agent-skills` (`plugins/dev-skills/bin/gh-review-threads`); the helper fix was tasked and delivered there (agent-skills task 013, merged 2026-07-31: replace the process substitution with a checked command substitution, and add a positive identity assertion via `repository { nameWithOwner }` / `pullRequest { number url }` in the same query).
powbox bakes that file verbatim (`docker/agent/Dockerfile:139` copies `.agent-skills-src/plugins/dev-skills/bin/gh-review-threads`; `scripts/build-image.sh:177-183` stages the clone), and this repo owns the test suite — so the **test-side** coverage lands here.

## Scope

**Widened 2026-08-01:** the paired agent-skills fix (task 013) merged to agent-skills main on 2026-07-31 (commits b5499b8b3f, 451f7e8b09, abbfcfeccd; merge 289c2dc4d25f), so the ordering prerequisite is satisfied — and the post-013 helper's positive identity assertion made updating the existing fixtures REQUIRED, not out of scope.

Evidence: powbox Tier 1 run 30568178025 went red (38/56 checks failed) because every pre-widening threads-page fixture lacked the identity fields the helper now asserts before any case logic runs.

Included:

- New cases in `scripts/test-gh-review-threads.sh` feeding malformed thread shapes through the fake `gh`:
  - a thread with `"comments": null`;
  - a thread with `"comments": {}` (no `nodes`);
  - a thread with `comments` absent entirely.
- Each case asserts the helper fails closed: exit code 3 (or the helper's documented fatal exit for extraction failure), **empty stdout**, and a diagnostic on stderr.
- A short comment in the suite recording the general principle: every fail-closed guard needs at least one case where the input **parser** fails, not only where the **validation** fails.
- (Widened) Update ALL existing threads-page fixtures to the post-013 identity contract: echo `repository.nameWithOwner` (matched case-insensitively against the requested owner/repo) and the exact `pullRequest.number` (plus a plausible `url`); nested comments-page responses (`.data.node...`) are not identity-asserted and stay bare.
- (Widened) Identity-mismatch fail-closed cases: a response echoing a wrong `nameWithOwner` and one echoing a wrong `pullRequest.number`, each served twice (whole-fetch retry) and asserting exit 3, empty stdout, and the generic "response identity does not match" stderr diagnosis — distinct from the offender-listing scope diagnosis and the "malformed response — could not extract comment urls" extraction diagnosis.

Out of scope:

- The helper fix itself (agent-skills task 013 — landed 2026-07-31, see above).

## Context and references

- `scripts/test-gh-review-threads.sh` — the hermetic suite with the fake-`gh` fixture machinery to extend.
- `docker/agent/Dockerfile:131-139`, `scripts/build-image.sh:177-183` — how the baked helper is staged from the agent-skills clone.
- Agent-skills task `tasks/013-gh-review-threads-fail-closed-on-parser-failure.md` (in `Roubtec/agent-skills`) — the paired helper fix.

## Target files or areas

- `scripts/test-gh-review-threads.sh`

## Implementation notes

- **Ordering (resolved):** the paired helper fix landed first — agent-skills task 013 merged to agent-skills main on 2026-07-31, and `scripts/build-image.sh` stages a fresh clone of agent-skills main on every build, so image builds consume the fixed helper with no coordination window left.
  Against the pre-fix helper these cases FAIL — that was the point, and it was verified once during development (at pre-fix agent-skills commit 22e1c76dd0 the new (h)/(i) cases fail; against the post-fix helper the whole suite passes).
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
