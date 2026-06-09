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
 * So this workflow does its own worktree management exactly like the
 * `address-tasks-worktrees` skill: each task gets ONE explicit worktree under
 * `.worktrees/$CONTAINER_NAME/<slug>`, created by its first implementer and
 * REUSED by that task's reviewer and every later round (so the reviewer sees the
 * commits and no agent ever tries to re-check-out a branch already checked out).
 * Tasks run concurrently because each lives in its own worktree; an agent's
 * WORKTREE CONTRACT keeps it inside its own directory. Push is for durability;
 * cross-stage visibility comes from sharing the on-disk worktree, not the remote.
 *
 * Runtime notes:
 *  - The script itself cannot read files or run shell/git — every git, gh, and
 *    file operation happens inside a spawned agent.
 *  - There is no mid-run user input. A blocker is surfaced by returning a result
 *    object, never by pausing to ask.
 */

const MAX_ROUNDS = 3;

const BOOTSTRAP_SCHEMA = {
  type: "object",
  properties: {
    ok: { type: "boolean" },
    blocker: { type: "string", description: "Why the batch cannot proceed (worktree roots unsafe, CONTAINER_NAME unset). Empty when ok." },
    wtBase: { type: "string", description: "Absolute path to this container's worktree base, `<repo>/.worktrees/$CONTAINER_NAME`." },
    remote: { type: "boolean", description: "True if push/PR is available (gh auth + remote reachable); false means local-branch-only fallback." },
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
  return `Prepare this container for a worktree-isolated task batch. Read \`AGENTS.md\` / \`CLAUDE.md\` first. Set \`ok: false\` with a \`blocker\` on any unrecoverable problem.

1. Require \`CONTAINER_NAME\` to be set (\`<agent>-<project>\`, Docker-unique). If empty, blocker and stop.
2. Compute and return \`wtBase = "$(git rev-parse --show-toplevel)/.worktrees/$CONTAINER_NAME"\` and \`mkdir -p\` it.
3. Verify worktree roots are container-local, not the host bind mount: \`.worktrees\` must be a mountpoint on a container-local fs, and \`.claude/worktrees\` + \`.git/worktrees\` must be tmpfs. If a root is missing/unsafe, try \`shadow-refresh.sh "$(git rev-parse --show-toplevel)"\`; if it still fails, blocker and stop (the image predates worktree-shadow support — the user must run \`enable-worktrees\` then rebuild/relaunch). (This is the \`address-tasks-worktrees\` Session Bootstrap — use its exact checks.)
4. Prune ONLY this container's orphaned worktree dirs under \`$wtBase\` (a dir whose \`git rev-parse --is-inside-work-tree\` fails): \`git worktree prune\` then remove the dead dirs. Never scan the rest of the volume — a peer container's live worktrees live under its own \`$CONTAINER_NAME\` subdir.
5. Ensure pushes work without rewriting the host remote: if \`origin\` is SSH, \`git config --global url."https://github.com/".insteadOf "git@github.com:"\`, then \`git ls-remote --heads origin >/dev/null\`. Set \`remote: true\` on success; on failure set \`remote: false\` (the batch will fall back to local branches and skip PRs) — this is not a blocker.

Edit no project files; this is setup only.`;
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

function worktreeContract(task) {
  return `## WORKTREE CONTRACT (do this before anything else)

Your worktree is \`$(git rev-parse --show-toplevel)/.worktrees/\${CONTAINER_NAME:?CONTAINER_NAME must be set}/${task.slug}\` (call it WT).
- If WT does not exist yet: \`git worktree add "$WT" -b ${task.branch} ${task.base}\` (create the branch off its base).
- If WT already exists (a prior round/stage of this same task created it): just \`cd "$WT"\` — it is already on \`${task.branch}\` with the prior commits. Do NOT \`git worktree add\` again and do NOT \`git switch\` to a branch that may be checked out elsewhere.
Then \`cd "$WT"\` and verify \`git rev-parse --show-toplevel\` prints exactly WT and \`git branch --show-current\` prints \`${task.branch}\`. If either is wrong, STOP and report.
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

${worktreeContract(task)}

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

(The worktree already exists from the implementer — you take the "WT already exists" branch above: \`cd\` in, do not re-add.)

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
    return `Remote push/PR is unavailable this run. Ensure branch \`${task.branch}\` and its commits are intact in the worktree at \`$(git rev-parse --show-toplevel)/.worktrees/\${CONTAINER_NAME}/${task.slug}\` and in shared \`.git\`. Return \`opened: false\`, \`pushed: false\`, \`reason: "no remote auth this run"\`. Do not fail.`;
  }
  const caveats = notes ? `\n\nReviewer caveats to surface in the PR body:\n${notes}` : "";
  return `Open a pull request for branch \`${task.branch}\` against base \`${task.base}\`. Work from this task's worktree (\`cd "$(git rev-parse --show-toplevel)/.worktrees/\${CONTAINER_NAME}/${task.slug}"\`).

1. Ensure the branch is pushed: \`git push -u origin ${task.branch}\` (or \`git push\`).
2. \`gh pr create --base ${task.base} --head ${task.branch} --title "<concise title>" --body "<summary>"\`.
   - Reference the task file (${task.path}); don't restate the whole task unless it adds review value.
   - Note tradeoffs / intentional divergences / uncertainties.${caveats}

Return \`opened: true\` with the \`url\` ONLY if \`gh pr create\` actually produced a PR URL. If the push succeeded but the PR could not be created (auth, API, or base-branch error), return \`opened: false\`, \`pushed: true\`, and \`reason\`. Do not claim a PR that was not created.`;
}

function cleanupNote(task) {
  // Best-effort worktree removal is requested at the end of runTask; commits and
  // the branch persist in shared `.git` and on the remote, so removal is safe.
  return `Remove this task's worktree to reclaim space — the branch and commits persist. Run from the repo root (not inside the worktree): \`git worktree remove "$(git rev-parse --show-toplevel)/.worktrees/\${CONTAINER_NAME}/${task.slug}"\` (add \`--force\` only after confirming \`git status\` in it is clean). Do not delete the branch \`${task.branch}\`. Report done.`;
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

for (let w = 0; w < plan.waves.length; w++) {
  const wave = plan.waves[w];
  if (!Array.isArray(wave) || wave.length === 0) continue;

  // Dependency gating: a task whose in-batch dependency did not finish `done`
  // must NOT run — it would branch from a missing/partial/rejected prerequisite.
  const runnable = [];
  for (const task of wave) {
    const deps = Array.isArray(task.dependsOn) ? task.dependsOn : [];
    const failedDep = deps.find((d) => statusBySlug.get(d) !== "done");
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
  const waveResults = await parallel(runnable.map((task) => () => runTask(task, remote)));
  waveResults.forEach((r, i) => {
    const res = r || { slug: runnable[i].slug, branch: runnable[i].branch, status: "error", detail: "task crashed" };
    statusBySlug.set(res.slug, res.status);
    results.push(res);
  });
}

phase("Summary");
const landed = results.filter((r) => r.status === "done").length;
log(`Batch complete: ${landed}/${results.length} tasks landed a PR.`);
return { batch: args, defaultBase: plan.defaultBase, remote, waves: plan.waves.length, results };
