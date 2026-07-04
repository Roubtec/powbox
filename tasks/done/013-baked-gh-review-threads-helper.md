# 013 — Bake a `gh-review-threads` helper: safe PR review-thread fetch with a scope assertion

## Why this task exists

A long-running `address-reviews` batch (session learnings, 2026-07-02) observed
`gh api graphql --paginate` returning **another PR's** `reviewThreads` when several `gh`
GraphQL calls ran concurrently from sibling worktrees (querying PR #10/#11 surfaced PR #9's
threads). Every subagent independently detected the anomaly, cross-checked via REST, and fell
back to a non-paginated query — several wasted turns per PR — and, unguarded, a publisher
would have posted `Fixed in <sha>` replies and `resolveReviewThread` mutations against the
**wrong PR's** threads.

The skills were already updated to describe the reliable approach in prose (commit
`1b79b5f`, `fix(skills): fetch review threads single-shot with a PR-scope check, not
--paginate`, on `minor-improvements`): single-shot queries, manual `endCursor` paging, and a
repo-qualified, boundary-safe PR-scope check on every returned comment `url`. But prose asks every agent to re-implement
the same multi-step recipe correctly, every run. A small **image-baked helper** makes the
safe path the easy path: one command that encapsulates the query, the manual pagination, and
the scope assertion — used identically by the Claude skill, the Codex skill, and the
`wf-address-review` workflow.

Model it on `gitcat`: a single-file bash helper in `docker/shared/`, baked into the **agent**
image layer (it evolves in lockstep with the skills that reference it), with a tooling mention
in `container-agent.md.tmpl` and a README pointer for discoverability.

## Scope

**In scope:**

1. The helper script `docker/shared/gh-review-threads`.
2. Agent-layer baking (`docker/agent/Dockerfile` COPY list + rationale comment).
3. Discoverability docs: `docker/shared/container-agent.md.tmpl` ("Git and GitHub" section,
   next to the `gitcat` bullet) and the `README.md` image-baked-helpers mention.
4. Updating the three consumers to use the helper as the primary recipe (raw query kept as a
   documented fallback): both `address-review` SKILL.md flavors and the
   `wf-address-review.js` gather prompt.
5. An offline unit test `scripts/test-gh-review-threads.sh` (fixture-driven, `gh` stubbed),
   wired into `commands/smoke-test.{sh,ps1}` alongside the existing `scripts/test-*.sh`.

**Out of scope:**

- Reproducing the underlying `gh --paginate` cross-response bug and filing it upstream
  against `cli/cli` (worthwhile, but independent — a possible follow-up task).
- The reply/resolve/comment recipes (they stay as-is; they are single-object REST/GraphQL
  calls with no pagination hazard).
- Base-image changes; anything Go/kalm2-specific.

## Helper contract (design sketch — refine details, keep the guarantees)

```
gh-review-threads [--all] [--repo <owner>/<repo>] <PR#>
```

- **Output:** JSON on stdout — an array of thread objects, each with `id`, `isResolved`,
  `isOutdated`, `path`, `line`, and `comments[]` carrying `databaseId`,
  `author { login, __typename }`, `body`, `diffHunk`, `url`. Exactly the fields the
  `address-review` skills triage on, in a stable shape for `jq`. Unresolved threads only by
  default; `--all` includes resolved ones (the skills' post-push re-read still wants
  unresolved only, but `--all` keeps the helper generally useful).
- **Repo resolution:** `--repo` wins; otherwise the current repo via
  `gh repo view --json owner,name`. (Review threads live on the base repo's PR, so this is
  correct in fork-PR worktrees checked out from the base repo; `--repo` covers the rest.)
- **Fetch strategy (the point of the helper):** one single-shot GraphQL query per page —
  `reviewThreads(first:100, after:$after)` with `totalCount` and
  `pageInfo{ hasNextPage endCursor }` — looping with an explicit cursor passed to a **fresh**
  `gh api graphql` invocation per page. Never `gh api graphql --paginate`. When a thread's
  nested `comments.pageInfo.hasNextPage` is true, fetch that thread's remaining comments the
  same way before emitting it. The exact query shape is already documented in the
  `address-review` SKILL.md "GitHub API recipes" section — keep the helper and the skills'
  fallback recipe identical.
- **Scope assertion:** before emitting anything, every comment `url` must point at the
  requested PR. Match exactly as the skills' recipe prescribes — `OWNER/REPO` plus
  `/pull/<N>` followed by `#`, `/`, `?`, or end (never a plain substring check) — so PR #12
  never accepts a `/pull/123` URL and a same-number PR in another repo also trips it. On a
  mismatch, discard the response and retry **once** with a fresh single-shot query; if the
  mismatch repeats, fail closed: emit **nothing** on stdout, print a diagnostic naming the
  offending URL(s) to stderr, and exit with a **distinct exit code** (e.g. `3`) so callers
  can distinguish "contaminated response" from usage or auth errors. These
  retry-once-then-fail-closed semantics match the skills' recipe; document them in the
  usage text.
- **Style:** follow `docker/shared/gitcat` — bash, `set -euo pipefail`, `usage()` to stdout
  for `-h`/`--help` (exit 0) and stderr on misuse (exit non-zero), `die()` for diagnostics,
  tab-indented, `shellcheck`/`shfmt` clean. Dependencies are `gh` and `jq`, both baked.

## Target files or areas

- `docker/shared/gh-review-threads` — new helper (executable; `scripts/check-exec-bits.sh`
  must pass).
- `docker/agent/Dockerfile` — add to the `COPY --chmod=755` list (~line 81) and extend the
  preceding rationale comment (~line 74), which currently reads "The wt-* worktree helpers
  (and the gitcat cross-branch reader) are baked here…". The same reasoning applies verbatim:
  the helper evolves in lockstep with the skills/workflows that call it, so agent-layer baking
  keeps `agent-update` / `build.sh agent` refreshing them together.
- `docker/shared/container-agent.md.tmpl` — add a bullet in "Git and GitHub" right after the
  `gitcat` bullet: usage one-liner, what it returns, and *why it exists* (reliable under
  concurrent multi-PR runs; asserts every thread belongs to the queried PR).
- `README.md` — extend the image-baked-helpers sentence (~line 462: "`wt-bootstrap`,
  `wt-enter`, `wt-remove` (plus `gitcat` for cross-branch reads)") to mention
  `gh-review-threads`.
- `docker/claude/agent-container/skills/address-review/SKILL.md` and
  `docker/codex/agent-container/skills/address-review/SKILL.md` — in "GitHub API recipes",
  make `gh-review-threads <PR#>` the primary recipe; keep the current raw single-shot query
  as the explicit fallback **when the helper is absent** (`command -v gh-review-threads`
  fails — a container built from an older image; same graceful-degradation pattern the skills
  already use for the gh-version-gated Copilot ping). Step 3 and the checklist should say
  "via `gh-review-threads` (or the fallback recipe)". Do not remove the scope-check prose —
  it explains *why*, and it governs the fallback path.
- `docker/claude/agent-container/workflows/wf-address-review.js` — gather prompt: same
  helper-first, fallback-second instruction.
- `scripts/test-gh-review-threads.sh` — new offline unit test; wire it into
  `commands/smoke-test.sh` and `commands/smoke-test.ps1` next to the existing unit-test
  invocations (`test-sensitive-host-path.sh` et al.).

## Implementation notes

- **No live GitHub calls in tests.** Stub `gh` with a PATH shim that serves canned JSON
  fixtures per invocation (count the calls to assert the pagination loop). Cover at minimum:
  (a) unresolved-only filtering (and `--all`); (b) a two-page thread list followed via
  `endCursor`, asserting **two separate** `gh` invocations with the right `after` values and
  that `--paginate` never appears in the shim's recorded args; (c) a contaminated fixture —
  one comment `url` from a different PR, served on the first call **and** the internal
  retry — exits with the distinct code and emits no stdout JSON, while a contaminated
  first response followed by a clean retry succeeds; (d) the URL boundary case
  (`/pull/12` vs `/pull/123`); (e) nested comment-page fetch-up.
- The helper must not depend on the repo it runs in (it is a generic container tool, like
  `gitcat` — keep it repo-agnostic; no powbox-specific assumptions).
- Keep the skills' fallback recipe and the helper's query **textually in sync** — a drift
  between them is exactly the kind of subtle inconsistency this task exists to remove. A
  short comment in the helper pointing back at the SKILL.md recipe section (and vice versa)
  is enough.
- The seeded skills refresh via `agent-update-skills` / entrypoint no-clobber seeding; the
  helper refreshes via the agent-image path (`agent-update`, `build.sh agent`). Both ride the
  same PR, so a rebuilt+reseeded container gets a consistent pair; the `command -v` fallback
  covers mixed states (new skills on an old image).

## Acceptance criteria

- `gh-review-threads <PR#>` on a real PR (manual validation) prints the JSON shape above,
  unresolved-only by default, and never invokes `--paginate`.
- A persistently contaminated response (contaminated on the internal retry too, simulated in
  the unit test) produces no stdout output, a stderr diagnostic naming the offending URL,
  and the documented distinct exit code; a clean retry after one contaminated response
  succeeds.
- `/pull/<N>` matching is boundary-safe (`12` never matches `123`) and repo-qualified.
- Fresh agent image (`build.sh agent` or `agent-update`) has the helper on `PATH` at
  `/usr/local/bin/gh-review-threads` with the exec bit set; `scripts/check-exec-bits.sh`
  passes.
- Both SKILL.md flavors and the workflow gather prompt recommend the helper first with the
  raw recipe as the explicit no-helper fallback; the scope-check prose remains.
- `container-agent.md.tmpl` and `README.md` mention the helper (gitcat-style discoverability).
- `scripts/test-gh-review-threads.sh` passes offline, is wired into
  `commands/smoke-test.{sh,ps1}`, and fails if the scope assertion or the manual-pagination
  behavior is reverted.
- `shellcheck` (error severity) and `shfmt` clean; CI static guards pass.

## Validation

Run `scripts/test-gh-review-threads.sh` standalone and via `commands/smoke-test.sh`. Rebuild
the agent image and confirm `command -v gh-review-threads` inside a fresh container, then run
it against a real open PR with unresolved threads (any powbox PR works) and eyeball the JSON
against `gh pr view --json` / the PR page. Temporarily break the scope regex (or feed the
fixture) to confirm the failure mode is loud and exit-code-distinct. `shellcheck`/`shfmt`
over the new/changed shell files.

## Review plan

Reviewer confirms: the helper never uses `--paginate` and pages with fresh per-page calls;
the scope assertion is boundary-safe, repo-qualified, and fails closed (no partial stdout);
the helper's query matches the skills' fallback recipe; both skill flavors and the workflow
prompt reference the helper with a working no-helper fallback; Dockerfile bakes it in the
agent layer with the comment updated; tmpl + README mention it; the offline test would catch
a reverted assertion or a reintroduced `--paginate`; exec bits and static guards pass.

## Status

**Not started.** Follow-up to the `minor-improvements` branch's skill-text fix (commit
`1b79b5f`); actionable once that branch merges, so the skills' recipe section this task
edits is in its final form.
