---
name: address-reviews-worktrees
description: Address maintainer-vetted review feedback on several pull requests in parallel, one git worktree per PR — each worktree checks out an existing PR head branch and runs the address-review skill in hands-off mode, with push/ping flags passed through, so many PRs are fixed concurrently without cross-talk. Trigger when the user asks to address reviews on multiple PRs at once, fix review comments across many PRs in parallel, or fan out review-addressing with worktrees. Do not trigger for a single PR (use address-review), for implementing new task files (use address-tasks-worktrees), or for rebasing a stack (use rebase-stack).
---

Address the review feedback on **several pull requests at once**, fanning each PR out into its own git worktree so they progress concurrently without polluting each other.

**Arguments:** `<PR numbers> [push] [ping-codex] [ping-claude]`

This skill is the parallel batch front-end for `address-review`.
It does **not** re-implement review-addressing — it sets up one isolated worktree per PR and runs the `address-review` skill inside each, `hands-off`, then aggregates the results.
It borrows its worktree machinery (isolation model, Session Bootstrap, adaptive throttling, cleanup) wholesale from `address-tasks-worktrees` — **read that skill for the rationale behind those pieces**; only the deltas are spelled out here.

## How this differs from address-tasks-worktrees

Everything here follows from one fact: **the PRs already exist**, so we modify existing branches rather than create new ones.

- **No new branches, no `gh pr create`.** Each worktree checks out an **existing PR head branch**; pushing (when asked) is a force-push-with-lease to that same branch, handled inside `address-review`.
- **No dependency waves.** Distinct PRs are independent review-addressing units, so they all run **concurrently** from the start (subject to throttling) — there is no dependency graph to compute. (Even genuinely stacked PRs are addressed independently here: each fixes its own review on its own branch; restacking comes later.)
- **Per-PR work is fully delegated to `address-review`.** Each per-PR subagent runs the whole `address-review` skill (which internally may spawn its own fixer/reviewer). The orchestrator does **not** run its own implement→review loop — it does worktree setup and result aggregation only.
- **A leafy branch stack is the expected outcome and is fine.** Parallel fixes leave the PR branches diverged. This skill does **not** build a restack guide — integrating the result is a deliberate follow-up via `rebase-stack` (or manual rebases). See "After the batch".

## Arguments

Parsing is **lenient** — accept commas, `&`, `#` prefixes, and free word order.

| Argument | Meaning |
|---|---|
| `<PR numbers>` | The batch: one or more PRs (`#38 #231 #6`, `38,231,6`, …). Each becomes one worktree + one `address-review` run. This is the only required argument. |
| `push` | Passed through to every PR's `address-review`: push the fixed branch (force-with-lease) and do the PR-side communication (replies, resolves, Summary comment). |
| `ping-codex` | Passed through: after pushing, post a dedicated `@codex review` comment on that PR. Implies `push`. |
| `ping-claude` | Passed through: after pushing, post a dedicated `@claude review` comment on that PR. Implies `push`. |

**Always force-injected into each subagent (not a user argument):** `hands-off`.
A parallel subagent has no line back to the user, so it must run `address-review` `hands-off` — best-effort, documenting every skipped/blocked item in its report.
The top-level orchestrator (you) may still consult the user for **batch-level** blockers (e.g. a PR number that resolves to nothing) when you yourself are running interactively.

**Not user-facing (orchestrator may supply at its own discretion):** the per-PR `#N` (you always pass each subagent its assigned PR) and `rebase on top of <branch>`.
The user has no reason to pass a rebase here — the leafy stack is resolved later — but if you detect a stacked PR that genuinely must be addressed against its near-final base, you may pass a rebase target to that one PR's `address-review`. Off by default.

Flag pass-through is **batch-uniform**: the same `push`/`ping-*` set applies to every PR in the run.

## Worktree isolation (inherited)

Each PR runs in its **own git worktree** — a separate working directory with its own `HEAD` and index, sharing the one append-only object store and lock-protected refs.
Two subagents in two worktrees never corrupt each other, so they run **concurrently**.
The only serialization rule that survives: agents sharing *one* worktree must run one-at-a-time — which is already enforced *inside* `address-review` (its fixer and reviewer). Across PRs, full parallelism.
See `address-tasks-worktrees` → "Why worktrees change the rules" and "Durability & host isolation" for the full model; the durability discipline (**commit early, push after every commit**, worktrees are disposable, committed `.git` survives recycle) applies unchanged.

## Session Bootstrap (run once, in the main working tree, before any worktree)

Identical to `address-tasks-worktrees` → "Session Bootstrap" — run that procedure. In brief, all idempotent:

1. **Verify the worktree roots are container-local and prune this container's orphans.** Confirm `.worktrees` is a mountpoint on a container-local fs (not the host bind mount) and that `.claude/worktrees` + `.git/worktrees` are tmpfs; if a check fails, stop and run `enable-worktrees` (or rebuild/relaunch) before continuing. Then prune only **this** container's orphaned worktree dirs under `.worktrees/$CONTAINER_NAME/` (scanning the whole volume would delete a peer container's live work). Use the exact command blocks from the sibling skill's Bootstrap.
2. **Ensure pushes work without rewriting the host remote.** If `origin` is SSH, add the container-local `url."https://github.com/".insteadOf "git@github.com:"` rewrite, then confirm `git ls-remote --heads origin >/dev/null`. If auth fails and the batch needs `push`/`ping-*`, stop and report — unlike `address-tasks-worktrees`, there is no "local branches only" fallback that still delivers value here, because the whole point of `push`/`ping` is updating the existing PRs.
3. **`git fetch origin`** so PR head branches resolve to their current remote tips before you check them out.

## Orchestrator responsibilities

You are the orchestrator. You do **not** address reviews yourself — `address-review` does, one instance per PR. Your job:

1. Resolve `<PR numbers>` to a concrete list of PRs; capture the pass-through flag set.
2. Run the **Session Bootstrap**.
3. For each PR, **resolve and sanity-check it, then create a worktree checked out on its existing head branch** (see next section). Skip-and-record any PR that cannot be set up (closed/merged, branch checked out elsewhere, fork edge cases you choose not to handle).
4. **Spawn one subagent per PR, fanned out concurrently** (throttled — see below), each running `address-review` `hands-off` with the pass-through flags. Wait for the in-flight set to return.
5. **Clean up** each worktree once its subagent returns (never delete the PR branch).
6. **Aggregate** every subagent's `address-review` final report into one batch summary, surfacing the hands-off blockers prominently.

## Per-PR worktree on an existing PR branch

This is the part that differs most from the task-file skills: you check out a branch that **already exists** (locally or only on `origin`, occasionally on a fork) rather than creating one.

For each PR `#N`, from the main tree:

1. **Resolve and sanity-check** the PR:

   ```bash
   gh pr view N --json number,state,headRefName,headRepositoryOwner,baseRefName,url,title
   ```

   - If `state` is not `OPEN`, skip and record it — there is no live PR to address.
   - Note `headRefName` (the branch) and whether `headRepositoryOwner` matches `origin`'s owner (same-repo PR) or differs (fork PR).

2. **Create the worktree on the PR head branch**, under this container's own subdir so a peer's prune never reaps it:

   ```bash
   ROOT="$(git rev-parse --show-toplevel)"
   WT_BASE="$ROOT/.worktrees/${CONTAINER_NAME:?CONTAINER_NAME must be set}"
   mkdir -p "$WT_BASE"
   ```

   **Same-repo PR** (the common case) — track the remote head:
   - If no local branch `<headRefName>` exists: `git worktree add --track -b <headRefName> "$WT_BASE/pr-<N>" origin/<headRefName>`.
   - If a local `<headRefName>` exists and is **not** checked out in another worktree: `git worktree add "$WT_BASE/pr-<N>" <headRefName>`. Do **not** silently reset it to `origin/<headRefName>`; if it diverges from origin, record that in the summary (a force-push would rewrite the PR), and let `address-review` work from the actual tip.
   - If `<headRefName>` is already checked out elsewhere (e.g. the main tree is sitting on it): skip-and-record — a branch cannot be checked out in two worktrees at once.

   **Fork PR** — let `gh` wire up the fork remote and tracking inside a detached worktree:
   ```bash
   git worktree add --detach "$WT_BASE/pr-<N>"
   ( cd "$WT_BASE/pr-<N>" && gh pr checkout N )
   ```
   `gh pr checkout` also works for same-repo PRs, so it is a fine uniform fallback whenever the explicit `git worktree add` path above is awkward.

3. The absolute path `"$WT_BASE/pr-<N>"`, the branch name, and `#N` are what you hand that PR's subagent.

These git calls are safe to run while other PRs' subagents are active — they touch only their own worktrees and the lock-protected refs.

## Per-PR subagent

Spawn one `general-purpose` `Agent` per PR. Each runs the entire `address-review` skill against its PR. Fan them out **concurrently** (one tool block, throttled by the rules below), then wait for the batch to return.

The prompt contract for each subagent:

- **WORKTREE CONTRACT first:** "Your worktree is `<absolute path>`. Before anything else, `cd` into it and verify `git rev-parse --show-toplevel` prints exactly that path; if not, STOP and report. Do all work inside this worktree only — never `cd` to the repo root or touch sibling worktrees. Other agents are working in other worktrees concurrently; stay in yours."
- **The assignment:** "You are on branch `<headRefName>`, the head of PR #N. Confirm with `git branch --show-current` and `gh pr view N`."
- **The action:** "Invoke the `address-review` skill with exactly: `/address-review #N hands-off <push?> <ping-codex?> <ping-claude?>` (a user-level seeded skill). If you cannot invoke a skill in your context, read and follow `address-review`'s `SKILL.md` from your skills directory and execute its procedure with those same arguments. `hands-off` is mandatory — you have no line to the user; make best-effort low-stakes calls and document everything else."
- **Repo context:** "Read `AGENTS.md` / `CLAUDE.md` first for conventions."
- **Validation in a worktree:** "If verifying fixes needs a build, install dependencies in this worktree first — cheap on the hardlinked pnpm store. Point Playwright at `/usr/bin/chromium` if used. App-server / `next build` e2e may not run from a nested worktree path; defer it per `address-tasks-worktrees`'s app-server caveat and note that in your report rather than forcing it."
- **No shared task-tracker:** "Do not use the `TaskCreate`/`TaskUpdate`/`TaskList` tools — their entries leak into the orchestrator's view."
- **Reporting:** "Return `address-review`'s full final report verbatim, especially: per-thread dispositions with their stable refs (file:line, author, thread node id, permalink), every push-back with rationale, every item you skipped for lack of feedback (you ran hands-off), whether you pushed and pinged, and any blocker (e.g. a lease-rejected push, an unidentifiable PR, or the reviewer hitting its 3-round cap)."

Do **not** give a subagent any other PR's context — strict per-PR isolation.

## Adaptive throttling (finish over fan-out)

Inherit `address-tasks-worktrees` → "Adaptive throttling" in full (storage headroom before each fan-out, `ENOSPC` back-off, serialize shared-exclusive-resource phases, fan out less on `429`/`529`).

One amplifier specific to this skill: **each per-PR subagent runs a full `address-review`, which may itself spawn a fixer and a reviewer subagent.** So effective concurrency is a *multiple* of the PR count, not equal to it. Throttle the number of **PRs in flight** more conservatively than you would task worktrees — start a few PRs at a time (e.g. 2–3), not the whole batch, and widen only if storage and rate limits are comfortable. Run the rest in sub-batches. Record in the summary whenever you ran narrower than the batch size and why.

## Cleanup

- `git worktree remove "<path>"` once a PR's subagent has returned and its work is committed (and pushed, on push runs). The branch and commits persist in `.git` and on the remote.
- **Never delete the branch** — it is the PR's head. (This is the opposite of nothing-to-lose task branches: deleting it would orphan the PR.)
- Because `.git/worktrees` is tmpfs-shadowed, host hygiene needs no `git worktree prune`; prune only to clear a stale registration within the live session.

## After the batch

The PR branches are now independently fixed and almost certainly form a **leafy stack** (diverged tips, possibly shared ancestors).
This skill intentionally stops here.
If the user wants them integrated into a linear, mergeable order, point them at **`rebase-stack`** (explicit-chain form for independent branches) or a manual rebase — that is the deliberate, separate follow-up step, not something to fold into this parallel run.

## Final summary

Aggregate the per-PR `address-review` reports into one batch summary:

- **Per PR:** its URL, the branch, whether it was pushed and/or pinged, and a one-line outcome (`fixed & pushed`, `fixed, not pushed`, `skipped — <reason>`, `blocked — <reason>`).
- **Hands-off blockers, surfaced prominently** — every item any subagent skipped for lack of an authoritative decision, gathered across all PRs so the user can act on them in one place. This is the main value of an unattended batch: nothing silently dropped.
- **Push-backs** made across the batch, with their rationale.
- **No-push runs:** include each PR's per-thread disposition map (from its `address-review` report) so a later "push now" pass can replay replies/resolves precisely.
- **Throttling:** note whenever you ran narrower than the batch size, and why (storage-bound, rate-limited, resource-serialized).
- **A leafy-stack note** pointing at `rebase-stack` if the user will want to integrate the branches.

## Checklist

- [ ] Session Bootstrap ran: worktree roots verified container-local, this container's orphans pruned, push auth confirmed, `git fetch origin` done.
- [ ] `<PR numbers>` resolved; pass-through flag set (`push`/`ping-*`) captured; `hands-off` force-injected into every subagent.
- [ ] Each PR sanity-checked (open?), worktree created on its **existing** head branch under `.worktrees/$CONTAINER_NAME/`; un-setup-able PRs skipped-and-recorded.
- [ ] One subagent per PR, each running `/address-review #N hands-off …`; fanned out concurrently but throttled (PRs-in-flight conservative due to nested fixer/reviewer agents).
- [ ] No new branches created, no `gh pr create`, no restack performed.
- [ ] Worktrees removed after each subagent returns; **no PR branch deleted**.
- [ ] Batch summary aggregates outcomes, hands-off blockers (prominently), push-backs, no-push disposition maps, throttling notes, and the `rebase-stack` follow-up pointer.
