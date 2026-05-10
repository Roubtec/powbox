---
description: Kick off work on a task or set of tasks in turn. Create a branch for each task, implement the work, and open a PR for review. Use when the user is ready to start executing on the implementation of pre-planned work items.
disable-model-invocation: true
argument-hint: <glob-or-file-list of task files to implement>
---

Implement the given task or a set of tasks using a delegated subagent workflow.

## Architecture

You are the **orchestrator**.
Your job is to sequence tasks, manage branches and PRs, and coordinate two specialized subagent roles per task:

- **Orchestrator** (you) — sequencing, branching, PR creation, progress tracking. Runs as the top-level agent.
- **Implementer** — deep implementation work for a single task. Spawned via the `Agent` tool with `subagent_type: "general-purpose"`.
- **Reviewer** — fresh-eyes acceptance check against the task definition. Spawned via the `Agent` tool with `subagent_type: "general-purpose"`.

This separation keeps your context window clean across long batches and ensures the reviewer evaluates the work without implementation bias.

**Trivial-task escape hatch:** for genuinely trivial tasks (a single obvious change with unambiguous criteria), you may implement directly without delegating.
Default to delegation for anything requiring exploration or judgment.
Even when you skip the implementer, always spawn a fresh reviewer agent — no task skips review.

## Orchestrator Responsibilities

You own the overall workflow.
You MUST NOT do implementation work yourself (except for the trivial-task escape hatch above).
Your responsibilities are:

1. Resolve the input arguments to a list of task files.
2. Read each task file enough to understand dependencies and sequencing — do not deeply analyze implementation details.
3. Manage branch creation and PR base determination.
4. Construct focused prompts and spawn subagents (implementer, then reviewer) for each task.
5. Handle the review feedback loop.
6. Open PRs once a task passes review.
7. Advance to the next task or stop on blockers.
8. Produce the final batch summary.

## Implementer Agent

The implementer receives a focused, self-contained prompt and works autonomously on a single task.
It should be launched in the **foreground** (not background) since the orchestrator needs its result before proceeding.

### What to include in the implementer prompt

Construct a prompt that contains:

- **The full task file content** — paste it into the prompt. Do not assume the agent has prior context.
- **The branch name** it should be working on, and instruction to verify it is on the correct branch.
- **Instruction to read `AGENTS.md`** at the start for full project context and conventions.
- **Relevant upstream context** — if this task depends on a previous task in the batch, briefly describe what the previous task introduced so the implementer can build on it.
- **Commit and validation instructions:**
  - Commit at logical milestones, keeping each commit buildable when practical.
- **Reporting instructions** — when done, report back with:
  - A concise summary of what was implemented.
  - Any decisions, tradeoffs, or deviations from the task description.
  - Any uncertainties or areas that may need focused review.

### What the implementer should NOT receive

- The full batch context or other unrelated task files.
- Review feedback from unrelated prior tasks.

### Example implementer prompt structure

```text
You are implementing a single task on branch `feature/task-slug`.
Verify you are on this branch before starting.

Read `AGENTS.md` first for project conventions.

## Task

<full task file content pasted here>

## Context

<any relevant info about prior tasks this builds on>

## Instructions

- Implement the task according to its description and acceptance criteria.
- Commit at logical milestones. Aim for one commit per logical unit of work.
- Run the project's build and lint commands periodically. Run a full build check before reporting completion.
- When done, report: what you did, any decisions/tradeoffs, any uncertainties.
```

## Reviewer Agent

The reviewer is a **fresh** subagent with no knowledge of the implementation process.
It evaluates the current codebase state against two orthogonal dimensions: acceptance criteria compliance and implementation quality.
It must be a **new** `Agent` invocation — never a `SendMessage` continuation of the implementer.
It should be launched in the **foreground** (not background) since the feedback loop must complete before the orchestrator can advance branches or start the next task.

### What to include in the reviewer prompt

- **The full task file content** — same source of truth the implementer received.
- **The PR base branch name** (the branch this task will be merged into). The reviewer uses this to scope its review by listing files touched on the task branch versus the base. If the orchestrator omits this, the reviewer should fall back to `main` and note the fallback in its report.
- **Instruction to read the relevant areas of the codebase** and check each acceptance criterion against the actual code.
- **Instruction to perform a code quality pass** (see dimensions below) orthogonal to the criteria check.
- **Scoping guidance** — the reviewer may run `git diff --name-only <base>...HEAD` to identify the set of touched files and prioritize quality review there. It must still read each touched file in full (not just the diff) and may follow references into untouched files when needed to evaluate consistency or call sites.
- **Reporting format:**
  - **Pass** — all acceptance criteria are met, build passes, and no material quality issues found. State this clearly.
  - **Issues** — a numbered list of specific, actionable findings. Each finding must include: the category (criteria gap vs. quality), where in the code the gap is, and what needs to change.
- **Instruction to be strict but fair** — flag genuine gaps and functional problems, not style preferences or minor nitpicks.
- **Instruction NOT to edit any files** — the reviewer only reads and reports.

#### Code quality dimensions to check

These are checked **in addition to** the acceptance criteria, not instead of them.

- **Logic correctness** — control flow, conditionals, and branching produce the right outcomes. Look for off-by-one errors, inverted conditions, incorrect operator precedence, or logic that silently produces wrong results.
- **Error handling** — errors are caught where they can occur, propagated with meaningful context, and never silently swallowed. Return types and thrown types are accurate.
- **Edge cases** — null/undefined inputs, empty collections, zero/negative numbers, and boundary values are handled gracefully or explicitly rejected with a clear error.
- **Dead code and unreachable paths** — branches, parameters, or exported symbols that can never be reached or used should be flagged. Defensive code for conditions that cannot occur should be questioned.
- **Code consistency** — naming, patterns, and idioms are consistent with the surrounding codebase. New abstractions follow the same conventions as existing ones.
- **Avoid code duplication** — Reused patterns should ideally be implemented once and shared rather than duplicated (if practical) to reduce maintenance overhead and improve readability.
- **Type safety** — types are precise and not widened unnecessarily. Casts, `any`, or `as unknown` that could hide real type errors should be flagged.

### What the reviewer should NOT receive

- The implementer's summary, reasoning, or notes.
- Instruction to read commit messages or diffs. The reviewer may use git to list touched files (for scoping), but it should not read commit messages or `git diff` output, since both anchor the reviewer to the implementer's intent and to a line-by-line view that hides issues spanning the boundary between changed and unchanged code. Read whole files instead.

### Example reviewer prompt structure

```text
You are reviewing a task implementation. You have no prior knowledge of how it was built.
Your job is to evaluate the current codebase on two orthogonal dimensions:
1. Acceptance criteria compliance — does the code do what was specified?
2. Implementation quality — is the code correct, robust, and consistent?

DO NOT edit any files. Only read, search, and run validation commands.

The PR base branch for this task is `<base-branch>`. The current branch is `<task-branch>`.

## Task

<full task file content pasted here>

## Instructions

- Run a full build and verify there are no type errors before checking anything else. A build failure is an automatic blocker.
- Identify the touched files with `git diff --name-only <base-branch>...HEAD`. Use this list to scope your code quality review. If no base branch was provided above, fall back to `main` and mention the fallback in your report.
- Do NOT read commit messages (`git log`) and do NOT read diffs (`git diff` with content). Read each touched file in full instead — diff-only review hides issues that span the boundary between changed and unchanged code, and commit messages anchor you to the implementer's intent.
- You may follow references from touched files into untouched files when needed to evaluate consistency, call sites, or downstream effects.
- Read the relevant areas of the codebase and check each acceptance criterion.
- Perform a code quality pass on the touched files using the following checklist:
  - **Logic**: are conditionals, branching, and control flow correct? Any off-by-one, inverted conditions, or silent wrong-result paths?
  - **Error handling**: are errors caught and propagated with context? Anything silently swallowed?
  - **Edge cases**: are null/undefined, empty collections, and boundary values handled or explicitly rejected?
  - **Dead code**: any unreachable branches, unused parameters, or defensive guards for impossible conditions?
  - **Consistency**: do naming, patterns, and idioms match the surrounding codebase?
  - **Duplication**: any non-trivial patterns duplicated that could be shared instead?
  - **Type safety**: are types precise? Flag unnecessary widening, `any`, or unsafe casts.
- Report either:
  - **Pass**: all criteria met, build passes, no material quality issues.
  - **Issues**: numbered list. For each: category (criteria gap / logic / error-handling / edge-case / dead-code / consistency / duplication / types), file and line, what is wrong, and what should change instead.
- Be strict but fair. Flag real gaps and functional problems. Do not flag style preferences or superficial nitpicks.
```

## Execution Model

Process the batch **sequentially**, not in parallel.
Each task is its own delivery unit, but stack later task branches on top of earlier ones when needed so dependent work can continue without waiting for review.

### Determining the PR base

Use the following precedence:

1. **Explicit override** — if the user specifies a base branch (e.g. "make a PR against `main`"), use that for every task in the batch. If the user asks for no PR, skip PR creation entirely.
2. **Previous task branch** — for the second task onward in a serialized batch, branch from and target the previous task branch when the work depends on earlier changes.
3. **Current branch** — if neither of the above applies, the branch you are on when the batch starts is the PR base for the first task.

## Per-Task Workflow

For each task file in the input set:

1. **Record the PR base branch** for this task (see precedence rules above).
2. **Create a dedicated implementation branch** for the task.
3. **Read the task file** enough to construct a good implementer prompt. Identify the acceptance criteria so you can later evaluate the reviewer's report.
4. **Spawn the implementer agent** with a well-structured prompt (see Implementer Agent section). Wait for completion.
5. **Evaluate the implementer's report.** If the implementer hit a blocker it could not resolve, stop and surface it to the user before spawning a reviewer.
6. **Spawn the reviewer agent** with a fresh prompt (see Reviewer Agent section). Wait for completion.
7. **Evaluate the reviewer's report:**
   - If **pass**: proceed to step 8.
   - If **issues found**: enter the feedback loop (see below).
8. **Open a PR** against the recorded base branch.
   - Reference the task file in the PR description for context.
   - Include any reviewer-relevant caveats (tradeoffs, intentional divergences, uncertainties surfaced by the implementer or reviewer).
   - Do not restate the entire task unless doing so adds real review value.
9. **Continue to the next task** or, if this was the last one, produce the final summary.
   If you hit a blocker that prevents responsible progress, stop and ask the user for clarification.

## Feedback Loop

When the reviewer reports material issues:

1. **Spawn a new implementer agent** with:
   - The original task file content.
   - The reviewer's numbered findings, verbatim.
   - The branch name (same as before).
   - Instruction to address each finding specifically and report what was fixed.
   - The same project context and validation instructions as the original implementer prompt.
2. After the fix-up implementer completes, **spawn a new reviewer agent** to re-check (same fresh prompt structure as before).
3. Repeat until the reviewer passes or you judge that remaining findings are minor enough to note in the PR description rather than block on.
4. **Cap the feedback loop at 3 iterations.** If issues persist after 3 rounds, stop iterating and do not open a PR for this task. Surface the outstanding findings clearly to the user in the final summary and ask for guidance on how to proceed.

## Hints

For serialized task batches, branch each new task from the previous task branch when the work is expected to depend on earlier changes.
This keeps the batch moving while review happens incrementally.

If a PR cannot be opened for any reason, still create the task branch and finish the implementation commits.
The user can open the PR manually later.

Prefer every commit to remain buildable, but do not treat that as an absolute requirement for intermediate checkpoints.
The completed task branch and final PR should be clean and pass validation.

## Final Output

After completing the batch, provide a concise summary:

- Which tasks were implemented and their PR links.
- How many review iterations each task required (and whether any hit the cap).
- Any observations outside the task descriptions worth flagging.
- Any blockers or uncertainties that remain.

$ARGUMENTS
