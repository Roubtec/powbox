/**
 * address-tasks — dynamic-workflow form of the `address-tasks` skill.
 *
 * Resolve a batch of pre-planned task files into dependency waves, then for each
 * task run an implement -> review -> fix loop (max 3 rounds), open a PR per
 * passing task, and report. Invoke as `/address-tasks <glob-or-file-list>`.
 *
 * Why a workflow rather than a skill
 * ----------------------------------
 * The skill's single biggest constraint is that every subagent shares the
 * orchestrator's one working tree, which forces strict one-agent-at-a-time
 * sequencing and an elaborate per-task worktree + shadow-mount bootstrap (the
 * whole reason `address-tasks-worktrees` exists) to claw parallelism back.
 *
 * The workflow runtime gives each spawned agent its own git worktree via
 * `isolation: "worktree"`, so independent tasks run concurrently with no
 * shared-tree corruption and no bootstrap. The control flow that the skill
 * spells out in prose — waves, the 3-round loop, the "implementer fully
 * finishes before its reviewer starts" rule — becomes ordinary JavaScript.
 * One workflow therefore supersedes BOTH `address-tasks` and
 * `address-tasks-worktrees`.
 *
 * Runtime notes (validate against the live runtime when promoting this):
 *  - The script itself cannot read files or run shell/git — every git, gh, and
 *    file operation happens inside a spawned agent. So a `resolve` agent reads
 *    the task files and returns their content; later agents receive that
 *    content as plain arguments.
 *  - There is no mid-run user input. A blocker is surfaced by returning a
 *    result object, never by pausing to ask — this is the skill's hands-off
 *    posture, made structural.
 *  - Per-task durability rides on push, not on the worktree: each agent pushes
 *    its branch so commits and the branch ref survive regardless of how the
 *    runtime recycles its worktree, and so a dependent wave can branch from the
 *    pushed ref.
 */

const MAX_ROUNDS = 3;

const PLAN_SCHEMA = {
  type: "object",
  properties: {
    defaultBase: {
      type: "string",
      description: "PR base branch for independent tasks (the user's override, else the current branch, else main).",
    },
    waves: {
      type: "array",
      description: "Tasks grouped into dependency waves; wave N runs only after wave N-1 has fully passed review.",
      items: {
        type: "array",
        items: {
          type: "object",
          properties: {
            slug: { type: "string", description: "Stable, ref-safe identifier for the task (e.g. task number + short name)." },
            path: { type: "string", description: "Path to the task file." },
            content: { type: "string", description: "Full verbatim content of the task file." },
            branch: { type: "string", description: "Branch the implementer should create and work on." },
            base: { type: "string", description: "Base branch to create from and target the PR against (a prior task's branch for dependents)." },
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
    emptyDiffFlag: { type: "boolean", description: "True if `git diff --name-only <base>...HEAD` looked empty despite an expected implementation — signals a race/wrong-branch, not real absence." },
    notes: { type: "string", description: "Caveats worth carrying into the PR body (tradeoffs, intentional divergences)." },
  },
  required: ["pass", "issues"],
};

function resolvePrompt(input) {
  return `You are scoping a batch of pre-planned task files for implementation. Do NOT implement anything.

Read \`AGENTS.md\` / \`CLAUDE.md\` first for project conventions.

Argument (a glob or file list): ${JSON.stringify(input)}

Do this:
1. Resolve the argument to the concrete set of task files and read each one in full.
2. Determine dependencies between tasks: an explicit "Depends on" field, shared infrastructure, or files/modules two tasks both create or migrate. When in doubt, treat tasks that touch the same files or migrations as dependent.
3. Group tasks into WAVES: wave 1 is every task with no unmet dependency; wave 2 depends only on wave 1; and so on. Tasks within a wave are independent and will run concurrently.
4. Assign each task:
   - a ref-safe \`slug\` (task number + short name),
   - a \`branch\` to implement on,
   - a \`base\`: the user's explicit base (if given) else the current branch for independent tasks; for a dependent task, the branch of the dependency it most directly extends (stacked PRs),
   - \`upstream\`: a one-line note on what an in-batch dependency introduced, if any.
5. Set \`defaultBase\` to the user's explicit base override, else the current checked-out branch, else \`main\`.

Return the structured plan. Paste each task file's FULL content verbatim into \`content\` — downstream agents have no other access to it.`;
}

function implementPrompt(task, round, findings) {
  const fixup = round > 1 && findings
    ? `\n## Reviewer findings to address (round ${round})\n\nAddress each of these specifically and report what you fixed:\n\n${JSON.stringify(findings, null, 2)}\n`
    : "";
  const upstream = task.upstream ? `\n## Upstream context\n\n${task.upstream}\n` : "";
  return `You are implementing a single task on branch \`${task.branch}\` (base \`${task.base}\`).

Read \`AGENTS.md\` / \`CLAUDE.md\` first for project conventions.

Branch setup: ensure \`${task.branch}\` exists off \`${task.base}\` and is checked out; confirm with \`git branch --show-current\`. The base branch already contains any dependency's work — build on it, do not recreate it.
${upstream}
## Task

${task.content}
${fixup}
## Instructions

- Implement the task to its description and acceptance criteria.
- Commit at logical milestones; keep each commit buildable where practical.
- After every commit, push: \`git push -u origin ${task.branch}\` on the first push, \`git push\` thereafter. Pushing is the durability guarantee — the workflow's worktree is disposable, but pushed commits and the branch ref survive and let later waves branch from this work. If a push fails (e.g. no remote auth), keep committing and note it.
- Run the project build/lint periodically and a full build check before reporting done.
- Do not revert unrelated or concurrent edits; other agents may be working on sibling tasks.
- Do NOT use the \`TaskCreate\`/\`TaskUpdate\`/\`TaskList\` tools.
- When done, report: what you implemented, any decisions/tradeoffs/deviations, and anything that warrants focused review.`;
}

function reviewPrompt(task) {
  return `You are reviewing a task implementation with fresh eyes — no knowledge of how it was built. Evaluate two orthogonal dimensions: (1) acceptance-criteria compliance and (2) implementation quality. Edit NOTHING; only read, search, and run validation.

Read \`AGENTS.md\` / \`CLAUDE.md\` first for conventions.

The implementation is already committed on branch \`${task.branch}\` (base \`${task.base}\`). Read the actual files. If \`git diff --name-only ${task.base}...HEAD\` looks empty, set \`emptyDiffFlag\` true and stop — that signals a race or wrong branch, not real absence; do not "review nothing".

## Task

${task.content}

## How to review

1. Run a full build / type-check first. A failure is an automatic blocker (\`pass: false\`).
2. List touched files with \`git diff --name-only ${task.base}...HEAD\` to scope your quality pass. Do NOT read commit messages or \`git diff\` content — read each touched file in full (diff-only review hides issues spanning the changed/unchanged boundary). Follow references into untouched files when needed.
3. Check each acceptance criterion against the actual code.
4. Quality pass over the touched files: logic correctness, error handling, edge cases, dead code, consistency, duplication, type safety.
5. Be strict but fair — flag real gaps and functional problems, not style nits. Do not write follow-up task files.

Return \`pass: true\` only if every criterion is met, the build passes, and there are no material issues; otherwise \`pass: false\` with numbered, actionable \`issues\`. Put PR-worthy caveats in \`notes\`.`;
}

function prPrompt(task, notes) {
  const caveats = notes ? `\n\nReviewer caveats to surface in the PR body:\n${notes}` : "";
  return `Open a pull request for branch \`${task.branch}\` against base \`${task.base}\`.

Run: \`gh pr create --base ${task.base} --head ${task.branch} --title "<concise title>" --body "<summary>"\`.

- Reference the task file (${task.path}) for context; do not restate the whole task unless it adds review value.
- Note tradeoffs / intentional divergences / uncertainties.${caveats}
- If the PR cannot be opened (e.g. no remote auth), ensure the branch and commits are pushed and report that the PR must be opened manually.

Report the PR URL (or "branch pushed, PR not opened: <reason>").`;
}

async function runTask(task) {
  let findings = null;
  let verdict = null;
  let rounds = 0;

  for (let round = 1; round <= MAX_ROUNDS; round++) {
    rounds = round;

    const report = await agent(implementPrompt(task, round, findings), {
      label: `implement:${task.slug}#${round}`,
      isolation: "worktree",
    });
    if (!report) {
      return { slug: task.slug, branch: task.branch, status: "error", detail: `implementer failed on round ${round}` };
    }

    // Sequential await: the implementer has fully finished and pushed before the
    // reviewer starts, so the reviewer never scans a half-written branch. Tasks
    // run concurrently with each other because runTask() invocations are driven
    // by parallel() and each agent is worktree-isolated.
    verdict = await agent(reviewPrompt(task), {
      label: `review:${task.slug}#${round}`,
      schema: VERDICT_SCHEMA,
      isolation: "worktree",
    });
    if (!verdict) {
      return { slug: task.slug, branch: task.branch, status: "error", detail: `reviewer failed on round ${round}` };
    }
    if (verdict.emptyDiffFlag) {
      return { slug: task.slug, branch: task.branch, status: "error", detail: `reviewer saw an empty diff on round ${round} (likely race/wrong-branch)` };
    }
    if (verdict.pass) break;
    findings = verdict.issues;
  }

  if (!verdict || !verdict.pass) {
    return { slug: task.slug, branch: task.branch, status: "review-cap", rounds, outstanding: verdict ? verdict.issues : null };
  }

  const pr = await agent(prPrompt(task, verdict.notes), {
    label: `pr:${task.slug}`,
    isolation: "worktree",
  });
  return { slug: task.slug, branch: task.branch, status: "done", rounds, pr };
}

phase("Resolve batch");
const plan = await agent(resolvePrompt(args), { label: "resolve", schema: PLAN_SCHEMA });
if (!plan || !Array.isArray(plan.waves) || plan.waves.length === 0) {
  return { error: "Could not resolve any task files from the argument.", args };
}

const results = [];
for (let w = 0; w < plan.waves.length; w++) {
  const wave = plan.waves[w];
  if (!Array.isArray(wave) || wave.length === 0) continue;
  phase(`Wave ${w + 1} (${wave.length} task${wave.length === 1 ? "" : "s"})`);
  const waveResults = await parallel(wave.map((task) => () => runTask(task)));
  waveResults.forEach((r, i) => {
    results.push(r || { slug: wave[i].slug, branch: wave[i].branch, status: "error", detail: "task crashed" });
  });
}

phase("Summary");
log(`Batch complete: ${results.filter((r) => r.status === "done").length}/${results.length} tasks landed a PR.`);
return { batch: args, defaultBase: plan.defaultBase, waves: plan.waves.length, results };
