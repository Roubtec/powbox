---
name: write-tasks
description: Turn a plan, design doc, or free-form description into a sequence of concrete, numbered task files an implementer can execute one at a time. Trigger when the user asks to decompose work into committable task files, write tasks from a plan, or produce a phased task list. Do not trigger for one-off implementation requests or general planning advice.
---

Write one or more actionable task files based on the input.

**Arguments:** `<plan-reference-or-description> [target-folder]`

## Primary objective

Turn the source material into task files that are concrete, sequenceable, and easy for an implementer to execute without unnecessary clarification.

The output should help a worker understand what to build, why it matters, what constraints apply, and how completion will be verified.

## Version control — commit on the current branch, never branch or push

Writing the task files and committing them on the **current branch** is the entire git footprint of this skill. Whatever branch is checked out right now is where the task files land.

- **Never create a new branch** for the tasks — stay on the branch that is already checked out.
- Follow-up tasks recorded for in-flight work (review deferrals, decision records) belong **on the branch that prompted them** — being on a PR or task branch when invoked is intended, not a mistake: merging that branch then also lands the record of its loose ends. Do not relocate such tasks to a fresh branch off `main`; they would only need manual re-homing onto the real branch later.
- **Never push.** Do not run `git push` for any reason, and most emphatically never push to `main` or the repository's default branch. Task files are local artifacts an implementer picks up later; publishing them is a separate, explicit decision the user makes, not part of this skill.
- If the checked-out branch happens to **be** `main` or the default branch, still commit locally only — committing task files onto a local `main` is fine, pushing them is not.
- Commit only the task files you wrote — a focused commit with a clear message; do not sweep unrelated working-tree changes into it.

## Decomposition strategy

If the input is a plan, break it down into **vertical slices** by default so work can proceed in a coherent order.
Prefer tasks that deliver a meaningful increment of behavior, infrastructure, or product capability.

Examples of good task boundaries:

- scaffold the app and baseline tooling
- add a specific API endpoint and its backing service logic
- build one page plus its required data loading and validation
- implement one migration or rollout step with verification

Avoid vague or oversized tasks such as:

- build the backend
- finish the frontend
- improve performance everywhere
- clean up the architecture

## Task sizing guidance

Aim for tasks that are large enough to be worthwhile but small enough to review and land confidently.
If a task would require the implementer to make too many architectural decisions on their own, split it further or strengthen the context.

Split when:

- the task spans multiple loosely related concerns
- dependencies are hard to explain cleanly
- the acceptance criteria cover unrelated outcomes
- one part can be completed safely without the rest

Keep work together when splitting would force brittle interfaces or excessive coordination.

## File naming and ordering

Number files as `{phase}-{taskNo}-{brief-kebab-name}.md` to make execution order obvious.
Examples: `A-01-scaffold-project.md`, `02-12-hook-keyboard-shortcuts.md`.

If there are existing task files in the target folder, continue the numbering sequence.
Use numbering to reflect intended order, even if some tasks could later be parallelized.

## Task file content

Each task file must include:

1. **Title**
   Use a clear imperative statement focused on the deliverable.

2. **Why this task exists**
   Briefly explain the goal and its place in the broader effort.

3. **Scope**
   State what is included.
   If useful, also state what is out of scope so the task stays bounded.

4. **Context and references**
   Provide enough background to start work confidently.
   Cite the relevant plan sections, design docs, tickets, or files instead of repeating large amounts of source material.

5. **Target files or areas**
   Point to the expected modules, pages, services, folders, or systems involved.
   This helps establish a practical ownership boundary.

6. **Implementation notes**
   Include important constraints, assumptions, dependencies, or interface expectations.
   If another task must land first, say so explicitly.

7. **Acceptance criteria**
   Define what done looks like in concrete, observable terms.
   Include both behavior and structural expectations when relevant.

8. **Validation**
   State how the implementer should verify the work.
   Prefer measurable goals such as:
   - build passes
   - relevant tests pass
   - the target flow works manually end to end
   - the output matches the referenced contract or design

9. **Review plan**
   Add a short sentence or checklist describing how a reviewer should inspect the completed work.

## Writing guidance

Keep each task self-contained enough that someone can pick it up, implement it, and commit without needing to read every other task first.
Point to supporting documents for detail instead of overwhelming the task with copied context.

Be explicit about:

- prerequisites and dependency order
- intended ownership boundary
- non-obvious constraints
- expected deliverables
- what not to change as part of this task

Avoid:

- hidden assumptions
- tasks that are mostly restatements of a whole plan section
- acceptance criteria that are too vague to review
- instructions that force the implementer to rediscover key decisions

## Quality guidance

Encourage:

- Clear separation of concerns
- Consistent naming and file organization
- Accessible and responsive UX where relevant
- Thoughtful implementation instead of quick patchwork
- Reviewable commits at meaningful milestones

## Output expectations

The resulting task files should read like strong engineering briefs, not reminders.
An implementer should be able to begin meaningful work after reading one task file and the documents it directly references.

Any new code should pass build.
