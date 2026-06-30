---
name: resolve-open-questions
description: >-
  Resolve outstanding decisions or open questions with the maintainer, one at a time, by grounding
  each item in real artifacts, showing a concrete trigger example, presenting distinct resolution
  outcomes with a recommendation, capturing the maintainer's choice, and applying it. Use for
  generic decision lists and especially for deferred/open items left by address-review or
  address-reviews runs: agent-proposed deferrals, hands-off blockers, discovered findings,
  and cross-branch issues. Trigger when the user wants to work through decision points, decide
  fix-now-vs-defer on follow-ups, or unblock PR/implementation progress. With no arguments, use the
  just-completed run's in-context items; with a pointer (PRs, task file, issue list, doc), re-derive
  the list. Do not trigger to address fresh review threads (use address-review or
  address-reviews) or to rebase a stack (use rebase-stack).
---

# resolve-open-questions

Put the human in the loop on a **batch of decisions**, served **one at a time**. Any non-trivial
process — addressing a review, executing a plan, untangling a migration, or coordinating an
operational change — can produce forks where several legitimate paths exist and only the maintainer
can pick. This skill takes that pile of contentious calls and, instead of dumping them or guessing,
presents each as a tight, grounded brief, captures the decision, then applies it.

The agent does the unattended part (research, grounding, an adjacent-invariant audit, and once a
call is locked, the implementation); the **human makes every judgment call**. The agent only
recommends.

This is the **interactive counterpart** to the hands-off skills. Where `address-review`,
`address-reviews`, and batch executors *document and stop* on anything they should not
guess, this skill is where those parked questions get answered.

> **Generic core, review-aware layer.** Sections 1–5 below are domain-neutral and apply to any list
> of open questions. The later **"When the items come from a review-addressing pass"** section adds
> the review-lifecycle machinery (deferrals, cross-branch reads, fix-now publish, task hygiene). If
> the list at hand is *not* review follow-up, read that layer as inapplicable and ignore its
> vocabulary — don't force review framing onto, say, a set of product or accounting decisions.

## Inputs

- **Continuation mode (no args).** A run just completed in this session (commonly a review pass).
  Harvest the open questions from the **in-context output**: every parked decision, "hands-off
  blocker", "ambiguous / needs-a-decision" item, and "discovered finding" note. This is the common
  case and the richest — the candidate options are often already drafted.
- **Pointed mode (a pointer to the list).** No prior context. The user hands you where the questions
  live — PR numbers, a task/issues file, a doc, or a free-form description. **Re-derive** the
  work-list from that source (for the review case, see the review layer), then proceed identically.

Optional trailing flags, honored only by the review layer's apply phase for items chosen to fix now,
mirror the review skills: `push` and `ping-codex` / `ping-claude` / `ping-copilot` / `ping-contributing`
(re-request bot review after the follow-up push). This is a **fully interactive** skill, so it does **not** assume
publication: even for a fix-now item it **asks the maintainer to confirm before pushing and before
editing any review threads** (the flags merely pre-answer that prompt). `ping-codex` / `ping-claude`
post an `@codex` / `@claude` review comment; **`ping-copilot` requests review via
`gh pr edit <PR#> --add-reviewer @copilot`** — never an `@copilot review` comment, which drives
Copilot's coding agent rather than its reviewer. **`ping-contributing`** carries the same meaning as in
`address-review`: re-ping a bot only if it brought a genuinely new finding this round, so a reviewer
that has gone quiet drops out of the loop — combined with explicit `ping-*` it filters that named set,
supplied alone it falls back to the bots that reviewed.

## The core loop

### 1. Gather the work-list

Sweep every source into one list of **distinct decisions**. Generic sources:

- **Parked choices** — anything an earlier turn flagged as "needs a human call" / "ambiguous" /
  "I didn't want to guess".
- **Blockers** — something a process *stopped on* because proceeding required authority it lacked.
- **Discovered side-issues** — observations noticed but not actioned because they were out of the
  run's scope.
- **Coupled forks** — one underlying choice that surfaces in two places (handle as one item).

(For the review-addressing case, the concrete forms these take — `deferred-to-task` dispositions,
hands-off blockers, sibling observations, cross-branch issues — are enumerated in the review layer.)

### 2. Ground each item — do this BEFORE asking anything

A question the maintainer can decide **in seconds** needs the concrete situation and the true blast
radius, not a summary. For every item pull the **authoritative artifact**, never a paraphrase and
never the original agent's reasoning:

- Read the real source of truth (the code at the cited sites, the spec/task file, the data, the
  document) — *end to end* for short artifacts, at the exact sites for long ones.
- **Confirm the gap still exists** as described. An earlier fix or an intervening change may have
  altered or resolved it; re-verify against the current state before you put it to the user.
- Establish **how real and how reachable** it is — the single most important input to your
  recommendation:
  - *Live today* — a real user/operator path hits it in normal operation.
  - *Dormant* — only bites after a specific condition flips (a deploy-time flag, a stub replaced by
    a real implementation, a config change).
  - *Impossible until X* — a named prerequisite must land first for the situation to even arise.

### 3. Triage & order

- **Couple items that share one decision.** Two forks at the same seam — or a fix plus its analog
  elsewhere — are one call; present them together so the user isn't asked the same thing twice.
- **Order for momentum and dependency.** Lead with the clearest / highest-value calls; keep
  prerequisite-bound items adjacent. Note coupled groups up front so the user sees the shape.
- **Serve in turn — don't pre-bundle into one giant prompt.** One decision per round (a coupled pair
  counts as one). The whole point is piecemeal presentation. *Exception:* genuinely trivial,
  independent calls may be batched into **a single multiple-choice round** when doing so saves the
  user time without losing clarity.

### 4. Serve each question — the core move

For each item (or coupled group), present a tight brief, then ask.

**Open each round with a one-line progress header** so the maintainer always knows how deep the
queue still is — this matters most on long lists (20, 35, or more items), where the absence of any
"how much is left" signal is exactly what makes wading through them tedious. State it as
**resolved · pending · total**, counting individual open questions/items (a coupled round closes more
than one at once), where *pending* **includes the item(s) you are about to serve** and *total* is the
full count identified up front (call it out if coupling or a fresh discovery later shifts the total).
For example: `Progress: 12 resolved · 23 pending · 35 total — this round: #13–14 (coupled).` Use
judgment on cadence rather than a fixed threshold: always show it when the remaining count is large
or a round closes several items, and you may fold it into the prose for a quick run of trivial single
confirmations — but never let the maintainer lose the sense of how far along they are. Keep it to one
compact line so it never buries the brief.

Every brief has the same four parts:

1. **Context (grounded).** What the concern is, in terms of the actual artifact and the documented
   intent. Cite the exact site (`file:line`, the spec, the record).
2. **A concrete trigger example.** The specific situation that produces the problem — *what causes
   it or how to make it manifest* — with the reachability verdict explicit ("live today: a user
   who…", "dormant until the async rail exists", "only on a flag flip across overlapping periods").
   This is what lets a busy maintainer decide fast.
3. **Options as distinct outcomes.** The candidate resolutions — typically *do it one way (A)*, *the
   other way (B)*, *defer / leave as-is* — and for each, **what choosing it actually produces**:
   blast radius, where it lands, cost, what stays exposed. Pull pre-drafted options straight from
   the source where they exist; add the do-now-vs-defer axis.
4. **A recommendation, when one is defensible.** State your pick and *why*, using the heuristics
   below. Put it first in the option list and mark it "(Recommended)". If the call genuinely turns
   on something only the maintainer knows ("do you ever change this cadence live?"), say so and make
   the recommendation conditional on their answer.

Then capture the decision with **AskUserQuestion** (options = the resolutions; recommended one first
and labelled). Honor any clarifying push-back before locking it — maintainers often refine the
*mechanism*, not just the yes/no.

**Offer an exit each round — the escape hatch.** Whenever more than one item still remains, include
in the *same* `AskUserQuestion` call a second, separate question — *"After this, continue or wrap
up?"* with options **Continue (Recommended)** and **Wrap up after this** — so the maintainer can end
a long session at any point (a meeting, a context switch) without having to smuggle the request into
a free-text answer. It consumes one of `AskUserQuestion`'s four question slots, so when you batch
trivial decisions cap them at three to leave room; skip the control entirely on the final remaining
item, where there is nothing left to continue to. If the maintainer picks **Wrap up** — or says so
in any wording at any time — do **not** abandon the work in flight: finish resolving and
**persisting/applying the item(s) already on the table** (step 5), then stop and produce the ledger
plus a closing progress count (`N of TOTAL resolved; M still pending, listed`) so a later session
resumes cleanly. Treat a wrap-up as a clean pause, never a discard.

**Sub-step — audit adjacent code/data when the decision relies on an invariant.** If a resolution
introduces or leans on a non-obvious invariant (e.g. "a record may stay `ACTIVE` past its
soft-expiry"), do not just implement it — first **sweep every other consumer of that invariant** and
report whether any mishandles it. This turns "fix this one spot" into "confirm the whole subsystem
agrees", and is frequently the most valuable thing the skill does. Use `rg` (per `AGENTS.md`, never
recursive `grep`) and, for broad sweeps, an Explore fan-out; report findings before proceeding.

### 5. Apply the decision

Collect decisions across the whole list, then apply. The mechanics depend on the kind of item:

- **A decision that just records intent** (a product choice, a spec edit, a "leave as-is") → make
  the edit, leave nothing dangling, note where it landed.
- **A decision that writes code** → implement it under whatever verification the repo expects
  (tests, build/lint, isolated validation), through a fresh review before anything ships. For the
  review-follow-up case the full machinery is in the review layer.

Keep a per-item ledger: the decision, where it landed (file/commit/record), or how the item was
refined.

---

## When the items come from a review-addressing pass

This is the canonical application and the reason the skill exists. `address-review` (one PR) and
`address-reviews` (a batch) run **hands-off**: every thread a fixer couldn't resolve with
authority is parked, the run surfaces blockers and out-of-scope findings, and **none of those are
calls an unattended agent should make**. This layer is where they get made — interactively — and
where the agreed fixes land. It is the interactive inverse of the review-addressing contract.

### Review-specific sources for the work-list (step 1)

- **`deferred-to-task` dispositions** — every thread the run replied to with "deferred to
  `tasks/NNN-*.md`". The committed task file is the spec; the thread is the origin.
- **Hands-off blockers** — anything a fixer or publisher *documented and stopped on* (a
  migration-ordering conflict, an ambiguous high-stakes choice).
- **Discovered findings with no thread** — sibling observations a fixer/reviewer noticed but didn't
  action (often a bug on an adjacent branch).
- **Cross-branch issues** — a fix whose prerequisite lives only on another branch in a stack, or an
  analog of one fix that recurs on a sibling branch.

In **pointed mode** for review work, re-derive these: for each PR read its committed task files
(grep `tasks/` for bodies citing that PR's deferred threads), read the threads resolved-as-deferred,
and scan recent run reports / commit messages for discovered findings.

### Review-specific grounding (step 2)

- Read the **committed task file** end to end — it restates the concern, names the code sites, lists
  "decision direction" options, and gives acceptance criteria. Pull its options straight into the
  brief.
- Read the **real code** at those sites. In a stack, read **across branches without checking
  anything out** using the image-baked `gitcat <ref> <path> [start [end]]` helper (stable line
  numbers). Confirm the gap still exists on the *addressed* tip.
- Classify **reachability** exactly as in the core (live today / dormant under a stub-flag-adapter /
  impossible until a named prerequisite) — it drives the recommendation.

### Review-specific apply (step 5)

**Fix-now items → worktree → review → publish** (borrow the machinery from
`address-reviews`):

- One **git worktree per owning branch** (Session Bootstrap, `wt-enter`, isolation model — see that
  skill). A coupled fix + sibling-analog may span two branches: each lands on **the branch that owns
  that code**; never split one atomic change across two worktrees.
- Delegate the implementation to a fresh subagent with the worktree contract, the task-file spec,
  and the decided option. Require: real **tests** (deterministic, clock-injected where the bug is a
  race — they verify the fix even when the production trigger is dormant), validation on an
  **isolated DB**, a clean commit, **no push**. When the fix **fully satisfies** the task, that same
  commit must also **move the task file to `tasks/done/`** so a later round cannot pick up a stale
  copy of work already done; when it only **partially** satisfies the task, leave the file in
  `tasks/` for a follow-up round and do **not** claim the thread as done. Archiving inside the
  *same* commit/PR is deliberate, not a violation of `tasks/AGENTS.md`'s "move to `done/` after
  merge" rule: a fix-now item pulled into another PR's scope has **no branch of its own**, so its
  `tasks/done/` move can only ride that PR — if the PR never merges, the move is discarded with it
  and nothing is lost. That is distinct from a task **selected for its own implementation**, which
  stays in `tasks/` for a final review under the one-task-one-branch model.
- Run a **fresh-eyes reviewer** per change (it edits nothing; PASS or numbered issues); fix-up
  rounds as needed.
- **Publish** each passing change *only after the maintainer confirms the push* — this interactive
  skill never pushes or edits review threads unprompted (a one-line "publish these fixes now?"
  question, pre-answered by a `push`/`ping-*` flag): these are commits *on top of* an already-pushed
  tip, so the push is a normal **fast-forward** (not a lease rewrite). Then post a **follow-up reply
  on the now-implemented thread** ("now implemented in `<sha>`" — append "task moved to
  `tasks/done/`" only when the commit actually archived it; a partially-satisfied task stays in
  `tasks/` and its thread is left as it stands — do **not** reopen a thread a prior run already
  resolved, since a re-review (codex especially) re-raises anything still unaddressed and rewriting
  historical resolutions is needless and messy), a Summary comment, and re-ping bots if requested
  (`@codex`/`@claude` via comment; Copilot via `gh pr edit <PR#> --add-reviewer @copilot`, never an
  `@copilot review` comment; under `ping-contributing`, only the bots that brought a new finding this round).

**Deferred items → task hygiene** (no code, but leave nothing dangling):

- **Reuse task numbers — no orphans.** If a better solution emerged, **rewrite the existing task in
  place** rather than spawning a new number. If two tasks collapse into one (a shared helper),
  consolidate into one existing number and have it absorb the others.
- **Lock the chosen option.** Edit the task to mark the maintainer-selected approach as *the*
  solution and demote the rejected ones to a "considered & declined" note, so the implementer has no
  ambiguity.
- **Keep-standalone vs bind-to-prerequisite is the maintainer's risk call.** Binding a task as a
  hard prerequisite of a future feature is clean on paper but fragile (it can be forgotten when the
  feature ships). Default to a **self-standing committed task** unless the maintainer prefers the
  binding; either way the resolved thread already points at the file.
- **Archive implemented tasks** to `tasks/done/` (repo convention) with the implementing commit
  noted.

### Review-specific aggregate & flag

- **New review threads that arrived mid-run.** A bot re-review triggered by the *original* push may
  have posted fresh threads while this session ran; publishers will report them. Surface them
  prominently — they are a *new* round, **not this skill's scope** (point at `address-review` /
  `address-reviews`).
- **Stack state.** Fix-now follow-ups make a stacked chain leafier; inherited-code fixes and
  consolidated tasks **collapse at restack**. Point at `rebase-stack` for the integration pass.

---

## Recommendation heuristics (how to pick the "(Recommended)" option)

- **Reachability dominates.** *Live today* → lean **do it now** (it bites real users). *Dormant
  under a stub/adapter/flag* → lean **defer**, and tie the follow-up to the trigger that wakes it.
  *Impossible until a named prerequisite* → **defer**, but keep the work *implementable and
  verifiable now* if it's independent of that prerequisite (hardening a seam *before* the feature
  that exposes it is the safer order).
- **Blast radius & altitude.** A one-seam fix that mirrors an already-accepted pattern → do it now.
  A change that widens a cross-module interface, reverses a prior accepted decision, or touches the
  most sensitive path (money, auth, migrations) → prefer the **robust** option or defer; never the
  blunt stopgap on a sensitive path.
- **Robust over blunt** for a correctness invariant: prefer the option that holds under *any* input
  (and is a no-op in the common case) over one that parks/blocks legitimate flows.
- **Stack-aware placement** (review case). Land a fix on the branch that **owns** the code; inherited
  copies heal at restack — don't duplicate it on every branch. Surface a sibling-branch **analog**
  and let the maintainer opt in rather than silently expanding scope.
- **Conservatism on the sensitive path.** When unsure between do-now and defer on a
  financial/security/migration change, recommend the committed task/deliberate build — defendable as
  it stands, and the fix gets built carefully.
- **Make it conditional when it hinges on intent.** If the right answer depends on a product/ops
  fact only the maintainer holds ("will you ever change this setting live?"), ask *that* and frame
  the recommendation around the answer.

## Notes

- This skill **consults the user** — that is its whole purpose. The only things it does unattended
  are the *grounding/audit research* and, once a decision is locked, the *implementation* (which
  still goes through review before publish).
- Read `AGENTS.md` / `CLAUDE.md` for repo conventions (task layout, `tasks/done/`, test harness,
  isolated-DB story) before forming options.
- Cross-branch reads use `gitcat`; never check a sibling branch out just to read it.

## Checklist

- [ ] Mode detected (continuation vs pointed); full work-list gathered (parked choices + blockers +
      discovered findings + — for review work — deferrals & cross-branch issues).
- [ ] Each item **grounded** in its authoritative artifact (real code/data/spec; cross-branch via
      `gitcat`); gap re-confirmed; reachability classified.
- [ ] Coupled items grouped; order set; served **one at a time** (trivial independents may share one
      multiple-choice round) with context + trigger example + options-as-outcomes + recommendation;
      decision captured via AskUserQuestion. Each round opens with a `resolved · pending · total`
      progress line, and (while >1 item remains) offers a **continue / wrap-up** escape hatch; on
      wrap-up, finish + persist the current item, then stop with a resume-ready ledger.
- [ ] Adjacent-invariant audit run whenever a resolution relies on/introduces one; findings reported
      before implementing.
- [ ] Code-writing decisions verified (tests, build, isolated validation) through a fresh review;
      review-case fix-now items: worktree per owning branch → subagent implement → fresh review →
      **fast-forward** publish (thread reply, Summary, re-ping); no atomic change split across
      branches.
- [ ] Review-case deferred items: task numbers reused (no orphans), chosen option locked, rejected
      options demoted, implemented tasks archived to `tasks/done/`; keep-standalone vs bind decided
      with the maintainer.
- [ ] Final ledger + (review case) prominent flag of any NEW review threads + `rebase-stack` pointer
      for the leafy stack.
