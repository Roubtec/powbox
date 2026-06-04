---
name: address-tasks-worktrees
description: Execute a batch of pre-planned task files in parallel using one git worktree per task — schedule independent tasks concurrently, run a sequential implement→review→fix loop inside each task's isolated worktree, push commits as durability backup, and open PRs against the resolved base. Trigger when the user asks to address tasks in parallel, work a task batch with worktrees, or fan out implementation across independent tasks. Do not trigger for one-off coding requests, for planning new tasks, or when strictly sequential single-branch execution is wanted (use `address-tasks` for that).
---

Implement a set of pre-planned task files using a **parallel, worktree-isolated** delegated subagent workflow.

**Arguments:** `<glob-or-file-list of task files to implement>`

This skill is the parallel sibling of `address-tasks`. The roles (orchestrator / implementer / reviewer), the implementer and reviewer prompt contracts, and the code-quality review checklist are all inherited from that skill — read it if you need the rationale behind those pieces. **What changes here is the execution model:** instead of one branch on one shared working tree processed strictly sequentially, each task gets its **own git worktree** so independent tasks can run **concurrently**, while each individual task still runs its implement→review→fix loop **sequentially** (up to 3 iterations).

## Why worktrees change the rules

`address-tasks` forbids running two checkout-dependent agents at once because every subagent shares the orchestrator's single working tree — a reviewer spawned alongside its implementer scopes its diff against a branch the implementer hasn't finished committing to, sees nothing, and ships the work unreviewed.

A git worktree removes that constraint. Each worktree is a **separate working directory with its own `HEAD` and index** (`.git/worktrees/<name>/`), while sharing the one common object store (`.git/objects`, append-only and concurrency-safe) and refs (lock-protected). So:

- **Two agents in two different worktrees never corrupt each other.** They touch different files, different indexes, different HEADs. Concurrent commits land on different branches under separate ref locks.
- Therefore the base skill's "one agent at a time" rule is replaced by: **agents that operate in distinct worktrees may run concurrently; only agents sharing one worktree must be serialized.**
- **Within a single task, the implementer and its reviewer still share that task's worktree** — so they still run one-at-a-time, implementer first. The parallelism is strictly *across* independent tasks, never between a task's own implementer and reviewer.

### Durability & host isolation (this container)

This repo's main checkout is bind-mounted from a Windows host into a Linux container, so the worktree roots are **shadowed** to keep their writes container-local and invisible to the host (no cross-platform path pollution). They are shadowed two different ways, and the difference matters:

- **`.worktrees/`** is backed by a **persistent per-project ext4 Docker volume** that the powbox launcher mounts there, and which *also* holds the pnpm store (`.worktrees/.pnpm-store`). Because the store and every `.worktrees/<task>/node_modules` live under that **one mount**, `pnpm install` inside a worktree **hardlinks** package files from the store instead of copying them — so worktree installs are near-free, there is **no shared 2 GB tmpfs cap**, and many worktrees can install concurrently. The volume is on disk (the Docker VM's ext4), not RAM. *(Fallback: if the container was launched without that volume, `.worktrees` is tmpfs-shadowed instead — see Bootstrap.)*
- **`.claude/worktrees/`** and **`.git/worktrees/`** remain **tmpfs-shadowed** (ephemeral): the harness-native worktree path and the per-worktree git metadata.

Crucially, the **common `.git` is NOT shadowed**: commit objects and branch refs (`.git/refs/heads/...`) persist on the host. **Committed work therefore survives container recycle even without pushing** — only uncommitted changes are lost. The operating discipline that follows:

- **Commit early and often**, and **push after every commit** (a worktree's working tree is more volatile than committed `.git`, and pushing also lets the host sync via `git pull`).
- On recycle, the `.worktrees` **volume persists** (so the pnpm store — the efficiency win — survives), but the per-worktree git metadata in the tmpfs `.git/worktrees` does **not**. A leftover `.worktrees/<task>` working dir from a crashed prior session is therefore orphaned (its `.git` pointer dangles); the Bootstrap prunes such orphans while preserving `.pnpm-store`. Worktrees remain disposable — push committed work.

## Session Bootstrap (run once, before any worktree)

Do this in the **main working tree** before creating worktrees. All steps are idempotent.

1. **Verify the worktree roots are container-local (not on the host bind mount).** The powbox launcher mounts the per-project ext4 volume at `.worktrees`; `.claude/worktrees` and `.git/worktrees` are tmpfs-shadowed from `.powbox.yml`. Confirm each is its own mount and **not** the host bind-mount filesystem (`9p`/`drvfs`/`virtiofs`), self-healing the tmpfs ones if `.powbox.yml` was missing entries:

   ```bash
   mkdir -p .worktrees .claude/worktrees .git/worktrees
   shadow-refresh.sh "$(git rev-parse --show-toplevel)"   # tmpfs-shadows any unmounted root (fallback for .worktrees too)
   # .worktrees should be ext4 (the volume) or tmpfs (fallback); the others tmpfs:
   findmnt -no TARGET,FSTYPE -T .worktrees .claude/worktrees .git/worktrees
   ```

   If `.worktrees` reports the host bind-mount fstype (`9p`/`drvfs`/`virtiofs`) rather than `ext4`/`tmpfs`, **stop and tell the user** — worktree files would leak to the host. When `.worktrees` is the ext4 volume, per-worktree `pnpm install` hardlinks from the co-located store, so there is no shared 2 GB cap to exhaust. *(Only in the tmpfs fallback do all worktrees share one ~2 GB cap; an `ENOSPC` there means the container must be relaunched with a larger `SHADOW_TMPFS_SIZE`, or — better — with the worktrees volume.)*

   Then prune any worktree dirs orphaned by a prior recycle (their tmpfs git metadata is gone), preserving the persistent store:

   ```bash
   git worktree prune
   for d in .worktrees/*/; do
     [ -e "$d" ] || continue
     case "$d" in .worktrees/.pnpm-store/) continue ;; esac
     git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || rm -rf "$d"
   done
   ```

2. **Ensure pushes work without rewriting the host remote.** If `origin` is an SSH URL, add a *container-local* rewrite so git reaches it over HTTPS via the gh credential helper (this touches only the container's global config, never the host `.git/config`):

   ```bash
   git config --global url."https://github.com/".insteadOf "git@github.com:"
   git ls-remote --heads origin >/dev/null   # confirm auth before relying on push
   ```

   If `ls-remote` fails, fall back to **local reviewed branches only** and note in the final summary that PRs/pushes were skipped.

## Orchestrator Responsibilities

You are the orchestrator. You MUST NOT do implementation work yourself (except the trivial-task escape hatch below). Your responsibilities:

1. Resolve the input arguments to a list of task files.
2. Run the **Session Bootstrap** above.
3. Build a **dependency graph** across the tasks and group them into **waves** (see Scheduling).
4. For each wave, create one worktree per task on the right base branch, then drive each task's implement→review→fix loop — fanning the loop's same-phase agents out **concurrently** across the wave's tasks.
5. Push branches, open PRs against the resolved base, and track progress.
6. Clean up finished worktrees.
7. Produce the final batch summary.

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

If the whole batch is a linear dependency chain, this degrades gracefully to one task per wave — i.e. effectively sequential, like `address-tasks`, but still worktree-isolated.

## Adaptive throttling (finish over fan-out)

When this skill runs **unattended**, completing the batch matters more than maximizing parallel width. A wave that runs four-wide and dies to `ENOSPC`, a port clash, or provider rate-limiting has delivered nothing; the same wave run two-wide — or serially — delivers everything a little slower. So treat wave width as a knob to turn **down** the moment concurrency is the problem. Prefer a slower run that completes over a faster one that fails, and never push fan-out past what the container can sustain.

Cap each wave's concurrency at the **minimum** of its dependency-derived width and what the environment can support. Concretely, before and during each wave:

- **tmpfs headroom.** Before launching a wave, measure free space on the worktree tmpfs (`findmnt -nbo AVAIL -T .worktrees`, or `df -PB1 .worktrees | awk 'NR==2{print $4}'`). A full per-worktree `pnpm install` in a node monorepo can copy on the order of a gigabyte into tmpfs when the store can't be hardlinked. Don't assume a fixed number — measure one install if unsure, then set `max_concurrent = max(1, floor(free_bytes / per_worktree_need))`, where `per_worktree_need ≈ install size + build-artifact headroom`. If `max_concurrent` is below the wave's task count, run the wave in **sub-batches** of `max_concurrent`, not all at once.
- **`ENOSPC` mid-wave.** If any worktree's install/build fails with `ENOSPC`, stop adding concurrency: remove that worktree, halve `max_concurrent` (floor 1), and retry the remaining tasks in smaller sub-batches — ultimately one at a time. Never abandon a task because the *parallel* attempt failed; fall back to serial and let it through.
- **Shared exclusive resources.** Some validation cannot run two-at-once even in separate worktrees because it contends for a single host-wide resource: a fixed listen port, one shared dev database on one port, or a build/e2e server that infers the workspace root from the repo-root lockfile (see below). Run such phases **serially** regardless of wave width — give each task exclusive use, then move on.
- **Provider rate-limiting.** Repeated `429`/`529` errors when spawning many subagents at once are a signal to fan out less. Reduce the number of concurrent subagents per phase and proceed.

Record in the final summary whenever you throttled below the dependency-derived width, and why — it tells the user whether the run was capacity-bound (worth relaunching with a larger `SHADOW_TMPFS_SIZE`) or genuinely serial by dependency.

### App-server / e2e validation in a worktree

Validation that boots a *built* app server is the most common thing that won't run from inside a worktree. Next.js `next build` standalone output and Playwright's `webServer` both infer the workspace root from the repo-root lockfile, then look for the server at a path that ignores the nested `.worktrees/<slug>/` prefix — so `test:e2e` can't find the server and self-skips or errors. This is a repo-config limitation, not something the worktree skill can fix from the outside; handle it by choosing one of these, in order of preference:

1. **Run that task's e2e phase serially in the main checkout** after its branch is pushed: from the main tree, check out the task branch, build, run e2e, then restore. This keeps unit/integration coverage in-worktree and serializes only the part that needs the un-nested path.
2. **Defer e2e to CI** and rely on the in-worktree unit/integration suites for the in-loop signal, noting in the PR that e2e runs in CI.
3. **Run it in-worktree only if the repo's config is worktree-aware** (resolves the standalone/server path from `next build`'s actual output dir rather than assuming repo root).

Treat a task whose acceptance hinges on app-server e2e as a **serialize-this-phase** task per the shared-resource rule above, and say so in the summary. (Browser availability itself is fine in-worktree: point Playwright at the baked Chromium — `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium`, or `npx playwright install chromium` — the worktree problem is the server path, not the browser.)

## Per-wave execution

For a wave of tasks `T1..Tn`:

1. **Create a worktree per task** from the main tree (orchestrator git calls; safe to run while other waves' subagents are active — they touch only their own worktrees):

   ```bash
   ROOT="$(git rev-parse --show-toplevel)"
   git worktree add "$ROOT/.worktrees/<task-slug>" -b <branch-name> <base-branch>
   ```

   Use a stable, collision-free slug per task (e.g. the task number + short name). The absolute path `"$ROOT/.worktrees/<task-slug>"` is what you hand to that task's subagents.

2. **Run each task's loop, fanned out by phase.** Each task runs its own implement→review→fix loop, but you advance all of the wave's tasks **in lockstep by phase** so that same-phase agents (which live in different worktrees) can be spawned **together in one tool block and run concurrently**:

   - **Phase A — implement:** spawn one implementer per still-unfinished task in the wave, each pointed at its own worktree path, **all in a single tool block** (concurrent). Wait for all to return.
   - **Phase B — review:** only after *all* Phase-A implementers have returned, spawn one fresh reviewer per task, each in its task's worktree, **all in a single tool block** (concurrent). Wait for all. Collect verdicts.
   - Tasks whose reviewer passes exit the loop. Tasks with issues carry their reviewer's verbatim findings into the next round's Phase A.
   - Repeat A→B for up to **3 rounds** total. After round 3, any task still failing review does **not** get a PR; surface its outstanding findings to the user.

   > Phase ordering is what preserves the per-task discipline: a task's reviewer never starts until that task's implementer (and every sibling implementer) has finished and committed. You get cross-task parallelism without ever running a task's own implementer and reviewer at the same time.

   Concurrency is safe here **only because each agent has its own worktree.** If for any reason a task is not running in its own worktree, fall back to serializing that task as in `address-tasks`.

3. **On pass, push and open a PR** for the task (see Delivery), then `git worktree remove` its worktree to free tmpfs (the branch and its commits persist in `.git` and on the remote).

4. When the wave is fully resolved, unlock the next wave (dependents can now branch from these stable branches).

## Implementer Agent

Same contract as `address-tasks`, plus a **worktree isolation contract** and **push-every-commit**. Launch implementers as described in per-wave Phase A.

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
  - **After every commit, push:** `git push -u origin HEAD` on the first push, `git push` thereafter. WIP in a tmpfs worktree is volatile; pushing is the backup. If a push fails (e.g. no remote auth), keep committing and note it — commits still persist locally.
  - Run the project build/lint periodically and a full build check before reporting done.
- **Coordination:** it must not revert unrelated or concurrent edits, and must accommodate that its base branch may itself be a sibling task's branch.
- **Reporting:** when done, report what was implemented, decisions/tradeoffs/deviations, and any areas needing focused review.

On a fix-up round, spawn a **fresh** implementer for the task — a new `Agent`, never a "continued" prior implementer. If an `Agent` result prints a `SendMessage` continuation footer, ignore it; this harness does not expose that tool. A fresh spawn is the preferred path because the new implementer reads the committed worktree plus the findings without bias toward its earlier choices. Paste the reviewer's numbered findings verbatim and instruct it to address each specifically and report what changed (same branch, same worktree).

## Reviewer Agent

Same fresh-eyes contract and code-quality checklist as `address-tasks`. A reviewer is always a **new** `Agent` invocation — a fresh-eyes spawn, never a continuation of the implementer — launched only **after** every Phase-A implementer in the wave has returned. Ignore any `SendMessage` continuation footer from earlier `Agent` results; this harness does not expose that tool.

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
3. If pushing/PR creation is unavailable (no remote auth — see Bootstrap step 2), fall back to **local reviewed branches**: the work still persists in `.git`, and the host can `git pull` once a remote is reachable. Note the fallback in the final summary.

After the PR is open, `git worktree remove "<absolute worktree path>"` to reclaim tmpfs. Do not delete the branch — the PR and any dependents need it.

## Cleanup

- Remove each task's worktree once its PR is open (or once you've decided to stop on it): `git worktree remove <path>` (add `--force` only if you've confirmed the work is committed and pushed).
- Because `.git/worktrees` is tmpfs-shadowed, you do **not** need `git worktree prune` for host hygiene — the metadata never reaches the host. Prune only if a removed worktree leaves a stale registration *within the live session*.
- Never remove a worktree whose branch a not-yet-started dependent wave still needs to branch from; branch the dependent first, then remove.

## Final Output

After the batch, provide a concise summary:

- Each task: its PR link (or "local branch only" if PRs were skipped) and which wave it ran in.
- How many review rounds each task needed, and any task that hit the 3-round cap without passing (with its outstanding findings).
- The dependency/wave structure actually used, and any base-branch/stacking choices worth flagging.
- Any blockers, host-sync notes (branches to `git pull` on the host), or uncertainties that remain.
