---
description: Write actionable task files from a plan or description. Use when the user wants to break work into sequenced, committable task files.
disable-model-invocation: true
argument-hint: <plan-reference-or-description> [target-folder]
---

Write one or more actionable task files based on the input.

## Primary objective

Turn the source material into task files that are concrete, sequenceable, and easy for an implementer to execute without unnecessary clarification.

The output should help a worker understand what to build, why it matters, what constraints apply, and how completion will be verified.

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

$ARGUMENTS
