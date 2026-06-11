/**
 * wf-address-review — dynamic-workflow form of the `address-review` skill.
 *
 * Work through every UNRESOLVED review thread on one pull request: gather the
 * threads, fix what is right / push back on what is wrong, verify every
 * disposition with a fresh-eyes reviewer (max 3 rounds), then — only when asked
 * — publish (lease-safe push, reply + resolve threads, Summary comment, pings).
 * The re-review pings fire ONLY when the push actually advanced the branch with
 * new commits/rewritten history; a no-op push (nothing new to review) skips them
 * so an automated review -> address -> review loop can terminate.
 *
 * Invoke as `/wf-address-review [PR#] [rebase on top of <branch>] [push]
 * [ping-codex] [ping-claude]`.
 *
 * Why a workflow rather than a skill
 * ----------------------------------
 * The interesting part of this skill is its control flow: a verify-and-loop
 * cycle with a hard round cap, followed by a conditional publish stage gated on
 * flags. That sequencing is exactly what a workflow expresses as code instead of
 * prose, and the verifier is a textbook fresh-`Agent` spawn.
 *
 * Workflows have no mid-run user input, so this is structurally the skill's
 * `hands-off` mode: low-stakes ambiguity is decided best-effort by the agents
 * and recorded; high-stakes ambiguity is left open and reported, never guessed.
 * A non-trivial rebase conflict (when `rebase on top of` is supplied) is aborted
 * cleanly and stops the run, as in the skill.
 *
 * Worktree model
 * --------------
 * This is a SINGLE-PR, strictly SEQUENTIAL pipeline (gather -> fix -> review ->
 * publish) with no fan-out, so the agents deliberately do NOT use
 * `isolation: "worktree"`. They all run in the one working tree on the PR
 * branch, so the fixer's commits are directly visible to the reviewer and the
 * publisher. (Runtime isolation gives each agent a *separate* temporary worktree
 * started from the default branch, which would hide the fixer's commits from the
 * reviewer — the failure the original draft had. The batch front-end role —
 * many PRs at once — is where per-PR isolation belongs, and that must use the
 * explicit `.worktrees/$CONTAINER_NAME/` convention, not runtime isolation; see
 * wf-address-tasks.js and the directory README.)
 *
 * Runtime notes:
 *  - The script cannot run git/gh/file IO; the gather/fix/review/publish agents
 *    do all of it and hand structured packets back as plain data.
 *  - Fixes are done by a single fixer agent (not fanned out per thread): review
 *    fixes routinely touch the same files, so parallel per-thread fixers would
 *    contend.
 */

// The runtime requires `export const meta = {...}` (a pure literal) as the
// FIRST statement: it is how the script registers as the `/wf-address-review`
// command and what the pre-run approval prompt shows. The conditional report
// phases are not declared; undeclared phase() titles get their own group.
export const meta = {
  name: "wf-address-review",
  description: "Address every unresolved review thread on one PR: fix or push back, verify with a fresh-eyes reviewer (max 3 rounds), then publish only when asked.",
  whenToUse: "Work through maintainer-vetted review feedback on a single PR hands-off. Not for new task batches (wf-address-tasks) or stack rebases.",
  phases: [
    { title: "Gather", detail: "resolve the PR, branch state, and unresolved threads" },
    { title: "Fix and verify", detail: "fix/push-back per thread, fresh-eyes verification loop" },
    { title: "Publish", detail: "lease-safe push, thread replies, summary comment, pings" },
    { title: "Summary" },
  ],
};

const MAX_ROUNDS = 3;

const PACKET_SCHEMA = {
  type: "object",
  properties: {
    ok: { type: "boolean", description: "False if the run cannot proceed (blocker set)." },
    blocker: { type: "string", description: "Why the run stopped: unidentifiable/unrelated PR, dirty tree, rebase in progress, non-trivial rebase conflict, auth failure. Empty when ok." },
    pr: {
      type: "object",
      description: "Required whenever ok is true. The downstream phases dereference these fields, so populate them all.",
      properties: {
        number: { type: "integer" },
        url: { type: "string" },
        branch: { type: "string", description: "The PR's remote head ref (headRefName) — publication metadata, the push target. May differ from what is checked out." },
        workingBranch: { type: "string", description: "The branch actually checked out in the working tree right now (`git branch --show-current`). Usually equals branch, but for a supported local-offshoot of a merge-pending PR it differs — the fixer edits THIS branch, not the remote head ref." },
        base: { type: "string", description: "Effective review base — the rebase target if a rebase ran, else baseRefName." },
        headOid: { type: "string", description: "Expected remote head OID, for the publication lease. Populate from the PR's headRefOid." },
        rebased: { type: "boolean", description: "True if a rebase rewrote the branch tip (publish must use --force-with-lease)." },
      },
      required: ["number", "url", "branch", "workingBranch", "base", "headOid"],
    },
    items: {
      type: "array",
      description: "Every UNRESOLVED review thread plus any explicitly-included standalone item (issue comment / review summary), verbatim.",
      items: {
        type: "object",
        properties: {
          type: { type: "string", description: "`review-thread` (resolvable, threaded) or `standalone` (a top-level issue/review comment with no resolve state)." },
          threadId: { type: "string", description: "GraphQL review-thread node id — REQUIRED for type `review-thread` (used to resolve). Absent/empty for `standalone`." },
          commentId: { type: "string", description: "Top comment databaseId — REQUIRED for type `review-thread` (used to thread the reply). Absent/empty for `standalone`." },
          path: { type: "string" },
          line: { type: "integer" },
          author: { type: "string", description: "Comment author login." },
          authorIsBot: { type: "boolean", description: "True if the comment author is a bot / GitHub App. Derive from GraphQL author `__typename` (`Bot`) — NOT from guessing the login; if the author is unavailable (e.g. deleted account), use false, the safe value that keeps the thread open. Drives whether a push-back or deferred thread may be auto-resolved." },
          body: { type: "string", description: "Comment text, verbatim." },
          url: { type: "string", description: "Permalink to the comment (the stable reference for a standalone item, which has no threadId)." },
        },
        required: ["type", "body", "authorIsBot"],
      },
    },
  },
  required: ["ok", "items"],
};

const DISPOSITION_SCHEMA = {
  type: "object",
  properties: {
    dispositions: {
      type: "array",
      items: {
        type: "object",
        properties: {
          type: { type: "string", description: "`review-thread` or `standalone`, echoed from the gathered item." },
          threadId: { type: "string", description: "The review-thread node id — REQUIRED for type `review-thread` (publication resolves it); omit for `standalone`." },
          commentId: { type: "string", description: "The comment databaseId — REQUIRED for type `review-thread` (publication replies to it); omit for `standalone`." },
          authorIsBot: { type: "boolean", description: "Echoed from the gathered item; lets publication decide whether a push-back or deferred thread may be auto-resolved (bot) or must stay open (human). REQUIRED — if the gathered item somehow lacked it, re-derive from GraphQL author `__typename`, or use false (human), the safe value that keeps the thread open." },
          url: { type: "string", description: "Permalink — the stable reference, especially for `standalone` items." },
          ref: { type: "string", description: "file:line + author, a human-readable reference." },
          kind: { type: "string", description: "actionable-fixed | already-addressed | push-back | deferred-to-task | ambiguous-skipped" },
          detail: { type: "string", description: "For fixed: the one-line summary + commit sha. For already-addressed: where it's handled. For push-back: the rationale. For deferred: the committed task file path + one-line scope, and whether the deferral was maintainer-directed or agent-proposed. For ambiguous: what decision is needed." },
        },
        required: ["type", "kind", "detail", "authorIsBot"],
      },
    },
    proactiveFixes: { type: "string", description: "Same-pattern fixes made beyond the literal comments, or empty." },
    finalSha: { type: "string", description: "HEAD sha after all fixes are committed." },
    clean: { type: "boolean", description: "True only if `git status --porcelain` is empty with every intended change committed." },
  },
  required: ["dispositions", "clean"],
};

const VERDICT_SCHEMA = {
  type: "object",
  properties: {
    pass: { type: "boolean", description: "True only if every disposition holds in the committed code, the build passes, and no material quality issue remains." },
    issues: {
      type: "array",
      items: {
        type: "object",
        properties: {
          threadRef: { type: "string", description: "Which disposition or file:line this concerns." },
          problem: { type: "string" },
          fix: { type: "string" },
        },
        required: ["problem", "fix"],
      },
    },
  },
  required: ["pass", "issues"],
};

const PUBLISH_SCHEMA = {
  type: "object",
  properties: {
    published: { type: "boolean", description: "True only if the push AND every required reply/resolve/summary/ping step succeeded. False if any guard (moved head, unmatched remote, rejected lease, failed comment) aborted publication." },
    aborted: { type: "string", description: "Why publication stopped, when published is false (e.g. `head moved`, `lease rejected`, `push remote unmatched`). Empty when published." },
    pushed: { type: "boolean", description: "Whether a push was performed at all (may be an `Everything up-to-date` no-op)." },
    pushedNewCommits: { type: "boolean", description: "True ONLY if the push actually advanced the remote branch — new commits or rewritten history. False when no push happened or for a no-op `Everything up-to-date` push. Gates whether the re-review pings may fire." },
    threadOutcomes: {
      type: "array",
      description: "Per item: its stable reference and what was done (replied/resolved/left-open).",
      items: {
        type: "object",
        properties: {
          ref: { type: "string" },
          outcome: { type: "string" },
        },
        required: ["ref", "outcome"],
      },
    },
    summaryCommentUrl: { type: "string", description: "URL of the posted Summary of Review Fixes, or empty if not posted." },
    pings: { type: "string", description: "Which ping comments were posted, or empty." },
  },
  required: ["published", "pushed", "pushedNewCommits"],
};

// Shell-quote a ref before embedding it in a copy-paste command these prompts
// emit. A PR head/base ref name (from `gh pr view`) may legally contain shell
// metacharacters (`;`, `$`, backticks — git ref names forbid spaces but little
// else), so an unquoted ref could run the rest of the line or act on the wrong
// thing. Single-quote and escape embedded quotes; adjacent quoted spans like
// `refs/heads/'b'` concatenate into one shell word, so the path still resolves.
function shq(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

function gatherPrompt(input) {
  return `You are preparing a pull request for review-addressing. Read \`AGENTS.md\` / \`CLAUDE.md\` first.

Request (lenient parsing — commas, &, free word order): ${JSON.stringify(input)}
Possible tokens: a PR number (e.g. #38), \`rebase on top of <branch>\`, \`push\`, \`ping-codex\`, \`ping-claude\`. You only act on the PR# and the rebase here; the push/ping flags are handled later.

Preflight (set \`ok: false\` with a \`blocker\` and stop on any failure):
1. Working tree clean (\`git status --porcelain\` empty). Do not auto-stash.
2. No rebase already in progress.
3. \`gh auth status\` succeeds.

Resolve the PR: explicit PR# wins (but sanity-check it shares history with the current branch — if genuinely unrelated, blocker and stop); else auto-detect via \`gh pr view\`. When \`ok\` is true you MUST populate the whole \`pr\` object: \`number\`, \`url\`, \`branch\` (the PR's remote headRefName — the push target), \`workingBranch\` (the branch actually checked out now, from \`git branch --show-current\`), \`base\`, \`headOid\` (the PR's headRefOid — the publish phase needs it for a safe \`--force-with-lease\`), and \`rebased\`. Do NOT switch branches: \`workingBranch\` is whatever is checked out. It usually equals \`branch\`, but for a supported local off-shoot of a merge-pending PR it differs — downstream fixes must edit \`workingBranch\`, while \`branch\`/\`headOid\` remain publication metadata for the push.

If \`rebase on top of <branch>\` was given: save \`refs/pre-rebase/<branch>/<ts>\`, then \`git rebase <target>\`. Resolve only TRIVIAL conflicts (imports/whitespace/pure additions/already-represented patches → in-file resolve or \`git rebase --skip\`). On the FIRST non-trivial conflict, \`git rebase --abort\`, confirm a clean tree, set \`blocker\` and stop. After a conflicted rebase, run the build to confirm. Set \`pr.rebased\` true if the tip was rewritten and \`pr.base\` to the rebase target; otherwise \`pr.base = baseRefName\` and \`pr.rebased = false\`. (When rebased, \`pr.headOid\` is still the *remote* tip you will replace — read it before the rebase.)

Gather feedback into \`items\` (each verbatim):
- UNRESOLVED review threads via GraphQL \`reviewThreads\` (paginate past 100; keep only \`isResolved == false\`). Emit each as \`type: "review-thread"\` with \`threadId\` (node id), \`commentId\` (top comment databaseId), \`path\`, \`line\`, \`author\` (login), \`authorIsBot\` (true when the comment's GraphQL \`author.__typename\` is \`Bot\` — query \`author{ login __typename }\`; do not guess from the login), \`body\`, \`url\`. \`threadId\` and \`commentId\` are mandatory for these — they are how publication resolves and replies.
- Top-level context — ALWAYS fetch every review summary (\`gh pr view --json reviews\`) and every issue comment (\`gh api --paginate repos/{owner}/{repo}/issues/<PR>/comments\`), even when the request names no standalone item: this sweep is how maintainer replies and decision comments are discovered. A maintainer reply on an unresolved thread is authoritative — fold it into that thread's context. So is a top-level maintainer comment recording per-item verdicts (often titled "Maintainer Decisions" or similar) — fold each decision into the relevant thread's context as its binding disposition (including "defer to a follow-up task" and "keep as-is").
- A standalone issue comment or review summary becomes its own item ONLY if the request explicitly identifies it as outstanding. Emit it as \`type: "standalone"\` with \`author\`, \`authorIsBot\`, \`body\`, and \`url\` (its permalink is the stable reference; it has no threadId and is never resolved as a thread).

If there are no unresolved threads and no included standalone item, return \`ok: true\` with an empty \`items\` array — the caller will exit as a successful no-op.

Edit NO files here; this is gather-only.`;
}

function fixPrompt(packet, findings) {
  const fixup = findings
    ? `\n## Reviewer findings to address\n\nThe previous fix round did not fully pass. Address each finding, then re-confirm every disposition:\n\n${JSON.stringify(findings, null, 2)}\n`
    : "";
  return `You are addressing review feedback on PR #${packet.pr.number} (base \`${packet.pr.base}\`). You are on branch \`${packet.pr.workingBranch}\` in the working tree — confirm with \`git branch --show-current\` and do NOT switch branches. (The PR's remote head ref is \`${packet.pr.branch}\`; that is the push target, which may be a different name for a local off-shoot — edit the checked-out \`${packet.pr.workingBranch}\`, not the remote ref name.) Read \`AGENTS.md\` / \`CLAUDE.md\` first.

This run is unattended (hands-off): decide low-stakes ambiguity best-effort and record it; for high-stakes ambiguity that needs an authoritative decision, do NOT guess — mark the item \`ambiguous-skipped\` and leave it open.

## Items to address (verbatim)

${JSON.stringify(packet.items, null, 2)}
${fixup}
## Instructions

Triage each item into exactly one kind and act:
- \`actionable-fixed\` — implement the fix. Commit at logical milestones.
- \`already-addressed\` — current code already satisfies it; note where.
- \`push-back\` (should be rare) — the comment is wrong/misunderstands context. Do NOT implement; draft a respectful, specific rationale. Never implement a fix you believe is wrong just to clear a comment.
- \`deferred-to-task\` — the concern is real but fixing it here would expand the PR's scope considerably while the branch is defendable as it stands (builds, covers its main paths), or a maintainer reply/decision comment defers it. Do NOT implement; write a standalone follow-up task file instead, per the write-tasks skill conventions: place it in the repo's task folder (commonly \`tasks/\`; parked work in its deferred subfolder, e.g. \`tasks/deferred/\` — follow the repo's existing layout), number it to continue the existing sequence, restate the concern with file/line references and the PR thread link, and commit it on this branch SEPARATELY from code-fix commits. Never use this to dodge a cheap fix.
- \`ambiguous-skipped\` — needs an authoritative decision you cannot make here.

- Preclude repeat comments: for each pattern you fix, grep the PR's changed files and closely related code for the SAME offending pattern and fix those too; report them in \`proactiveFixes\`.
- Keep commits buildable where practical; run build/lint before declaring done.
- Before returning, \`git status --porcelain\` MUST be empty with every intended change committed — set \`clean\` accordingly and set \`finalSha\` to HEAD.
- Do NOT push, reply, resolve, or comment on the PR — publication is a separate, later step.
- Do NOT use the \`TaskCreate\`/\`TaskUpdate\`/\`TaskList\` tools.

For each disposition, echo the item's \`type\` and \`authorIsBot\` (both MANDATORY — publication uses \`authorIsBot\` to decide whether a push-back/deferred thread may be auto-resolved, so never omit it; if the gathered item lacked it, use false, the safe human default), and carry its identifiers: for \`review-thread\` items \`threadId\` and \`commentId\` are MANDATORY (publication cannot reply/resolve without them); for \`standalone\` items include \`url\`. Return the structured dispositions.`;
}

function reviewPrompt(packet, dispositions) {
  return `You are an independent fresh-eyes reviewer for PR #${packet.pr.number} (branch \`${packet.pr.workingBranch}\`, base \`${packet.pr.base}\`). You are on that branch with the fixer's commits already in the working tree. Verify every proposed disposition against the committed code. Edit NOTHING. Read \`AGENTS.md\` / \`CLAUDE.md\` first.

You are given the unresolved items and the proposed dispositions — but NOT the fixer's reasoning. Independently confirm each:
- \`actionable-fixed\` / \`already-addressed\` claims must actually hold in the committed code.
- \`push-back\` must be technically justified, not a convenient dismissal.
- \`deferred-to-task\` must point at a committed task file that genuinely covers the concern, with the deferral itself justified (maintainer-directed, or genuinely scope-expanding while the branch builds and covers its main paths) — not an evasion of a cheap fix.
- \`ambiguous-skipped\` must genuinely require an authoritative decision.
You may reclassify any item.

## Items

${JSON.stringify(packet.items, null, 2)}

## Proposed dispositions

${JSON.stringify(dispositions, null, 2)}

How to verify:
1. Run the build / type-check first; a failure is an automatic blocker (\`pass: false\`).
2. Read the actual files. If \`git diff --name-only ${shq(packet.pr.base)}...HEAD\` looks empty despite claimed fixes, report a likely race/wrong-branch in \`issues\` rather than reviewing nothing.
3. Quality pass on changed files (logic, error handling, edge cases, dead code, consistency, duplication, type safety) and confirm the same-pattern sweep did not miss a sibling occurrence.

Return \`pass: true\` only if every disposition holds, the build passes, and no material issue remains; else \`pass: false\` with numbered, actionable \`issues\`. Do not use the task-tracker tools.`;
}

function publishPrompt(packet, dispositions, flags) {
  return `Publish the addressed review for PR #${packet.pr.number} (branch \`${packet.pr.branch}\`). A fresh reviewer has PASSED. Read \`AGENTS.md\` / \`CLAUDE.md\` first.

Flags for this publication: ${JSON.stringify(flags)}.

Report a STRUCTURED result: set \`published: true\` ONLY if the push and every required reply/resolve/summary/ping below succeeded. If any guard aborts you, set \`published: false\` and \`aborted: "<reason>"\` and report what (if anything) was pushed — never claim success on an aborted publication.

1. Re-check before publication: clean worktree, no rebase in progress; re-fetch the PR and confirm it is still open and still points at the expected head repo/ref. Resolve the branch's exact push remote/ref and verify it matches the PR head (never assume \`origin\`, especially for forks). Expected head OID to replace: \`${packet.pr.headOid}\`. If the head moved or the target can't be matched, set \`published: false\`, \`aborted\`, and STOP — do not guess.
2. Push: if the expected tip is an ancestor of HEAD, normal push (\`git push <remote> HEAD:refs/heads/${shq(packet.pr.branch)}\`). If history was rewritten (rebased: ${packet.pr.rebased ? "yes" : "no"}), use an exact lease: \`git push <remote> --force-with-lease=refs/heads/${shq(packet.pr.branch)}:${packet.pr.headOid} HEAD:refs/heads/${shq(packet.pr.branch)}\`. If the lease is rejected, NEVER escalate to bare \`--force\`; set \`published: false\`, \`aborted: "lease rejected"\`, and stop.
3. Re-read unresolved threads after the push. Do not mutate newly-arrived feedback that was not triaged this run — leave it open and call it out.
4. Per-item hygiene for each disposition:
   - \`review-thread\` items: reply via REST \`pulls/.../comments/<commentId>/replies\`, resolve via GraphQL \`resolveReviewThread\` on \`threadId\`:
     - actionable-fixed → reply \`Fixed in <sha>: <one line>\` AND resolve.
     - already-addressed → reply pointing to where it's handled AND resolve.
     - push-back → reply with the rationale; resolve ONLY when the disposition's \`authorIsBot\` is true (a bot thread), and leave a thread with \`authorIsBot\` false (human) open unless explicitly authorized. Use that flag, not a guess from the author login.
     - deferred-to-task → reply citing the committed task file (\`Deferred to <task file>: <one line>\`); resolve when the deferral was maintainer-directed or \`authorIsBot\` is true, else leave the human thread open. Never re-implement a deferred thread.
     - ambiguous-skipped → leave open.
   - \`standalone\` items (no thread to resolve): address them only in the Summary comment below; do NOT call \`resolveReviewThread\`. Record their outcome by \`url\`.
   Avoid duplicate replies (check for an equivalent prior reply by the authed user); resolve only after the reply succeeds.
5. Summary comment: post a top-level "Summary of Review Fixes" (\`gh pr comment\`) — what was fixed (with proactive same-pattern fixes), a prominent "Pushed back — please re-examine" section, a "Deferred to follow-up tasks" section listing each deferral with its committed task file (agent-proposed deferrals flagged for confirmation), and any ambiguous/skipped or newly-arrived items. Write "codex"/"claude" plain (no bare @-mentions) so only the dedicated pings below trigger a re-review. Put its URL in \`summaryCommentUrl\`.
6. Pings (only after push + summary succeeded, AND only when the push ACTUALLY advanced the remote branch with new commits or rewritten history — never on an \`Everything up-to-date\` no-op push): ${flags.pingCodex ? "post a dedicated comment \`@codex review\`. " : ""}${flags.pingClaude ? "post a dedicated comment \`@claude review\`. " : ""}${!flags.pingCodex && !flags.pingClaude ? "none requested. " : "If both, post two separate comments. "}If nothing new was pushed this run (the remote ref already pointed at your HEAD — e.g. every disposition was already-addressed/push-back, or the branch was up to date), SKIP all pings even if requested above: re-requesting a review with nothing new to look at would spin the review->address->review loop forever. Set \`pushedNewCommits\` to whether the push advanced the branch, and record which pings (if any) you posted in \`pings\`.

## Dispositions to publish

${JSON.stringify(dispositions, null, 2)}

Record each item's outcome with its stable reference (file:line, author, threadId or url) in \`threadOutcomes\`.`;
}

// --- Flag parsing (the only logic the script does itself; no shell needed) ---
// `args` may arrive as a string OR, per the workflow docs, as structured data
// (array / object). Flatten any shape into the words it contains so `push` /
// `ping-codex` / `ping-claude` survive `Run /wf-address-review on #38 with push`
// being delivered as an object — `String(args)` would yield "[object Object]".
function flattenArgs(a) {
  if (a == null) return "";
  if (typeof a === "string") return a;
  if (Array.isArray(a)) return a.map(flattenArgs).join(" ");
  if (typeof a === "object") return Object.values(a).map(flattenArgs).join(" ");
  return String(a);
}
const raw = flattenArgs(args);
const lower = raw.toLowerCase();
// Detect publish intent carefully. `push-back`/`pushback` means rebutting a
// comment, not git push, so strip it before looking for the push token. Honor
// explicit negation ("no push", "do not push", "don't push", "without push",
// "skip push", "no-push") so a local-only request is never silently published —
// pushing mutates the remote and the PR threads. A ping still implies push (a
// re-review is meaningless without it), so negation cannot veto a requested ping.
const pushWords = lower.replace(/\bpush-?back\b/g, " ");
const pushNegated =
  /\bno-push\b/.test(lower) || /\b(?:no|not|never|without|skip|dont|don't|do not)\b[\s-]*push\b/.test(pushWords);
const pingCodex = /\bping-?codex\b/.test(lower);
const pingClaude = /\bping-?claude\b/.test(lower);
const wantPush = pingCodex || pingClaude || (/\bpush\b/.test(pushWords) && !pushNegated);
const flags = {
  push: wantPush,
  pingCodex,
  pingClaude,
};

phase("Gather");
const packet = await agent(gatherPrompt(args), { label: "gather", schema: PACKET_SCHEMA });
if (!packet) {
  return { error: "Gather phase failed (agent returned nothing)." };
}
if (!packet.ok) {
  return { error: "Stopped before any change.", blocker: packet.blocker || "(unspecified)", pr: packet.pr };
}
// The schema requires `pr` fields, but a schema-valid agent can still omit the
// object; validate before any phase dereferences packet.pr.* so an incomplete
// response is a reported failure, not a thrown crash.
if (!packet.pr || packet.pr.number == null || !packet.pr.branch || !packet.pr.workingBranch || !packet.pr.base) {
  return { error: "Gather succeeded but returned incomplete PR metadata (need number, branch, workingBranch, base).", pr: packet.pr || null };
}
// headOid is only consumed by the publish lease, so require it specifically when
// a push is requested — its absence would otherwise interpolate `undefined` into
// the expected-head check and the --force-with-lease, defeating remote-movement
// protection only AFTER fixes were made. Catch it before any work starts.
if (flags.push && !packet.pr.headOid) {
  return { error: "Push requested but gather returned no pr.headOid; refusing to proceed without the expected-head OID needed for a safe --force-with-lease.", pr: packet.pr };
}
if (!packet.items || packet.items.length === 0) {
  return { status: "no-op", detail: "No unresolved threads and no included standalone item — nothing to address.", pr: packet.pr };
}

phase("Fix and verify");
let dispositions = null;
let verdict = null;
let rounds = 0;
let findings = null;

for (let round = 1; round <= MAX_ROUNDS; round++) {
  rounds = round;

  // No worktree isolation: the fixer commits on the PR branch in the shared
  // working tree, so the reviewer below sees those commits directly.
  const fixResult = await agent(fixPrompt(packet, findings), {
    label: `fix#${round}`,
    schema: DISPOSITION_SCHEMA,
  });
  if (!fixResult) {
    return { error: `Fixer failed on round ${round}.`, pr: packet.pr, rounds };
  }
  if (!fixResult.clean) {
    return { error: `Fixer left an unclean worktree on round ${round}; refusing to review a partial state.`, pr: packet.pr, rounds, dispositions: fixResult.dispositions };
  }
  dispositions = fixResult;

  // Fresh-eyes reviewer, only after the fixer has committed everything.
  verdict = await agent(reviewPrompt(packet, dispositions.dispositions), {
    label: `review#${round}`,
    schema: VERDICT_SCHEMA,
  });
  if (!verdict) {
    return { error: `Reviewer failed on round ${round}.`, pr: packet.pr, rounds, dispositions: dispositions.dispositions };
  }
  if (verdict.pass) break;
  findings = verdict.issues;
}

const passed = verdict && verdict.pass;

if (!flags.push) {
  // Local-only run: make NO PR mutations. The disposition map is the deliverable
  // so a later "push" turn can replay replies/resolves precisely.
  phase("Report (no-push)");
  return {
    status: passed ? "fixed-local" : "review-cap",
    pr: packet.pr,
    rounds,
    reviewerPassed: !!passed,
    dispositions: dispositions.dispositions,
    proactiveFixes: dispositions.proactiveFixes,
    outstanding: passed ? null : (verdict ? verdict.issues : null),
    note: "Local-only run: no push, no replies/resolves, no comment. Re-run with `push` to publish.",
  };
}

if (!passed) {
  // push requested but the verify loop hit its cap — do NOT publish unverified work.
  phase("Report (cap hit, not published)");
  return {
    status: "review-cap-not-published",
    pr: packet.pr,
    rounds,
    dispositions: dispositions.dispositions,
    outstanding: verdict ? verdict.issues : null,
    note: `Hit the ${MAX_ROUNDS}-round cap without a passing review; nothing was pushed.`,
  };
}

// Guard before any publication side effect: a `review-thread` disposition with
// no threadId/commentId cannot be replied to or resolved, and the JSON schema
// cannot make those conditionally required. Catch it here so we never push and
// then fail mid-publish on a missing id (nothing has been pushed yet on a push
// run — the publisher does the push — so aborting now leaves the remote clean).
const badDisp = dispositions.dispositions.find(
  (d) => d.type === "review-thread" && (!d.threadId || !d.commentId)
);
if (badDisp) {
  return {
    status: "publish-aborted-incomplete-dispositions",
    pr: packet.pr,
    rounds,
    dispositions: dispositions.dispositions,
    note: `Review-thread disposition "${badDisp.ref || badDisp.kind}" is missing threadId/commentId; nothing was pushed. Re-run so every review thread carries its identifiers.`,
  };
}

// A ping summons a FRESH review, which only makes sense when this run actually
// pushed something new. With no new commits and no rebase, the branch tip is
// unchanged — pushing is a no-op and re-pinging would spin the
// review->address->review loop forever, so suppress the pings. We can positively
// know "nothing new" only when the final SHA equals the pre-run remote tip and
// no rebase ran; in every other case (incl. missing finalSha, or a local
// off-shoot whose SHA legitimately differs) we leave the flag on and defer to
// the publisher's own git check, which the prompt also gates on a no-op push.
const knownNoNewCommits =
  !packet.pr.rebased &&
  !!dispositions.finalSha &&
  dispositions.finalSha === packet.pr.headOid;
const publishFlags = {
  ...flags,
  pingCodex: flags.pingCodex && !knownNoNewCommits,
  pingClaude: flags.pingClaude && !knownNoNewCommits,
};

phase("Publish");
const publishReport = await agent(publishPrompt(packet, dispositions.dispositions, publishFlags), {
  label: "publish",
  schema: PUBLISH_SCHEMA,
});

phase("Summary");
const published = !!(publishReport && publishReport.published);
const pingsRequested = flags.pingCodex || flags.pingClaude;
const nothingNewPushed = knownNoNewCommits || (publishReport && publishReport.pushedNewCommits === false);
return {
  status: published ? "fixed-published" : "fixed-publish-failed",
  pr: packet.pr,
  rounds,
  flags: publishFlags,
  dispositions: dispositions.dispositions,
  proactiveFixes: dispositions.proactiveFixes,
  publishReport: publishReport || { published: false, aborted: "publisher returned nothing" },
  note: published
    ? (pingsRequested && nothingNewPushed
        ? "Published, but nothing new was pushed this run, so the re-review ping(s) were skipped to keep an automated review->address->review loop from spinning forever."
        : undefined)
    : "Fixes passed review but publication did not fully complete — see publishReport.aborted; nothing may have been pushed.",
};
