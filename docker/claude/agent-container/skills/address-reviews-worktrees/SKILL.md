---
name: address-reviews-worktrees
description: Address maintainer-vetted review feedback on several pull requests in parallel, one git worktree per entry — supply the batch as PR numbers and/or local branch names; each worktree checks out the chosen branch (your local ref when you name a branch, the PR head when you give a number) and runs the address-review skill in hands-off mode, with push/ping flags passed through, so many PRs are fixed concurrently without cross-talk. Trigger when the user asks to address reviews on multiple PRs or branches at once, fix review comments across many PRs in parallel, or fan out review-addressing with worktrees. Do not trigger for a single PR (use address-review), for implementing new task files (use address-tasks-worktrees), or for rebasing a stack (use rebase-stack).
---

Address the review feedback on **several pull requests at once**, fanning each PR out into its own git worktree so they progress concurrently without polluting each other.

**Arguments:** `<PRs and/or branches> [push] [ping-codex] [ping-claude]`

This skill is the parallel batch front-end for `address-review`.
It does **not** re-implement review-addressing — it sets up one isolated worktree per entry and runs the `address-review` skill inside each, `hands-off`, then aggregates the results.
Each batch entry is either a **PR number** (work the PR head from `origin`) or a **local branch name** (work *your* local ref exactly as it stands) — see "Resolving and checking out each entry" for the local-first rule that keeps a locally-rebased branch from being silently replaced by a stale `origin` copy.
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
| `<PRs and/or branches>` | The batch: one or more entries, each a **PR number** (`#38`, `38`) or a **local branch name** (`task/088`). May be mixed (`#38 task/084 6`). Each becomes one worktree + one `address-review` run. This is the only required argument. |
| `push` | Passed through to every entry's `address-review`: push the fixed branch (force-with-lease) and do the PR-side communication (replies, resolves, Summary comment). |
| `ping-codex` | Passed through: after pushing, post a dedicated `@codex review` comment on that PR. Implies `push`. |
| `ping-claude` | Passed through: after pushing, post a dedicated `@claude review` comment on that PR. Implies `push`. |

**Classifying each entry:** a bare integer or `#`-prefixed integer is a **PR number**; anything else (contains a `/`, letters, etc.) is a **branch name**. A branch literally named like an integer is the one ambiguous case — name it with an explicit `refs/heads/` prefix or just pass its PR number instead.

**Local-first guarantee.** When you supply a branch name, the worktree is checked out from **your local ref, never from `origin`** — so a branch you rebased locally while `origin` is stale is worked exactly as it stands on disk. More broadly, this skill checks out `origin` for an entry **only when there is no local branch to use** (a PR number whose head branch you don't have locally). It never silently swaps your local copy for a stale remote one. The `git fetch origin` in Bootstrap updates **remote-tracking refs only** (`origin/*`); it never moves a local branch or changes which commits a branch-entry worktree operates on — it just makes the later force-with-lease accurate.

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
3. **`git fetch origin`** to refresh remote-tracking refs. This updates `origin/*` only — it never moves a local branch or rewrites a worktree — so it is safe for branch entries (which work the local ref regardless) and is what makes a later `--force-with-lease` push compare against the true current remote tip. It also lets a PR-number entry whose head you lack locally check out the current `origin` head.
4. **Record the main checkout's starting branch** (`git -C "$ROOT" branch --show-current`). A branch can be checked out in only one place at a time, so any entry branch the **main checkout currently occupies** must be freed before its worktree is created. The orchestrator does this on demand by detaching the main `HEAD` (see "Resolving and checking out each entry"), which needs the main tree clean — so you do **not** have to start from a particular branch. The simplest way to avoid the dance at all, though, is to launch from a branch **not** in the batch: `main` is ideal, since you never address review on `main`.

## Orchestrator responsibilities

You are the orchestrator. You do **not** address reviews yourself — `address-review` does, one instance per PR. Your job:

1. Parse the batch into a list of entries, classifying each as a PR number or a branch name (see Arguments); capture the pass-through flag set.
2. Run the **Session Bootstrap**.
3. For each entry, **resolve it to a `(local-or-origin branch, PR number)` pair, sanity-check it, then create a worktree on the right ref** (see next section). Skip-and-record any entry that cannot be set up (closed/merged or PR-less, branch checked out elsewhere, fork edge cases you choose not to handle).
4. **Spawn one subagent per PR, fanned out concurrently** (throttled — see below), each running `address-review` `hands-off` with the pass-through flags. Wait for the in-flight set to return.
5. **Clean up** each worktree once its subagent returns (never delete the PR branch).
6. **Aggregate** every subagent's `address-review` final report into one batch summary, surfacing the hands-off blockers prominently.

## Resolving and checking out each entry

This is the part that differs most from the task-file skills: you check out a branch that **already exists** (your local ref, or `origin`'s, occasionally a fork's) rather than creating one. Each entry resolves to a `(branch-to-check-out, PR-number)` pair; the pair drives the worktree and the subagent.

Shared setup, from the main tree:

```bash
ROOT="$(git rev-parse --show-toplevel)"
WT_BASE="$ROOT/.worktrees/${CONTAINER_NAME:?CONTAINER_NAME must be set}"
mkdir -p "$WT_BASE"
```

These git calls are safe to run while other entries' subagents are active — they touch only their own worktrees and the lock-protected refs. Use a stable, collision-free slug per entry (e.g. `pr-<N>` or a sanitized branch name).

### Branch entry — work your local ref

The local-control path (the rebased-locally / stale-origin case). The branch must exist locally, and **pairs to its PR by head name** — i.e. the local branch name equals the PR's `headRefName` (which is the norm: a local rebase keeps the branch name). If your local copy has a *different* name than the PR head, this auto-pairing can't see it; use that PR's number with `address-review` directly, or rename to match.

1. **Pair to the PR by head:** `gh pr list --head <branch> --state open --json number,url,headRepositoryOwner`.
   - Exactly one open PR → that's the pairing.
   - Zero → skip-and-record: with no PR there are no review threads to address.
   - More than one → skip-and-record as ambiguous (or, interactive, ask which).
2. **Check out the local ref as-is** — never `origin`, never a reset:
   - Not checked out anywhere → `git worktree add "$WT_BASE/<slug>" <branch>`.
   - Occupied by the **main checkout** (it's the orchestrator's current branch) → free it by detaching the main `HEAD` (`git -C "$ROOT" switch --detach`) **when the main tree is clean**, then `git worktree add`; the starting branch recorded in Bootstrap is restored in Cleanup. If the main tree is *dirty*, skip-and-record (commit/stash or move the main checkout off it first).
   - Occupied by **another worktree** (a sibling entry, or the same branch listed twice) → skip-and-record; a branch can't live in two worktrees.
3. **Set the push target** so a later `--force-with-lease` is clean and accurate: `git -C "$WT_BASE/<slug>" branch --set-upstream-to=origin/<branch>` (origin's head ref for the paired PR, refreshed by Bootstrap's fetch). The push then rewrites the stale `origin/<branch>` to your local tip, and `--force-if-includes` still guards against clobbering a remote commit you never saw.

### PR-number entry — work the PR head

The canonical path. Resolve the PR, then prefer a same-named local branch if you have one (so we still never bypass your local copy), else check out `origin`'s head.

1. **Resolve and sanity-check:** `gh pr view N --json number,state,headRefName,headRepositoryOwner,baseRefName,url,title`. If `state` is not `OPEN`, skip-and-record. Note `headRefName` and whether `headRepositoryOwner` matches `origin`'s owner (same-repo) or differs (fork).
2. **Same-repo:**
   - Local `<headRefName>` exists and is free → `git worktree add "$WT_BASE/pr-<N>" <headRefName>` (use the local tip; **record any divergence from `origin/<headRefName>`** in the summary, since a force-push would rewrite the PR to your local state).
   - No local `<headRefName>` → `git worktree add --track -b <headRefName> "$WT_BASE/pr-<N>" origin/<headRefName>`.
   - Local `<headRefName>` is occupied → handle exactly as the Branch-entry case: detach the clean main `HEAD` to free it (and restore in Cleanup), or skip-and-record if it's held by another worktree or the main tree is dirty.
3. **Fork PR** — let `gh` wire up the fork remote and tracking inside a detached worktree:
   ```bash
   git worktree add --detach "$WT_BASE/pr-<N>"
   ( cd "$WT_BASE/pr-<N>" && gh pr checkout N )
   ```
   `gh pr checkout` also works for same-repo PRs, so it is a fine uniform fallback whenever the explicit `git worktree add` path is awkward.

The absolute worktree path, the checked-out branch name, the **paired PR number**, and (for branch entries) the note "this is your local ref" are what you hand that entry's subagent.

## Per-PR subagent

Spawn one `general-purpose` `Agent` per PR. Each runs the entire `address-review` skill against its PR. Fan them out **concurrently** (one tool block, throttled by the rules below), then wait for the batch to return.

The prompt contract for each subagent:

- **WORKTREE CONTRACT first:** "Your worktree is `<absolute path>`. Before anything else, `cd` into it and verify `git rev-parse --show-toplevel` prints exactly that path; if not, STOP and report. Do all work inside this worktree only — never `cd` to the repo root or touch sibling worktrees. Other agents are working in other worktrees concurrently; stay in yours."
- **The assignment:** "You are on branch `<branch>`, paired with PR #N. Confirm the branch with `git branch --show-current`. PR #N is the **authoritative pairing** — treat the supplied number as correct and do not re-derive it. This branch may be a local, possibly-rebased copy of the PR head, so its SHAs can differ from `origin`'s; that is expected, not a wrong-PR signal." (For a branch entry, add: "This is *your local ref*; work it exactly as it stands — do not reset or pull from `origin`.")
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
- **Restore the main checkout** if an entry's setup detached its `HEAD` to free a branch: after that branch's worktree is removed, `git -C "$ROOT" switch <starting-branch>` (recorded in Bootstrap) returns the main tree to where it began — now pointing at the addressed, possibly force-pushed tip. Note the restore in the summary so the user knows their branch advanced.
- Because `.git/worktrees` is tmpfs-shadowed, host hygiene needs no `git worktree prune`; prune only to clear a stale registration within the live session.

## After the batch

The PR branches are now independently fixed and almost certainly form a **leafy stack** (diverged tips, possibly shared ancestors).
This skill intentionally stops here.
If the user wants them integrated into a linear, mergeable order, point them at **`rebase-stack`** (explicit-chain form for independent branches) or a manual rebase — that is the deliberate, separate follow-up step, not something to fold into this parallel run.

## Final summary

Aggregate the per-PR `address-review` reports into one batch summary:

- **Per entry:** its PR URL, the branch, **which ref was worked** (your local ref — and how far it diverged from `origin` — vs. the `origin` head), whether it was pushed and/or pinged, and a one-line outcome (`fixed & pushed`, `fixed, not pushed`, `skipped — <reason>`, `blocked — <reason>`). Call out divergence explicitly: it tells the user a push rewrote `origin` to their local state.
- **Hands-off blockers, surfaced prominently** — every item any subagent skipped for lack of an authoritative decision, gathered across all PRs so the user can act on them in one place. This is the main value of an unattended batch: nothing silently dropped.
- **Push-backs** made across the batch, with their rationale.
- **No-push runs:** include each PR's per-thread disposition map (from its `address-review` report) so a later "push now" pass can replay replies/resolves precisely.
- **Throttling:** note whenever you ran narrower than the batch size, and why (storage-bound, rate-limited, resource-serialized).
- **A leafy-stack note** pointing at `rebase-stack` if the user will want to integrate the branches.

## Checklist

- [ ] Session Bootstrap ran: worktree roots verified container-local, this container's orphans pruned, push auth confirmed, `git fetch origin` done.
- [ ] Batch parsed into entries (each classified PR-number vs branch-name); pass-through flag set (`push`/`ping-*`) captured; `hands-off` force-injected into every subagent.
- [ ] Each entry resolved to a `(branch, PR#)` pair and checked out on the right ref — **branch entries use the local ref, never `origin`**; PR-number entries prefer a same-named local branch, else `origin` head; worktrees under `.worktrees/$CONTAINER_NAME/`; un-setup-able / PR-less entries skipped-and-recorded.
- [ ] One subagent per entry, each running `/address-review #N hands-off …` with the PR# as the authoritative pairing; fanned out concurrently but throttled (in-flight count conservative due to nested fixer/reviewer agents).
- [ ] No new branches created, no `gh pr create`, no restack performed.
- [ ] Worktrees removed after each subagent returns; **no PR branch deleted**; main checkout restored to its starting branch if its `HEAD` was detached to free an entry.
- [ ] Batch summary aggregates outcomes, hands-off blockers (prominently), push-backs, no-push disposition maps, throttling notes, and the `rebase-stack` follow-up pointer.
