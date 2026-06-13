/**
 * wf-address-tasks — dynamic-workflow form of the `address-tasks` skill.
 *
 * Resolve a batch of pre-planned task files into dependency waves, then for each
 * task run an implement -> review -> fix loop (max 3 rounds), scan reviewed
 * sibling branches for add/add collisions before delivery and deconflict them
 * (an orchestrator-deputy agent renames one side, regenerates derived files, and
 * the changed branch is re-reviewed) — or hold a name that must stay identical —
 * then open PRs for the delivered tasks and report. Invoke as
 * `/wf-address-tasks <glob-or-file-list>`.
 *
 * Why a workflow rather than a skill
 * ----------------------------------
 * The control flow the skill spells out in prose — dependency waves, the 3-round
 * loop, dependent waves gated on their prerequisites, "the implementer finishes
 * before its reviewer starts" — becomes ordinary JavaScript here, run
 * deterministically instead of relying on the model to follow it. Independent
 * tasks fan out via `parallel()`.
 *
 * Worktree model — why NOT `isolation: "worktree"`
 * ------------------------------------------------
 * The runtime's built-in `isolation: "worktree"` creates a fresh temporary
 * worktree per agent at a runtime-chosen path (default `.claude/worktrees/`),
 * started from the repository's DEFAULT branch, with no documented way to
 * redirect it. That is wrong for this container in two ways:
 *   1. It does not honor powbox's `.worktrees/$CONTAINER_NAME/<slug>` convention
 *      — the per-container subdir on the persistent project volume that carries
 *      the pnpm hardlink store and lets two containers (Claude + Codex) share one
 *      repo without a peer's prune reaping live work. The runtime would land in
 *      the tmpfs-shadowed `.claude/worktrees/` instead (full package copies, a
 *      shared ~2 GB cap, no per-`$CONTAINER_NAME` discipline).
 *   2. A SEPARATE worktree per agent, started from the default branch, hides an
 *      implementer's commits from its reviewer.
 * So this workflow uses the same explicit worktree model as the
 * `address-tasks-worktrees` skill: each task gets ONE worktree under
 * `.worktrees/$CONTAINER_NAME/<slug>`, created by its first implementer and
 * REUSED by that task's reviewer and every later round (so the reviewer sees the
 * commits and no agent ever tries to re-check-out a branch already checked out).
 * Tasks run concurrently because each lives in its own worktree; an agent's
 * WORKTREE CONTRACT keeps it inside its own directory. Push is for durability;
 * cross-stage visibility comes from sharing the on-disk worktree, not the remote.
 *
 * The worktree/git MECHANICS are not spelled out in prompt text. They live in
 * three image-baked helpers — `wt-bootstrap` (root-safety checks + orphan prune
 * + remote probe), `wt-enter` (rerun-safe worktree resolve/attach/create), and
 * `wt-remove` (guarded cleanup) — the same single source of truth the
 * *-worktrees skills call. Agents here invoke those scripts and exercise
 * judgment; they never re-derive the lifecycle from prose.
 *
 * Runtime notes:
 *  - The script itself cannot read files or run shell/git — every git, gh, and
 *    file operation happens inside a spawned agent.
 *  - There is no mid-run user input. A blocker is surfaced by returning a result
 *    object, never by pausing to ask.
 */

// The runtime requires `export const meta = {...}` (a pure literal) as the
// FIRST statement: it is how the script registers as the `/wf-address-tasks`
// command and what the pre-run approval prompt shows. Wave phases are dynamic
// (`Wave N (...)`), so only the fixed phases are declared here; undeclared
// phase() titles still get their own progress group.
export const meta = {
  name: "wf-address-tasks",
  description: "Implement a batch of pre-planned task files: dependency waves, per-task worktree, implement->review->fix loop (max 3 rounds), pre-PR collision guard that deconflicts add/add clashes (rename one side + re-review) or holds an imperative name, one PR per delivered task.",
  whenToUse: "Execute a folder/glob of pre-planned task files end to end with per-task worktree isolation. Not for one-off coding requests or planning new tasks.",
  phases: [
    { title: "Bootstrap", detail: "wt-bootstrap: root-safety checks, orphan prune, remote probe" },
    { title: "Resolve batch", detail: "read task files, derive dependency waves and branches" },
    { title: "Collision scan", detail: "diff added files across sibling branches for add/add clashes" },
    { title: "Collision resolve", detail: "rename one side of each clash, regen, re-review, then deliver" },
    { title: "Summary" },
  ],
};

const MAX_ROUNDS = 3;

// Finish over fan-out (inherited from the skills' adaptive-throttling rule): a
// wave that runs four-wide and dies to ENOSPC delivers nothing; the same wave
// two-wide delivers everything a little slower. Width is the MINIMUM of the
// dependency-derived wave size, this hard cap, and a storage-headroom cap
// computed from wt-bootstrap's availBytes.
const MAX_WAVE_WIDTH = 4;
// Conservative per-task estimate. On the volume-backed path pnpm packages are
// hardlinked, so the real cost is build artifacts + package metadata; 1 GiB
// keeps a comfortable margin without measuring a representative install (which
// a deterministic script cannot do).
const PER_WORKTREE_BYTES = 1024 ** 3;

const BOOTSTRAP_SCHEMA = {
  type: "object",
  properties: {
    ok: { type: "boolean" },
    blocker: { type: "string", description: "Why the batch cannot proceed (worktree roots unsafe, CONTAINER_NAME unset, wt-bootstrap missing). Empty when ok." },
    wtBase: { type: "string", description: "Absolute path to this container's worktree base, `<repo>/.worktrees/$CONTAINER_NAME`." },
    remote: { type: "boolean", description: "True if push/PR is available (remote reachable); false means local-branch-only fallback." },
    availBytes: { type: "number", description: "Free bytes on the .worktrees mount, verbatim from wt-bootstrap (drives wave-width throttling)." },
  },
  required: ["ok"],
};

const PLAN_SCHEMA = {
  type: "object",
  properties: {
    defaultBase: { type: "string", description: "PR base branch for independent tasks (the user's override, else the current branch, else main)." },
    waves: {
      type: "array",
      description: "Tasks grouped into dependency waves; wave N runs only after wave N-1 has finished.",
      items: {
        type: "array",
        items: {
          type: "object",
          properties: {
            slug: { type: "string", description: "Stable, ref-safe identifier (task number + short name); also the worktree dir name." },
            path: { type: "string", description: "Path to the task file." },
            content: { type: "string", description: "Full verbatim content of the task file." },
            branch: { type: "string", description: "Branch the implementer should create and work on." },
            base: { type: "string", description: "Base branch to create from and target the PR against (a prior task's branch for dependents)." },
            dependsOn: { type: "array", items: { type: "string" }, description: "Slugs of in-batch tasks this one depends on (its base is one of them). Empty array for independent tasks — required, never omitted, so a forgotten dependency cannot silently unblock a dependent." },
            upstream: { type: "string", description: "Short note on what an in-batch dependency introduced, or empty." },
          },
          required: ["slug", "path", "content", "branch", "base", "dependsOn"],
        },
      },
    },
  },
  required: ["defaultBase", "waves"],
};

const VERDICT_SCHEMA = {
  type: "object",
  properties: {
    pass: { type: "boolean", description: "True only if every acceptance criterion is met, the build passes, and there are no material quality issues." },
    issues: {
      type: "array",
      description: "Numbered, actionable findings when pass is false. Empty when pass is true.",
      items: {
        type: "object",
        properties: {
          category: { type: "string", description: "criteria-gap | logic | error-handling | edge-case | dead-code | consistency | duplication | types" },
          location: { type: "string", description: "file:line of the gap." },
          problem: { type: "string", description: "What is wrong." },
          fix: { type: "string", description: "What should change instead." },
        },
        required: ["category", "location", "problem", "fix"],
      },
    },
    emptyDiffFlag: { type: "boolean", description: "True if `git diff --name-only <base>...HEAD` looked empty despite an expected implementation — signals a race/wrong-worktree, not real absence." },
    notes: { type: "string", description: "Caveats worth carrying into the PR body (tradeoffs, intentional divergences)." },
  },
  required: ["pass", "issues"],
};

const PR_SCHEMA = {
  type: "object",
  properties: {
    opened: { type: "boolean", description: "True ONLY if `gh pr create` succeeded and a PR URL exists." },
    url: { type: "string", description: "The created PR URL when opened is true." },
    pushed: { type: "boolean", description: "Whether the branch was pushed to the remote." },
    reason: { type: "string", description: "When opened is false: why (no remote auth, gh error, branch-target failure). Empty when opened." },
  },
  required: ["opened", "pushed"],
};

const COLLISION_SCHEMA = {
  type: "object",
  properties: {
    collisions: {
      type: "array",
      description: "Each entry is one newly-added surface that two or more INDEPENDENT sibling branches created on their own — a likely add/add clash (or duplicate definition) when the branches linearize. Empty array when none.",
      items: {
        type: "object",
        properties: {
          kind: { type: "string", description: "path | filename | symbol — a duplicated repo-relative path, a duplicated basename at different paths, or a duplicated exported top-level name (class/function/const/interface/type/enum)." },
          name: { type: "string", description: "The colliding value: the repo-relative path, the basename, or the symbol name." },
          branches: { type: "array", items: { type: "string" }, description: "The two or more branches that each independently added it." },
          detail: { type: "string", description: "One actionable line for the integrator (e.g. 'both define class PaymentReconciliationController — rename one side and regen contracts')." },
        },
        required: ["kind", "name", "branches"],
      },
    },
  },
  required: ["collisions"],
};

const RESOLUTION_SCHEMA = {
  type: "object",
  properties: {
    resolutions: {
      type: "array",
      description: "One entry per collision from the scan: how it was deconflicted (which side renamed, to what) or that the shared name is imperative and the collision is blocked for a human.",
      items: {
        type: "object",
        properties: {
          collision: { type: "string", description: "The exact `name` of the collision (from the guard's list) this entry resolves." },
          action: { type: "string", description: "renamed | blocked. `renamed` = a side was renamed, regenerated, and committed; `blocked` = the name must stay identical and cannot be changed without a design decision." },
          changedBranches: { type: "array", items: { type: "string" }, description: "Branches actually modified + committed by this resolution (each is re-reviewed before delivery). Empty when blocked." },
          from: { type: "string", description: "The original colliding name/path. Empty when blocked." },
          to: { type: "string", description: "The new name/path on the renamed side(s). Empty when blocked." },
          regenerated: { type: "string", description: "Derived files regenerated after the rename (e.g. 'contracts'), or empty if none." },
          reason: { type: "string", description: "Why that side was chosen to rename, why multiple sides were renamed, or why the collision is blocked." },
        },
        required: ["collision", "action", "changedBranches"],
      },
    },
  },
  required: ["resolutions"],
};

function bootstrapPrompt() {
  return `Prepare this container for a worktree-isolated task batch. This is setup only — edit no project files.

1. From the repo root, run \`wt-bootstrap\` (an image-baked helper on PATH). It performs the whole Session Bootstrap deterministically: verifies the worktree roots are container-local (never the host bind mount), prunes ONLY this container's orphaned worktrees under \`.worktrees/$CONTAINER_NAME/\`, sets up the container-local SSH→HTTPS remote rewrite, probes push access, and prints one JSON object.
2. Map that JSON onto the structured result verbatim — \`ok\`, \`blocker\`, \`wtBase\`, \`remote\`, \`availBytes\` — with no reinterpretation. \`remote: false\` is NOT a blocker (the batch falls back to local branches and skips PRs).
3. If \`wt-bootstrap\` is not on PATH, the image predates it: return \`ok: false\` with blocker \`"image predates the wt-* helpers; rebuild the powbox image and relaunch"\`. Do not re-derive the checks by hand.
4. On \`ok: false\` from the script, return its \`blocker\` verbatim (typical remedies it names: set CONTAINER_NAME, run \`enable-worktrees\`, rebuild/relaunch).`;
}

function resolvePrompt(input) {
  return `You are scoping a batch of pre-planned task files for implementation. Do NOT implement anything.

Read \`AGENTS.md\` / \`CLAUDE.md\` first for project conventions.

Argument (a glob or file list): ${JSON.stringify(input)}

Do this:
1. Resolve the argument to the concrete set of task files and read each one in full.
2. Determine dependencies: an explicit "Depends on" field, shared infrastructure, or files/modules two tasks both create or migrate. When in doubt, treat tasks that touch the same files or migrations as dependent.
3. Group tasks into WAVES: wave 1 is every task with no unmet dependency; wave 2 depends only on wave 1; and so on. Tasks within a wave are independent and will run concurrently.
4. For each task set:
   - a ref-safe \`slug\` (task number + short name; also its worktree dir name),
   - a \`branch\` to implement on,
   - a \`base\`: the user's explicit base (if given) else the current branch for independent tasks; for a dependent task, the \`branch\` of the dependency it most directly extends (stacked PRs),
   - \`dependsOn\`: the slugs of in-batch tasks it depends on (the task(s) whose branch is its base), or empty,
   - \`upstream\`: a one-line note on what an in-batch dependency introduced, if any.
5. Set \`defaultBase\` to the user's explicit base override, else the current checked-out branch, else \`main\`.

Return the structured plan. Paste each task file's FULL content verbatim into \`content\` — downstream agents have no other access to it.`;
}

// Shell-quote a ref/slug before embedding it in a copy-paste command these
// prompts emit. `slug`/`branch`/`base` come from the plan agent's reading of
// task files, so a stray space or shell metacharacter (a git ref name forbids
// spaces but little else) could push/PR the wrong ref or run the rest of the
// line. Single-quote and escape embedded quotes; adjacent quoted spans like
// `'a'..'b'` concatenate into one shell word, so `base..branch` still works.
function shq(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

function worktreeContract(task, { mayCreate = false } = {}) {
  // wt-enter encodes the rerun-safe lifecycle (reuse the existing worktree,
  // attach an existing branch, create off the base) so prompts never re-derive
  // it. Stages that must not create work (reviewer, PR) omit the base: a
  // missing branch then errors instead of silently checking out an empty tree.
  const enter = mayCreate
    ? `WT="$(wt-enter ${shq(task.slug)} ${shq(task.branch)} ${shq(task.base)})" && cd "$WT"`
    : `WT="$(wt-enter ${shq(task.slug)} ${shq(task.branch)})" && cd "$WT"`;
  return `## WORKTREE CONTRACT (do this before anything else)

Resolve your worktree with the image-baked helper and \`cd\` into it:

    ${enter}

\`wt-enter\` is rerun-safe: it reuses this task's existing worktree (prior commits intact)${mayCreate ? `, attaches the existing branch \`${task.branch}\` if its worktree is gone, or creates the branch off \`${task.base}\` if neither exists yet` : ` or re-attaches the existing branch \`${task.branch}\`; it deliberately CANNOT create the branch for this stage — if it errors that the branch does not exist, the implementation is missing`}. If the command fails, STOP and report its error verbatim — never improvise your own \`git worktree add\` or \`git switch\`.

Then verify: \`git rev-parse --show-toplevel\` prints exactly \`$WT\` and \`git branch --show-current\` prints \`${task.branch}\`. If either is wrong, STOP and report.
Do ALL work inside WT only. Never \`cd\` to the repo root or touch sibling worktrees — other agents are working in their own worktrees concurrently.`;
}

function implementPrompt(task, round, findings, remote) {
  const fixup = round > 1 && findings
    ? `\n## Reviewer findings to address (round ${round})\n\nThe worktree already holds your prior commits. Address each finding specifically and report what you fixed:\n\n${JSON.stringify(findings, null, 2)}\n`
    : "";
  const upstream = task.upstream ? `\n## Upstream context\n\n${task.upstream}\n` : "";
  const pushLine = remote
    ? `- After every commit, push for durability: \`git push -u origin ${shq(task.branch)}\` first, \`git push\` thereafter. The reviewer reads your worktree directly, so a transient push failure is not fatal — keep committing and note it — but pushed commits are the backup if the worktree is lost.`
    : `- Remote push is unavailable this run; commit locally (the shared \`.git\` persists). Do not fail on missing push.`;
  return `You are implementing a single task on branch \`${task.branch}\` (base \`${task.base}\`).

${worktreeContract(task, { mayCreate: true })}

Read \`AGENTS.md\` / \`CLAUDE.md\` first for project conventions. The base branch already contains any dependency's work — build on it.
${upstream}
## Task

${task.content}
${fixup}
## Instructions

- Implement the task to its description and acceptance criteria.
- Commit at logical milestones; keep each commit buildable where practical.
${pushLine}
- Run the project build/lint periodically and a full build check before reporting done.
- Do not revert unrelated edits.
- Do NOT use the \`TaskCreate\`/\`TaskUpdate\`/\`TaskList\` tools.
- When done, report: what you implemented, any decisions/tradeoffs/deviations, and anything that warrants focused review.`;
}

function reviewPrompt(task) {
  return `You are reviewing a task implementation with fresh eyes — no knowledge of how it was built. Evaluate two orthogonal dimensions: (1) acceptance-criteria compliance and (2) implementation quality. Edit NOTHING; only read, search, and run validation.

${worktreeContract(task)}

Read \`AGENTS.md\` / \`CLAUDE.md\` first for conventions. The implementation is already committed on \`${task.branch}\` in WT — read the actual files. If \`git diff --name-only ${shq(task.base)}...HEAD\` looks empty, set \`emptyDiffFlag\` true and stop — that signals a wrong worktree/branch, not real absence.

## Task

${task.content}

## How to review

1. Run a full build / type-check first. A failure is an automatic blocker (\`pass: false\`).
2. List touched files with \`git diff --name-only ${shq(task.base)}...HEAD\` to scope your quality pass. Do NOT read commit messages or \`git diff\` content — read each touched file in full. Follow references into untouched files when needed.
3. Check each acceptance criterion against the actual code.
4. Quality pass over the touched files: logic correctness, error handling, edge cases, dead code, consistency, duplication, type safety.
5. Be strict but fair — flag real gaps and functional problems, not style nits. Do not write follow-up task files.

Return \`pass: true\` only if every criterion is met, the build passes, and there are no material issues; otherwise \`pass: false\` with numbered, actionable \`issues\`. Put PR-worthy caveats in \`notes\`.`;
}

function prPrompt(task, notes, remote) {
  if (!remote) {
    return `Remote push/PR is unavailable this run. Verify branch \`${task.branch}\` and its commits are intact: \`WT="$(wt-enter ${shq(task.slug)} ${shq(task.branch)})" && git -C "$WT" log --oneline ${shq(task.base)}..${shq(task.branch)}\` shows the work. Return \`opened: false\`, \`pushed: false\`, \`reason: "no remote auth this run"\`. Do not fail.`;
  }
  const caveats = notes ? `\n\nReviewer caveats to surface in the PR body:\n${notes}` : "";
  return `Open a pull request for branch \`${task.branch}\` against base \`${task.base}\`. Work from this task's worktree: \`WT="$(wt-enter ${shq(task.slug)} ${shq(task.branch)})" && cd "$WT"\` (rerun-safe resolve of the existing worktree; if it errors, STOP and report).

1. Ensure the branch is pushed: \`git push -u origin ${shq(task.branch)}\` (or \`git push\`).
2. \`gh pr create --base ${shq(task.base)} --head ${shq(task.branch)} --title "<concise title>" --body "<summary>"\`.
   - Reference the task file (${task.path}); don't restate the whole task unless it adds review value.
   - Note tradeoffs / intentional divergences / uncertainties.${caveats}

Return \`opened: true\` with the \`url\` ONLY if \`gh pr create\` actually produced a PR URL. If the push succeeded but the PR could not be created (auth, API, or base-branch error), return \`opened: false\`, \`pushed: true\`, and \`reason\`. Do not claim a PR that was not created.`;
}

function cleanupNote(task) {
  // Best-effort worktree removal is requested after delivery; commits and the
  // branch persist in shared `.git` and on the remote, so removal is safe.
  return `Remove this task's worktree to reclaim space — the branch and commits persist. From the repo root (not inside the worktree) run \`wt-remove ${shq(task.slug)}\`. It refuses to delete uncommitted work; if it refuses, report why instead of forcing (\`--force\` only clears git's refusal over ignored build artifacts — the clean checks still apply). It never deletes the branch \`${task.branch}\`. Report done.`;
}

function collisionScanPrompt(branches) {
  const list = branches
    .map((b) => `- slug ${b.slug}: branch ${JSON.stringify(b.branch)} diverged from base ${JSON.stringify(b.base)}`)
    .join("\n");
  return `You are a read-only PRE-PR COLLISION GUARD for a batch of sibling task branches implemented in parallel, each reviewed and ready for its own PR. Edit, stage, commit, or push NOTHING. Work from the repo ROOT; do not enter or create any worktree — these branches live in the shared \`.git\` and you compare them by ref.

Why this exists: independent siblings never conflict while they are implemented (each in its own worktree), so two of them can each ADD the same new file path — or a file with the same basename, or a file that exports the same top-level class/symbol — with no warning. The clash only surfaces later, when the branches linearize or merge (an add/add conflict, or a duplicate definition). Find those overlaps now so they can be reconciled before merge.

Branches:
${list}

Method:
1. For each branch, list ONLY the files it ADDED relative to its OWN base:
       git diff --diff-filter=A --name-only <base>...<branch>
   Use the three-dot form so the comparison is against the merge-base. A dependent branch built on a sibling will NOT re-list that sibling's files, so legitimate stacking is never flagged.
2. Report a collision when, across two or more DIFFERENT branches:
   - the same repo-relative path was added (kind \`path\`), OR
   - the same basename was added at different paths (kind \`filename\`), OR
   - two added source files (sharing a basename, or clearly the same kind of module) declare the same exported top-level name — class/function/const/interface/type/enum (kind \`symbol\`). Open ONLY those candidate files to confirm; keep it cheap.
3. For each collision give the colliding value, the 2+ branches that added it, and a one-line reconciliation hint. In \`branches\`, use the exact branch strings from the Branches list without shell quote characters.

Flag only genuine overlaps between independently-based branches; never flag a file a branch merely inherited from its base. If nothing overlaps, return an empty \`collisions\` array.`;
}

function normalizeBranchName(s) {
  const value = String(s || "").trim();
  if (value.length >= 2) {
    const first = value[0];
    const last = value[value.length - 1];
    if ((first === "'" && last === "'") || (first === '"' && last === '"')) {
      return value.slice(1, -1);
    }
  }
  return value;
}

function collisionBranchNames(collision) {
  return Array.isArray(collision.branches)
    ? collision.branches.map(normalizeBranchName).filter(Boolean)
    : [];
}

function resolveCollisionsPrompt(tasks, waveCollisions, remote) {
  const taskList = tasks
    .map(
      (t) =>
        `- slug ${JSON.stringify(t.slug)}: branch ${JSON.stringify(t.branch)} (base ${JSON.stringify(t.base)})\n      enter its worktree with: WT="$(wt-enter ${shq(t.slug)} ${shq(t.branch)})" && cd "$WT"`
    )
    .join("\n");
  const collisionList = JSON.stringify(waveCollisions, null, 2);
  const pushLine = remote
    ? "Push each rename for durability and so the PR carries it: `git push` (the implement loop already set the upstream)."
    : "Remote push is unavailable this run; commit locally — the shared `.git` persists.";
  return `You are the orchestrator's deputy DECONFLICTING add/add naming collisions between sibling task branches built in parallel. Each branch already passed review on its own, but the pre-PR scan found that two or more INDEPENDENTLY added the same new file path, basename, or exported top-level symbol — which will clash (an add/add conflict, or a duplicate definition) when the branches merge. You decide how to deconflict, and you carry it out.

Each held branch's commits persist in the shared \`.git\`; its worktree may have been reclaimed after review to bound disk use. For each branch you CHANGE, \`cd\` into its worktree using the exact, ready-to-run \`wt-enter\` command listed for that branch under "Held branches" below — its slug and branch are already shell-quoted there because a generated/task-derived branch name can contain shell metacharacters (\`$\`, backticks, \`;\`). NEVER hand-substitute a raw \`<branch>\` into \`wt-enter\` — copy the listed command verbatim. No base argument is needed: the branch already exists and \`wt-enter\` is rerun-safe, re-attaching the worktree if it was reclaimed.

If \`wt-enter\` errors, STOP and report it. Verify \`git rev-parse --show-toplevel\` is that worktree and \`git branch --show-current\` is that branch before editing. Touch ONLY the worktree of the branch you are changing; never edit a sibling's worktree. Read \`AGENTS.md\` / \`CLAUDE.md\` for the project's regen and build commands.

Held branches:
${taskList}

Collisions to resolve (from the read-only scan; \`name\` is the colliding value):
${collisionList}

For each collision:
1. Pick the side(s) to change. There is no inherent "first", so choose the LEAST disruptive rename(s): branches with fewer references, not a path a framework mandates, not a name a task file pins. Read the colliding files on each branch first. Rename enough sides that AT MOST ONE branch keeps the original colliding path/basename/symbol. With a two-branch collision, renaming one side is normally enough and the other then delivers unchanged; with three or more branches, you may need to rename multiple sides.
2. If the name is genuinely IMPERATIVE — it MUST stay identical (a framework-required filename, an external/published contract, or a name a task file explicitly mandates) — do NOT invent a divergent name. Mark the collision \`blocked\` with the reason and leave those branches untouched; a human decides. Blocking a real conflict beats shipping a wrong rename.
3. Otherwise, on EACH branch you chose to change, rename the file and/or exported symbol plus every in-branch reference to it, to a clear name that is distinct from the original AND from any other renamed side — so two renamed branches cannot themselves re-collide on the new name. Regenerate anything derived from it (e.g. contracts). Run the project build / type-check — it MUST pass. Commit with a clear message. ${pushLine}
4. Record the outcome with \`collision\` set to the exact \`name\` from the list above: \`renamed\` (with \`changedBranches\`, \`from\`, \`to\`, what you \`regenerated\`, and why that side) or \`blocked\` (with the reason; empty \`changedBranches\`).

Do NOT open any PR and do NOT remove any worktree — the workflow re-reviews each changed branch and handles delivery. Return one resolution entry per collision.`;
}

async function implementTask(task, remote) {
  let findings = null;
  let verdict = null;
  let rounds = 0;

  for (let round = 1; round <= MAX_ROUNDS; round++) {
    rounds = round;

    const report = await agent(implementPrompt(task, round, findings, remote), {
      label: `implement:${task.slug}#${round}`,
    });
    if (!report) {
      return { slug: task.slug, branch: task.branch, status: "error", detail: `implementer failed on round ${round}` };
    }

    // Sequential await + a SHARED on-disk worktree: the implementer has fully
    // finished and committed in WT before the reviewer cd's into the same WT, so
    // the reviewer always sees the commits. Cross-task concurrency comes from
    // parallel() over distinct WTs, not from per-agent runtime isolation.
    verdict = await agent(reviewPrompt(task), {
      label: `review:${task.slug}#${round}`,
      schema: VERDICT_SCHEMA,
    });
    if (!verdict) {
      return { slug: task.slug, branch: task.branch, status: "error", detail: `reviewer failed on round ${round}` };
    }
    if (verdict.emptyDiffFlag) {
      return { slug: task.slug, branch: task.branch, status: "error", detail: `reviewer saw an empty diff on round ${round} (likely wrong worktree/branch)` };
    }
    if (verdict.pass) break;
    findings = verdict.issues;
  }

  if (!verdict || !verdict.pass) {
    // Leave the worktree for inspection on a cap-out; commits are durable.
    return { slug: task.slug, branch: task.branch, status: "review-cap", rounds, outstanding: verdict ? verdict.issues : null };
  }

  // Reviewed and ready, but not delivered yet: the wave-level collision guard
  // runs before any PR is opened or worktree is cleaned up.
  return { slug: task.slug, branch: task.branch, status: "ready", rounds, notes: verdict.notes || "" };
}

async function deliverTask(task, ready, remote) {
  const pr = await agent(prPrompt(task, ready.notes, remote), {
    label: `pr:${task.slug}`,
    schema: PR_SCHEMA,
  });

  // Best-effort cleanup once the work is durable (pushed/committed).
  await agent(cleanupNote(task), { label: `cleanup:${task.slug}` });

  if (pr && pr.opened && pr.url) {
    return { slug: task.slug, branch: task.branch, status: "done", rounds: ready.rounds, prUrl: pr.url };
  }
  // Reviewed and (usually) pushed, but no PR — do NOT count this as a landed PR.
  return {
    slug: task.slug,
    branch: task.branch,
    status: remote ? "pushed-no-pr" : "local-only",
    rounds: ready.rounds,
    pushed: pr ? pr.pushed : false,
    reason: pr ? pr.reason : "PR agent returned nothing",
  };
}

phase("Bootstrap");
const boot = await agent(bootstrapPrompt(), { label: "bootstrap", schema: BOOTSTRAP_SCHEMA });
if (!boot || !boot.ok) {
  return { error: "Worktree bootstrap failed; batch not started.", blocker: boot ? boot.blocker : "(agent returned nothing)" };
}
// `remote` is optional in BOOTSTRAP_SCHEMA (only `ok` is required), so a
// schema-valid response can omit it. Treat remote as available ONLY when
// explicitly true: pushing and opening PRs are outward side effects, so a
// missing/undefined probe result must fall back to local-branch-only rather
// than silently attempt a publish.
const remote = boot.remote === true;

phase("Resolve batch");
const plan = await agent(resolvePrompt(args), { label: "resolve", schema: PLAN_SCHEMA });
if (!plan || !Array.isArray(plan.waves) || plan.waves.length === 0) {
  return { error: "Could not resolve any task files from the argument.", args };
}

// Track each task's terminal status so dependent waves can be gated.
const statusBySlug = new Map();
const results = [];
const throttled = [];
const collisions = [];

// Map every in-batch branch to the slug that produces it. A dependent task's
// `base` IS its prerequisite's `branch` (stacked PRs), so this lets the gate
// derive the prerequisite structurally instead of trusting only the plan
// agent's `dependsOn` list — a forgotten entry can no longer slip a dependent
// past a failed prerequisite and have it build on known-bad work. Independent
// tasks base off `defaultBase` / the current branch, which no in-batch task
// produces, so they pick up no spurious dependency.
const slugByBranch = new Map();
for (const wave of plan.waves) {
  if (!Array.isArray(wave)) continue;
  for (const task of wave) {
    if (task && typeof task.branch === "string" && typeof task.slug === "string") {
      slugByBranch.set(task.branch, task.slug);
    }
  }
}

// Wave width: dependency-derived size, capped by MAX_WAVE_WIDTH and by storage
// headroom measured at bootstrap (finish over fan-out — see the constants).
const availBytes = typeof boot.availBytes === "number" ? boot.availBytes : 0;
const storageCap = availBytes > 0 ? Math.max(1, Math.floor(availBytes / PER_WORKTREE_BYTES)) : MAX_WAVE_WIDTH;
const widthCap = Math.min(MAX_WAVE_WIDTH, storageCap);

for (let w = 0; w < plan.waves.length; w++) {
  const wave = plan.waves[w];
  if (!Array.isArray(wave) || wave.length === 0) continue;

  // Dependency gating: a task whose in-batch dependency did not finish
  // successfully must NOT run — it would branch from a missing/partial/rejected
  // prerequisite. A dependency is "succeeded" if it landed a PR (`done`) OR, on a
  // no-remote run, was implemented and reviewed locally (`local-only`): its base
  // branch and commits persist in the shared `.git`, so dependents can still
  // build on it. `error`/`review-cap`/`skipped-dep`/`pushed-no-pr`,
  // `collision-hold`, `collision-blocked`, and `collision-scan-error` do not unlock.
  // Effective deps = the declared `dependsOn` UNION the prerequisite derived from
  // the `base`→`branch` relationship, so the gate holds even if the plan agent
  // omits a `dependsOn` entry it should have listed.
  const succeeded = (s) => s === "done" || s === "local-only";
  const runnable = [];
  for (const task of wave) {
    const deps = new Set(Array.isArray(task.dependsOn) ? task.dependsOn : []);
    const baseDep = slugByBranch.get(task.base);
    if (baseDep && baseDep !== task.slug) deps.add(baseDep);
    const failedDep = [...deps].find((d) => !succeeded(statusBySlug.get(d)));
    if (failedDep) {
      const r = { slug: task.slug, branch: task.branch, status: "skipped-dep", blockedBy: failedDep, depStatus: statusBySlug.get(failedDep) || "missing" };
      statusBySlug.set(task.slug, "skipped-dep");
      results.push(r);
    } else {
      runnable.push(task);
    }
  }
  if (runnable.length === 0) continue;

  phase(`Wave ${w + 1} (${runnable.length} task${runnable.length === 1 ? "" : "s"})`);
  if (runnable.length > widthCap) {
    log(`Throttling wave ${w + 1} to ${widthCap} concurrent task(s) (cap ${MAX_WAVE_WIDTH}, storage allows ${storageCap}).`);
    throttled.push({ wave: w + 1, tasks: runnable.length, width: widthCap });
  }
  // Sub-batch the wave at the width cap: a wave that exhausts the .worktrees
  // mount mid-flight delivers nothing. But the pre-PR collision scan must compare
  // EVERY reviewed branch before any delivery, so — unlike the old per-task flow
  // that delivered and `wt-remove`d each task as it finished — delivery is now
  // deferred to after the whole wave is scanned. Left unmanaged, that would let
  // reviewed worktrees from earlier slices pile up while later slices run,
  // re-introducing the ENOSPC the sub-batching exists to prevent. So reclaim each
  // finished slice's reviewed worktrees right here: the branch refs persist in
  // the shared `.git`, the scan compares by ref (it never enters a worktree), and
  // the resolver, re-review, and delivery each re-attach on demand via `wt-enter`
  // — keeping the live worktree count bounded by the cap. Only when the wave is
  // actually sub-batched; a single-slice wave already fits the cap, so reclaiming
  // it just to re-attach for delivery would be pure churn.
  const ready = [];
  const subBatched = runnable.length > widthCap;
  for (let i = 0; i < runnable.length; i += widthCap) {
    const slice = runnable.slice(i, i + widthCap);
    const sliceResults = await parallel(slice.map((task) => () => implementTask(task, remote)));
    const sliceReady = [];
    sliceResults.forEach((r, j) => {
      const res = r || { slug: slice[j].slug, branch: slice[j].branch, status: "error", detail: "task crashed" };
      if (res.status === "ready") {
        const entry = { task: slice[j], result: res };
        ready.push(entry);
        sliceReady.push(entry);
      } else {
        statusBySlug.set(res.slug, res.status);
        results.push(res);
      }
    });
    if (subBatched && sliceReady.length) {
      await parallel(sliceReady.map(({ task }) => () => agent(cleanupNote(task), { label: `reclaim:${task.slug}` })));
    }
  }

  // Pre-PR collision guard. Independent sibling branches in this wave each live
  // in their own worktree, so two can ADD the same new file or exported symbol
  // with no in-worktree conflict. Scan reviewed branches before delivery so a
  // known clash does not become a fresh PR that immediately needs a rename.
  let heldBranches = new Set();
  let scanError = "";
  if (ready.length >= 2) {
    phase(`Collision scan (wave ${w + 1})`);
    const scan = await agent(
      collisionScanPrompt(ready.map(({ task }) => ({ slug: task.slug, branch: task.branch, base: task.base || plan.defaultBase }))),
      { label: `collision-scan:w${w + 1}`, schema: COLLISION_SCHEMA }
    );
    if (!scan || !Array.isArray(scan.collisions)) {
      scanError = `collision scan failed for wave ${w + 1}; holding reviewed branches before PR delivery`;
      log(scanError);
    } else if (scan.collisions.length) {
      collisions.push(...scan.collisions.map((c) => ({ ...c, wave: w + 1 })));
      heldBranches = new Set(scan.collisions.flatMap(collisionBranchNames));
      log(`${scan.collisions.length} cross-branch naming collision(s) in wave ${w + 1}; holding ${heldBranches.size} branch(es) before PR delivery.`);
    }
  }

  // Partition the wave's reviewed branches: clean ones are deliverable; ones the
  // scan flagged go to resolution; a scan failure holds everything it covered.
  const deliverable = [];
  const heldTasks = [];
  ready.forEach(({ task, result }) => {
    if (scanError) {
      const held = {
        slug: task.slug,
        branch: task.branch,
        status: "collision-scan-error",
        rounds: result.rounds,
        detail: scanError,
      };
      statusBySlug.set(task.slug, held.status);
      results.push(held);
    } else if (heldBranches.has(task.branch) || heldBranches.has(task.slug)) {
      heldTasks.push({ task, result });
    } else {
      deliverable.push({ task, result });
    }
  });

  // Collision resolution. Neither side of an add/add clash is inherently "first",
  // so a single orchestrator-deputy agent — seeing every held branch and its
  // worktree, still in place — decides which side to rename and does it: rename
  // the file/symbol, regenerate derived files, commit, push. A name that MUST
  // stay identical (framework-mandated, externally fixed, or pinned by a task
  // file) is reported `blocked` instead of getting an invented divergent name.
  // Each branch the resolver CHANGED is then re-reviewed fresh (one pass) before
  // it may deliver; the unchanged side of a resolved clash delivers as-is; a
  // blocked, unresolved, or re-review-failed branch stays held for a human.
  if (heldTasks.length) {
    const waveCollisions = collisions.filter((c) => c.wave === w + 1);
    const relatedFor = (task) =>
      waveCollisions.filter((c) => {
        const names = collisionBranchNames(c);
        return names.includes(task.branch) || names.includes(task.slug);
      });

    phase(`Collision resolve (wave ${w + 1})`);
    const resolution = await agent(
      resolveCollisionsPrompt(
        heldTasks.map(({ task }) => ({ slug: task.slug, branch: task.branch, base: task.base || plan.defaultBase })),
        waveCollisions,
        remote
      ),
      { label: `collision-resolve:w${w + 1}`, schema: RESOLUTION_SCHEMA }
    );
    const resolutions = resolution && Array.isArray(resolution.resolutions) ? resolution.resolutions : null;

    // Index the resolver's outcome by branch and by collision name. A collision
    // is actually resolved only when enough involved branches were changed that
    // at most one branch still carries the original colliding value. This matters
    // for 3+ branch clashes: renaming one side leaves the other two still
    // colliding, so those unchanged branches must stay held.
    const changedBranches = new Set();
    const changedBranchesByCollision = new Map();
    const blockedNames = new Set();
    if (resolutions) {
      for (const r of resolutions) {
        const changed = Array.isArray(r.changedBranches) ? r.changedBranches.map(normalizeBranchName).filter(Boolean) : [];
        if (r.action === "renamed") {
          changed.forEach((n) => changedBranches.add(n));
          if (r.collision) {
            const existing = changedBranchesByCollision.get(r.collision) || new Set();
            changed.forEach((n) => existing.add(n));
            changedBranchesByCollision.set(r.collision, existing);
          }
        } else if (r.action === "blocked" && r.collision) {
          blockedNames.add(r.collision);
        }
      }
    }
    const collisionBlocked = (c) => blockedNames.has(c.name);
    // Only branches the resolver reported as changed FOR THIS collision count
    // toward resolving it. An earlier version also credited any branch in the
    // global `changedBranches` set, to guard against a resolver that mistypes the
    // collision echo — but that is unsound when a branch sits in more than one
    // collision: renaming branch B to fix an A/B path clash would also mark B
    // "changed" for an unrelated B/C symbol clash, dropping that clash to a single
    // remaining branch and letting B and C both deliver while still colliding. A
    // mis-echoed rename now conservatively leaves the branch held (for a manual
    // pass / re-scan) instead — matching this guard's bias that holding a real
    // conflict beats shipping a wrong delivery.
    const changedForCollision = (c) => new Set(changedBranchesByCollision.get(c.name) || []);
    const remainingForCollision = (c) => {
      const changed = changedForCollision(c);
      return collisionBranchNames(c).filter((n) => !changed.has(n));
    };
    const collisionResolved = (c) => !collisionBlocked(c) && remainingForCollision(c).length <= 1;
    const collisionStillIncludes = (c, task) => {
      if (collisionBlocked(c)) return true;
      const names = collisionBranchNames(c);
      const participates = names.includes(task.branch) || names.includes(task.slug);
      if (!participates) return false;
      const changed = changedForCollision(c);
      if (changed.has(task.branch) || changed.has(task.slug)) return false;
      return remainingForCollision(c).length >= 2;
    };

    for (const { task, result } of heldTasks) {
      const related = relatedFor(task);
      const isChanged = changedBranches.has(task.branch) || changedBranches.has(task.slug);

      if (!resolutions) {
        const held = { slug: task.slug, branch: task.branch, status: "collision-hold", rounds: result.rounds, detail: "collision resolver returned no result; branch held before PR delivery — deconflict manually and re-review", collisions: related };
        statusBySlug.set(task.slug, held.status);
        results.push(held);
      } else if (related.some(collisionBlocked)) {
        // An imperative shared name still clashes even if this branch was also
        // touched — keep it held for a human/design decision.
        const held = { slug: task.slug, branch: task.branch, status: "collision-blocked", rounds: result.rounds, detail: "shared name must stay identical (imperative); resolver could not deconflict — needs a human/design decision", collisions: related };
        statusBySlug.set(task.slug, held.status);
        results.push(held);
      } else if (related.some((c) => collisionStillIncludes(c, task))) {
        const held = { slug: task.slug, branch: task.branch, status: "collision-hold", rounds: result.rounds, detail: "collision still has two or more unchanged branches after resolver ran; branch held before PR delivery — rename enough sides and re-review", collisions: related };
        statusBySlug.set(task.slug, held.status);
        results.push(held);
      } else if (isChanged) {
        // Fresh re-review of the rename — one pass; hold on failure rather than loop.
        const verdict = await agent(reviewPrompt(task), { label: `re-review:${task.slug}`, schema: VERDICT_SCHEMA });
        if (verdict && verdict.pass && !verdict.emptyDiffFlag) {
          deliverable.push({ task, result: { ...result, notes: verdict.notes || result.notes } });
        } else {
          const held = { slug: task.slug, branch: task.branch, status: "collision-hold", rounds: result.rounds, detail: "rename did not pass fresh re-review; held before PR delivery", outstanding: verdict ? verdict.issues : null, collisions: related };
          statusBySlug.set(task.slug, held.status);
          results.push(held);
        }
      } else if (related.every(collisionResolved)) {
        // Unchanged side of a clash the resolver fixed on the other branch.
        deliverable.push({ task, result });
      } else {
        // Resolver neither changed nor blocked this branch's clash — do not
        // re-introduce it by delivering; hold for a manual pass.
        const held = { slug: task.slug, branch: task.branch, status: "collision-hold", rounds: result.rounds, detail: "collision left unresolved by the resolver; branch held before PR delivery — deconflict manually and re-review", collisions: related };
        statusBySlug.set(task.slug, held.status);
        results.push(held);
      }
    }
  }

  for (let i = 0; i < deliverable.length; i += widthCap) {
    const slice = deliverable.slice(i, i + widthCap);
    const delivered = await parallel(slice.map(({ task, result }) => () => deliverTask(task, result, remote)));
    delivered.forEach((r, j) => {
      const res = r || { slug: slice[j].task.slug, branch: slice[j].task.branch, status: "error", detail: "delivery crashed" };
      statusBySlug.set(res.slug, res.status);
      results.push(res);
    });
  }
}

phase("Summary");
const landed = results.filter((r) => r.status === "done").length;
log(`Batch complete: ${landed}/${results.length} tasks landed a PR.`);
return { batch: args, defaultBase: plan.defaultBase, remote, waves: plan.waves.length, throttled, collisions, results };
