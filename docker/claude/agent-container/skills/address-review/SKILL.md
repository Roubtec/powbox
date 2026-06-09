---
name: address-review
description: Address the maintainer-vetted review feedback on one pull request — optionally rebase the branch onto a target first, fix or push back on each unresolved review thread, verify the fixes with a fresh-eyes reviewer subagent, then (when asked) force-push with lease, reply/resolve the threads, post a "Summary of Review Fixes" comment, and request fresh bot reviews. Trigger when the user asks to address review comments, action a reviewed PR, work through review feedback, or run address-review. Do not trigger for planning, for implementing new task files (use address-tasks), or for rebasing a whole stacked chain (use rebase-stack).
---

Address the review feedback on a single pull request, end to end.

**Arguments:** `[PR#] [rebase on top of <branch>] [push] [hands-off] [ping-codex] [ping-claude]`

A maintainer triggers this skill once a PR has been reviewed (by bots like `@codex`/`@claude` and/or humans) and they have decided the outstanding feedback is ready to be acted upon.
Your job is to work through every **unresolved** review thread — fix what is right, push back on what is wrong, confirm what is already handled — keep the thread state tidy, and optionally publish the result and summon a fresh review round.

The maintainer signals intent through GitHub's own resolved/unresolved state, not a custom marker.
They resolve threads they want dropped (or reply with their own push-back) **before** triggering you, so the rule is simply: **unresolved = actionable, resolved = leave alone.**
Because you resolve the threads you address (on push runs), running this skill repeatedly is self-cleaning — each run only re-examines what truly remains open.

## Arguments

All arguments are optional and parsing is **lenient** — accept commas, `&`, and free word order, mirroring the example prompts. Trust yourself to extract intent, then sanity-check against the PR.

| Argument | Meaning |
|---|---|
| `PR#` (e.g. `#38`) | The PR to address. Takes precedence over auto-detection — useful when the current branch is a local off-shoot of a merge-pending branch or otherwise disjoint from the PR head. Always sanity-check that it really relates to this branch. |
| `rebase on top of <branch>` | Rebase the **current branch** onto `<branch>` before doing anything else (Procedure step 2). Single-branch rebase only. |
| `push` | When done, push the branch to origin and perform all PR-side communication (replies, resolves, summary comment). Force-pushes are expected and frequent (especially after a rebase) — always `--force-with-lease`. |
| `hands-off` | Run with no user interaction — best-effort to completion, documenting every skipped/blocked item in the final report. See "Hands-off mode". Typically how a parallel review orchestrator invokes this skill in a subagent. |
| `ping-codex` | After pushing, post a dedicated top-level `@codex review` comment to summon a fresh review round. **Implies `push`** (nothing to re-review unpushed). |
| `ping-claude` | After pushing, post a dedicated top-level `@claude review` comment. **Implies `push`.** |

### Flag interactions

- **`ping-*` implies `push`.** If `ping-codex` or `ping-claude` is present without `push`, push anyway — a re-review of unpushed work is meaningless. `push + ping-claude` is technically redundant; resolve it gracefully as "push, then ask Claude for a fresh review."
- **Both pings present** → two separate comments, one per bot (never a single comment mentioning both). They are also separate from the Summary comment.
- **`hands-off` + `rebase`** is uncommon and the riskiest combination: a non-trivial rebase conflict has no one to consult, so you abort cleanly and stop rather than guess (see "Hands-off mode" and step 2).
- **No `push` and no `ping`** → a local-only run. Make commits, but **do not mutate the PR at all** (no replies, no resolves, no summary comment). The final report captures every disposition so a later "push now" turn can replay it.

## Architecture

You address the feedback **inline** in your own context for ordinary comments, and **delegate to a subagent only for large or independent rework**.
Then you always hand verification to a **fresh, independent reviewer subagent**.
This skill is frequently invoked *as* a subagent by a parallel review orchestrator, so keep nesting shallow — do not stand up a full orchestrator/implementer/reviewer tree like `address-tasks`; spawn helpers only when the work genuinely warrants it.

Two subagent roles, both spawned via the `Agent` tool with `subagent_type: "general-purpose"`:

- **Fixer** (optional) — handles a large, multi-file, or exploratory fix for one or more related comments. Skip it for small surgical fixes you can do directly.
- **Reviewer** (default before any push) — a fresh-eyes agent that receives the **review comments verbatim** (the "what must change") but **not** your implementation reasoning, and confirms each is genuinely resolved in the committed code, plus a quality pass on the changed files. This is the `address-tasks` reviewer pattern.

> **Critical — one checkout-dependent agent at a time; subagents share your working tree.**
> Every subagent operates on your single checked-out branch — they are not isolated copies. Never spawn two checkout-dependent agents in the same turn or parallel tool block, and never spawn the reviewer until the fixer's commits have landed on disk. A reviewer racing an unfinished fixer scopes its diff against a half-written branch, sees nothing, and falsely reports "no changes" — shipping the work unverified. Spawn one, await its result, then the next. This overrides the harness's general "batch independent calls" guidance: these calls are not independent.

> **Fix-ups and re-reviews always use a fresh `Agent` spawn**, never a "continued" prior agent. If an `Agent` result prints a `SendMessage`/continuation footer, ignore it — this harness does not expose that tool. A fresh reviewer with no attachment to the fix is the whole point.

**Trivial escape hatch:** for a single obvious comment with an unambiguous fix, you may fix it directly and skip the reviewer subagent — but if you are about to `push`/`ping` (i.e. summon fresh bot reviews), prefer to run the reviewer anyway. You do not want to invite a new review round on top of a fix that does not hold.

## Procedure

### Step 0 — Preflight

1. **Working tree must be clean** (`git status --porcelain`). If anything is staged/modified/untracked-and-conflicting, stop and ask the user to commit/stash/clean (hands-off: document and stop). Do not auto-stash.
2. **No rebase already in progress** — check `git rev-parse --git-path rebase-merge` and `--git-path rebase-apply`. If either exists, stop and ask the user to finish or abort it first.
3. **Confirm `gh` is authenticated** (`gh auth status`). Without it you cannot read threads, reply, resolve, or comment.
4. **Record the starting branch and tip SHA** so you can describe exactly what changed in the final report and recover if needed.

### Step 1 — Resolve and verify the PR

Precedence for identifying the PR:

1. **Explicit `PR#`** — use it, but **sanity-check the relationship to the current branch**. Compare the PR's `headRefName` and head SHA against the current branch: do they share recent history? Is the branch an ahead/behind copy of the PR head? If they look genuinely unrelated (no shared commits), surface it — *"the supplied PR #N targets branch `x`, which shares no history with the current branch `y`; proceed anyway?"* — and ask before operating (hands-off: stop and document, since acting on the wrong PR is high-stakes).
2. **Auto-detect** — `gh pr view --json number,headRefName,baseRefName,url,title,state` resolves the PR for the current branch; `gh pr list --head <branch>` is the fallback.
3. **Ambiguous or none found** — ask the user which PR (hands-off: stop and document the blocker; do not guess).

Record `owner`, `repo`, PR `number`, `baseRefName`, and `headRefName` for the API calls below.

### Step 2 — Rebase first (only if `rebase on top of <branch>` was given)

Rule 0: rebasing brings the branch close to its final merged state, so you address the feedback against the geometry the work will actually land in (essential when several stacked PRs are being fixed at once).
This is a **single-branch** rebase. To restack a whole chain of dependent branches, that is the separate `rebase-stack` skill — mention it if the user seems to want chain-wide restacking.

1. Verify the target branch ref exists locally.
2. Save a recovery ref: `git update-ref refs/pre-rebase/<branch>/<YYYYMMDD-HHMMSS> <branch>`.
3. `git rebase <target>`. Git's patch-id detection drops commits already present on the target.
4. **Conflicts:**
   - **Trivial** (import/whitespace/formatting collisions, pure additions, or a patch already represented on the new base) → resolve in-file and `git add` + `git rebase --continue`, or `git rebase --skip` for an already-represented commit. Narrate one line each; don't pause.
   - **Non-trivial** (a genuine semantic dilemma) → **interactive:** present the conflict, your proposed resolution and reasoning, and confirm before applying — loop the user in as many times as needed rather than guessing. **Hands-off:** `git rebase --abort`, `git clean -fd`, confirm `git status --porcelain` is empty, and **stop the whole run** — addressing review on a wrong/stale base then force-pushing is worse than not running. Document the conflict (files, offending commit, why) as the blocker.
5. After a conflicted rebase, run the project's build/lint (discover via `AGENTS.md`/`CLAUDE.md`, then `package.json` scripts, then ecosystem signals) to confirm the resolution is sound before proceeding. A clean rebase needs no validation.

If the rebase changed the branch tip, expect the eventual push to be a force-push (`--force-with-lease`).

### Step 3 — Gather the review feedback

Fetch the **unresolved** review threads and enough context to judge them (see "GitHub API recipes"):

- **Review threads** (inline comments) via GraphQL `reviewThreads` — keep only `isResolved == false`. For each, capture the thread `id`, `path`, `line`, `isOutdated`, and every comment's `databaseId`, `author.login`, `body`, and `diffHunk`.
- **Top-level review summaries** (`gh pr view --json reviews`) and **issue comments** (`gh api repos/{owner}/{repo}/issues/{number}/comments`) — read for context, especially **maintainer replies/push-backs** that override or qualify a bot's original comment.

A maintainer reply on an unresolved thread is **authoritative**: if they said "skip this" or "do X instead," follow the maintainer over the original reviewer.

### Step 4 — Triage every unresolved thread

Classify each into one of:

- **Actionable** — a real issue; implement the fix.
- **Already addressed** — the current code (possibly thanks to the rebase or an earlier commit) already satisfies it. Note where.
- **Push-back** (rule 2 — should be **rare**) — the comment is wrong, misunderstands context, or points in the wrong direction. Do **not** implement it; draft a respectful, specific rationale instead. Lean on judgment; never implement a fix you believe is wrong just to clear a comment.
- **Ambiguous** — the right fix needs an authoritative decision you cannot make from the code/history. **Interactive:** ask the user. **Hands-off:** make a best-effort call only when stakes are low; otherwise skip and document it (rule 3) — do not guess where an authoritative determination is required.

### Step 5 — Fix

For the actionable items:

- **Small/surgical** → fix directly in your own context, committing at logical milestones.
- **Large/multi-file/exploratory** → spawn a **Fixer** subagent (see Architecture and the prompt sketch below). One at a time; await its commits before moving on.
- **Preclude repeat comments (rule 4):** for each pattern you fix, grep the PR's changed files and closely related code for the **same offending pattern** and fix those too, so the next review round doesn't re-raise it. Mention these proactive fixes in the summary.
- Keep commits buildable where practical; run the build/lint before declaring done.

Fixer subagent prompt should include: the relevant review comment(s) **verbatim**, the file/line locations, the branch name (and "verify you are on it"), an instruction to read `AGENTS.md` first, the rule-4 sweep instruction, commit/validation instructions, an instruction **not** to use the `TaskCreate`/`TaskUpdate`/`TaskList` tools (their entries leak into your task view), and a request to report what it changed, any tradeoffs, and anything uncertain. Do **not** give it unrelated context.

### Step 6 — Verify with a fresh reviewer

Once fixes are committed, spawn **one fresh Reviewer subagent** (never concurrently with a fixer; only after commits land):

Give it: the actionable review comments **verbatim**, the PR base branch (`baseRefName`) for scoping, and the current branch. Do **not** give it your implementation reasoning or the fixer's report. Tell it to:

- Verify each comment is genuinely resolved in the committed code (read the actual files; if `git diff --name-only <base>...HEAD` looks empty, say so as a likely race/wrong-branch flag rather than reviewing nothing).
- Run the build/typecheck; a failure is an automatic blocker.
- Do a quality pass on the changed files (logic correctness, error handling, edge cases, dead code, consistency, duplication, type safety) and check the rule-4 sweep didn't miss a sibling occurrence.
- Report **Pass** or a numbered, actionable **Issues** list. Edit nothing; touch no task-tracker tools.

If the reviewer finds material gaps, loop: a fresh **Fixer** spawn with the verbatim findings, then a fresh Reviewer, **cap at 3 iterations**. If issues persist past the cap, stop iterating, do **not** push, and surface the outstanding findings in the final report (and to the user if interactive).

### Step 7 — Publish (only on `push` / `ping-*` runs)

If neither `push` nor a `ping` is set, **skip this entire step** — do not touch the PR. Go to step 8.

Otherwise:

1. **Push:** `git push --force-with-lease --force-if-includes`. If the lease is rejected, the remote moved under you — **do not** escalate to a bare `--force`; stop and report (hands-off: document the blocker), because someone/some bot pushed a commit you'd clobber.
2. **Per-thread hygiene** — for each thread (recipes below):
   - *Actionable-fixed* → reply (`Fixed in <sha>: <one line>`) **and resolve**.
   - *Already-addressed* → reply pointing to where it's handled **and resolve**.
   - *Push-back* → reply with the rationale **and resolve**, and flag it prominently in the summary (see below). Resolving keeps the unresolved set clean; the maintainer re-opens if they disagree.
   - *Ambiguous/skipped* → **leave open**, list it in the summary as needing a decision.
3. **Summary comment** — post a top-level **"Summary of Review Fixes"** (`gh pr comment`). Structure: what was fixed (with the proactive rule-4 sweeps called out), a **prominent "Pushed back — please re-examine" section** for every push-back with its rationale, any ambiguous/skipped items still needing a decision, and (in hands-off runs) every automatic low-stakes decision and every item skipped for lack of feedback. In this comment, avoid bare `@codex`/`@claude` mentions (write "codex"/"claude" plain) so only the dedicated ping comments below trigger a review.
4. **Pings** — `ping-codex` → a dedicated comment whose body is `@codex review`; `ping-claude` → a dedicated comment whose body is `@claude review`. If both, post two separate comments.

### Step 8 — Final report

Always produce a report (this is the only output of a no-push run, and it doubles as the body of the Summary comment on push runs):

- The PR, the branch, before/after tip SHAs, and whether a rebase happened (and how conflicts went).
- Each addressed comment with a **stable reference** — file:line, comment author, the thread's GraphQL node id, and the comment permalink — and its disposition (fixed / already-addressed / pushed-back / skipped). On a **no-push** run this mapping is essential: a later "push now" turn uses it to replay the exact replies/resolves without re-deriving everything.
- Push-backs, prominently, with rationale.
- Proactive rule-4 fixes made beyond the literal comments.
- Reviewer outcome and how many iterations it took (and whether it hit the cap).
- Anything blocked or skipped for lack of an authoritative decision, with what's needed to unblock.

## Hands-off mode

Purpose: run inside a parallelized agent that has no direct line to the user (e.g. a review orchestrator's subagent). Reach the orchestrator if you can, but otherwise drive to a best-effort completion and **document, never guess on high-stakes choices.**

- Low-stakes ambiguity → make a sensible best-effort call and record it.
- High-stakes/authoritative ambiguity → skip, do not guess, document precisely what's needed.
- Non-trivial rebase conflict → abort cleanly and stop the run (step 2).
- Lease-rejected push, unidentifiable/unrelated PR, or reviewer cap hit → stop and document; do not force or guess your way past it.
- Subagents (fixer, reviewer) are still fine — they need no user. Every skipped/blocked item must appear in the final report (and the Summary comment if pushing) so the user learns of it and can act later.

## GitHub API recipes

`gh api` expands `{owner}`/`{repo}` to the current repo. For GraphQL, pass real values (`gh repo view --json owner,name`).

**List unresolved review threads** (id for resolve, comment `databaseId` for replies):

```sh
gh api graphql -f query='
query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){
      reviewThreads(first:100){ nodes{
        id isResolved isOutdated path line
        comments(first:50){ nodes{ databaseId author{login} body diffHunk url } }
      }}
    }
  }
}' -F owner=OWNER -F repo=REPO -F pr=NUMBER
```

**Reply to a review comment** (REST, threads the reply under the original):

```sh
gh api --method POST repos/{owner}/{repo}/pulls/NUMBER/comments/COMMENT_DATABASE_ID/replies -f body='Fixed in <sha>: ...'
```

**Resolve a thread** (GraphQL, using the thread `id` from the query above):

```sh
gh api graphql -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' -F id=THREAD_NODE_ID
```

**Top-level comments** (summary and pings):

```sh
gh pr comment NUMBER --body '...'        # Summary of Review Fixes
gh pr comment NUMBER --body '@codex review'
gh pr comment NUMBER --body '@claude review'
```

**Read context:** `gh pr view NUMBER --json reviews,comments,headRefName,baseRefName,url,state` and `gh api repos/{owner}/{repo}/issues/NUMBER/comments`.

## Checklist

- [ ] Working tree clean; no rebase in progress; `gh` authenticated.
- [ ] PR resolved (explicit `PR#` precedence) and sanity-checked against the current branch.
- [ ] If requested, single-branch rebase done first; non-trivial conflict handled (interactive loop-in / hands-off abort+stop); validated when conflicted.
- [ ] All **unresolved** threads gathered; resolved ones ignored; maintainer replies treated as authoritative.
- [ ] Each thread triaged: actionable / already-addressed / push-back / ambiguous.
- [ ] Fixes done inline or via a fixer subagent (one checkout-dependent agent at a time); rule-4 sweep for the same pattern in changed/related code.
- [ ] Fresh independent reviewer ran after commits landed; feedback loop capped at 3.
- [ ] Push run: `--force-with-lease` (never bare `--force`); replies + resolves applied; push-backs resolved and flagged; ambiguous items left open; Summary comment posted without stray `@` mentions; pings as separate dedicated comments.
- [ ] No-push run: zero PR mutations; final report maps every thread to its disposition for a later push turn.
- [ ] Final report covers rebase outcome, dispositions with stable refs, push-backs, proactive fixes, reviewer result, and blocked/skipped items.
