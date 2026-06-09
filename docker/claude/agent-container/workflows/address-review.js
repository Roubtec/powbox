/**
 * address-review — dynamic-workflow form of the `address-review` skill.
 *
 * Work through every UNRESOLVED review thread on one pull request: gather the
 * threads, fix what is right / push back on what is wrong, verify every
 * disposition with a fresh-eyes reviewer (max 3 rounds), then — only when asked
 * — publish (lease-safe push, reply + resolve threads, Summary comment, pings).
 *
 * Invoke as `/address-review [PR#] [rebase on top of <branch>] [push]
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
 * Runtime notes:
 *  - The script cannot run git/gh/file IO; the gather/fix/review/publish agents
 *    do all of it and hand structured packets back as plain data.
 *  - Fixes are done by a single fixer agent (not fanned out per thread): review
 *    fixes routinely touch the same files, so parallel per-thread fixers would
 *    contend. The fan-out unit here is the verify loop's fresh reviewer, and —
 *    if extended — one workflow run per PR across a batch (the role the
 *    `address-reviews-worktrees` skill plays today).
 */

const MAX_ROUNDS = 3;

const PACKET_SCHEMA = {
  type: "object",
  properties: {
    ok: { type: "boolean", description: "False if the run cannot proceed (blocker set)." },
    blocker: { type: "string", description: "Why the run stopped: unidentifiable/unrelated PR, dirty tree, rebase in progress, non-trivial rebase conflict, auth failure. Empty when ok." },
    pr: {
      type: "object",
      properties: {
        number: { type: "integer" },
        url: { type: "string" },
        branch: { type: "string", description: "headRefName." },
        base: { type: "string", description: "Effective review base — the rebase target if a rebase ran, else baseRefName." },
        headOid: { type: "string", description: "Expected remote head OID, for the publication lease." },
        rebased: { type: "boolean", description: "True if a rebase rewrote the branch tip (publish must use --force-with-lease)." },
      },
      required: ["number", "branch", "base"],
    },
    threads: {
      type: "array",
      description: "Every UNRESOLVED review thread plus any explicitly-included standalone item, verbatim.",
      items: {
        type: "object",
        properties: {
          threadId: { type: "string", description: "GraphQL node id (for resolve)." },
          commentId: { type: "string", description: "Top comment databaseId (for the reply)." },
          path: { type: "string" },
          line: { type: "integer" },
          author: { type: "string" },
          body: { type: "string", description: "Comment text, verbatim." },
          url: { type: "string" },
        },
        required: ["body"],
      },
    },
  },
  required: ["ok", "threads"],
};

const DISPOSITION_SCHEMA = {
  type: "object",
  properties: {
    dispositions: {
      type: "array",
      items: {
        type: "object",
        properties: {
          threadId: { type: "string" },
          ref: { type: "string", description: "file:line + author, a stable human reference." },
          kind: { type: "string", description: "actionable-fixed | already-addressed | push-back | ambiguous-skipped" },
          detail: { type: "string", description: "For fixed: the one-line summary + commit sha. For already-addressed: where it's handled. For push-back: the rationale. For ambiguous: what decision is needed." },
        },
        required: ["threadId", "kind", "detail"],
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

function gatherPrompt(input) {
  return `You are preparing a pull request for review-addressing. Read \`AGENTS.md\` / \`CLAUDE.md\` first.

Request (lenient parsing — commas, &, free word order): ${JSON.stringify(input)}
Possible tokens: a PR number (e.g. #38), \`rebase on top of <branch>\`, \`push\`, \`ping-codex\`, \`ping-claude\`. You only act on the PR# and the rebase here; the push/ping flags are handled later.

Preflight (set \`ok: false\` with a \`blocker\` and stop on any failure):
1. Working tree clean (\`git status --porcelain\` empty). Do not auto-stash.
2. No rebase already in progress.
3. \`gh auth status\` succeeds.

Resolve the PR: explicit PR# wins (but sanity-check it shares history with the current branch — if genuinely unrelated, blocker and stop); else auto-detect via \`gh pr view\`. Record number, url, headRefName, baseRefName, headRefOid.

If \`rebase on top of <branch>\` was given: save \`refs/pre-rebase/<branch>/<ts>\`, then \`git rebase <target>\`. Resolve only TRIVIAL conflicts (imports/whitespace/pure additions/already-represented patches → in-file resolve or \`git rebase --skip\`). On the FIRST non-trivial conflict, \`git rebase --abort\`, confirm a clean tree, set \`blocker\` and stop. After a conflicted rebase, run the build to confirm. Set \`pr.rebased\` true if the tip was rewritten, and \`pr.base\` to the rebase target; otherwise \`pr.base = baseRefName\`.

Gather feedback: fetch UNRESOLVED review threads via GraphQL \`reviewThreads\` (paginate past 100; keep only \`isResolved == false\`; for each capture threadId, top comment databaseId, path, line, author, body verbatim, url). Read top-level reviews and issue comments for context — a maintainer reply on an unresolved thread is authoritative. Include a standalone item only if the request explicitly identifies it as outstanding.

If there are no unresolved threads and no included standalone item, return \`ok: true\` with an empty \`threads\` array — the caller will exit as a successful no-op.

Edit NO files here; this is gather-only.`;
}

function fixPrompt(packet, findings) {
  const fixup = findings
    ? `\n## Reviewer findings to address\n\nThe previous fix round did not fully pass. Address each finding, then re-confirm every disposition:\n\n${JSON.stringify(findings, null, 2)}\n`
    : "";
  return `You are addressing review feedback on PR #${packet.pr.number} (branch \`${packet.pr.branch}\`, base \`${packet.pr.base}\`). Read \`AGENTS.md\` / \`CLAUDE.md\` first.

This run is unattended (hands-off): decide low-stakes ambiguity best-effort and record it; for high-stakes ambiguity that needs an authoritative decision, do NOT guess — mark the thread \`ambiguous-skipped\` and leave it open.

## Unresolved threads (verbatim)

${JSON.stringify(packet.threads, null, 2)}
${fixup}
## Instructions

Triage each thread into exactly one kind and act:
- \`actionable-fixed\` — implement the fix. Commit at logical milestones.
- \`already-addressed\` — current code already satisfies it; note where.
- \`push-back\` (should be rare) — the comment is wrong/misunderstands context. Do NOT implement; draft a respectful, specific rationale. Never implement a fix you believe is wrong just to clear a comment.
- \`ambiguous-skipped\` — needs an authoritative decision you cannot make here.

- Preclude repeat comments: for each pattern you fix, grep the PR's changed files and closely related code for the SAME offending pattern and fix those too; report them in \`proactiveFixes\`.
- Keep commits buildable where practical; run build/lint before declaring done.
- Before returning, \`git status --porcelain\` MUST be empty with every intended change committed — set \`clean\` accordingly and set \`finalSha\` to HEAD.
- Do NOT push, reply, resolve, or comment on the PR — publication is a separate, later step.
- Do NOT use the \`TaskCreate\`/\`TaskUpdate\`/\`TaskList\` tools.

Return the structured dispositions.`;
}

function reviewPrompt(packet, dispositions) {
  return `You are an independent fresh-eyes reviewer for PR #${packet.pr.number} (branch \`${packet.pr.branch}\`, base \`${packet.pr.base}\`). Verify every proposed disposition against the committed code. Edit NOTHING. Read \`AGENTS.md\` / \`CLAUDE.md\` first.

You are given the unresolved threads and the proposed dispositions — but NOT the fixer's reasoning. Independently confirm each:
- \`actionable-fixed\` / \`already-addressed\` claims must actually hold in the committed code.
- \`push-back\` must be technically justified, not a convenient dismissal.
- \`ambiguous-skipped\` must genuinely require an authoritative decision.
You may reclassify any item.

## Threads

${JSON.stringify(packet.threads, null, 2)}

## Proposed dispositions

${JSON.stringify(dispositions, null, 2)}

How to verify:
1. Run the build / type-check first; a failure is an automatic blocker (\`pass: false\`).
2. Read the actual files. If \`git diff --name-only ${packet.pr.base}...HEAD\` looks empty despite claimed fixes, report a likely race/wrong-branch in \`issues\` rather than reviewing nothing.
3. Quality pass on changed files (logic, error handling, edge cases, dead code, consistency, duplication, type safety) and confirm the same-pattern sweep did not miss a sibling occurrence.

Return \`pass: true\` only if every disposition holds, the build passes, and no material issue remains; else \`pass: false\` with numbered, actionable \`issues\`. Do not use the task-tracker tools.`;
}

function publishPrompt(packet, dispositions, flags) {
  return `Publish the addressed review for PR #${packet.pr.number} (branch \`${packet.pr.branch}\`). A fresh reviewer has PASSED. Read \`AGENTS.md\` / \`CLAUDE.md\` first.

Flags for this publication: ${JSON.stringify(flags)}.

1. Re-check before publication: clean worktree, no rebase in progress; re-fetch the PR and confirm it is still open and still points at the expected head repo/ref. Resolve the branch's exact push remote/ref and verify it matches the PR head (never assume \`origin\`, especially for forks). Expected head OID to replace: \`${packet.pr.headOid || "(re-derive)"}\`. If the head moved or the target can't be matched, STOP and report — do not guess.
2. Push: if the expected tip is an ancestor of HEAD, normal push (\`git push <remote> HEAD:refs/heads/${packet.pr.branch}\`). If history was rewritten (rebased: ${packet.pr.rebased ? "yes" : "no"}), use an exact lease: \`git push <remote> --force-with-lease=refs/heads/${packet.pr.branch}:<expected-oid> HEAD:refs/heads/${packet.pr.branch}\`. If the lease is rejected, NEVER escalate to bare \`--force\`; stop and report.
3. Re-read unresolved threads after the push. Do not mutate newly-arrived feedback that was not triaged this run — leave it open and call it out.
4. Per-thread hygiene for each triaged thread still unresolved (reply via REST \`pulls/.../comments/<databaseId>/replies\`, resolve via GraphQL \`resolveReviewThread\`):
   - actionable-fixed → reply \`Fixed in <sha>: <one line>\` AND resolve.
   - already-addressed → reply pointing to where it's handled AND resolve.
   - push-back → reply with the rationale; resolve a BOT-authored thread, but leave a HUMAN-authored thread open unless explicitly authorized.
   - ambiguous-skipped → leave open.
   Avoid duplicate replies (check for an equivalent prior reply by the authed user); resolve only after the reply succeeds.
5. Summary comment: post a top-level "Summary of Review Fixes" (\`gh pr comment\`) — what was fixed (with proactive same-pattern fixes), a prominent "Pushed back — please re-examine" section, and any ambiguous/skipped or newly-arrived items. Write "codex"/"claude" plain (no bare @-mentions) so only the dedicated pings below trigger a re-review.
6. Pings (only after push + summary succeeded): ${flags.pingCodex ? "post a dedicated comment \`@codex review\`. " : ""}${flags.pingClaude ? "post a dedicated comment \`@claude review\`. " : ""}${!flags.pingCodex && !flags.pingClaude ? "none." : "If both, post two separate comments."}

## Dispositions to publish

${JSON.stringify(dispositions, null, 2)}

Report each thread's final disposition with a stable reference (file:line, author, threadId, permalink), the push/ping outcome, and anything left open.`;
}

// --- Flag parsing (the only logic the script does itself; no shell needed) ---
const raw = typeof args === "string" ? args : Array.isArray(args) ? args.join(" ") : "";
const lower = raw.toLowerCase();
const wantPush = /\bpush\b/.test(lower) || /\bping-?codex\b/.test(lower) || /\bping-?claude\b/.test(lower);
const flags = {
  push: wantPush,
  pingCodex: /\bping-?codex\b/.test(lower),
  pingClaude: /\bping-?claude\b/.test(lower),
};

phase("Gather");
const packet = await agent(gatherPrompt(args), { label: "gather", schema: PACKET_SCHEMA });
if (!packet) {
  return { error: "Gather phase failed (agent returned nothing)." };
}
if (!packet.ok) {
  return { error: "Stopped before any change.", blocker: packet.blocker, pr: packet.pr };
}
if (!packet.threads || packet.threads.length === 0) {
  return { status: "no-op", detail: "No unresolved threads and no included standalone item — nothing to address.", pr: packet.pr };
}

phase("Fix and verify");
let dispositions = null;
let verdict = null;
let rounds = 0;
let findings = null;

for (let round = 1; round <= MAX_ROUNDS; round++) {
  rounds = round;

  const fixResult = await agent(fixPrompt(packet, findings), {
    label: `fix#${round}`,
    schema: DISPOSITION_SCHEMA,
    isolation: "worktree",
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
    isolation: "worktree",
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

phase("Publish");
const publishReport = await agent(publishPrompt(packet, dispositions.dispositions, flags), {
  label: "publish",
  isolation: "worktree",
});

phase("Summary");
return {
  status: "fixed-published",
  pr: packet.pr,
  rounds,
  flags,
  dispositions: dispositions.dispositions,
  proactiveFixes: dispositions.proactiveFixes,
  publishReport,
};
