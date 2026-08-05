# Task 049 — Settle the shfmt story for extensionless shared helpers (normalize or document)

## Why this task exists

`docker/shared/pg-dev-up` (and possibly other extensionless helpers) diverges from `shfmt`'s default style (indented `case` bodies), so `shfmt -d` shows diffs on files a change never touched.
CI's shfmt step is advisory and only globs `*.sh`, so the extensionless files are not even checked — but agents and reviewers don't know that: across many powbox review rounds, every fresh reviewer independently re-derived the whole chain ("diff is pre-existing, main shows the same, CI doesn't cover this file, advisory anyway") before dismissing it.
Correct every time, re-litigated every time.
One decision — normalize the files once, or write the exception down — ends the re-derivation.

## Scope

Pick ONE (the maintainer leans toward whichever is least churn; state the choice in the PR):

- **Option A — normalize:** run `shfmt -w` (repo-standard flags) over the extensionless shell helpers in `docker/shared/` in a dedicated, functionally-empty commit; extend the CI shfmt step's file selection to include them (keeping it advisory or not — separate call, default keep advisory).
- **Option B — document:** add a short note to AGENTS.md "Validating Changes" naming the house style for extensionless helpers (indented `case` is accepted), stating that CI's shfmt is advisory and `*.sh`-scoped, and telling reviewers not to raise pre-existing shfmt diffs on those files.

Included either way:

- Enumerate which extensionless files under `docker/shared/` currently show `shfmt -d` diffs (at minimum `pg-dev-up`; check `wt-*`, `gitcat`, `peer-review-run`, `pnpm-shadow-doctor`, `cid`, `powbox-provenance`).
- Make AGENTS.md "Validating Changes" reflect the outcome in one line either way (Option A: "all shell helpers, including extensionless ones, are shfmt-normalized"; Option B: the exception note).

Out of scope:

- Changing shellcheck coverage or severity.
- Reformatting `.sh` files that are already clean.

## Context and references

- AGENTS.md → "Validating Changes" — the line agents read before running lint gates.
- `.github/workflows/native-linux-ci.yml` — the Tier 0 shfmt step and its glob.
- `docker/shared/` — the helper inventory (see the file table in that directory).

## Target files or areas

- Option A: `docker/shared/*` extensionless helpers + `.github/workflows/native-linux-ci.yml` glob + AGENTS.md line.
- Option B: AGENTS.md only.

## Implementation notes

- Option A must be a formatting-only diff: verify with `git diff -w` being empty-ish (whitespace-only) and by running each touched helper's test suite (`test-pg-dev-up-scoped.sh`, `test-peer-review-run.sh`, `test-wt-orphan-safety.sh`, `test-gh-review-threads.sh` where applicable) before and after.
- If Option A, do it in one commit with no functional changes so `git blame` damage is bounded and the commit can be listed in a `.git-blame-ignore-revs` if the repo adopts one (optional, note it).

## Acceptance criteria

- A reviewer touching `docker/shared/pg-dev-up` after this task has a documented, one-line answer to "why does shfmt -d complain?" — either "it doesn't anymore" or "known house exception, see AGENTS.md".
- No functional behavior change (Option A: suites pass unchanged).

## Validation

- Option A: `shfmt -d` clean on the normalized files; the helpers' test suites pass; shellcheck clean.
- Option B: docs-only; markdown renders.

## Review plan

Reviewer verifies formatting-only-ness (Option A) or that the documented exception names the exact scope (extensionless `docker/shared/` helpers) rather than a blanket shfmt waiver.
