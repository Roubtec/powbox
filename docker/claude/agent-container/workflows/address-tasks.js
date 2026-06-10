/**
 * address-tasks — dynamic-workflow form of the `address-tasks` skill.
 *
 * Resolve a batch of pre-planned task files into dependency waves, then for each
 * task run an implement -> review -> fix loop (max 3 rounds), open a PR per
 * passing task, and report. Invoke as `/address-tasks <glob-or-file-list>`.
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
            dependsOn: { type: "array", items: { type: "string" }, description: "Slugs of in-batch tasks this one depends on (its base is one of them). Empty for independent tasks." },
            upstream: { type: "string", description: "Short note on what an in-batch dependency introduced, or empty." },
          },
          required: ["slug", "path", "content", "branch", "base"],
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

function worktreeContract(task, { mayCreate = false } = {}) {
  // wt-enter encodes the rerun-safe lifecycle (reuse the existing worktree,
  // attach an existing branch, create off the base) so prompts never re-derive
  // it. Stages that must not create work (reviewer, PR) omit the base: a
  // missing branch then errors instead of silently checking out an empty tree.
  const enter = mayCreate
    ? `WT="$(wt-enter ${task.slug} ${task.branch} ${task.base})" && cd "$WT"`
    : `WT="$(wt-enter ${task.slug} ${task.branch})" && cd "$WT"`;
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
    ? `- After every commit, push for durability: \`git push -u origin ${task.branch}\` first, \`git push\` thereafter. The reviewer reads your worktree directly, so a transient push failure is not fatal — keep committing and note it — but pushed commits are the backup if the worktree is lost.`
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

Read \`AGENTS.md\` / \`CLAUDE.md\` first for conventions. The implementation is already committed on \`${task.branch}\` in WT — read the actual files. If \`git diff --name-only ${task.base}...HEAD\` looks empty, set \`emptyDiffFlag\` true and stop — that signals a wrong worktree/branch, not real absence.

## Task

${task.content}

## How to review

1. Run a full build / type-check first. A failure is an automatic blocker (\`pass: false\`).
2. List touched files with \`git diff --name-only ${task.base}...HEAD\` to scope your quality pass. Do NOT read commit messages or \`git diff\` content — read each touched file in full. Follow references into untouched files when needed.
3. Check each acceptance criterion against the actual code.
4. Quality pass over the touched files: logic correctness, error handling, edge cases, dead code, consistency, duplication, type safety.
5. Be strict but fair — flag real gaps and functional problems, not style nits. Do not write follow-up task files.

Return \`pass: true\` only if every criterion is met, the build passes, and there are no material issues; otherwise \`pass: false\` with numbered, actionable \`issues\`. Put PR-worthy caveats in \`notes\`.`;
}

function prPrompt(task, notes, remote) {
  if (!remote) {
    return `Remote push/PR is unavailable this run. Verify branch \`${task.branch}\` and its commits are intact: \`WT="$(wt-enter ${task.slug} ${task.branch})" && git -C "$WT" log --oneline ${task.base}..${task.branch}\` shows the work. Return \`opened: false\`, \`pushed: false\`, \`reason: "no remote auth this run"\`. Do not fail.`;
  }
  const caveats = notes ? `\n\nReviewer caveats to surface in the PR body:\n${notes}` : "";
  return `Open a pull request for branch \`${task.branch}\` against base \`${task.base}\`. Work from this task's worktree: \`WT="$(wt-enter ${task.slug} ${task.branch})" && cd "$WT"\` (rerun-safe resolve of the existing worktree; if it errors, STOP and report).

1. Ensure the branch is pushed: \`git push -u origin ${task.branch}\` (or \`git push\`).
2. \`gh pr create --base ${task.base} --head ${task.branch} --title "<concise title>" --body "<summary>"\`.
   - Reference the task file (${task.path}); don't restate the whole task unless it adds review value.
   - Note tradeoffs / intentional divergences / uncertainties.${caveats}

Return \`opened: true\` with the \`url\` ONLY if \`gh pr create\` actually produced a PR URL. If the push succeeded but the PR could not be created (auth, API, or base-branch error), return \`opened: false\`, \`pushed: true\`, and \`reason\`. Do not claim a PR that was not created.`;
}

function cleanupNote(task) {
  // Best-effort worktree removal is requested at the end of runTask; commits and
  // the branch persist in shared `.git` and on the remote, so removal is safe.
  return `Remove this task's worktree to reclaim space — the branch and commits persist. From the repo root (not inside the worktree) run \`wt-remove ${task.slug}\`. It refuses to delete uncommitted work; if it refuses, report why instead of forcing (\`--force\` only clears git's refusal over ignored build artifacts — the clean checks still apply). It never deletes the branch \`${task.branch}\`. Report done.`;
}

async function runTask(task, remote) {
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

  const pr = await agent(prPrompt(task, verdict.notes, remote), {
    label: `pr:${task.slug}`,
    schema: PR_SCHEMA,
  });

  // Best-effort cleanup once the work is durable (pushed/committed).
  await agent(cleanupNote(task), { label: `cleanup:${task.slug}` });

  if (pr && pr.opened && pr.url) {
    return { slug: task.slug, branch: task.branch, status: "done", rounds, prUrl: pr.url };
  }
  // Reviewed and (usually) pushed, but no PR — do NOT count this as a landed PR.
  return {
    slug: task.slug,
    branch: task.branch,
    status: remote ? "pushed-no-pr" : "local-only",
    rounds,
    pushed: pr ? pr.pushed : false,
    reason: pr ? pr.reason : "PR agent returned nothing",
  };
}

phase("Bootstrap");
const boot = await agent(bootstrapPrompt(), { label: "bootstrap", schema: BOOTSTRAP_SCHEMA });
if (!boot || !boot.ok) {
  return { error: "Worktree bootstrap failed; batch not started.", blocker: boot ? boot.blocker : "(agent returned nothing)" };
}
const remote = boot.remote !== false;

phase("Resolve batch");
const plan = await agent(resolvePrompt(args), { label: "resolve", schema: PLAN_SCHEMA });
if (!plan || !Array.isArray(plan.waves) || plan.waves.length === 0) {
  return { error: "Could not resolve any task files from the argument.", args };
}

// Track each task's terminal status so dependent waves can be gated.
const statusBySlug = new Map();
const results = [];
const throttled = [];

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
  // build on it. `error`/`review-cap`/`skipped-dep`/`pushed-no-pr` do not unlock.
  const succeeded = (s) => s === "done" || s === "local-only";
  const runnable = [];
  for (const task of wave) {
    const deps = Array.isArray(task.dependsOn) ? task.dependsOn : [];
    const failedDep = deps.find((d) => !succeeded(statusBySlug.get(d)));
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
  // Sub-batch the wave at the width cap: slower than full fan-out, but a wave
  // that exhausts the .worktrees mount mid-flight delivers nothing.
  for (let i = 0; i < runnable.length; i += widthCap) {
    const slice = runnable.slice(i, i + widthCap);
    const sliceResults = await parallel(slice.map((task) => () => runTask(task, remote)));
    sliceResults.forEach((r, j) => {
      const res = r || { slug: slice[j].slug, branch: slice[j].branch, status: "error", detail: "task crashed" };
      statusBySlug.set(res.slug, res.status);
      results.push(res);
    });
  }
}

phase("Summary");
const landed = results.filter((r) => r.status === "done").length;
log(`Batch complete: ${landed}/${results.length} tasks landed a PR.`);
return { batch: args, defaultBase: plan.defaultBase, remote, waves: plan.waves.length, throttled, results };
