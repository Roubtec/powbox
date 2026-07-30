# 013b (deferred) — Repro harness for GitHub's cross-PR GraphQL contamination, then an upstream report

## Why this task exists (and why it is deferred)

Concurrent `gh api graphql` calls against the same repository have repeatedly returned **another PR's** review threads: observed live in kalm2 (a PR #142 query returning PR #143's comments; earlier, #10/#11 queries surfacing #9's threads) and documented in `gh-review-threads`' header as the reason that helper exists.
The defect is server-side (GitHub) and can only be detected locally — which the helper now does fail-closed (after the agent-skills scope-check fix, task 013 there).
An upstream report is goodwill toward the real fix, and a repro harness makes the maintainers' lives easy enough that the report might actually go somewhere.

**Deferred because:** local detection already fails closed, so there is no active bleeding; the harness is an hour or two of work best spent when we next see a contamination (fresh evidence to attach) or when someone has slack.
Filing at all remains the maintainer's call — this task delivers the evidence pack that makes the call easy.

## Trigger to action this

The next observed contamination (a `gh-review-threads` exit-3 with offender URLs), or a decision to file the report regardless.

## Scope

- `scripts/repro-gh-graphql-cross-pr.sh` (or a small Go/node script if cleaner): given a repo and ≥2 PR numbers that have review threads, fan out R rounds × N concurrent GraphQL `reviewThreads` queries (the same query shape `gh-review-threads` sends, one PR per call), and for every response assert the echoed identity (`repository.nameWithOwner`, `pullRequest.number`) and every comment URL belong to the requested PR.
- On mismatch: capture the full request/response pair (sanitized — strip tokens; the repo used should be one whose thread contents are shareable, or bodies redacted), the timestamps, concurrency level, and `gh`/API version headers, into an evidence directory.
- Run it against an **existing** repo with suitable PRs (kalm2 already qualifies; any repo with ≥2 open-or-closed PRs carrying review threads works). Creating a dedicated repo with synthetic PRs/comments is explicitly out of scope — if the bug won't reproduce against existing repos within a bounded run (say, a few hundred rounds), record the negative result and stop; the historical evidence still stands.
- Draft the upstream report (GitHub Support ticket and/or `cli/cli` discussion — the crossing has been observed via `gh api graphql`, so ruling `gh`'s HTTP/2 connection reuse in or out is part of what the harness should vary: `--paginate` vs single-shot, HTTP/1.1 via `GIT_CURL_VERBOSE`-style forcing if feasible): symptom, query shape, concurrency conditions, observed pairs with timestamps, harness link/attachment.

## Context and references

- `Roubtec/agent-skills:plugins/dev-skills/bin/gh-review-threads` — the query shape, the manual-paging rationale (`--paginate` under concurrency was the original suspect), and the documented prior occurrences.
- `scripts/test-gh-review-threads.sh` — the local (fake-`gh`) suite; the harness is its live-API sibling, and belongs beside it.
- Historical observed pairs to cite: kalm2 #142←#143 (2026-07-29 session), kalm2 #9→#10/#11 (earlier, per helper header).

## Implementation notes

- Vary one dimension per run: concurrency (2/4/8), pagination mode, connection reuse — the report is far stronger if it says which combination reproduces.
- Never write to the target repo; the harness is read-only GraphQL.
- Rate-limit aware: budget requests per round and back off on secondary-limit responses; this must be polite enough to run against a work repo.

## Acceptance criteria

- One command reproduces-or-bounds the issue against an existing repo and emits a self-contained evidence directory.
- A ready-to-file report draft exists referencing that evidence.

## Validation

- A bounded run against a real repo completes within rate limits, with correct pass/fail classification verified by injecting one synthetic mismatch (env-forced) through the validator.

## Review plan

Reviewer checks the validator matches the helper's identity/URL rules exactly (no weaker), the sanitization actually strips tokens/bodies, and the run-length/rate budget is bounded.
