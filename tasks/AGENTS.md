# Task Management

## Writing and Reviewing Tasks

Tasks should convey the intent and/or goal, and the reasoning if not obvious, so the implementer may make informed decisions. Do not enumerate or count in tasks, do not restate existing code, do not list what can be specified by a rule (maybe an example). Avoid drift-prone verbiage. Reference symbols (not file lines) where helpful. Feel free to mention known landmines and edge cases, but don't implement in code, and don't spell out implementation details that invite nitpick review rounds.

## Numbering and Referencing Tasks

New top-level tasks should be numbered with three digits, e.g. 001, 002. Follow-up tasks (that are out of scope of an existing PR but relate to it) can be queued as 001a, 001b, etc. This allows us to preserve follow-up intent and implement it soon after the original task has been addressed satisfactorily enough.

Letter suffixes run `a` through `z` only. When a parent's letters have exhausted "a-z", the next follow-up takes its own three-digit number and names the parent in its **Relates to** or **Depends on** line rather than overflowing the suffix, i.e. do **not** extend to `aa`. Task numbers are stable and clear dependencies are more important than ordered task numbers.

## Task Lifecycle

Once a task is completed and merged, it is moved to "tasks/done/" during the next task cleanup cycle, not in its own PR. This is why cross-referenced tasks could be found in either folder. The cleanup cycle (a.k.a. task sweep) verifies delivery against the merged tree. Tasks that we need to keep track of but are not yet actionable are tracked in "tasks/deferred/". They shall be moved to "tasks/" when they become actionable. Any done = archived tasks get moved to "tasks/done/" during a sweep.

We do not preserve task status in task text: the placement in the folder structure is the source of truth, and prose would drift. Apply to newly edited tasks especially.

A reaped task whose residual gaps are filed as a follow-up task is archived to "tasks/done/" like any other delivered task; the follow-up is what stays active, and it is the only task file that records the residual. The original need not be held open or edited to carry it.

The `Depends on:` header names a task's dependencies: list the task numbers it depends on and why each one matters (briefly). Keep active, drifting language out of the header — no "landing", "landed", "merged", "on branch X", "this branch", "nothing outstanding", "no task blocks this", and no merge SHA or PR number used to report that a dependency has arrived. Each of those is true only until it is not, and keeping such verbiage true causes futile churn.
