# 089 — `pg-dev-up` remembers its credentials and can list and destroy its clusters

**Depends on:** 088, because it changes where a cluster's data lives and what a cluster records about itself, and listing and destroying have to cover both.

**Relates to:** `docker/layers/full/pg-dev-up` (`print_url`, the scoped markers), its suite `scripts/test-pg-dev-up-scoped.sh`, `docker/shared/wt-bootstrap`, `docker/shared/wt-remove`, and the "Local PostgreSQL" section of `docker/layers/full/agent-notes.md`.

## Why this task exists

Housekeeping gaps make the helper's clusters harder to live with than they should be.

First, `url` and `status` build their answer from whatever `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_DB` hold in the calling shell. The values given to `up` are not recorded: the scoped markers hold only the port and the data directory. Every tool call an agent makes is a fresh shell, so a later `pg-dev-up url` prints the default credentials for a cluster that was created with others. Nothing warns, and the URL simply fails to connect or names the wrong database.

Second, scoped clusters accumulate. `down` keeps the data directory on purpose. No command lists the clusters the helper knows about or removes one. The directory name is a hash, so a leftover cannot be traced to the worktree it served. `wt-remove` and `wt-bootstrap` know nothing about them. Once a cluster's data can sit in RAM, a forgotten one holds memory as well as disk.

## Goal

`url` and `status` describe the cluster that `up` created, whatever the caller's environment holds, and a disagreement between the two is reported instead of being resolved silently. An agent can see every cluster the helper knows about, with enough to tell whose it is and whether it is running, and can remove one completely with a single command. Leftovers from worktrees that no longer exist are visible where an agent already looks at the start of a session.

## Direction and constraints

- The unscoped cluster has the same credential amnesia. Decide whether it gets a record too, and say why if it does not.
- Recording the password in plain text is acceptable for a trust-auth, loopback-only cluster inside the container boundary, in a directory the helper already keeps owner-only. Say so where it is stored.
- Destroying is the helper's one destructive verb, so hold it to the standard `dc-remove` sets: it removes only what the helper created and marked, a running cluster is stopped first or refused, and an explicit `PGDATA` pointing somewhere else must never turn it into a way to delete an arbitrary directory.
- Listing is read-only. It must not disturb a concurrent `up`, whose port reservation the existing lock protects.
- Having `wt-remove` destroy a worktree's cluster is tempting. But `wt-remove` promises never to destroy work, and it is baked into every image while this helper exists only in an optional layer set. Reporting leftovers is the safe default; removing them automatically needs an argument.
- For the same reason, anything `wt-bootstrap` reports about clusters must be tolerant of the helper being absent.
- Validation is as for task 088: a host smoke against an image built with the `full` layer set.
