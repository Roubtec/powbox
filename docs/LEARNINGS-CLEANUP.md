# Session-learnings adoption — cleanup checklist

Ferried out on a **transport-only commit** — drop that commit before opening the PR; this file is a working checklist, not repo documentation.
Written 2026-07-30 after distilling all 12 learnings reports into standing tasks and handoff docs.

## Deliverables (review/merge these first)

| Repo | Branch | Contents |
|---|---|---|
| `Roubtec/powbox` | `tasks/session-learnings-adoption` | Tasks 033–049 (nine powbox adoption tasks) + `docs/learnings-handoff-{kalm2,jabko,scribz}.md` (self-contained per-repo adoption guides for ferrying) |
| `Roubtec/agent-skills` | `tasks/session-learnings-adoption` | Tasks 013–029 (nine dev-skills improvement tasks) |

Cross-references between the two task sets: powbox 033 ↔ agent-skills 013 (gh-review-threads fix + tests, land in coordination); powbox 041 and agent-skills 015 both consume `peer-review-run`.

## Branches to delete once the deliverables are merged

All are report-only transport refs (one commit adding a `docs/agent-session-learnings-*.md`); every actionable item in them has been carried into the deliverables above.
Delete both the remote branch and any local copy in the host checkout.

### kalm2 (`Roubtec/kalm2`)

- `codex/ferry-session-learnings-20260711`
- `throwaway/session-learnings-20260711-0701`
- `ferry/session-learnings-20260713-1318`
- `throwaway/agent-session-learnings-20260719-0927` (also exists as a **local** branch in the host checkout)
- `learnings/session-20260724-165950`
- `learnings/session-20260727-234514`
- `learnings/session-20260729-073856`

### jabko (`Roubtec/jabko`)

- `chore/agent-session-learnings-20260718-1242`
- `docs/powbox-shadow-pnpm-state-findings` (the pnpm empty-shadow deep-dive — fix shipped in powbox: entrypoint workspace-state invalidation + `pnpm-shadow-doctor`)
- `temp-learnings` — **not in your list**; it carries the June 17 Codex report that first observed the same pnpm empty-shadow trap. Fully superseded by the deep-dive and the shipped fix. Confirm and delete with the others.

### Scribz (`Roubtec/Scribz`)

- `learnings/shared-scratchpad`
- `learnings/session-20260727-232236`

### powbox (`Roubtec/powbox`)

- `throwaway/session-learnings-20260721-0547` (local + remote)
- `throwaway/session-learnings-20260722-0020` (local + remote)

Suggested command shape per repo (after verifying nothing else references them): `git push origin --delete <branch>` and `git branch -D <branch>` for the local ones.

## Items routed upstream (Claude Code harness — not fixable in powbox/agent-skills)

Written up ready-to-file in **`UPSTREAM-REPORT-claude-code.md`** (untracked, next to this file) — eight sections, each pasteable as its own issue on anthropics/claude-code:

1. Read/Edit stale file cache after out-of-band changes in worktrees.
2. Shared session scratchpad, undocumented (the `verify.log`/`threads.json` collision class).
3. Backgrounded-Bash completion notifications describing the launcher, not detached children.
4. Subagents' background children not reaped; subagents silently un-resumable.
5. Workflow tool: no drain mode, retroactive resume of inserted stages (no `fromCache`), opaque `*.meta.json`.
6. Skill tool: false "already loaded" dedup.
7. Feature request: declarative co-tenant resource budget.
8. Docs nit: soften the subagent-transcript warning to permit bounded greps.

## Dropped items (deliberate, with reasons)

- `wt-bootstrap` "commands after it in the same invocation didn't run" (kalm 07-11): not reproducible from the script (it ends by printing JSON; nothing execs/kills the shell) and never re-observed — dropped as unactionable.
- Codex peer dropping its `-o` output under sustained concurrency (powbox 07-21): superseded by `peer-review-run` (normalizes empty-output to `forfeited`, transient-retry) plus concurrency caps in agent-skills task 015 and the existing powbox task 023 (Codex concurrency seed).
- In-container reap-grace test masking (powbox 07-22): already addressed — `scripts/test-peer-review-run.sh` case 12h exercises the zombie-leader reap path.
- Claude CLI credential precedence doc (powbox 07-22): already in `docs/architecture.md`.
- Podman compose exec-form healthcheck (kalm 07-11): already tracked as powbox tasks 025 (done) / 025a (open).
- Shared-checkout/worktree boundary documentation (kalm 07-11): already shipped (task 031; the template's "Shared vs. isolated surfaces" section).

## Formerly open questions — resolved into deferred tasks (2026-07-30)

1. **Structural git-wrapper guard** → `tasks/deferred/031a-git-wrapper-guard-shared-checkout-cleanup.md`. Not currently warranted (docs shipped, no recurrence); the spec exists as inspiration, with the trigger being any recurrence of co-tenant cleanup destroying uncommitted work.
2. **GraphQL cross-PR contamination** → `tasks/deferred/013b-graphql-cross-pr-contamination-repro-and-report.md`. The repro harness needs **no new repo** — it fans out concurrent read-only GraphQL queries against any existing repo with ≥2 PRs carrying review threads (kalm2 qualifies), so the effort trade-off works. Filing remains your call; the task delivers the evidence pack.
3. **Read-only peers executing tests** → `tasks/deferred/029b-peer-writable-overlay-for-test-execution.md`. Framed as a timeboxed feasibility spike first (bwrap native overlay, fuse-overlayfs fallback, or documented infeasibility), productized only on a green spike; designed generically (copy-on-write worktree view, writes land in a discardable upper layer) so any worktree-based multi-agent user benefits, and the result JSON gains an executed-vs-static field. The cheaper repo-side cache-relocation alternative stays in the Scribz handoff independently.
