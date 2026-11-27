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

Other subcommands: `pg-dev-up status`, `pg-dev-up down` (stop but keep data), `pg-dev-up destroy` (stop and delete the cluster with its data), `pg-dev-up list`, `pg-dev-up help`.

`up` records the role, password and database it set a cluster up with, next to the cluster's data, so a later `pg-dev-up url` or `status` from any shell describes that cluster, and `up` without `POSTGRES_*` reuses them. If your environment's `POSTGRES_*` disagree with the recorded values, `url` refuses and `status` says so: unset them, or run `up` with them to add that role or database. The password is kept in plain text in the owner-only data directory, which is fine for a trust-auth, loopback-only cluster inside the container.

A cluster is **non-durable** by default: it runs with `fsync`, `synchronous_commit` and `full_page_writes` off, so a test suite never waits on a flush to stable storage. Its data does not survive an unclean stop, and a later `up` that cannot start such a leftover recreates it empty rather than failing. Where the container has RAM-backed storage (a tmpfs at `/run/pg-dev-up`, 2 GB shared by all clusters unless the container was launched with a larger `POWBOX_PG_RAM_SIZE`), a new cluster's data lives there and is lost when the container stops; without it, or when it has less than 256 MB free, the cluster goes on disk, still non-durable. When you want the data kept, create the cluster with `POWBOX_PG_DURABLE=1 pg-dev-up up` for a durable cluster on disk; the choice is recorded with the cluster, so later commands need not repeat it. `pg-dev-up status` says which kind a cluster is and where its data lives, and `pg-dev-up check` says whether RAM-backed storage is available. If a suite fails with `No space left on device` or `could not extend file` on a RAM-backed cluster, the RAM disk is full, which is not a bug in your tests: `status` says so, and stopping and deleting clusters you no longer need frees it.

For parallel worktrees that each run database tests, opt into a worktree-scoped cluster so they do not share one data dir or port. Put the flag before the subcommand; it derives an isolated data directory and a free loopback port from the current Git worktree (recorded so later `status`/`url`/`down` resolve the same server):

```bash
pg-dev-up --worktree up                        # isolated cluster on an allocated port
eval "$(pg-dev-up --worktree url --export)"     # export this worktree's DATABASE_URL
pg-dev-up --worktree down                       # stops only this worktree's cluster
```

Outside a Git repo, pass an explicit identifier instead: `pg-dev-up --profile <id> up`. Explicit `PGDATA`/`PGPORT` still override the scoped defaults (`POWBOX_PG_SCOPED_ROOT` overrides the scoped temp root).

`down` keeps a cluster's data, and a scoped cluster lives outside its worktree, so clusters outlive the work they served (one in RAM holds memory too). `pg-dev-up list` shows every cluster the helper knows about, whose worktree or profile it is (and whether that worktree still exists), whether it runs, and the command that removes it; `pg-dev-up --worktree destroy` removes this worktree's cluster, and `pg-dev-up --instance <key> destroy` one whose worktree is gone. `destroy` removes only a cluster pg-dev-up created and marked, never a directory an explicit `PGDATA` points it at otherwise. `wt-remove` mentions a cluster the removed worktree leaves behind, and `wt-bootstrap` lists those whose worktree is gone as `pgLeftovers`; neither removes one, since its data may be durable.
