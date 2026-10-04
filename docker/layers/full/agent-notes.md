| Category | Tools |
|----------|-------|
| Core runtime | `php`, `composer` |
| PowerShell | `pwsh` runs `.ps1` scripts; lint them with `pwsh -Command "Invoke-ScriptAnalyzer -Path . -Recurse"` (without `-Recurse` only the scripts directly in that directory are checked; PSScriptAnalyzer is a `pwsh` module/cmdlet, not a shell command — and `shellcheck` does *not* lint PowerShell) |
| Build | `cmake`, `ninja`, `pkg-config` — the OpenSSL and zlib dev headers are baked too, so `-lssl -lcrypto -lz` linking and `pkg-config openssl` work without any install. `ccache` is baked as an **opt-in** compiler cache: plain `gcc`/`cmake` builds are untouched (no interposition), but activate it per build with `CC="ccache gcc" CXX="ccache g++"` or `cmake -DCMAKE_C_COMPILER_LAUNCHER=ccache`. On a JS/powbox, Go, or detected .NET project the cache persists in `.worktrees/.ccache` (shared across worktrees) so repeated large native builds survive container recreation; a dir-mounted C/CMake-only folder with none of those project markers does not mount that volume, so ccache falls back to its container-lifetime default there |
| Go | `go` (pinned current stable, with `gofmt`/`go vet`/`go test`; prefer `go mod tidy` over hand-merging `go.sum` conflicts) and `golangci-lint` (v2). A repo whose `go.mod` pins a newer toolchain auto-downloads it on first `go` run (`GOTOOLCHAIN=auto`). `~/go/bin` is on `PATH`, so `go install ...@latest` covers anything not baked (e.g. `gopls`, `dlv`). In a Go project the module/build caches persist across container recreation (`GOMODCACHE`/`GOCACHE` point into `.worktrees/`, shared across worktrees), and `golangci-lint` is a transparent wrapper that scopes its analysis cache per worktree — parallel worktree lint runs never see a sibling's stale results; no setup needed. |
| .NET | `dotnet` (SDK 10.0 LTS) — `dotnet build`, `dotnet test`, and `dotnet format` all ship in the SDK, so a C#/F# project's CI leg runs here before you push. The SDK bundles the .NET 10 runtime and targeting packs, so `dotnet test -f net10.0` needs nothing extra, and a project can target .NET Framework (`net48`) from Linux via the `Microsoft.NETFramework.ReferenceAssemblies` NuGet package — no targeting pack, no Mono. Only the 10.0 band is baked. A project still targeting an older TFM such as `net8.0` builds as-is, but its binaries and tests fail to run with "You must install or update .NET to run this application": either run them on the baked runtime with `DOTNET_ROLL_FORWARD=Major`, or install that band side by side with `sudo apt-get update && sudo apt-get install -y dotnet-sdk-N.0` (the Microsoft apt repo is already configured, but the package lists are not — the `update` is required). In self-hosted mode and a dir-mounted JS/powbox, Go, or boundedly detected .NET project, `NUGET_PACKAGES` points at persistent `.worktrees/.nuget`, shared safely across this project's worktrees, so restores stay warm across container recreation; a dir-mounted layout whose only solution/project markers are deeper than one direct child keeps NuGet's container-lifetime default until it adds a root solution or opts into project volumes. |
| Policy | `opa` (Open Policy Agent, pinned static build) — unit-test Rego authorization policy with `opa test policy/…`, the same command a project's CI runs. One baked release; a project pinning OPA to an exact engine version (e.g. a matching envoy sidecar) should still verify against its own pin. |
| Databases | `psql` + a bundled **PostgreSQL 16** server — run `pg-dev-up` to start a throwaway local cluster (see "Local PostgreSQL" below); `sqlcmd`/`bcp` (Azure SQL / MSSQL) |
| Document processing | `marp` (Markdown → slide decks), `mmdc` (Mermaid diagram source → SVG/PNG/PDF) |
| Headless browser | `chromium` — used by `marp` and `mmdc`, but also available for web automation: E2E/visual tests, smoke-testing a local dev server, screenshots, Lighthouse audits, HTML→PDF/PNG. Puppeteer-based tools work out of the box (`PUPPETEER_EXECUTABLE_PATH` and `CHROME_NO_SANDBOX` are pre-set). |
| Playwright | The `playwright` **CLI** is baked and on `PATH` (`playwright screenshot`, `playwright pdf`, `playwright codegen`, `playwright install`), but **browsers are not** — run `playwright install chromium` once per container (`playwright install --only-shell chromium` is enough for headless runs and is well under half the size). In a repo with its own pinned `playwright`/`@playwright/test`, use that repo's `npx playwright …` so its version wins; the bare `playwright` binary is the no-repo fallback. On a JS/powbox, Go, or detected .NET project the browser download lands in persistent `.worktrees/.ms-playwright` (`PLAYWRIGHT_BROWSERS_PATH`), so it survives container recreation and is shared by every worktree; elsewhere it falls back to container-lifetime `~/.cache/ms-playwright`. The global package is **CLI-only**: `require('playwright')` / `import … from 'playwright'` does not resolve from a folder without a local install (global npm packages are not on Node's module path, and powbox deliberately sets no `NODE_PATH` — it would mask undeclared dependencies), so a programmatic script needs a local `npm i playwright` (~19 MB, seconds; the browsers it then finds are the shared ones). The system `chromium` above is **not** a substitute: Playwright has no browser-executable env override (`PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` does not exist), and a headless launch wants a `chrome-headless-shell` binary the distro package does not ship. Only an explicit `launch({ executablePath: '/usr/bin/chromium' })` reuses it. |
| Containers | `podman`, `podman compose`, and a `docker` shim (→ `podman`) run **rootless** here — build images and spin up multi-service stacks (databases, Adminer, etc.) with `docker compose` / `podman compose`, no privileged daemon and no host Docker socket. Common dev images (`postgres`, `redis`, `mariadb`, `adminer`) are pre-cached in a shared read-only store, so they start without a pull. Storage is otherwise per-agent and persistent: pulled images and `podman volume`s (e.g. a database's data) survive container restarts, and each agent (Claude, Codex) keeps its own store for the same repo so concurrent agents never clobber each other. Reach a nested service from here via its **published port on `localhost`**; within a compose stack, containers reach each other by **service name**. Nested containers inherit this container's egress firewall. Uses `/dev/fuse` when the host exposes it, else the slower `vfs` driver. |

### Filesystem layout

| Path | What it is |
|------|------------|
| `/home/node/.local/share/containers` | Per-container rootless Podman storage, keyed by agent + project (Claude and Codex get separate stores for the same repo) — images and named volumes persist here (Docker volume) |

### Network

Containers you start with Podman route their outbound traffic through this container, so they inherit the same firewall: they can pull images and reach the public internet, but not your LAN or host. Talk to a nested service from this container (or from a sibling container) via its **published port on `localhost`** rather than its in-container IP.

### Local PostgreSQL

The PostgreSQL 16 server binaries are baked in, but no daemon runs by default (it would clash with a project's own docker-compose Postgres). When a suite needs a live database (`prisma migrate`, a `test:db` integration run, etc.), stand one up on demand:

```bash
pg-dev-up                      # initdb + start + create db, prints DATABASE_URL
eval "$(pg-dev-up url --export)"   # export DATABASE_URL into the current shell
```

The emitted URL ends in `?sslmode=disable` — the cluster has no SSL and Go's `lib/pq` refuses to connect when the parameter is absent — so keep it, and append any extra parameter with `&`.

The cluster runs as the unprivileged `node` user with trust auth on a loopback socket (the container is the security boundary), so no `sudo -u postgres` dance is needed. Defaults are `postgres`/`postgres`/`postgres` on port `5432`; override per project to match its `.env` before the first call:

```bash
POSTGRES_USER=telemed POSTGRES_PASSWORD=telemed POSTGRES_DB=telemed pg-dev-up
```

Other subcommands: `pg-dev-up status`, `pg-dev-up down` (stop but keep data), `pg-dev-up help`.

For parallel worktrees that each run database tests, opt into a worktree-scoped cluster so they do not share one data dir or port. Put the flag before the subcommand; it derives an isolated data directory and a free loopback port from the current Git worktree (recorded so later `status`/`url`/`down` resolve the same server):

```bash
pg-dev-up --worktree up                        # isolated cluster on an allocated port
eval "$(pg-dev-up --worktree url --export)"     # export this worktree's DATABASE_URL
pg-dev-up --worktree down                       # stops only this worktree's cluster
```

Outside a Git repo, pass an explicit identifier instead: `pg-dev-up --profile <id> up`. Explicit `PGDATA`/`PGPORT` still override the scoped defaults (`POWBOX_PG_SCOPED_ROOT` overrides the scoped temp root).
