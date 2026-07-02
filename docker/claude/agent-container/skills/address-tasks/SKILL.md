---
name: address-tasks
description: Execute a batch of pre-planned task files in parallel using one git worktree per task — schedule independent tasks concurrently, run a sequential implement→review→fix loop inside each task's isolated worktree, open PRs, then create an unpushed local review stack without rewriting the PR branches. This is the default task-batch executor. Trigger when the user asks to address tasks, work through a task batch, kick off implementation of planned work, process a folder of task files, or fan out implementation across independent tasks. Do not trigger for one-off coding requests, for planning new tasks, or when strictly sequential single-branch execution is explicitly wanted (use `address-tasks-serialized` for that).
---

Implement a set of pre-planned task files using a **parallel, worktree-isolated** delegated subagent workflow.

**Arguments:** `<glob-or-file-list of task files to implement>`

This skill is the parallel sibling of `address-tasks-serialized`. The roles (orchestrator / implementer / reviewer), the implementer and reviewer prompt contracts, and the code-quality review checklist are all inherited from that skill — read it if you need the rationale behind those pieces. **What changes here is the execution model:** instead of one branch on one shared working tree processed strictly sequentially, each task gets its **own git worktree** so independent tasks can run **concurrently**, while each individual task still runs its implement→review→fix loop **sequentially** (up to 3 iterations).

## Why worktrees change the rules

`address-tasks-serialized` forbids running two checkout-dependent agents at once because every subagent shares the orchestrator's single working tree — a reviewer spawned alongside its implementer scopes its diff against a branch the implementer hasn't finished committing to, sees nothing, and ships the work unreviewed.

A git worktree removes that constraint. Each worktree is a **separate working directory with its own `HEAD` and index** (`.git/worktrees/<name>/`), while sharing the one common object store (`.git/objects`, append-only and concurrency-safe) and refs (lock-protected). So:

- **Two agents in two different worktrees never corrupt each other.** They touch different files, different indexes, different HEADs. Concurrent commits land on different branches under separate ref locks.
- Therefore the base skill's "one agent at a time" rule is replaced by: **agents that operate in distinct worktrees may run concurrently; only agents sharing one worktree must be serialized.**
- **Within a single task, the implementer and its reviewer still share that task's worktree** — so they still run one-at-a-time, implementer first. The parallelism is strictly *across* independent tasks, never between a task's own implementer and reviewer.

### Durability & host isolation (this container)

This repo's main checkout is bind-mounted from the host, so the worktree roots are **shadowed** to keep their writes container-local and invisible to the host. They are shadowed two different ways, and the difference matters:

- **`.worktrees/`** is backed by a **persistent per-container Docker volume** that the powbox launcher mounts there, and which *also* holds the pnpm store (`.worktrees/.pnpm-store`). Because the store and every `.worktrees/$CONTAINER_NAME/<task>/node_modules` live under that **one mount**, `pnpm install` inside a worktree **hardlinks** package files from the store instead of copying them — so installs avoid full package copies, there is **no shared 2 GB tmpfs cap**, and many worktrees can install concurrently. The volume is on disk, not RAM. *(Fallback: if the container was launched without that volume, `.worktrees` is tmpfs-shadowed instead — see Bootstrap.)*
- **`.claude/worktrees/`** and **`.git/worktrees/`** remain **tmpfs-shadowed** (ephemeral): the harness-native worktree path and the per-worktree git metadata.

Crucially, the **common `.git` is NOT shadowed**: commit objects and branch refs (`.git/refs/heads/...`) persist on the host. **Committed work therefore survives container recycle even without pushing** — only uncommitted changes are lost. The operating discipline that follows:

- **Commit early and often**, and **push after every commit** (a worktree's working tree is more volatile than committed `.git`, and pushing provides remote durability and keeps the PR current).
- On recycle, the `.worktrees` **volume persists** (so the pnpm store — the efficiency win — survives), but the per-worktree git metadata in the tmpfs `.git/worktrees` does **not**. A leftover `.worktrees/$CONTAINER_NAME/<task>` working dir from a crashed prior session is therefore orphaned (its `.git` pointer dangles); the Bootstrap prunes such orphans (each with its scoped `.worktrees/.golangci-cache/$CONTAINER_NAME/<task>` lint cache) while preserving the volume-root stores (`.pnpm-store`, the shared Go caches `.gomodcache`/`.gocache`). Worktrees remain disposable — push committed work.
- **The `.worktrees` volume is now per-container (agent + project), so this project's Claude and Codex containers each get their own — they no longer share one.** Each container still creates and prunes its worktrees under its own `.worktrees/$CONTAINER_NAME/` subdir (`$CONTAINER_NAME` = `<agent>-<project>`, Docker-unique and stable across recycle), and the prune only ever reaps *this* container's own crashed-session orphans. With the volume private this is now defensive scoping rather than a necessity — it keeps the prune from touching anything it did not create. The `.pnpm-store` and the shared Go caches stay at the volume root, and because the volume is private, this container's worktree disk budget (the `availBytes` headroom in Scheduling) is its own — a concurrent peer agent can no longer draw it down.

## Session Bootstrap (run once, before any worktree)

Do this in the **main working tree** before creating worktrees. The mechanics are an image-baked helper shared by every worktree consumer (this skill, `address-reviews`, and the Claude dynamic workflows), so they can never drift apart:

```bash
wt-bootstrap   # idempotent; prints one JSON object; exit 1 on a blocker
```

What it does, and how to react to its JSON output:

1. **Verifies the worktree roots are container-local (not on the host bind mount).** The powbox launcher normally mounts the per-container volume at `.worktrees`; `.claude/worktrees` and `.git/worktrees` are tmpfs-shadowed from `.powbox.yml`. The script first applies `shadow-refresh.sh` (which mounts declared-but-unmounted shadows, but cannot add missing declarations), then enforces: all three roots are mountpoints, the two metadata roots are tmpfs, and `.worktrees` is not on a host filesystem (9p/drvfs/virtiofs). The safety criterion for `.worktrees` is the **mount**, not one specific local fstype — the volume may be ext4/xfs/btrfs, with tmpfs the supported fallback. On `ok: false`, stop and fix per the `blocker` before continuing: run `enable-worktrees` to add missing `.powbox.yml` declarations, or, if the roots are already declared, rebuild the powbox image on the host (`./build.sh all`) and relaunch (the running image predates worktree-shadow support). *(Only in the `.worktrees` tmpfs fallback do all worktrees share one ~2 GB cap; an `ENOSPC` there means relaunching with the worktrees volume or a larger `SHADOW_TMPFS_SIZE`.)*

2. **Prunes this container's own orphans.** Worktree dirs under `.worktrees/$CONTAINER_NAME/` whose tmpfs git metadata vanished in a prior recycle are removed (reported in `prunedOrphans`). The scan is scoped to this container's subdir — a peer container's live worktrees are never touched (see Durability).

3. **Probes remote access without rewriting the host remote.** If `origin` is an SSH URL it adds the *container-local* `url."https://github.com/".insteadOf "git@github.com:"` rewrite (the container's global config only, never the host `.git/config`), then runs `git ls-remote --heads origin`. `remote: false` is **not** a blocker: fall back to **local reviewed branches only** and note in the final summary that PRs/pushes were skipped.

It also reports `wtBase` (this container's `.worktrees/$CONTAINER_NAME/`, where every worktree goes) and `availBytes` (free space on the `.worktrees` mount — the starting input for Adaptive throttling below).

## Orchestrator Responsibilities

You are the orchestrator. You MUST NOT do implementation work yourself (except the trivial-task escape hatch below). Your responsibilities:

1. Resolve the input arguments to a list of task files.
2. Run the **Session Bootstrap** above.
3. Build a **dependency graph** across the tasks and group them into **waves** (see Scheduling).
4. For each wave, create one worktree per task on the right base branch, then drive each task's implement→review→fix loop — fanning the loop's same-phase agents out **concurrently** across the wave's tasks.
5. Push branches, open PRs against the resolved base, and track progress.
6. Clean up finished worktrees.
7. Build a **local review stack** from disposable copies of the mergeable branches — delegated to the `rebase-stack` skill in a subagent, never pushed and never rewriting the PR branches (see Post-batch restack).
8. Produce the final batch summary.

**Trivial-task escape hatch:** for a genuinely trivial task (single obvious change, unambiguous criteria) you may implement it directly in its worktree without an implementer subagent — but still spawn a fresh reviewer. No task skips review.

## Scheduling: dependency waves

True parallelism only helps for tasks that don't depend on each other. Determine dependencies from the task files (an explicit "Depends on" field, shared infrastructure, or files/modules two tasks both create or migrate). When in doubt, treat tasks that touch the same files or migrations as dependent.

- **Wave** = the set of tasks whose dependencies are all already complete. All tasks in a wave run **concurrently**.
- Tasks with **no** unmet dependencies form wave 1; tasks depending on them form wave 2; etc.
- **Base branch per task:**
  - Independent task (wave 1, or no dependency in-batch) → branch from and PR against the user's chosen base (default `main`, or an explicit override).
  - Dependent task → branch from and PR against its **dependency's branch** (stacked PRs), so it builds on work that may not be merged yet.
  - If a task depends on *several* tasks, branch from an integration branch that merges them, or from the single dependency it most directly extends — pick the simplest base that contains the code it needs and note the choice.
  - **Building a multi-parent integration branch is the orchestrator's job** — a bounded exception to "the orchestrator does not implement." Creating the branch and resolving its merge conflicts is small, mechanical, and a prerequisite for the wave rather than task work, so do it yourself rather than delegating. Keep the merge minimal, build/lint the result before branching any task off it, and record any non-trivial conflict resolutions (in the batch summary or a short merge-advice note) so they can be reproduced when the stack later lands on `main`.
- Start a wave only after every task it depends on has **passed review** (its branch is stable enough to build on).

If the whole batch is a linear dependency chain, this degrades gracefully to one task per wave — i.e. effectively sequential, like `address-tasks-serialized`, but still worktree-isolated.

## Adaptive throttling (finish over fan-out)

When this skill runs **unattended**, completing the batch matters more than maximizing parallel width. A wave that runs four-wide and dies to `ENOSPC`, a port clash, or provider rate-limiting has delivered nothing; the same wave run two-wide — or serially — delivers everything a little slower. So treat wave width as a knob to turn **down** the moment concurrency is the problem. Prefer a slower run that completes over a faster one that fails, and never push fan-out past what the container can sustain.

Cap each wave's concurrency at the **minimum** of its dependency-derived width and what the environment can support. Concretely, before and during each wave:

- **Storage headroom.** Before launching a wave, measure free space on the `.worktrees` mount (`wt-bootstrap` already reported it as `availBytes`; re-measure mid-run with `findmnt -nbo AVAIL -T .worktrees`). Estimate `per_worktree_need`, then cap width at `max_concurrent = max(1, floor(free_bytes / per_worktree_need))`; if that is below the wave's task count, run the wave in **sub-batches** of `max_concurrent` rather than all at once. On the normal volume-backed path pnpm packages are hardlinked, so `per_worktree_need` is mainly build artifacts plus package metadata; on the tmpfs fallback, measure one representative install and add its full package-copy cost. When unsure, measure one install before fanning out.
- **`ENOSPC` mid-wave.** Stop adding concurrency, let viable in-flight tasks finish, and reclaim only worktrees whose changes are committed and pushed. Then retry the failed and remaining tasks in smaller sub-batches — ultimately one at a time. Never force-remove a worktree with uncommitted changes just to free space, and never abandon a task because the parallel attempt failed.
- **Shared exclusive resources.** Some validation cannot run two-at-once even in separate worktrees because it contends for a single host-wide resource: a fixed listen port, one shared dev database on one port, or a build/e2e server that infers the workspace root from the repo-root lockfile (see below). Run such phases **serially** regardless of wave width — give each task exclusive use, then move on.
- **Provider rate-limiting.** Repeated `429`/`529` errors when spawning many subagents at once are a signal to fan out less. Reduce the number of concurrent subagents per phase and proceed.

Record in the final summary whenever you throttled below the dependency-derived width, and why — it tells the user whether the run was storage-bound, provider-bound, resource-serialized, or genuinely serial by dependency. Mention `SHADOW_TMPFS_SIZE` only when `.worktrees` is actually using the tmpfs fallback.

### App-server / e2e validation in a worktree

Validation that boots a *built* app server is the most common thing that won't run from inside a worktree. Next.js `next build` standalone output and Playwright's `webServer` both infer the workspace root from the repo-root lockfile, then look for the server at a path that ignores the nested `.worktrees/$CONTAINER_NAME/<slug>/` prefix — so `test:e2e` can't find the server and self-skips or errors. This is a repo-config limitation, not something the worktree skill can fix from the outside; handle it by choosing one of these, in order of preference:

1. **Run that task's e2e phase serially in the main checkout** after its branch is pushed: from the main tree, check out the task branch, build, run e2e, then restore. This keeps unit/integration coverage in-worktree and serializes only the part that needs the un-nested path.
2. **Defer e2e to CI** and rely on the in-worktree unit/integration suites for the in-loop signal, noting in the PR that e2e runs in CI.
3. **Run it in-worktree only if the repo's config is worktree-aware** (resolves the standalone/server path from `next build`'s actual output dir rather than assuming repo root).

Treat a task whose acceptance hinges on app-server e2e as a **serialize-this-phase** task per the shared-resource rule above, and say so in the summary. (Browser availability itself is fine in-worktree: point Playwright at the baked Chromium — `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium`, or `npx playwright install chromium` — the worktree problem is the server path, not the browser.)

## Per-wave execution

For a wave of tasks `T1..Tn`:

1. **Create a worktree per task** from the main tree (orchestrator calls; safe to run while other waves' subagents are active — they touch only their own worktrees), using the image-baked helper:

   ```bash
   WT="$(wt-enter <task-slug> <branch-name> <base-branch>)"
   ```

   `wt-enter` places the worktree under this container's own `.worktrees/$CONTAINER_NAME/` subdir so a peer container's prune can never mistake it for an orphan (see Durability), and it is **rerun-safe**: it reuses the task's existing worktree (prior commits intact), attaches the branch without `-b` if the branch already exists (an interrupted prior run), or creates the branch off the base — and refuses with a non-zero exit rather than guessing when the worktree is on the wrong branch, the slug is unsafe, or the base does not resolve. Use a stable, collision-free slug per task (e.g. the task number + short name). The printed absolute path is what you hand to that task's subagents.

2. **Run each task's loop, fanned out by phase.** Each task runs its own implement→review→fix loop, but you advance all of the wave's tasks **in lockstep by phase** so that same-phase agents (which live in different worktrees) can be spawned **together in one tool block and run concurrently**:

   - **Phase A — implement:** spawn one implementer per still-unfinished task in the wave, each pointed at its own worktree path, **all in a single tool block** (concurrent). Wait for all to return.
   - **Phase B — review:** only after *all* Phase-A implementers have returned, spawn one fresh reviewer per task, each in its task's worktree, **all in a single tool block** (concurrent). Wait for all. Collect verdicts.
   - Tasks whose reviewer passes exit the loop. Tasks with issues carry their reviewer's verbatim findings into the next round's Phase A.
   - Repeat A→B for up to **3 rounds** total. After round 3, any task still failing review does **not** get a PR; surface its outstanding findings to the user.

   > Phase ordering is what preserves the per-task discipline: a task's reviewer never starts until that task's implementer (and every sibling implementer) has finished and committed. You get cross-task parallelism without ever running a task's own implementer and reviewer at the same time.

   Concurrency is safe here **only because each agent has its own worktree.** If for any reason a task is not running in its own worktree, fall back to serializing that task as in `address-tasks-serialized`.

3. **Before delivery, run the sibling add/add collision guard below** across the wave's reviewed-passing branches. For non-colliding tasks, push and open a PR (see Delivery), then `wt-remove <task-slug>` to reclaim storage (the branch and its commits persist in `.git` and on the remote). For colliding tasks, do **not** open the PR yet; leave the worktree in place, reconcile the naming/path conflict, regenerate derived files, and re-review that task before delivery.

4. When the wave is fully resolved, unlock the next wave (dependents can now branch from these stable branches). A branch held for a collision is not resolved and must not unlock its dependents.

### Guarding against sibling add/add collisions

Independent tasks in the same wave run in **separate worktrees**, so two of them can each *add* the same new file — or a file exporting the same top-level class/symbol — with no conflict at implementation time. The clash only surfaces later, when the branches linearize or merge (an add/add conflict, or a duplicate definition). It is rare, but it has happened; two cheap guards keep it from costing a fix-up round:

- **Prevent it up front.** When you fan out two independent tasks that both introduce the same *kind* of new surface (a "reconciliation controller", a "work-list endpoint", a migration helper), assign each a **distinct file and class name** in its implementer prompt. The implementers can't see each other, so the disambiguation has to come from you.
- **Catch it before the PRs.** After a wave's tasks pass review but **before** opening their PRs, compare what each sibling branch newly added:

  ```bash
  # Exact same new path.
  for b in <wave-branch-1> <wave-branch-2> ...; do
    git diff --diff-filter=A --name-only <that-branch's-base>...$b
  done | sort | uniq -d

  # Same new basename at any path; inspect repeated first columns.
  for b in <wave-branch-1> <wave-branch-2> ...; do
    git diff --diff-filter=A --name-only <that-branch's-base>...$b |
      awk -v branch="$b" '{ n=split($0, p, "/"); print p[n] "\t" branch "\t" $0 }'
  done | sort
  ```

  A duplicated path (or basename, or a shared exported top-level class/function/const/interface/type/enum name across two added files) is a collision. Hold the colliding branch(es) before PR delivery, then **deconflict — that call is yours to make** (a bounded exception to "the orchestrator doesn't implement", like building an integration branch): there is no inherent "first", so pick the side(s) whose rename is least disruptive, rename enough files and/or symbols that at most one branch keeps the original colliding value, regenerate anything derived (e.g. contracts), and **re-review each changed task with fresh eyes** before its PR; any unchanged non-colliding side then delivers unchanged. If the shared name is **imperative** — a framework-mandated path, an external/published contract, or a name a task file explicitly pins — do **not** invent a divergent name: keep those branches held and surface it as a design decision for a human. Diff each branch against **its own base** with the three-dot form so a dependent branch that legitimately builds on a sibling isn't flagged — it never re-lists an inherited file. (The `wf-address-tasks` workflow automates this end to end: a deputy agent makes the same which-side call, performs the rename + regen, and the workflow re-reviews each changed branch before delivery — holding as `collision-blocked` any branch whose name it can't deconflict.)

## Implementer Agent

Same contract as `address-tasks-serialized`, plus a **worktree isolation contract** and **push-every-commit**. Launch implementers as described in per-wave Phase A.

Include in each implementer prompt:

- A **WORKTREE CONTRACT** as the very first instruction:
  - "Your worktree is `<absolute worktree path>`. Before anything else, `cd` into it and verify: `git rev-parse --show-toplevel` MUST print exactly that path. If it does not, STOP and report — do not run any git or edit command outside this path."
  - "Do all work inside this worktree only. Never `cd` to the repository root, never touch sibling worktrees or the main checkout. You are not the only agent in this container; other agents are working in other worktrees concurrently — stay in yours."
- The **branch name** (already checked out in the worktree) and instruction to confirm it with `git branch --show-current`.
- **The full task file content**, pasted in. Do not assume prior context.
- Instruction to **read the repository's agent-context file** (`AGENTS.md` / `CLAUDE.md` / `.github/CLAUDE.md`) for conventions.
- **Upstream context:** if this task builds on a dependency task, briefly describe what that task introduced (and that the worktree was branched from it, so that code is already present).
- **Commit, push, and validation instructions:**
  - Commit at logical milestones, keeping each commit buildable when practical.
  - **After every commit, push:** `git push -u origin HEAD` on the first push, `git push` thereafter. Worktrees are disposable and their git metadata is ephemeral, so pushing is the backup. If a push fails (e.g. no remote auth), keep committing and note it — commits still persist locally.
  - Run the project build/lint periodically and a full build check before reporting done.
- **Coordination:** it must not revert unrelated or concurrent edits, and must accommodate that its base branch may itself be a sibling task's branch.
- **Reporting:** when done, report what was implemented, decisions/tradeoffs/deviations, and any areas needing focused review.

On a fix-up round, spawn a **fresh** implementer for the task — a new `Agent`, never a "continued" prior implementer. If an `Agent` result prints a `SendMessage` continuation footer, ignore it; this harness does not expose that tool. A fresh spawn is the preferred path because the new implementer reads the committed worktree plus the findings without bias toward its earlier choices. Paste the reviewer's numbered findings verbatim and instruct it to address each specifically and report what changed (same branch, same worktree).

## Reviewer Agent

Same fresh-eyes contract and code-quality checklist as `address-tasks-serialized`. A reviewer is always a **new** `Agent` invocation — a fresh-eyes spawn, never a continuation of the implementer — launched only **after** every Phase-A implementer in the wave has returned. Ignore any `SendMessage` continuation footer from earlier `Agent` results; this harness does not expose that tool.

Include in each reviewer prompt:

- The same **WORKTREE CONTRACT** first: "Your worktree is `<absolute worktree path>`. `cd` into it and confirm `git rev-parse --show-toplevel` matches before doing anything. Review only this worktree."
- **The full task file content** (same source of truth the implementer got).
- **The PR base branch** for this task, so the reviewer scopes with `git -C <worktree> diff --name-only <base>...HEAD`. The implementation is already committed on the current branch in this worktree — the reviewer must read the actual files and must NOT conclude "no implementation" without first confirming the diff is genuinely empty (an empty diff at this stage signals a wrong worktree/branch, not real absence — say so rather than reviewing nothing).
- Instruction to run a **full build / type-check first** (a failure is an automatic blocker), then check each acceptance criterion against the code, then a code-quality pass over the touched files using the inherited checklist (logic, error handling, edge cases, dead code, consistency, duplication, type safety).
- Reporting format: **Pass** (all criteria met, build passes, no material issues) or **Issues** (numbered, each with category + file/line + what's wrong + what to change).
- **Do NOT edit, create, or delete any files. Do NOT read commit messages or `git diff` content** — list touched files for scoping only, then read whole files. Be strict but fair; flag real gaps, not style nits. Put any follow-up suggestions in the report only.

## Delivery (push + PR, per task)

Default behavior, matching the existing workflow: each task that passes review gets **pushed and a PR opened** against its resolved base.

1. The implementer already pushed its branch during the loop. Ensure the final state is pushed: `git -C <worktree> push`.
2. Open the PR against the recorded base branch (the chosen base for independent tasks; the dependency's branch for dependent tasks → stacked PR):

   ```bash
   gh pr create --base <base-branch> --head <branch-name> --title "<task title>" --body "<summary>"
   ```

   - Reference the task file for context. Include reviewer-relevant caveats (tradeoffs, intentional divergences, uncertainties).
   - For stacked PRs, note in the body which branch it stacks on, so reviewers understand the base.
3. If pushing/PR creation is unavailable (no remote auth — see Bootstrap step 2), fall back to **local reviewed branches**: the work persists in the shared `.git` and is available to the host directly. Note in the final summary which branches still need to be pushed once a remote is reachable.

After the PR is open, `wt-remove <task-slug>` to reclaim storage. Do not delete the branch — the PR and any dependents need it (`wt-remove` never touches branches).

## Cleanup

- Remove each task's worktree once its PR is open (or once you've decided to stop on it): `wt-remove <task-slug>`. It refuses to delete uncommitted work or an in-progress rebase/merge — even with `--force`, which only clears git's refusal over leftovers like ignored build artifacts after the clean checks pass. If it refuses, surface why rather than deleting evidence.
- Because `.git/worktrees` is tmpfs-shadowed, you do **not** need `git worktree prune` for host hygiene — the metadata never reaches the host. Prune only if a removed worktree leaves a stale registration *within the live session*.
- Removing a worktree does not delete its branch; future dependent waves can still branch from that ref after the worktree is gone.

## Post-batch restack: a local review stack (never pushed)

After Delivery and Cleanup, build one linear **local** stack in the order you recommend reviewing and merging the PRs.
This is an integration check and merge-order guide; it is **never pushed**.

Do **not** rebase the task/PR branch names themselves.
Those local refs should continue to match the pushed PR heads; rewriting them locally creates misleading ahead/behind state and makes later pull/push operations error-prone.
Instead, create disposable `review-stack/...` branches that snapshot the canonical task branches, then rebase only those guide branches.
The guide refs persist in the host's un-shadowed `.git`, while the PR branches and remote PRs remain unchanged.

**Skip it when** the batch produced **0 or 1** mergeable branch.
Exclude branches that failed review or that the user asked to skip.
If the batch was already a linear dependency chain, still build the guide stack: it verifies the chain against the current local base without risking the PR refs.

**Compute the order yourself.**
Reuse the dependency graph and emit a topological order: every dependency precedes its dependents.
Break ties between independent branches deterministically: keep closely related areas adjacent, then fall back to task number.
Record the order using the canonical task branches as `b1 → b2 → … → bN`, rooted at the chosen local base, where `b1` is the recommended first merge.
Dependency edges are binding; the relative order of independent branches is only a stable review recommendation, not a newly invented dependency.

Before creating guide branches, inspect each canonical branch's unique history relative to its recorded PR base for merge commits.
If the batch used a synthetic multi-parent integration branch, or `git rev-list --merges <pr-base>..<branch>` is non-empty, do not automatically rebase that branch or any dependent suffix: plain `rebase-stack` intentionally linearizes history and could discard merge-only conflict resolutions.
Build and report the safe prefix, then report the remaining canonical order as not integration-checked and include the integration-branch merge advice already recorded during Scheduling.

Create collision-free guide branch names such as `review-stack/<batch>-<YYYYMMDD-HHMMSS>/01-<task-slug>`, using a git-ref-safe UTC timestamp — digits and dashes only, no `:` (ISO-8601 colons are invalid in ref names), matching the `YYYYMMDD-HHMMSS` form `rebase-stack` already uses for pre-rebase refs.
Point each guide branch `gN` at the captured tip of its canonical branch `bN`; do not check out or move any `bN`.
Create a dedicated worktree attached to `g1`: `wt-enter _review-stack-<batch>-<YYYYMMDD-HHMMSS> <g1>` (same ref-safe timestamp; `g1` already exists, so this attaches it under `$WT_BASE` without creating anything).
Running the restack there keeps the user's main checkout and current branch untouched.
A fresh worktree has no installed dependencies, so if `rebase-stack`'s post-conflict validation would need a build, install the project's dependencies in this worktree first (cheap on the hardlinked store) — otherwise a resolved trivial conflict that triggers validation false-stops the guide on missing modules rather than a real failure.

Delegate the restack to one fresh `general-purpose` subagent in that dedicated worktree and have it invoke `/rebase-stack` with the explicit guide chain.
Use the explicit form because independently created branches have no topology from which to infer the intended order.
The prompt contract is:

- Start with the usual worktree contract: `cd` to the exact dedicated worktree, verify `git rev-parse --show-toplevel`, and operate only there.
- "Invoke `/rebase-stack` in its delegated unattended mode with exactly: `chain <g1> <g2> ... <gN> onto <base>`. This explicit chain and prompt are the up-front authorization; do not re-derive, reorder, or wait for confirmation."
- "Every `gN` is a disposable local snapshot created only for this integration check. The canonical task branches `b1 ... bN` and all remote refs are read-only."
- "Do not push and do not fetch. Resolve only conflicts the skill classifies as trivial. On the first non-trivial conflict or unrecoverable validation failure, use the unattended clean-stop behavior: restore the current guide branch, leave the worktree clean, and stop without waiting for input."
- "Report the canonical merge order, the `bN → gN` mapping, each guide branch outcome, any stop point, every conflict's files/offending commit/resolution or abort reason, any guide branch with no unique commits relative to its new base, and the exact `refs/pre-rebase/...` snapshots created."

After the subagent returns, verify the canonical `bN` tips still equal the SHAs captured before creating the guide branches, verify the dedicated worktree is clean with no rebase in progress, then remove only that worktree (`wt-remove` its slug — the script enforces the same clean checks).
If the subagent unexpectedly returns with a rebase in progress or dirty files, reset it to the disposable branch's reported pre-rebase ref, clear any untracked leftovers with `git clean -fd`, and confirm a clean `git status` before removal; never force-remove unresolved state.
Delete only the exact `refs/pre-rebase/...` snapshots the subagent created for these disposable guide branches; the unchanged canonical `bN` refs are their recovery source.
Never bulk-delete unrelated pre-rebase refs.
Do not delete or push the guide branches; they are the local artifact the maintainer can inspect.
The main checkout must remain on the branch and commit where it started.

An empty guide branch means that canonical branch contributes no unique patch after the earlier recommended branches; flag it as potentially redundant or already subsumed, not as a reason to merge it first.
If the restack stops partway, the canonical order remains the review recommendation, but only the completed prefix was integration-checked; report the first unstacked branch and the remaining suffix.

## Final Output

After the batch, provide a concise summary:

- Each task: its PR link (or "local branch only" if PRs were skipped) and which wave it ran in.
- How many review rounds each task needed, and any task that hit the 3-round cap without passing (with its outstanding findings).
- The dependency/wave structure actually used, and any base-branch/stacking choices worth flagging.
- The **recommended merge order** using canonical PR branch names — `b1 → … → bN`, merge `b1` first — plus the corresponding local `review-stack/...` guide refs, the integration-checked prefix, any stop point or merge-history guard, reproducible conflict notes, and any empty guide branch. Make clear the guide stack is local only and not pushed; the canonical PR branches were not rewritten, and independent-branch tie ordering is advisory.
- Any blockers, local branches that still need pushing, or uncertainties that remain.
