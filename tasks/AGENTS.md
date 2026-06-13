# Task Management

Tasks should be numbered with odd numbers with three digits, starting from 001. This allows us to insert new follow-up tasks using even numbers.

Follow-up tasks (that are out of scope of an existing PR but relate to it) can be queued as 001a, 001b, etc. This allows us to preserve follow-up intent and implement it soon after the original task has been addressed satisfactorily enough. Generic follow-up tasks (that arose from batch reviews or other general observations) can be queued as 002a, 002b, etc. This allows us to queue new tasks between existing ones as needed.

Once a task is completed and merged, it is moved to "tasks/done/" during the next task cleanup cycle. This is why cross-referenced tasks could be found in either folder. Tasks that we need to keep track of but are not yet actionable are tracked in "tasks/deferred/". They will be moved to "tasks/" when they become actionable.
