# 088 — `pg-dev-up` test clusters skip durability and can live in RAM

**Relates to:** `docker/layers/full/pg-dev-up`, its suite `scripts/test-pg-dev-up-scoped.sh`, the "Local PostgreSQL" section of `docker/layers/full/agent-notes.md`, `docs/architecture.md` "Bundled PostgreSQL", and the launchers (`scripts/launch-agent.sh`, `scripts/launch-agent.ps1`) with the compose files.

## Why this task exists

`pg-dev-up` describes itself as a throwaway cluster for integration suites, yet it runs PostgreSQL with full durability on disk-backed storage: every commit is flushed to stable storage, for data nobody would ever recover.

A project with heavy database-backed integration tests, run repeatedly and in parallel worktrees, spent much of its test time in those flushes and thrashed the host's SSD doing it. It ended up writing its own RAM-backed database script. That is this helper failing at the one job it has.

## Goal

An agent that runs `pg-dev-up` for a test suite gets a cluster that does not pay for durable writes, without having to know to ask. Where the container can offer RAM-backed storage, the cluster's data lives there, for speed and to spare the hardware. Someone who does want the data to survive can say so and get today's behaviour. `status` shows which kind of cluster it is looking at.

## Direction and constraints

- The work has a light step and a heavy one, and they may ship separately. Non-durable server settings are a change to the helper alone and bring most of the benefit. RAM-backed storage needs something the container does not have today: `/tmp` sits on the container's disk-backed layer and `/dev/shm` is tiny.
- Providing RAM-backed storage is therefore a launch-time matter (both launcher twins, or the compose files) or a privileged in-container mount. The sudoers scope is narrow on purpose (AGENTS.md "Security"); do not widen it casually for this.
- RAM is not free. Pages on a tmpfs count against the container's memory, which parallel worktrees already compete for. The RAM-backed mode needs a stated size bound and a failure that reads as "the RAM disk is full" and not as a test failure. It also needs a fallback to disk when RAM-backed storage is absent or too small.
- A non-durable cluster does not survive an unclean stop, and a RAM-backed data directory vanishes with the container while a marker recorded elsewhere may not. `down` keeps the data directory for a later `up`. So `up` must cope with a leftover it cannot start, and with a marker whose data is gone, by recreating the cluster. Nothing in it was worth keeping, and a confusing startup failure is the worst outcome here.
- An explicit `PGDATA` stays authoritative, as it is today.
- Scoped and unscoped clusters should not differ in which mode they get.
- A PostgreSQL that a project runs through Podman is a different path and out of scope.
- Validation needs a host build. The scoped suite and the smoke test's `pg-dev-up` stage start real daemons and run only in a host smoke against an image built with the `full` layer set, which CI never builds. The launch-side half also needs a relaunched container. Ask the maintainer for both.
