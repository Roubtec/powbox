# Task 033a — Fail closed on a malformed nested comments page in gh-review-threads

## Why this task exists

Task 013 in `Roubtec/agent-skills` hardened `gh-review-threads` against parser failures on the **threads** pages, and powbox task 033 pinned that with hermetic cases (h)/(i).
The **nested comments** fetch-up — the second query the helper issues when a thread's `comments.pageInfo.hasNextPage` is true — was not hardened, and it still fails **open**.

Reproduced against agent-skills main `21af561` while reviewing PR #118 (2026-08-01).
Feed a well-formed, in-scope threads page whose single thread advertises `comments.pageInfo.hasNextPage: true`, then serve `{"data":{"node":{}}}` as the nested comments response:

- `jq -c '.data.node.comments.nodes'` yields `null`;
- `jq -cs '.[0] + .[1]'` treats `null` as the identity for `+`, so the merge silently succeeds;
- `hasNextPage` reads `null`, the fetch-up loop exits;
- the helper emits the thread with **only its first page of comments**, **exit 0, nothing on stderr**.

The truncated comments are silently dropped. That is the exact failure mode task 033 exists to prevent — "every fail-closed guard needs at least one case where the input **parser** fails, not only where the **validation** fails" — applied to the one path 013 did not cover.
It matters because a caller (the `address-review` skill) uses this output to decide which review threads are still open: silently losing comments can make a thread look addressed when it is not.

Note the scope guard on that path is fine and is now covered: a nested page carrying a **cross-PR url** is correctly caught (powbox case (e2), added in PR #118 review). Only the **malformed-shape** path fails open.

## Scope

This spans two repos and has a hard ordering constraint.

Included — in `Roubtec/agent-skills` (must land first):

- Harden the nested comments fetch-up in `plugins/dev-skills/bin/gh-review-threads` (`complete_comments()`) so a malformed nested response fails closed rather than silently truncating: check that `.data.node.comments.nodes` is an array before merging, and treat a failure as the same retryable/extraction condition the threads-page path already uses (whole-fetch retry once, then exit 3 with the "malformed response" diagnosis on stderr and nothing on stdout).
- Cover the reasonable malformed shapes: `{"data":{"node":{}}}`, `comments: null`, `nodes: null`, and a response missing `data.node` entirely.

Included — in this repo (only after the above merges to agent-skills main):

- Add the matching hermetic cases to `scripts/test-gh-review-threads.sh`, in the style of (h)/(i): each fixture is a response that would OTHERWISE pass, plus one malformed nested comments page, asserting exit 3, empty stdout, the extraction diagnosis on stderr, and the retry count.

Out of scope:

- The threads-page parser and identity guards (agent-skills task 013 / powbox task 033 — both landed).
- The nested-page **scope** check (already correct, and pinned by case (e2)).

## Ordering (important)

`scripts/build-image.sh` stages a fresh clone of agent-skills main on every build, and smoke Stage 0b runs this suite against the **baked** helper.
So adding the powbox tests before the agent-skills fix merges would turn Stage 0b red on powbox main — the same ordering hazard task 033 flagged.
Land the agent-skills fix first, then the tests here.

## Context and references

- `.agent-skills-src/plugins/dev-skills/bin/gh-review-threads` — `complete_comments()` is the affected function; the threads-page path in `fetch_all()` shows the established fail-closed pattern to mirror.
- `scripts/test-gh-review-threads.sh` — cases (h)/(i) are the model for the new cases; case (e)/(e2) already build nested-page fixtures via `$d/comments-N`.
- `docker/agent/Dockerfile:139`, `scripts/build-image.sh:177-183` — how the baked helper is staged.
- `tasks/033-gh-review-threads-parser-failure-fail-closed-tests.md` — the parent task and its fail-open principle.
- Discovered during review of PR #118 (https://github.com/Roubtec/powbox/pull/118), by the independent reviewer verifying the same-pattern sweep; not raised in a review thread.

## Target files or areas

- `Roubtec/agent-skills`: `plugins/dev-skills/bin/gh-review-threads`
- this repo: `scripts/test-gh-review-threads.sh`

## Acceptance criteria

- A malformed nested comments page makes `gh-review-threads` exit 3 with nothing on stdout and a "malformed response" diagnosis on stderr, after the single whole-fetch retry.
- No well-formed multi-page comment thread regresses: case (e) still merges both comment pages at exit 0.
- The new powbox cases fail against the pre-fix helper and pass against the fixed one (verify by mutation or by pinning the pre-fix commit, as task 033 did).
- `bash scripts/test-gh-review-threads.sh`, `shellcheck`, and `shfmt -d` all clean.
