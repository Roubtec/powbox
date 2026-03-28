---
description: Review completed task files against the actual codebase, close satisfied tasks, and create follow-up tasks for any gaps. Use after a batch of tasks has been implemented.
argument-hint: <glob-or-file-list of task files to review>
---

Review the specified task files against the current state of the codebase and determine whether each task has been delivered satisfactorily.

## Primary objective

For each task file in the input set, perform a thorough review of the actual codebase to verify that the task's acceptance criteria, scope, and intent have been met.
The goal is to close completed work cleanly and surface any remaining gaps as new, actionable follow-up tasks.

## Review process

For every task file:

1. **Read the task file fully**, including its acceptance criteria, validation steps, scope, implementation notes, and spec divergences.

2. **Run a full build** and verify there are no type errors.
   A build failure is an automatic blocker regardless of whether the task's acceptance criteria mention it.

3. **Inspect the codebase** to verify delivery.
   Do not take file existence at face value — read the relevant source files, check route behavior, verify that tests exist and pass, confirm that types are sound, and validate that the implementation matches the task's stated intent.

4. **Compare against legacy references** when the task cites them.
   Verify that behavioral fidelity has been preserved unless the task explicitly documents a spec divergence.

5. **Decide the task status:**
   - **Satisfied** — the task has been delivered as expected or better. All acceptance criteria are met. Minor stylistic preferences do not block closure.
   - **Needs follow-up** — the core delivery is present but there are concrete, actionable gaps: missing edge cases, incomplete validation, absent tests, broken behavior, accessibility issues, or deviations from the stated spec that were not flagged as intentional divergences.

## Actions after review

### For satisfied tasks

Delete the task file outright.
The work is done; the task file no longer serves a purpose.

### For tasks that need follow-up

Do **not** modify the original task file.
Instead, create one or more new follow-up task files in the same task folder using the `/write-tasks` command conventions:

- Continue the numbering sequence within the same phase.
  For example, if reviewing six `01-*` tasks, a follow-up file might be `01-07-phase-01-follow-ups.md`.
- If the remaining items are small and span multiple original tasks, prefer a single consolidated follow-up task (e.g. "Phase 01 minor fixes and gaps") over one file per original task.
  Group by theme or proximity, not by origin.
- If a gap is substantial enough to warrant its own task, give it its own file with a descriptive name.
- Follow-up tasks must stand on their own: include enough context, references, and acceptance criteria that an implementer can pick them up without re-reading the deleted original tasks.
- Then delete the original task file, since the follow-up replaces it.

### Consolidated follow-up format

When grouping small items into a single follow-up task, structure it as:

1. A brief summary of what was reviewed and why follow-up is needed.
2. A numbered or bulleted list of individual action items, each with:
   - what needs to change and where
   - why it matters (reference the original acceptance criterion or spec)
   - what done looks like for that item
3. Standard acceptance criteria and validation sections covering the full set.

## Review standards

- Be thorough but fair. The goal is to catch real gaps, not to nitpick style.
- A task is satisfied if its acceptance criteria are met, even if the implementation took a different structural approach than the task suggested.
- Do not fail a task for work that is explicitly out of scope or deferred to a later phase.
- Do not fail a task for missing test coverage unless the task's acceptance criteria specifically require tests.
- Flag security, accessibility, and data-integrity issues even if the original task did not explicitly mention them — these are always in scope.
- If you discover a problem that is clearly outside the scope of the tasks being reviewed, note it to the user but do not create a follow-up task for it unless asked.

## Output expectations

After reviewing all tasks, provide a clear summary to the user:

- Which tasks were closed (satisfied and deleted).
- Which tasks produced follow-up work, with a brief description of what remains.
- Any observations that fall outside the reviewed tasks but are worth flagging.

$ARGUMENTS
