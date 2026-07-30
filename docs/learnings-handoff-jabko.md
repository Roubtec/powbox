# Learnings handoff — jabko

Improvements for the `Roubtec/jabko` repo, distilled from agent-session retrospectives run there in July 2026 (a 6-PR parallel review batch and a pnpm/workspace-state incident investigation).
This document is self-contained and is the basis for writing jabko task files; the original learnings branches are being deleted.

## 1. DB-backed e2e tests must fail loudly when no database is provisioned (highest priority)

The eZdravie e2e suite self-skips (or errors on an unmigrated cluster) when no database is configured.
A fixer subagent reported "tests green" after running only the DB-free unit suites while two e2e assertions covering its own change were actually red — one introduced by the change (a Slovak→English string the e2e still pinned by the old value), one pre-existing.
It was caught only because a reviewer independently stood up a database (`pg-dev-up` + `prisma migrate deploy`) and re-ran; a cheaper review gate would have merged red e2e.

Adopt:

- Make DB-backed e2e fail loudly when no DB is configured, or gate it behind an explicit `REQUIRE_DB=1` that CI always sets and that contributor docs tell agents to set when touching submission/sweep/enrolment code.
- Add a `pnpm test:db` wrapper that provisions (`pg-dev-up`), migrates (`prisma migrate deploy`), and runs the e2e — one memorable command instead of three.
- Add one line to the verification checklist: "unit-green ≠ e2e-green; run the DB-backed e2e when you touch DB-exercising code."

## 2. `prisma format` is not idempotent on the committed schema

The committed `schema.prisma` predates the current Prisma version's canonical field alignment, so `prisma format` reflows ~36 unrelated lines on any edit; agents doing comment-only schema edits must know to fall back to `prisma validate` or they commit noise.

Adopt one of:

- a one-time `prisma format` normalization commit on a maintenance branch (ends the problem), or
- a short caveat in the DB/verification docs: "for comment-only or targeted schema edits, validate with `prisma validate`; a full `prisma format` reflows unrelated alignment until the schema is normalized once."

## 3. Parallel worktree validation: use worktree-scoped databases

The review batch serialized DB usage because there was a single default cluster on one port — a latent collision for concurrent DB-backed validation across worktrees.
powbox has since shipped `pg-dev-up --worktree`, which derives an isolated data directory and a free loopback port per Git worktree (`pg-dev-up --worktree up` / `url --export` / `down`).

Adopt: mention `pg-dev-up --worktree` in jabko's testing docs as the way to run DB-backed suites from parallel worktrees (pairs naturally with the `test:db` wrapper from item 1 — have the wrapper prefer the worktree-scoped cluster when inside a linked worktree).

## 4. pnpm empty-shadow / workspace-state trap — fixed in powbox, no jabko change needed

The investigation doc ferried on `docs/powbox-shadow-pnpm-state-findings` (empty tmpfs subpackage `node_modules` + warm persistent root volume ⇒ every `pnpm install` flavor no-ops via `.pnpm-workspace-state-v1.json`, unrecoverable without deleting that file) was adopted by powbox:

- the entrypoint now invalidates the stale workspace-state cache on start for dir-mounted projects (`docker/shared/entrypoint-core.sh`), and
- `pnpm-shadow-doctor` ships as the detector/repair safety net with the correct repair (remove the state file, then `pnpm install --frozen-lockfile`).

jabko needs no repo change; the findings branch can be deleted.
If the symptom ever recurs ("vitest not found" while root `node_modules` looks full), the one-shot manual repair remains: `rm -f node_modules/.pnpm-workspace-state-v1.json && pnpm install --frozen-lockfile`.

## Routed elsewhere (no jabko action needed)

- Scratchpad `threads.json` clobbering across concurrent per-PR fixers → agent-skills scratch-hygiene task (unique per-PR artifact names) + powbox docs task 045.
- Peer-launch shell footguns (backticks inside double-quoted prompts corrupting the prompt; `pkill -f` matching the killer's own argv) → superseded by powbox's `peer-review-run` (literal prompt-file handling, supervised process groups); skill adoption is agent-skills task 015.
- Backgrounded CLI peers not being harness-tracked → same `peer-review-run` adoption.
