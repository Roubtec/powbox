---
name: address-review
description: Address the maintainer-vetted review feedback on one pull request — optionally rebase the branch onto a target first, fix, push back on, or defer each unresolved review thread to a committed follow-up task file, verify every disposition with a fresh-eyes reviewer, then (when asked) push with exact lease protection, reply/resolve the threads, post a "Summary of Review Fixes" comment, and request fresh bot reviews. Trigger when the user asks to address review comments, action a reviewed PR, work through review feedback, or run address-review. Do not trigger for planning, for implementing new task files (use address-tasks), or for rebasing a whole stacked chain (use rebase-stack).
---

Address the review feedback on a single pull request, end to end.

**Arguments:** `[PR#] [rebase on top of <branch>] [push] [hands-off] [ping-codex] [ping-claude]`

Explicit Codex invocation uses `$address-review`; natural-language equivalents are fine.

A maintainer triggers this skill once a PR has been reviewed (by bots like `@codex`/`@claude` and/or humans) and they have decided the outstanding feedback is ready to be acted upon.
Your job is to work through every **unresolved** review thread — fix what is right, push back on what is wrong, confirm what is already handled, defer what is real but out of scope into a committed follow-up task — keep the thread state tidy, and optionally publish the result and summon a fresh review round.

The maintainer signals intent through GitHub's own resolved/unresolved state, not a custom marker.
They resolve threads they want dropped (or reply with their own push-back) **before** triggering you, so the rule is simply: **unresolved = actionable, resolved = leave alone.**
Because you resolve the threads you address (on push runs), running this skill repeatedly is self-cleaning — each run only re-examines what truly remains open.

## Arguments

All arguments are optional and parsing is **lenient** — accept commas, `&`, and free word order, mirroring the example prompts. Trust yourself to extract intent, then sanity-check against the PR.

| Argument | Meaning |
|---|---|
| `PR#` (e.g. `#38`) | The PR to address. Takes precedence over auto-detection — useful when the current branch is a local off-shoot of a merge-pending branch or otherwise disjoint from the PR head. Always sanity-check that it really relates to this branch. |
| `rebase on top of <branch>` | Rebase the **current branch** onto `<branch>` before gathering or fixing review feedback (Procedure step 2). Single-branch rebase only. |
| `push` | When done, push the branch to the PR's actual head repository/ref and perform all PR-side communication (replies, resolves, summary comment). Use a normal push for a fast-forward; use an explicit `--force-with-lease=<ref>:<expected-oid>` only when history was rewritten. |
| `hands-off` | Run with no user interaction — best-effort to completion, documenting every skipped/blocked item in the final report. See "Hands-off mode". Typically how a parallel review orchestrator invokes this skill in a subagent. |
| `ping-codex` | After a push that advances the PR branch (new commits or rewritten history), post a dedicated top-level `@codex review` comment to summon a fresh review round. **Implies `push`**, but skip the ping on an "Everything up-to-date" no-op push. |
| `ping-claude` | After a push that advances the PR branch, post a dedicated top-level `@claude review` comment. **Implies `push`**, but skip the ping on an "Everything up-to-date" no-op push. |

### Flag interactions

- **`ping-*` implies `push`.** If `ping-codex` or `ping-claude` is present without `push`, push anyway — a re-review of unpushed work is meaningless.
- **A ping fires only when the push actually advanced the branch.** A `ping-*` summons a *fresh* review, which is only meaningful if new commits (or a rewritten history) were just pushed. If this run produces nothing new to push — every disposition was already-addressed or push-back, or the branch was already up to date — **skip the pings even though `ping-*` was supplied.** Re-requesting a review with nothing new to look at would spin the review → address → review cycle forever; the resolved threads and Summary comment already record the outcome.
- **Both pings present** → two separate comments, one per bot (never a single comment mentioning both). They are also separate from the Summary comment.
- **`hands-off` + `rebase`** is uncommon and the riskiest combination: a non-trivial rebase conflict has no one to consult, so you abort cleanly and stop rather than guess (see "Hands-off mode" and step 2).
- **No `push` and no `ping`** → a local-only run. Make commits, but **do not mutate the PR at all** (no replies, no resolves, no summary comment). The final report captures every disposition so a later "push now" turn can replay it.

## Architecture

At top level, address ordinary feedback **inline** and delegate only large or independent rework.
Then hand verification to a **fresh, independent reviewer subagent**.

Two top-level subagent roles:

- **Fixer** (optional) — a fresh `worker` subagent that handles a large, multi-file, or exploratory fix for one or more related comments. Skip it for small surgical fixes you can do directly.
- **Reviewer** (default before any push) — a fresh `explorer` subagent that receives every unresolved thread and explicitly included standalone item verbatim, plus the proposed disposition labels, but **not** your implementation reasoning; it independently confirms that each disposition is sound in the committed code and performs a quality pass on the changed files. This is the `address-tasks` reviewer pattern.

> **Critical — one checkout-dependent agent at a time; Codex subagents share your working tree.**
> Unless explicitly assigned distinct git worktrees, subagents operate on the same checked-out branch as the orchestrator. Never spawn two checkout-dependent subagents in the same natural-language turn or tool-call batch, and never spawn the reviewer until the fixer's commits have landed. Spawn one, wait for it, close it, then spawn the next. A reviewer racing unfinished work can inspect an empty or partial branch and falsely pass it.

> **Fix-ups and re-reviews always use a fresh subagent spawn**, never `send_input` to continue a prior worker or reviewer. Fresh context with no attachment to the earlier fix is intentional.

### Codex subagent execution

Use the subagent interface exposed in the current session.
In tool-enabled sessions this is typically available through tools such as `multi_agent_v1.spawn_agent`, `multi_agent_v1.wait_agent`, and `multi_agent_v1.close_agent`; use those names only when present in the current tool listing.
Spawn fixers as `worker` agents and reviewers as `explorer` agents.
Pass self-contained prompts; do not fork the orchestrator's context, and omit model overrides unless the user asks for one.
Wait for each subagent and close its thread when no longer needed.
No custom agent personas (`~/.codex/agents/*.toml`) are required.

If the session exposes no subagent capability, do not publish unreviewed changes.
Only use the trivial local-only escape hatch below; otherwise tell the user the workflow requires Codex multi-agent support.

**Trivial escape hatch:** only on a local, no-push run with one obvious actionable comment may you skip the reviewer. Never skip review before publishing, and never skip it for a push-back disposition.

### Delegated modes for the worktree orchestrator

Codex subagents must not be assumed to spawn nested subagents.
`address-reviews-worktrees` therefore uses this skill in two internal modes; these are orchestrator controls, not normal user flags:

- **`delegated-fix`** — run steps 0–5 directly in the assigned worktree, without spawning helpers, then stop before review/publication and return a complete review packet: PR/head metadata, starting/final SHAs, every item verbatim with stable refs and proposed disposition, validation run, and any blocker.
- **`publish-reviewed`** — receive that packet plus a fresh external reviewer's Pass verdict, verify the packet still matches the clean committed `HEAD`, then run only step 7 and return step 8's report. Refuse to edit code, re-triage, or publish without the packet and Pass verdict.

The worktree orchestrator owns the fresh reviewer and any fix-up rounds between these modes.

## Procedure

### Step 0 — Preflight

1. **Working tree must be completely clean** (`git status --porcelain`). If it prints anything (staged, modified, or untracked), stop and ask the user to commit/stash/clean it (hands-off: document and stop). Do not auto-stash or discard files.
2. **No rebase already in progress** — check `git rev-parse --git-path rebase-merge` and `--git-path rebase-apply`. If either exists, stop and ask the user to finish or abort it first.
3. **Confirm `gh` is authenticated** (`gh auth status`). Without it you cannot read threads, reply, resolve, or comment.
4. **Record the starting branch and tip SHA** so you can describe exactly what changed in the final report and recover if needed.

### Step 1 — Resolve and verify the PR

Precedence for identifying the PR:

1. **Explicit `PR#`** — use it, but **sanity-check the relationship to the current branch**. Compare the PR's `headRefName` and head SHA against the current branch: do they share recent history? Is the branch an ahead/behind copy of the PR head? If they look genuinely unrelated (no shared commits), surface it — *"the supplied PR #N targets branch `x`, which shares no history with the current branch `y`; proceed anyway?"* — and ask before operating (hands-off: stop and document, since acting on the wrong PR is high-stakes).
2. **Auto-detect** — `gh pr view --json number,headRefName,baseRefName,url,title,state` resolves the PR for the current branch; `gh pr list --head <branch>` is the fallback.
3. **Ambiguous or none found** — ask the user which PR (hands-off: stop and document the blocker; do not guess).

Record `owner`, `repo`, PR `number`, `baseRefName`, `headRefName`, `headRefOid`, and the head repository owner/name for the API calls and publication guard below.

### Step 2 — Rebase first (only if `rebase on top of <branch>` was given)

Rebasing brings the branch close to its final merged state, so address the feedback against the geometry the work will actually land in (essential when several stacked PRs are being fixed at once).
This is a **single-branch** rebase. To restack a whole chain of dependent branches, that is the separate `rebase-stack` skill — mention it if the user seems to want chain-wide restacking.

1. Verify the target branch ref exists locally.
2. Save the branch being rewritten, not the target: `current_branch="$(git branch --show-current)"`, require it to be non-empty, set `ts="$(date -u +%Y%m%d-%H%M%S)"`, then `git update-ref "refs/pre-rebase/$current_branch/$ts" HEAD`.
3. `git rebase <target>`. Git's patch-id detection drops commits already present on the target.
4. **Conflicts:**
   - **Trivial** (import/whitespace/formatting collisions, pure additions, or a patch already represented on the new base) → resolve in-file and `git add` + `git rebase --continue`, or `git rebase --skip` for an already-represented commit. Narrate one line each; don't pause.
   - **Non-trivial** (a genuine semantic dilemma) → **interactive:** present the conflict, your proposed resolution and reasoning, and confirm before applying — loop the user in as many times as needed rather than guessing. **Hands-off:** `git rebase --abort`, confirm `git status --porcelain` is empty, and **stop the whole run** — addressing review on a wrong/stale base then force-pushing is worse than not running. If abort leaves unexpected files, preserve and report them rather than deleting blindly. Document the conflict (files, offending commit, why) as the blocker.
5. After a conflicted rebase, run the project's build/lint (discover via `AGENTS.md`/`CLAUDE.md`, then `package.json` scripts, then ecosystem signals) to confirm the resolution is sound before proceeding. A clean rebase needs no validation.

If the rebase changed the branch tip, expect the eventual push to be a force-push (`--force-with-lease`).

### Step 3 — Gather the review feedback

Fetch the **unresolved** review threads and enough context to judge them (see "GitHub API recipes"):

- **Review threads** (inline comments) via GraphQL `reviewThreads` — paginate past 100 threads, keep only `isResolved == false`, and detect unexpectedly truncated comment lists. For each, capture the thread `id`, `path`, `line`, `isOutdated`, and every comment's `databaseId`, author login/type, `body`, `diffHunk`, and `url`.
- **Top-level review summaries** (`gh pr view --json reviews`) and **issue comments** (`gh api --paginate repos/{owner}/{repo}/issues/{number}/comments`) — read for context, especially **maintainer replies/push-backs** that override or qualify a bot's original comment. They are not automatically actionable because they have no resolved/unresolved state; include a standalone item only when the maintainer explicitly identifies it as outstanding in the request or discussion.

A maintainer reply on an unresolved thread is **authoritative**: if they said "skip this" or "do X instead," follow the maintainer over the original reviewer.
The same authority extends to a **top-level decision comment** — a maintainer comment that walks the open feedback and records a verdict per item (often titled "Maintainer Decisions" or similar). Treat each recorded decision as the binding disposition for the thread(s) it covers — including "defer to a follow-up task" and "keep as-is" — rather than re-triaging those threads from scratch.
Treat `isOutdated` as context, not a disposition: inspect the current code and re-locate the concern rather than auto-dismissing an outdated thread.
If there are no unresolved threads and no explicitly included standalone items, stop as a successful no-op: make no commits, do not push or ping, do not post a summary comment, and report that nothing actionable remains.

### Step 4 — Triage every review item

Classify each into one of:

- **Actionable** — a real issue; implement the fix.
- **Already addressed** — the current code (possibly thanks to the rebase or an earlier commit) already satisfies it. Note where.
- **Push-back** (should be **rare**) — the comment is wrong, misunderstands context, or points in the wrong direction. Do **not** implement it; draft a respectful, specific rationale instead. Lean on judgment; never implement a fix you believe is wrong just to clear a comment.
- **deferred-to-task** — the concern is real, but fixing it here would expand the PR's scope considerably while the branch is defendable as it stands (it builds and covers its main paths) — or the maintainer has already deferred it (reply or decision comment). Do **not** implement it; record it as a committed task file instead (step 5). Never use this to dodge a cheap fix.
- **Ambiguous** — the right fix needs an authoritative decision you cannot make from the code/history. **Interactive:** ask the user. **Hands-off:** make a best-effort call only when stakes are low; otherwise skip and document it — do not guess where an authoritative determination is required.

### Step 5 — Fix

For the actionable items:

- **Small/surgical** → fix directly in your own context, committing at logical milestones.
- **Large/multi-file/exploratory** → spawn a **Fixer** subagent (see Architecture and the prompt sketch below). One at a time; await its commits before moving on.
- **Preclude repeat comments:** for each pattern you fix, grep the PR's changed files and closely related code for the **same offending pattern** and fix those too, so the next review round doesn't re-raise it. Mention these proactive fixes in the summary.
- Keep commits buildable where practical; run the build/lint before declaring done.
- Before review, require `git status --porcelain` to be empty. Inspect and commit every intended change; if a fixer leaves partial or unexplained changes, resolve that state or stop rather than letting the reviewer inspect only the committed subset.

For the **deferred** items, write the follow-up task file(s) following the `write-tasks` skill conventions (invoke that skill where available):

- Place them in the repo's task folder (commonly `tasks/`; parked, not-yet-scheduled work goes in its deferred subfolder, e.g. `tasks/deferred/`) — follow whatever layout the repo already uses.
- Number each file to continue the folder's existing sequence, slotted by priority/intended order.
- Each task must stand alone: restate the concern with file/line references and link the PR thread; an implementer should not need to re-read the review.
- **Commit task files on the current branch, separately from code-fix commits** (when practical). The task ships with the branch that prompted it — merging the PR then also lands the record of its loose ends, which is what makes deferral a legitimate way to close a thread.

Fixer subagent prompt should include: the relevant review comment(s) **verbatim**, the file/line locations, the branch name (and "verify you are on it"), an instruction to read `AGENTS.md` first, the same-pattern sweep instruction, commit/validation instructions, an instruction not to write to any shared task/plan tracker, and a request to report what it changed, any tradeoffs, and anything uncertain. Do **not** give it unrelated context.

In `delegated-fix` mode, do not spawn a Fixer or Reviewer.
Perform the fixes directly, leave the worktree clean with all intended changes committed, return the review packet defined above, and stop here.

### Step 6 — Verify with a fresh reviewer

Once fixes are committed and the worktree is clean, spawn **one fresh `explorer` Reviewer subagent** (never concurrently with a fixer; only after commits land), wait for it, and close it after recording the result:

Give it: every unresolved thread and explicitly included standalone item verbatim, each proposed disposition label (actionable-fixed / already-addressed / push-back / deferred-to-task / ambiguous), the effective review base, and the current branch. The effective review base is the requested rebase target when step 2 ran; otherwise it is `baseRefName`. Do **not** give it your implementation reasoning, drafted rationale, or the fixer's report. Tell it to:

- Independently verify every disposition: fixes and already-addressed claims must hold in the committed code; push-backs must be technically justified rather than convenient dismissals; deferred-to-task items must point at a committed task file that genuinely covers the concern, with the deferral itself justified (maintainer-directed, or genuinely scope-expanding while the branch builds and covers its main paths — not an evasion of a cheap fix); ambiguous items must genuinely require an authoritative decision. It may reclassify any item.
- Read the actual files; if `git diff --name-only <base>...HEAD` looks empty despite claimed fixes, report a likely race/wrong-branch flag rather than reviewing nothing.
- Run the build/typecheck; a failure is an automatic blocker.
- Do a quality pass on the changed files (logic correctness, error handling, edge cases, dead code, consistency, duplication, type safety) and check the same-pattern sweep did not miss a sibling occurrence.
- Report **Pass** or a numbered, actionable **Issues** list. Edit nothing; write to no shared task/plan tracker.

If the reviewer finds material gaps, re-triage the affected comments, then loop: a fresh `worker` Fixer with the verbatim findings when code must change, followed by a fresh `explorer` Reviewer. Wait for and close each before spawning the next. Allow at most **3 reviewer rounds total**, including the initial review. If issues persist after round 3, stop iterating, do **not** push, and surface the outstanding findings in the final report (and to the user if interactive).

### Step 7 — Publish (only on `push` / `ping-*` runs)

If neither `push` nor a `ping` is set, **skip this entire step** — do not touch the PR. Go to step 8.

Otherwise:

In `publish-reviewed` mode, first require the supplied review packet, a fresh external reviewer Pass, and a clean committed `HEAD` equal to the packet's final SHA. If any differ, stop; do not re-triage or publish stale work.

1. **Re-check before publication:** require a clean worktree and no rebase in progress; re-fetch the PR and confirm it is still open, still points to the recorded head repository/ref, and its current `headRefOid` is the expected remote tip you are prepared to replace. Resolve the current branch's exact push remote/ref, verify they match that PR head, and fetch that exact head ref without moving the local branch so the expected commit object is available for the ancestry test — never assume `origin`, especially for fork PRs. If the PR head moved, the push target cannot be matched, or the branch has no usable push permission, stop and report instead of guessing.
2. **Push:** if the expected remote tip is an ancestor of `HEAD`, use a normal explicit push (`git push <remote> HEAD:refs/heads/<headRefName>`). If history was rewritten, use an exact lease (`git push <remote> --force-with-lease=refs/heads/<headRefName>:<expected-head-oid> HEAD:refs/heads/<headRefName>`). If the lease is rejected, **never** escalate to bare `--force`; stop and report because the remote moved under you.
3. **Re-read unresolved threads after the push.** This catches comments resolved or added while fixes were in progress. Do not mutate newly-added feedback that was not triaged and reviewed in this run; leave it open and call it out for the next pass.
4. **Per-thread hygiene** — for each triaged thread still unresolved (recipes below):
   - *Actionable-fixed* → reply (`Fixed in <sha>: <one line>`) **and resolve**.
   - *Already-addressed* → reply pointing to where it's handled **and resolve**.
   - *Deferred-to-task* → reply citing the committed task file (`Deferred to tasks/0NN-…: <one line>`) **and resolve** when the deferral was maintainer-directed or the thread is bot-authored; leave a human-authored thread unresolved unless the maintainer authorized closing it. Never re-implement a deferred thread.
   - *Push-back* → reply with the rationale and flag it prominently in the summary. Resolve a bot-authored thread after independent review validates the push-back. Leave a human-authored thread unresolved unless the maintainer explicitly authorized resolving it, so unattended runs do not silently close a person's objection.
   - *Ambiguous/skipped* → **leave open**, list it in the summary as needing a decision.
   Before replying, inspect the thread for an equivalent prior reply from the authenticated user (for example, a previous run replied but failed to resolve) and avoid posting duplicates. Resolve only after the reply succeeds; record any communication failure and leave that thread open.
5. **Summary comment** — post a top-level **"Summary of Review Fixes"** (`gh pr comment`). Structure: what was fixed (with proactive same-pattern fixes called out), a **prominent "Pushed back — please re-examine" section** for every push-back with its rationale, a **"Deferred to follow-up tasks" section** listing each deferral with its committed task file (agent-proposed deferrals flagged for confirmation), any ambiguous/skipped or newly-arrived items still needing a decision, and (in hands-off runs) every automatic low-stakes decision and every item skipped for lack of feedback. In this comment, avoid bare `@codex`/`@claude` mentions (write "codex"/"claude" plain) so only the dedicated ping comments below trigger a review.
6. **Pings** — only after the push and summary succeeded **and only when the push actually introduced new commits or rewritten history** (the branch tip advanced — not an "Everything up-to-date" no-op push): `ping-codex` → a dedicated comment whose body is `@codex review`; `ping-claude` → a dedicated comment whose body is `@claude review`. If both, post two separate comments. **If nothing new was pushed this run, skip the pings entirely even when `ping-*` was supplied** (see "Flag interactions") — otherwise an automated review → address → review cycle never terminates.

### Step 8 — Final report

Always produce a report (this is the only output of a no-push run, and it doubles as the body of the Summary comment on push runs):

- The PR, the branch, before/after tip SHAs, and whether a rebase happened (and how conflicts went).
- Each addressed comment with a **stable reference** — file:line, comment author, the thread's GraphQL node id, and the comment permalink — and its disposition (fixed / already-addressed / pushed-back / deferred-to-task / skipped). On a **no-push** run this mapping is essential: a later "push now" turn uses it to replay the exact replies/resolves without re-deriving everything.
- Push-backs, prominently, with rationale.
- Deferrals, each with its committed task file, and whether it was maintainer-directed or agent-proposed.
- Proactive same-pattern fixes made beyond the literal comments.
- Reviewer outcome and how many iterations it took (and whether it hit the cap).
- Anything blocked or skipped for lack of an authoritative decision, with what's needed to unblock.

## Hands-off mode

Purpose: run inside a parallelized agent that has no direct line to the user (e.g. a review orchestrator's subagent). Reach the orchestrator if you can, but otherwise drive to a best-effort completion and **document, never guess on high-stakes choices.**

- Low-stakes ambiguity → make a sensible best-effort call and record it.
- A real concern whose fix would expand the PR's scope, on a branch that is defendable as it stands → defer it to a committed follow-up task (step 5) and flag the deferral prominently; this is a legitimate unattended resolution, not a skip.
- High-stakes/authoritative ambiguity → skip, do not guess, document precisely what's needed.
- Non-trivial rebase conflict → abort cleanly and stop the run (step 2).
- Lease-rejected push, unidentifiable/unrelated PR, or reviewer cap hit → stop and document; do not force or guess your way past it.
- At top level, fixer/reviewer subagents are still fine. In `delegated-fix` mode, do not attempt nested delegation; return the packet to the orchestrator. Every skipped/blocked item must appear in the final report (and the Summary comment if pushing) so the user learns of it and can act later.

## GitHub API recipes

`gh api` expands `{owner}`/`{repo}` to the current repo. For GraphQL, pass real values (`gh repo view --json owner,name`).

**List unresolved review threads** (id for resolve, comment `databaseId` for replies). `--paginate` follows `reviewThreads.pageInfo`; if a thread's nested `comments.pageInfo.hasNextPage` is true, fetch that thread's remaining comments before triage:

```sh
gh api graphql --paginate -f query='
query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){
      reviewThreads(first:100,after:$endCursor){ nodes{
        id isResolved isOutdated path line
        comments(first:100){
          nodes{ databaseId author{ login __typename } body diffHunk url }
          pageInfo{ hasNextPage endCursor }
        }
      } pageInfo{ hasNextPage endCursor }}
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

**Read context:** `gh pr view NUMBER --json reviews,comments,headRefName,headRefOid,headRepositoryOwner,baseRefName,url,state` and `gh api --paginate repos/{owner}/{repo}/issues/NUMBER/comments`.

## Checklist

- [ ] Working tree clean; no rebase in progress; `gh` authenticated.
- [ ] PR resolved (explicit `PR#` precedence) and sanity-checked against the current branch.
- [ ] If requested, single-branch rebase done first; non-trivial conflict handled (interactive loop-in / hands-off abort+stop); validated when conflicted.
- [ ] All **unresolved** threads gathered with pagination; resolved ones ignored; maintainer replies and top-level decision comments treated as authoritative; a zero-actionable run exits without push/comment/ping.
- [ ] Each thread triaged: actionable / already-addressed / push-back / deferred-to-task / ambiguous.
- [ ] Fixes done inline or via a fixer subagent (one checkout-dependent agent at a time); same-pattern sweep done in changed/related code.
- [ ] Deferred items recorded as standalone task files per `write-tasks` conventions, numbered into the repo's task folder, committed on the current branch separately from code fixes.
- [ ] Worktree clean and every intended change committed before review and publication.
- [ ] Fresh independent reviewer checked every disposition after commits landed; feedback loop capped at 3 reviewer rounds.
- [ ] Push run: PR head and exact push target re-verified; normal push used for fast-forward or explicit expected-OID lease used for rewrite (never bare `--force`); threads re-read after push; replies + resolves applied idempotently; push-backs resolved and flagged; deferred threads replied with their committed task file; ambiguous/new items left open; Summary comment posted without stray `@` mentions; pings as separate dedicated comments only after summary success **and only when new commits were actually pushed** (skip pings on a no-op push so an automated loop can terminate).
- [ ] No-push run: zero PR mutations; final report maps every thread to its disposition for a later push turn.
- [ ] Final report covers rebase outcome, dispositions with stable refs, push-backs, proactive fixes, reviewer result, and blocked/skipped items.
