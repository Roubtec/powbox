# Task 035 — Make pg-dev-up emit a lib/pq-compatible DATABASE_URL (sslmode=disable)

## Why this task exists

`pg-dev-up` builds its DATABASE_URL as `postgresql://user:pass@host:port/db` with no query parameters (`docker/shared/pg-dev-up:602`).
Go's `lib/pq` defaults to `sslmode=require` when the DSN does not specify one, so any Go integration suite pointed at a `pg-dev-up` cluster fails with `SSL is not enabled on the server` until someone appends `?sslmode=disable`.
This bit repeatedly in kalm2 (`-tags integration` suites are the main consumer of `pg-dev-up` there): a subagent rediscovered the workaround independently and had to flag it forward to every later runner — roughly one wasted debugging cycle per agent that touched a live database.

The cluster is loopback-only with trust auth and the container is the security boundary, so `sslmode=disable` is the honest description of the connection, not a weakening.

## Scope

Included:

- `pg-dev-up url` / `up` output: append `?sslmode=disable` to the emitted DATABASE_URL by default.
- Preserve any existing behavior for callers that already pass their own DSN expectations — if a consumer needs the bare form, the raw components are still printed/derivable; do not add a flag unless a concrete need exists.
- `pg-dev-up help`: mention the `sslmode=disable` default and why.
- Extend `scripts/test-pg-dev-up-scoped.sh` to assert the emitted URL carries `sslmode=disable` (both default and `--worktree` paths).

Out of scope:

- Enabling SSL on the bundled server.
- Changes to consumer repos (they simply stop needing the workaround).

## Context and references

- `docker/shared/pg-dev-up:602-605` — URL construction and `--export` printing.
- `scripts/test-pg-dev-up-scoped.sh` — the existing pure-shell suite to extend.
- node-postgres (JS `pg`) ignores absent `sslmode` and connects plaintext by default, so JS consumers are unaffected by the addition; `lib/pq` and `pgx` honor it — the parameter is compatible across the ecosystem.

## Target files or areas

- `docker/shared/pg-dev-up`
- `scripts/test-pg-dev-up-scoped.sh`
- README / docs mention of `pg-dev-up` output, if any describes the URL shape.

## Implementation notes

- Append the parameter in the single place the URL is constructed so `up`, `url`, and `url --export` all agree.
- Keep `printf %q` quoting for `--export` intact — the `?` must survive shell round-tripping.
- Check whether any in-repo consumer (smoke tests, docs examples) pattern-matches the URL and update those matches.

## Acceptance criteria

- `pg-dev-up url` and `eval "$(pg-dev-up url --export)"` produce a DATABASE_URL ending in `?sslmode=disable`.
- `pg-dev-up --worktree url` does the same.
- `pg-dev-up help` documents the default.
- The scoped test suite asserts the parameter's presence.

## Validation

- `bash scripts/test-pg-dev-up-scoped.sh` passes.
- Manual: `pg-dev-up up` in a throwaway dir, then `psql "$DATABASE_URL" -c 'select 1'` works (psql accepts `sslmode=disable` in the URL).
- `shellcheck` / `shfmt -d` clean.

## Review plan

Reviewer checks the URL is modified at the single construction site, the export quoting still round-trips, and the test asserts both scoped and default cluster paths.
