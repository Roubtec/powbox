# Learnings handoff — Scribz

Improvements for the `Roubtec/Scribz` repo, distilled from agent-session retrospectives run there on 2026-07-26/27-28 (parallel review-addressing, a `wf-address-tasks` batch, and peer-review retrofits).
This document is self-contained and is the basis for writing Scribz task files; the original learnings branches are being deleted.
Most of what those sessions surfaced was environment/orchestration-level and has been routed to powbox or agent-skills (summary at the end); the repo-specific items are few.

## 1. Let read-only reviewers execute the test suite (writable build-tool caches)

Every read-only Codex peer review of Scribz hit the same wall: Vitest could not start because Vite/SvelteKit must write cache metadata (`.vite-temp`/`node_modules/.vite`, `.svelte-kit`) inside the repo, and the read-only sandbox rejects those writes.
Every peer statement of the form "this test would fail without the fix" was therefore a static judgement, not an executed one — a systematic weakening of the second opinion on exactly the claim that matters most.

Adopt (investigation): make the build-tool cache locations overridable to a writable path outside the repo — e.g. honor an env var to relocate Vite's `cacheDir` and the SvelteKit output dir to `$TMPDIR` for check/test runs — so a read-only-workspace reviewer can actually run `vitest`.
If relocation turns out impractical for SvelteKit, document the limitation in the repo's review guidance so nobody implies the peer executed tests.

## 2. Task-file numbering collisions across in-flight branches

Two concurrent branches each filed a follow-up task by picking "next free number" from their own tree, producing two different `tasks/024-*.md` files that Git would merge without conflict (different filenames).
Caught only by an explicit cross-branch check before review.

The durable guard lands in agent-skills (the task-batch/review skills get a same-number-different-name collision check across open PR heads, and the task-writing skill gets numbering guidance).
Repo-side option if collisions keep happening: allocate numbers from a small manifest on `main` instead of by tree scan — only worth it if the skill-level guard proves insufficient.

## 3. Keep the two-verifier review setup

Recorded as a positive: across PRs #77–#83 the executing own-reviewer and the read-only Codex peer caught **different, non-overlapping** defect classes (the reviewer disproved a deferral by writing the missing test; the peer alone caught an unguarded timeout path later measured at ~10× the contracted request rate).
Worth keeping both gates for correctness-sensitive Scribz work, with the division of labour: executing reviewer gets mutation/build authority (and should *attempt* a deferral it is asked to accept), read-only peer does claim-level scrutiny.

## Routed elsewhere (no Scribz action needed)

- Shared session scratchpad collisions (two reviewers reading each other's `verify.log`; the misdiagnosis that followed) → agent-skills scratch-hygiene task + powbox docs task 045.
- `wf-address-tasks`/`wf-address-review` missing the peer-review stage → powbox task 041.
- No syntax checker / run introspection for workflow scripts → powbox task 047 (`wf-check`, `wf-status`).
- `.powbox-seeded` markers not naming the upstream source → powbox task 043.
- `wt-enter` error not naming the primary checkout as the blocker → powbox task 039.
- `gh pr merge --delete-branch` half-failing when a worktree holds the branch, `statusCheckRollup` empty-string jq footgun, other GitHub API recipes → agent-skills tasks.
- Rebase-conflict hunk-vs-whole-file guidance, same-class-findings ⇒ structural-defect heuristic, report-don't-correct for locked-decision deviations, no latched flags in loop summaries → agent-skills tasks.
- Harness-level items (per-subagent scratchpad namespacing, Workflow resume/drain/introspection internals, `Skill` re-invocation returning no instructions) → collected for an upstream Claude Code report; powbox documents workarounds only.
