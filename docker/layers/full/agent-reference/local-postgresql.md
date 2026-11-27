# Local PostgreSQL

The PostgreSQL 16 server binaries are baked in, but no daemon runs by default (it would clash with a project's own docker-compose Postgres). When a suite needs a live database (`prisma migrate`, a `test:db` integration run, etc.), stand one up on demand:

```bash
pg-dev-up                      # initdb + start + create db, prints DATABASE_URL
eval "$(pg-dev-up url --export)"   # export DATABASE_URL into the current shell
```

The emitted URL ends in `?sslmode=disable` — the cluster has no SSL and Go's `lib/pq` refuses to connect when the parameter is absent — so keep it, and append any extra parameter with `&`.

The cluster runs as the unprivileged `node` user with trust auth on a loopback socket (the container is the security boundary), so no `sudo -u postgres` dance is needed. Defaults are `postgres`/`postgres`/`postgres` on port `5432`; override per project to match its `.env` before the first call:

```bash
POSTGRES_USER=myapp POSTGRES_PASSWORD=myapp POSTGRES_DB=myapp pg-dev-up
```

Other subcommands: `pg-dev-up status`, `pg-dev-up down` (stop but keep data), `pg-dev-up help`.

For parallel worktrees that each run database tests, opt into a worktree-scoped cluster so they do not share one data dir or port. Put the flag before the subcommand; it derives an isolated data directory and a free loopback port from the current Git worktree (recorded so later `status`/`url`/`down` resolve the same server):

```bash
pg-dev-up --worktree up                        # isolated cluster on an allocated port
eval "$(pg-dev-up --worktree url --export)"     # export this worktree's DATABASE_URL
pg-dev-up --worktree down                       # stops only this worktree's cluster
```

Outside a Git repo, pass an explicit identifier instead: `pg-dev-up --profile <id> up`. Explicit `PGDATA`/`PGPORT` still override the scoped defaults (`POWBOX_PG_SCOPED_ROOT` overrides the scoped temp root).
