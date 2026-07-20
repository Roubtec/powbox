# Task 027: Add an opt-in worktree-scoped PostgreSQL profile

## Why this task exists

`pg-dev-up` intentionally defaults to one throwaway PostgreSQL cluster at `/tmp/pgdata` on port 5432.

That is convenient for a single task, but parallel worktrees in the same agent container share its data directory, server, and default database; destructive database tests must therefore serialize or risk contaminating each other.

Provide an opt-in worktree profile so a repository can run database-backed validation in parallel without re-deriving safe paths and ports in every task script.

## Scope

- Add a documented `pg-dev-up` worktree/profile mode that derives isolated defaults from the current Git worktree and Powbox container identity.
- Preserve the existing command and environment-variable behavior unchanged when the mode is not requested.
- Make `up`, `status`, `url`, `down`, and `url --export` resolve the same scoped instance reliably.
- Add tests and documentation for running two scoped instances concurrently.

Out of scope: automatically changing repositories' test commands, provisioning a database per CI job, making PostgreSQL data durable across container recreation, or silently enabling isolation for existing callers.

## Context and references

- `docker/shared/pg-dev-up` currently defaults `PGDATA=/tmp/pgdata` and `PGPORT=5432`; it is baked into the base image.
- A single shared cluster is a serialization point for concurrent destructive e2e runs, because test suites commonly truncate or migrate overlapping tables.
- Worktree identities already follow `.worktrees/$CONTAINER_NAME/<slug>` through `wt-bootstrap`/`wt-enter`; do not depend solely on a path basename that can collide across repositories.
- The helper's current URL escaping and SQL-variable quoting are security-sensitive behavior and must not regress.

## Target files or areas

- `docker/shared/pg-dev-up`
- `commands/smoke-test.sh` and `commands/smoke-test.ps1`
- `docker/shared/container-agent.md.tmpl`, `README.md`, and the relevant architecture/runtime documentation
- New focused shell tests under `scripts/`
- `docker/base/Dockerfile` only if a test/helper needs a new baked dependency

## Implementation notes

- Choose and document one explicit interface, such as `pg-dev-up --worktree <command>`; it must be discoverable from `pg-dev-up help` and leave ordinary `pg-dev-up up` untouched.
- In scoped mode, derive a stable instance key from the repository common Git directory, current worktree, and `CONTAINER_NAME` when available. Use a collision-resistant encoded/hash component rather than trusting a human-readable slug alone.
- Store the generated/selected port with the scoped data directory so later `url`, `status`, and `down` commands find the exact server started by `up`.
- Select a free loopback port safely under a scoped lock, and fail with a useful message rather than attaching to an unrelated process. Two different scoped instances must coexist.
- Explicit `PGDATA`, `PGPORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB` values remain authoritative. Document precisely which scoped defaults each override replaces.
- Keep all data under a constrained temporary root, enforce owner-only permissions where PostgreSQL requires them, and make `down` stop only the resolved scoped instance. Never sweep other `/tmp` clusters.
- Design the helper so it works from the main checkout and a linked worktree. Outside Git, scoped mode should fail clearly or require an explicit profile identifier; do not guess.

## Acceptance criteria

- Existing unscoped invocations retain the same default data directory, port, URL shape, and commands.
- Two different worktrees can run `pg-dev-up` in scoped mode concurrently, receive distinct data directories and ports, create/connect to their own configured databases, and stop independently.
- Re-running scoped `up`, `url`, `status`, and `down` from the same worktree resolves the same instance.
- Explicit environment overrides are honored and covered by tests.
- The help text and user documentation show both the ordinary and scoped recipes, including how to export `DATABASE_URL`.

## Validation

- Add a focused shell test that creates two temporary Git worktrees/profiles and verifies concurrent isolated clusters plus independent teardown. Skip only when PostgreSQL server binaries are unavailable; do not hide a collision.
- Run `shellcheck` and `shfmt -d` over changed shell files and the relevant pure-shell tests in-container.
- Because the helper is base-baked, ask for a host/CI image rebuild and run the full image-required smoke suite before handoff.

## Review plan

Review port allocation/locking, identity derivation, environment-override precedence, and cleanup boundaries. Confirm no code path can stop or reuse an unrelated PostgreSQL server.
