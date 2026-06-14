---
name: resolve-review-deferrals
description: >-
  Interactively work through the open questions an address-review / address-reviews-worktrees
  run leaves behind — the agent-proposed deferrals (deferred-to-task), hands-off blockers, and
  discovered cross-branch findings — serving them to the maintainer ONE AT A TIME, each grounded
  in its committed task file and the real code, with a concrete trigger example, the candidate
  resolutions as distinct outcomes, and a recommendation; then applying each decision (fix now via
  worktree → fresh review → fast-forward publish, or refine/defer the committed task). Trigger when
  the user wants to resolve the deferred/open items from a review-addressing pass, "go through the
  hands-off questions", or decide fix-now-vs-defer on a stack's follow-ups. Pass NOTHING to use the
  just-completed run's in-context packets, or a list of PR numbers to re-derive the open items in a
  fresh session. Do NOT trigger to address fresh review threads (use address-review /
  address-reviews-worktrees) or to rebase a stack (use rebase-stack).
---

# resolve-review-deferrals

The closing move of a review-addressing cycle. `address-review` (one PR) and
`address-reviews-worktrees` (a batch) run **hands-off**: every thread that a fixer could not
resolve with authority is parked as a `deferred-to-task` disposition backed by a committed task
file, plus the run surfaces **hands-off blockers** and **discovered out-of-scope findings**. None
of those are decisions an unattended agent should make. This skill is where the maintainer makes
them — interactively, one question at a time — and where the agreed fixes actually land.

It is the **interactive inverse** of the review-addressing skills: those impose the unattended
contract; this one exists to put the human in the loop on exactly the calls that contract refused
to guess.

## What counts as an "open question"

Sweep these sources into one work-list:

- **`deferred-to-task` dispositions** — every review thread the run replied to with "deferred to
  `tasks/NNN-*.md`". The committed task file is the spec; the thread is the origin.
- **Hands-off blockers** — anything a fixer or publisher *documented and stopped on* (e.g. a
  migration-ordering conflict, an ambiguous high-stakes choice).
- **Discovered findings with no review thread** — "sibling observations" a fixer/reviewer noticed
  but did not action because it was out of the run's scope (often a bug on an adjacent branch).
- **Cross-branch issues** — a fix whose prerequisite lives only on another branch in a stack, or an
  analog of one fix that recurs on a sibling branch.

## How this differs from address-review(s)

| | address-review(s) | resolve-review-deferrals |
|---|---|---|
| Posture | hands-off (document & stop) | **interactive** (serve & decide) |
| Unit | a review thread | an **open question / deferral** |
| Output of a turn | a disposition + reply | a **maintainer decision**, then code or a task edit |
| Default | fix or defer per the contract | **the human picks**; the agent only recommends |

## Inputs

Two entry modes — detect which applies:

- **Continuation mode (no args).** A review-addressing run just completed in this session. Harvest
  the open questions from the **in-context packets**: each PR's per-thread dispositions, the
  prominent "hands-off blockers" section, and any "discovered finding / sibling observation" notes.
  This is the common case and the richest — you already have the dispositions and proposed replies.
- **Fresh mode (PR numbers / branch names, like address-reviews-worktrees).** No prior context.
  **Re-derive** the work-list: for each PR read its committed task files (grep `tasks/` for files
  whose body cites that PR's `deferred-to-task` threads), read the PR's review threads that were
  resolved-as-deferred, and scan recent run reports / commit messages for discovered findings. Then
  proceed identically.

Optional trailing flags mirror the review skills and are passed through to the **apply** phase only
for items the user chooses to fix now: `push` (default on for fix-now items — a deferral resolution
that writes code is meant to ship), `ping-codex` / `ping-claude` (re-request bot review after the
follow-up push).

## Procedure

### 1. Gather & ground (do this BEFORE asking anything)

For every open question, pull the **authoritative artifact**, never a paraphrase and never the
original fixer's reasoning:

- Read the **committed task file** end to end — it restates the concern, names the exact code
  sites, lists "decision direction" options, and gives acceptance criteria.
- Read the **real code** at those sites. In a stack, read **across branches without checking
  anything out** using the image-baked `gitcat <ref> <path> [start [end]]` helper (stable line
  numbers). Confirm the gap still exists on the *addressed* tip (a fixer's earlier change may have
  altered it).
- Establish **reachability** — the single most important input to your recommendation:
  - *Reachable today* in normal operation (a real user/operator path hits it).
  - *Dormant under a config/stub/adapter* (only bites after a specific deploy-time flip, a stub is
    replaced by a real rail, etc.).
  - *Strictly impossible until X* (a named, deferred prerequisite must land first for the path to
    even exist).

Grounding is the point: a question the maintainer can actually decide needs the concrete trigger
and the true blast radius, not a summary.

### 2. Triage & order

- **Couple items that share one fix.** Two tasks at the same seam, or a fix-now item plus its
  discovered analog on a sibling branch, are one decision — present them together so the maintainer
  isn't asked the same thing twice.
- **Order for momentum and dependency.** Lead with the clearest / highest-value calls; keep
  prerequisite-bound items adjacent. Note coupled groups up front so the user sees the shape.
- **Don't pre-bundle into one giant prompt.** The maintainer explicitly wants them **served in
  turn** — one decision per round (a coupled pair counts as one).

### 3. Serve each question — the core loop

For each item (or coupled group), present a tight brief, then ask. Every brief has the same four
parts:

1. **Context (grounded).** What the concern is, in terms of the actual code sites and the documented
   intent. Cite `file:line` and the task file.
2. **A concrete trigger example.** The specific situation that produces the problem — with the
   reachability verdict made explicit ("reachable today: a patient who…", "dormant until the async
   rail (022a) exists", "only on a live `FOO_MODE` flip across overlapping periods"). This is what
   lets a busy maintainer decide in seconds.
3. **Options as distinct outcomes.** The candidate resolutions — typically *fix now (option A)*,
   *fix now (option B)*, *defer/keep-as-task* — and for each, **what shipping that choice actually
   produces** (blast radius, which branch it lands on, test cost, what stays exposed). Pull the
   "decision direction" options straight from the task file; add fix-now-vs-defer.
4. **A recommendation, when one is defensible.** State your pick and *why*, using the heuristics
   below. Put it first in the option list and mark it "(Recommended)". If the call genuinely turns
   on something only the maintainer knows (e.g. "do you ever change this cadence live?"), say so and
   make the recommendation conditional on their answer.

Then capture the decision with **AskUserQuestion** (one question; options = the resolutions; the
recommended one first and labelled). Honor any clarifying push-back the maintainer makes before
locking it — they often refine the *mechanism*, not just the yes/no.

**Sub-step — audit adjacent code when the decision relies on an invariant.** If a fix introduces or
leans on a non-obvious invariant (e.g. "a record may stay `ACTIVE` past its soft-expiry"), do not
just implement it — first **sweep every reader of that invariant** and report whether any other site
mishandles it. This is frequently the most valuable thing the skill does: it turns "fix this one
spot" into "confirm the whole subsystem agrees", and it is exactly the kind of diligence the
maintainer will ask for ("hopefully nothing else mishandles this — what do you think?"). Use
`grep`/`gitcat`/an Explore fan-out; report findings before proceeding.

### 4. Apply the decision

Collect decisions across the whole list, then apply. Two paths:

**Fix-now items → worktree → review → publish** (borrow the machinery from
`address-reviews-worktrees`):
- One **git worktree per owning branch** (Session Bootstrap, `wt-enter`, isolation model — see that
  skill). A coupled fix + sibling-analog may span two branches: each lands on **the branch that owns
  that code**; never split one atomic change across two worktrees.
- Delegate the implementation to a fresh subagent with the worktree contract, the task-file spec,
  and the decided option. Require: real **tests** (deterministic, clock-injected where the bug is a
  race — these verify the fix even when the production trigger is dormant), validation on an
  **isolated DB**, a clean commit, **no push**.
- Run a **fresh-eyes reviewer** per change (it edits nothing; PASS or numbered issues); fix-up
  rounds as needed.
- **Publish** each passing change: these are commits *on top of* an already-pushed tip, so the push
  is a normal **fast-forward** (not a lease rewrite). Then post a **follow-up reply on the
  now-implemented thread** ("now implemented in `<sha>`, task moved to `tasks/done/`"), a Summary
  comment, and re-ping bots if requested.

**Deferred items → task hygiene** (no code, but leave nothing dangling):
- **Reuse task numbers — no orphan/unaddressable tasks.** If a better solution emerged, **rewrite
  the existing task in place** rather than spawning a new number. If two tasks collapse into one
  (e.g. a shared helper), consolidate into one of the existing numbers and have it absorb the
  others.
- **Lock the chosen option.** Edit a deferred task to mark the maintainer-selected approach as *the*
  solution and demote the rejected ones to a "considered & declined" note, so the eventual
  implementer has no ambiguity.
- **Keep standalone vs bind-to-prerequisite is the maintainer's risk call.** Binding a task as a
  hard prerequisite of a future feature is clean on paper but fragile (implementation order is an
  imperfect science — the bound task can be forgotten when the feature ships). Default to a
  **self-standing committed task** unless the maintainer prefers the binding; either way the
  resolved review thread already points at the file.
- **Archive implemented tasks** to `tasks/done/` (follow the repo's existing convention) with the
  implementing commit noted.

### 5. Aggregate & flag

- A per-item ledger: decision, where it landed (branch + commit), or how the task was refined.
- **New review threads that arrived mid-run.** A bot re-review triggered by the *original*
  addressing push may have posted fresh threads while this session ran; publishers will report them.
  Surface them prominently — they are a *new* round, not this skill's scope (point at
  address-review(s)).
- **Stack state.** Fix-now follow-ups make a stacked chain leafier; inherited-code fixes and
  consolidated tasks **collapse at restack**. Point at `rebase-stack` for the integration pass.

## Recommendation heuristics (how to pick the "(Recommended)" option)

- **Reachability dominates.** *Reachable today* → lean **fix now** (it bites real users). *Dormant
  under a stub/adapter/flag* → lean **defer**, and tie the task to the trigger that wakes it.
  *Strictly impossible until a named prerequisite* → **defer**, but keep the task *implementable and
  test-verifiable now* if the fix is independent of that prerequisite (hardening a seam *before* the
  feature that exposes it is the safer order).
- **Blast radius & altitude.** A one-seam, mirrors-an-already-accepted-pattern fix → fix now. A
  change that widens a cross-module interface, reverses a prior accepted decision, or touches the
  most sensitive path (money, auth, migrations) → prefer the **robust** option or defer; never the
  blunt stopgap on a sensitive path.
- **Robust over blunt** when fixing a correctness invariant: prefer the option that holds under
  *any* input (and is a no-op in the common case) over one that parks/blocks legitimate flows.
- **Stack-aware placement.** Land a fix on the branch that **owns** the code; inherited copies heal
  at restack — don't duplicate the fix on every branch. Surface a sibling-branch **analog** and let
  the maintainer opt in rather than silently expanding scope.
- **Conservatism on the sensitive path** (per the repo's own AGENTS.md-style rules): when unsure
  between fix-now and defer on a financial/security/migration change mid-stack, recommend the
  committed task — the run is defendable as shipped and the fix gets built deliberately.
- **Make it conditional when it hinges on intent.** If the right answer depends on a product/ops
  fact only the maintainer holds ("will you ever change this setting live?"), ask *that* and frame
  the recommendation around the answer.

## Notes

- This skill **consults the user** — that is its whole purpose. The only thing it does unattended is
  the *grounding/audit research* and, once a decision is locked, the *implementation* (which still
  goes through review before publish).
- Read `AGENTS.md` / `CLAUDE.md` for repo conventions (task layout, `tasks/done/`, test harness,
  isolated-DB story) before forming options.
- Cross-branch reads use `gitcat`; never check a sibling branch out just to read it.

## Checklist

- [ ] Mode detected (continuation vs PR-number fresh); full work-list gathered (deferrals +
      hands-off blockers + discovered findings + cross-branch issues).
- [ ] Each item **grounded** in its committed task file + real code (read cross-branch via
      `gitcat`); reachability classified.
- [ ] Coupled items grouped; order set; served **one at a time** with context + trigger example +
      options-as-outcomes + recommendation; decision captured via AskUserQuestion.
- [ ] Adjacent-invariant audit run whenever a fix relies on/introduces one; findings reported before
      implementing.
- [ ] Fix-now items: worktree per owning branch → subagent implement (+ deterministic tests, isolated
      DB) → fresh review → **fast-forward** publish (thread follow-up reply, Summary, re-ping); no
      atomic change split across branches.
- [ ] Deferred items: task numbers reused (no orphans), chosen option locked, rejected options
      demoted, implemented tasks archived to `tasks/done/`; keep-standalone vs bind decided with the
      maintainer.
- [ ] Final ledger + prominent flag of any NEW review threads (a fresh round, not this skill) +
      `rebase-stack` pointer for the leafy stack.
