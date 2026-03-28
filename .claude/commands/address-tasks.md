---
description: Kick off work on a task or set of tasks in turn. Create a branch for each task, implement the work, and open a PR for review. Use when the user is ready to start executing on the implementation of pre-planned work items.
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
It evaluates the current codebase state against the task's acceptance criteria.
It must be a **new** `Agent` invocation — never a `SendMessage` continuation of the implementer.
It should be launched in the **foreground** (not background) since the feedback loop must complete before the orchestrator can advance branches or start the next task.

### What to include in the reviewer prompt

- **The full task file content** — same source of truth the implementer received.
- **Instruction to read the relevant areas of the codebase** and check each acceptance criterion against the actual code.
- **Reporting format:**
  - **Pass** — all acceptance criteria are met, validation passes. State this clearly.
  - **Issues** — a numbered list of specific, actionable findings. Each finding must include: what criterion is unmet, where in the code the gap is, and what needs to change.
- **Instruction to be strict but fair** — flag genuine gaps and functional problems, not style preferences or minor nitpicks.
- **Instruction NOT to edit any files** — the reviewer only reads and reports.

### What the reviewer should NOT receive

- The implementer's summary, reasoning, or commit messages.
- Instruction to look at diffs or git history — it should evaluate the codebase as-is.

### Example reviewer prompt structure

```text
You are reviewing a task implementation. You have no prior knowledge of how it was built.
Your job is to check the current codebase against the task's acceptance criteria.

DO NOT edit any files. Only read, search, and run validation commands.

## Task

<full task file content pasted here>

## Instructions

- Run a full build and verify there are no type errors before checking anything else. A build failure is an automatic blocker.
- Read the relevant areas of the codebase and check each acceptance criterion.
- Report either:
  - **Pass**: all criteria met, build passes, validation passes.
  - **Issues**: numbered list of specific findings (what criterion, where in code, what's wrong).
- Be strict but fair. Flag real gaps, not style preferences.
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
