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

This repo's main checkout is bind-mounted from the host, so the worktree roots are **shadowed** to keep their writes container-local and invisible to the host. They are shadowed two different ways, and the difference matters:

- **`.worktrees/`** is backed by a **persistent per-project Docker volume** that the powbox launcher mounts there, and which *also* holds the pnpm store (`.worktrees/.pnpm-store`). Because the store and every `.worktrees/$CONTAINER_NAME/<task>/node_modules` live under that **one mount**, `pnpm install` inside a worktree **hardlinks** package files from the store instead of copying them — so installs avoid full package copies, there is **no shared 2 GB tmpfs cap**, and many worktrees can install concurrently. The volume is on disk, not RAM. *(Fallback: if the container was launched without that volume, `.worktrees` is tmpfs-shadowed instead — see Bootstrap.)*
- **`.claude/worktrees/`** and **`.git/worktrees/`** remain **tmpfs-shadowed** (ephemeral): the harness-native worktree path and the per-worktree git metadata.

Crucially, the **common `.git` is NOT shadowed**: commit objects and branch refs (`.git/refs/heads/...`) persist on the host. **Committed work therefore survives container recycle even without pushing** — only uncommitted changes are lost. The operating discipline that follows:

- **Commit early and often**, and **push after every commit** (a worktree's working tree is more volatile than committed `.git`, and pushing also lets the host sync via `git pull`).
- On recycle, the `.worktrees` **volume persists** (so the pnpm store — the efficiency win — survives), but the per-worktree git metadata in the tmpfs `.git/worktrees` does **not**. A leftover `.worktrees/$CONTAINER_NAME/<task>` working dir from a crashed prior session is therefore orphaned (its `.git` pointer dangles); the Bootstrap prunes such orphans while preserving `.pnpm-store`. Worktrees remain disposable — push committed work.
- **The `.worktrees` volume is project-keyed, so this project's Claude and Codex containers share it** — but each container's `.git/worktrees` metadata is its own tmpfs, so a *peer* container's live worktree has no metadata here and looks exactly like an orphan. To never delete a peer's in-progress work, **each container creates and prunes its worktrees under its own `.worktrees/$CONTAINER_NAME/` subdir** (`$CONTAINER_NAME` = `<agent>-<project>`, Docker-unique and stable across recycle). The prune then only ever reaps *this* container's own crashed-session orphans; a peer's subdir is never scanned. The shared `.pnpm-store` stays at the volume root.

## Session Bootstrap (run once, before any worktree)

Do this in the **main working tree** before creating worktrees. All steps are idempotent.

1. **Verify the worktree roots are container-local (not on the host bind mount).** The powbox launcher normally mounts the per-project volume at `.worktrees`; `.claude/worktrees` and `.git/worktrees` are tmpfs-shadowed from `.powbox.yml`. `shadow-refresh.sh` applies existing declarations immediately but cannot add missing ones — if a check below fails, stop and fix it before continuing: run `enable-worktrees` to add any missing `.powbox.yml` declarations, or, if the roots are already declared, rebuild the powbox image on the host (`./build.sh all`) and relaunch (the running image predates worktree-shadow support):

   ```bash
   ROOT="$(git rev-parse --show-toplevel)"
   mkdir -p "$ROOT/.worktrees" "$ROOT/.claude/worktrees" "$ROOT/.git/worktrees"
   shadow-refresh.sh "$ROOT"   # tmpfs-shadows declared, unmounted roots
   for root in "$ROOT/.worktrees" "$ROOT/.claude/worktrees" "$ROOT/.git/worktrees"; do
     mountpoint -q "$root" || { echo "Unsafe worktree root (not a mountpoint): $root" >&2; exit 1; }
     findmnt -no TARGET,FSTYPE -T "$root"
   done
   for root in "$ROOT/.claude/worktrees" "$ROOT/.git/worktrees"; do
     [ "$(findmnt -nro FSTYPE -T "$root")" = tmpfs ] ||
       { echo "Unsafe worktree metadata root (expected tmpfs): $root" >&2; exit 1; }
   done
   case "$(findmnt -nro FSTYPE -T "$ROOT/.worktrees")" in
     9p|drvfs|virtiofs) echo "Unsafe .worktrees host filesystem" >&2; exit 1 ;;
   esac
   ```

   The safety criterion for `.worktrees` is the **mount**, not one specific local fstype: the volume may be backed by ext4, xfs, btrfs, or another container-local filesystem; tmpfs is the supported fallback. The other two roots must be tmpfs. If any check fails, worktree files or metadata could leak to the host. *(Only in the `.worktrees` tmpfs fallback do all worktrees share one ~2 GB cap; an `ENOSPC` there means relaunching with the worktrees volume or a larger `SHADOW_TMPFS_SIZE`.)*

   Then prune any of **this container's own** worktree dirs orphaned by a prior recycle (their tmpfs git metadata is gone). Worktrees live under a per-container `.worktrees/$CONTAINER_NAME/` subdir (see Durability), so scope the scan there — scanning the whole volume would delete a *peer* container's live worktrees and any uncommitted work in them:

   ```bash
   MINE="$ROOT/.worktrees/${CONTAINER_NAME:?CONTAINER_NAME must be set}"
   mkdir -p "$MINE"
   git -C "$ROOT" worktree prune
   for d in "$MINE"/*/; do
     [ -e "$d" ] || continue
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
7. Restack the batch's mergeable branches into a **local merge-order guide** — delegated to the `rebase-stack` skill in a subagent, never pushed (see Post-batch restack).
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

If the whole batch is a linear dependency chain, this degrades gracefully to one task per wave — i.e. effectively sequential, like `address-tasks`, but still worktree-isolated.

## Adaptive throttling (finish over fan-out)

When this skill runs **unattended**, completing the batch matters more than maximizing parallel width. A wave that runs four-wide and dies to `ENOSPC`, a port clash, or provider rate-limiting has delivered nothing; the same wave run two-wide — or serially — delivers everything a little slower. So treat wave width as a knob to turn **down** the moment concurrency is the problem. Prefer a slower run that completes over a faster one that fails, and never push fan-out past what the container can sustain.

Cap each wave's concurrency at the **minimum** of its dependency-derived width and what the environment can support. Concretely, before and during each wave:

- **Storage headroom.** Before launching a wave, measure free space on the `.worktrees` mount (`findmnt -nbo AVAIL -T .worktrees`, or `df -PB1 .worktrees | awk 'NR==2{print $4}'`). Estimate `per_worktree_need`, then cap width at `max_concurrent = max(1, floor(free_bytes / per_worktree_need))`; if that is below the wave's task count, run the wave in **sub-batches** of `max_concurrent` rather than all at once. On the normal volume-backed path pnpm packages are hardlinked, so `per_worktree_need` is mainly build artifacts plus package metadata; on the tmpfs fallback, measure one representative install and add its full package-copy cost. When unsure, measure one install before fanning out.
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

1. **Create a worktree per task** from the main tree (orchestrator git calls; safe to run while other waves' subagents are active — they touch only their own worktrees). Create them under this container's own `.worktrees/$CONTAINER_NAME/` subdir so a peer container's prune can never mistake them for orphans (see Durability):

   ```bash
   ROOT="$(git rev-parse --show-toplevel)"
   WT_BASE="$ROOT/.worktrees/${CONTAINER_NAME:?CONTAINER_NAME must be set}"
   mkdir -p "$WT_BASE"
   git worktree add "$WT_BASE/<task-slug>" -b <branch-name> <base-branch>
   ```

   Use a stable, collision-free slug per task (e.g. the task number + short name). The absolute path `"$WT_BASE/<task-slug>"` is what you hand to that task's subagents.

2. **Run each task's loop, fanned out by phase.** Each task runs its own implement→review→fix loop, but you advance all of the wave's tasks **in lockstep by phase** so that same-phase agents (which live in different worktrees) can be spawned **together in one tool block and run concurrently**:

   - **Phase A — implement:** spawn one implementer per still-unfinished task in the wave, each pointed at its own worktree path, **all in a single tool block** (concurrent). Wait for all to return.
   - **Phase B — review:** only after *all* Phase-A implementers have returned, spawn one fresh reviewer per task, each in its task's worktree, **all in a single tool block** (concurrent). Wait for all. Collect verdicts.
   - Tasks whose reviewer passes exit the loop. Tasks with issues carry their reviewer's verbatim findings into the next round's Phase A.
   - Repeat A→B for up to **3 rounds** total. After round 3, any task still failing review does **not** get a PR; surface its outstanding findings to the user.

   > Phase ordering is what preserves the per-task discipline: a task's reviewer never starts until that task's implementer (and every sibling implementer) has finished and committed. You get cross-task parallelism without ever running a task's own implementer and reviewer at the same time.

   Concurrency is safe here **only because each agent has its own worktree.** If for any reason a task is not running in its own worktree, fall back to serializing that task as in `address-tasks`.

3. **On pass, push and open a PR** for the task (see Delivery), then `git worktree remove` its worktree to reclaim storage (the branch and its commits persist in `.git` and on the remote).

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
  - **After every commit, push:** `git push -u origin HEAD` on the first push, `git push` thereafter. Worktrees are disposable and their git metadata is ephemeral, so pushing is the backup. If a push fails (e.g. no remote auth), keep committing and note it — commits still persist locally.
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

After the PR is open, `git worktree remove "<absolute worktree path>"` to reclaim storage. Do not delete the branch — the PR and any dependents need it.

## Cleanup

- Remove each task's worktree once its PR is open (or once you've decided to stop on it): `git worktree remove <path>` (add `--force` only if you've confirmed the work is committed and pushed).
- Because `.git/worktrees` is tmpfs-shadowed, you do **not** need `git worktree prune` for host hygiene — the metadata never reaches the host. Prune only if a removed worktree leaves a stale registration *within the live session*.
- Removing a worktree does not delete its branch; future dependent waves can still branch from that ref after the worktree is gone.

## Post-batch restack: a local merge-order guide (never pushed)

After Delivery and Cleanup, do one final orchestration step: replay the batch's mergeable branches into a single linear **local** stack whose order is the sequence you'd recommend merging them in. This is guidance for whoever lands the work — it is **never pushed**. The PRs already hold each task's canonical pushed state; this restack only rewrites local refs, which persist in the host's un-shadowed `.git` (commit objects and `.git/refs/heads/...` are not shadowed — see Durability), so the maintainer sees the stack from their own local branches.

**Why:** a fan-out batch leaves several branches each PR'd against `main` in parallel, and nothing in that picture tells the maintainer which to merge first or whether two of them collide. Replaying them as one chain — dependencies first, each branch rebased onto the previous — makes the merge order explicit and surfaces cross-branch conflicts now, while context is fresh, instead of at merge time.

**Skip it when** the batch produced **0 or 1** mergeable branch (nothing to stack). Exclude any branch that **failed review** at the 3-round cap or that the user asked to skip — stack only branches that passed. If the batch was already a linear dependency chain the branches are largely stacked already, so this is close to a no-op, but it still normalizes them onto the current base; cheap and idempotent, so still run it.

**Compute the order yourself** — small, mechanical, prerequisite work, like building an integration branch. Reuse the dependency graph you built for waves and emit a **topological order**: every dependency precedes its dependents (so stacked children sit above their parents). Break ties between mutually-independent branches with a stable heuristic — keep same-area branches adjacent for a coherent sequence, then fall back to task number. The result is an explicit chain `b1 → b2 → … → bN` rooted at the chosen base (default `main`), where `b1` is the one to merge first.

**Delegate the restack to one fresh subagent running the `rebase-stack` skill**, handing it the **explicit `chain` form** you computed. Use the explicit form — never auto-detection — because these branches typically all fork from `main`, where `rebase-stack`'s topology auto-detection has no stack to find. `rebase-stack` resolves trivial conflicts itself and reasons across the chain (that conflict-awareness is the reason to use it rather than a hand-rolled loop). Since no interactive user exists inside the subagent, the orchestrator's prompt *is* the confirmation. Prompt contract:

- Preconditions you guarantee before spawning: the **main working tree is clean** (worktrees removed, nothing staged/modified) and every chain branch exists locally — `rebase-stack` aborts on a dirty tree.
- "Invoke the `rebase-stack` skill with exactly this chain onto `<base>`: `chain <b1> -> <b2> -> ... -> <bN> onto <base>`. Treat this instruction as the up-front `go` confirmation — do not pause for it. The chain is authoritative: do not re-derive or reorder it."
- "**Do not push and do not fetch.** This stack is local guidance only." (`rebase-stack` never does either on its own; state it anyway so the subagent doesn't improvise.)
- Conflict policy: "Resolve trivial conflicts silently per the skill. For a non-trivial conflict you cannot resolve with confidence, do **not** guess and do **not** wait for input — stop at that branch via the skill's clean-stop path, leaving earlier branches rebased. A partial stack is still useful guidance."
- "Report back: the final order, each branch's outcome (rebased clean / with conflicts / stopped), any branch that came out **empty** after rebase (its commits were already represented upstream — a strong hint it can merge first or is redundant), and the `refs/pre-rebase/...` snapshots created."

**After it returns**, do not push anything. The main checkout is left on the top of the recommended stack; that's fine. Carry the result into the Final Output: the recommended merge order, any branch that stacked with conflicts or stopped (and so needs manual restacking), and any empty branches. If the restack stopped partway, the order up to the stop point is still the recommendation — note the remainder needs manual restacking.

## Final Output

After the batch, provide a concise summary:

- Each task: its PR link (or "local branch only" if PRs were skipped) and which wave it ran in.
- How many review rounds each task needed, and any task that hit the 3-round cap without passing (with its outstanding findings).
- The dependency/wave structure actually used, and any base-branch/stacking choices worth flagging.
- The **recommended merge order** from the post-batch restack — the chain `b1 → … → bN`, merge `b1` first — plus any branch that stacked with conflicts, stopped mid-restack (needs manual restacking), or came out empty. Make clear this stack is **local only and not pushed**: the PRs hold the canonical state and should be merged in this order.
- Any blockers, host-sync notes (branches to `git pull` on the host), or uncertainties that remain.
