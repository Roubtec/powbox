# Agent Instructions

## Documentation Practices

Update [README.md](README.md) if there are any changes to the project overview, tech stack, or development practices.

Use one line per paragraph in Markdown if possible.

## Working Tips

Suggest alternative strategies or push back on the user's ideas if there are better practices recommended or the user appears to be inconsistent.
Teach or question the user if that is in the best interest of the final product.

## Architecture

See README "Layout" for the repo file map. Rules that map does not state:

- There is one unified agent image `powbox-agent:latest` (`docker/agent/Dockerfile`) built on `powbox-agent-base:latest`. It installs both agent binaries — Codex below Claude so a Claude version bump (the common case) busts only the Claude layer plus the cheap asset/entrypoint layers above it; a Codex bump rebuilds the Claude layer on top too (accepted). The old per-agent images (`powbox-claude`, `powbox-codex`) and Dockerfiles are gone.
- Each agent's image-baked seed assets live under a per-agent directory `/home/node/.agent-container/<agent>` (e.g. `docker/claude/agent-container/` → `/home/node/.agent-container/claude/`), read by that agent's hook via the `AGENT_SEED_DIR` variable so the two agents' templates, skills, statusline, and build epoch never collide.
- Image-baked skills are seeded into each agent's user-level skills directory at startup (`$CLAUDE_CONFIG_DIR/skills/` for Claude, `~/.agents/skills/` for Codex), no-clobber at the skill-directory level; a per-repo `.claude/skills/` (or `.agents/skills/`) still takes precedence at invoke time. The copy logic and the `.powbox-seeded` ownership marker live in one baked helper `docker/shared/seed-skills.sh` (`/usr/local/bin/seed-skills.sh`), sourced by both entrypoint hooks (`seed_skills … noclobber`) and the updater, so the sites cannot drift. The marker means "powbox owns this copy": a marked skill may be refreshed/pruned, an unmarked folder is treated as user-authored and never touched.
- Because of the no-clobber, a rebuilt image's updated skill text does not replace the stale volume copies; `commands/update-skills.*` (function `agent-update-skills`) force-refreshes the baked skills onto both config volumes via a throwaway container, running the shared in-container worker `docker/shared/update-skills-incontainer.sh` (a classify/apply engine over the same `seed-skills.sh`). It seeds absent skills, refreshes marked ones, reports unmarked name-collisions as conflicts (overwritten only with `--adopt-all`), and reports marked skills no longer baked as obsolete (deleted only with `--prune`); `--dry-run` previews. On a TTY it prompts before adopting/pruning, and `agent-update` offers to run it after a successful rebuild. The `.powbox-seeded` marker records the image build epoch and the powbox commit baked via the `POWBOX_COMMIT` build-arg (`scripts/build-image.{sh,ps1}` → `docker-bake.hcl` → Dockerfile, next to `build-epoch`). User-authored skills (no marker) are left untouched.
- Claude-only dynamic workflows live under `docker/claude/agent-container/workflows/*.js` (no Codex sibling — Codex has no workflow runtime) and are seeded by `entrypoint-claude-hook.sh` into `$CLAUDE_CONFIG_DIR/workflows/` via `seed_workflows` in the shared `seed-skills.sh` (no-clobber at startup). A workflow is a single `.js` file with no "inside", so its `.powbox-seeded` ownership marker is a hidden sibling sidecar `.<name>.js.powbox-seeded` rather than an in-folder file; otherwise it mirrors skills exactly, so `update-skills-incontainer.sh` classifies / refreshes / adopts / prunes workflows as `workflow` items just like skills. They ship automatically because the Dockerfile copies the whole `docker/claude/agent-container/` tree. This is a testing batch (see that dir's README) reimagining the orchestration-heavy skills as workflows; they deliberately avoid the runtime's built-in `isolation: "worktree"` (it cannot honor the `.worktrees/$CONTAINER_NAME/<slug>` convention) — `wf-address-tasks` manages explicit convention worktrees, `wf-address-review` shares the one checkout — and the skills remain in place alongside them.
- The mechanical worktree lifecycle is encoded once, as three base-image scripts (`docker/shared/wt-bootstrap`, `wt-enter`, `wt-remove` → `/usr/local/bin/`) shared by both agents' `*-worktrees` skills and the Claude workflows: the workflows own control flow (waves, round caps, gating) as real code, agents own judgment, and the scripts own the git/worktree plumbing (root-safety checks, container-scoped orphan pruning, rerun-safe worktree resolve, guarded removal). Skill prose and workflow prompts must call these helpers rather than restate the plumbing — that split is what keeps the three layers from drifting.
- Image provenance: each image records the powbox commit that built it. A piecemeal build can carry up to three distinct commits — base (its own parent), codex, and claude/top — so they are tracked separately. Host-side: labels `powbox.commit.{base,codex,claude}` (+ `powbox.{codex,claude}.version` and `powbox.base.image.id`), surfaced by the `agent-image-info` shell function and in `agent-update` output. In-container: files `/home/node/.powbox/{base,codex,claude}.commit` (base inherited from the base image), printed by the baked `powbox-provenance` command. The codex commit is computed in `scripts/build-image.{sh,ps1}` (HEAD when the Codex layer rebuilds, else the prior image's value carried forward) and stamped only in the top metadata layer — never inside the Codex install layer, which would bust its cache. Reuse is judged against that layer's cache key — its parent base image (`powbox.base.image.id`) and `CODEX_VERSION` (`powbox.codex.version`) — so a separate base rebuild correctly re-stamps codex at HEAD; see [docs/skills-refresh-and-provenance.md](docs/skills-refresh-and-provenance.md) for the residual pre-build-prediction limitation. `-dirty` marks an uncommitted worktree. Introspection only; no logic depends on these values.
- Entrypoint scripts all live in `docker/shared/`, but only `entrypoint-core.sh` is baked by the base image. The unified entrypoint `entrypoint-agent.sh` and both per-agent hooks (`entrypoint-{claude,codex}-hook.sh`) are baked by the agent image, so editing the entrypoint or a hook only requires rebuilding the agent image — not the base. The old per-agent entrypoint shims (`entrypoint-{claude,codex}.sh`) are gone, replaced by `entrypoint-agent.sh` plus its in-script agent registry.
- After cutover the obsolete `powbox-claude` / `powbox-codex` images can be removed with `docker image rm powbox-claude powbox-codex` — non-destructive to the `claude-config` / `codex-config` volumes.

## Key Paths

| Path | Purpose |
|------|---------|
| `/workspace/<project-slug>` | Bind-mounted project directory (working directory; slug is `<name>-<hash>`) |
| `/ctx` | Optional read-only context volume (`--ctx`) |
| `/home/node/.claude` | Claude config volume (`claude-config`); always mounted regardless of primary agent |
| `/home/node/.codex` | Codex config volume (`codex-config`); always mounted regardless of primary agent |
| `/home/node/.agent-container/<agent>` | Per-agent image-baked seed assets (template, skills, statusline, build epoch); read via `AGENT_SEED_DIR` |
| `/home/node/.config/gh` | Shared GitHub CLI auth volume |
| `/workspace/<project-slug>/node_modules` | Per-project package volume (`agent-nm-<project>`) |
| `/workspace/<project-slug>/.worktrees` | Per-project worktrees volume (`agent-wt-<project>`); also holds the per-project pnpm store at `.worktrees/.pnpm-store` |

Both config volumes are always mounted (not just the primary agent's) so the primary agent can invoke the other in-container; see README "Cross-Agent Delegation".

## Entrypoint and Runtime

- `entrypoint-agent.sh` is the image ENTRYPOINT. It reads `PRIMARY_AGENT` (`claude` | `codex`, defaulting to `claude` for an unknown value), holds the agent registry (`agent_env` maps each agent to its `AGENT_CONFIG_DIR`, `AGENT_SETUP_HOOK`, `AGENT_SEED_DIR`, name, binary, autonomy flag, instruction file, and label), then seeds every agent and execs `entrypoint-core.sh` for the primary. Adding a harness = extend `agent_env` and `ALL_AGENTS`.
- It seeds in two passes: each non-primary agent is seeded directly (export its `AGENT_*` vars, run its hook); the primary agent's env is exported and handed to `entrypoint-core.sh`, which runs the primary's hook (so it is not run twice) alongside firewall/git/shadow setup before execing the CMD.
- Each per-agent hook (`entrypoint-claude-hook.sh`, `entrypoint-codex-hook.sh`) is run in full for every agent. Each writes only into its own config dir (`~/.claude` vs `~/.codex`/`~/.agents`), so there is no conflict; hooks are idempotent, no-clobber, and build-epoch-gated, and read their baked assets from `AGENT_SEED_DIR`.
- `entrypoint-core.sh` is a wrapper-style entrypoint that must end with `exec "$@"` and is unchanged by the unification (still runs the single `AGENT_SETUP_HOOK`).
- The shared instruction template is rendered via `envsubst` with agent-specific variables (including `${AGENT_PEERS}`, the registry-derived peer list for the "Delegating to another agent" section).
- `gh auth setup-git` runs from `$HOME` (not the workspace) and failure is non-fatal. On success it also adds a container-global `url."https://github.com/".insteadOf "git@github.com:"` rewrite (written to the ephemeral `GIT_CONFIG_GLOBAL`, never the host) so SSH-form `origin` remotes push/fetch over HTTPS+gh without rewriting the host repo.
- Workspace shadow mounts run after git setup, so any shadow logic must not assume an earlier ordering.

## Project Identity

Per-project identity uses `basename + SHA256(full path)` (truncated to 12 chars) so container names and `node_modules` volumes do not collide across similarly named projects.

## Volumes and Stores

See README "Workspace Shadow Mounts" and "Runtime" for volume behavior. The non-obvious constraint: pnpm can only **hardlink** from its store when the store and the target `node_modules` share **one mount** (not merely one device — `link(2)` returns `EXDEV` across mount points even on the same filesystem). So the per-project pnpm store lives *inside* the `.worktrees` volume (`agent-wt-<project>`) alongside every `.worktrees/<task>/node_modules`, and `package-import-method=auto` lets pnpm hardlink there and transparently fall back to copying for the root `node_modules` (a separate mount). The launcher passes `PNPM_STORE_DIR` and `entrypoint-core.sh` points pnpm at it per project.

## Bundled PostgreSQL

- The base image installs the PostgreSQL 16 server + client + contrib from the official PGDG apt repo (`docker/base/Dockerfile`), version-matched to the `postgres:16.x` images projects pin so integration suites don't hit behavior drift from Debian's stock 15.
- No daemon is started at build or runtime. `docker/shared/pg-dev-up` (baked to `/usr/local/bin/pg-dev-up`) stands up a throwaway loopback cluster on demand under `$PGDATA` (default `/tmp/pgdata`), as the unprivileged `node` user with trust auth — so it needs **no** sudoers entry. Credentials/port/db are env-overridable; see the script header.
- The server binaries live off `PATH` at `/usr/lib/postgresql/<major>/bin`; `pg-dev-up` resolves the newest installed major itself, so a future PG bump needs no path edit.

## Security

- Firewall rules allow loopback and block private/local networks for both IPv4 and IPv6.
- `/etc/sudoers.d/node` must stay scoped to `/usr/local/bin/init-firewall.sh`, `/usr/local/bin/shadow-mounts.sh`, and `/usr/bin/apt-get` only (mode `0440`).
- The base image includes `bubblewrap` for sandboxing.

See README "Workspace Shadow Mounts → Security" for the `shadow-mounts.sh` / `CAP_SYS_ADMIN` rationale.

## File Conventions

- Default to LF across the repo.
- Keep Windows-specific files (`.ps1`, `.bat`, `.cmd`) in CRLF.
- Save `.ps1` files that contain non-ASCII characters as UTF-8 **with BOM**, so Windows PowerShell 5.1 does not mangle them (the CRLF rule above is orthogonal to the BOM).

## PowerShell Linting

- Lint with `pwsh -Command "Invoke-ScriptAnalyzer -Path ."`. `Invoke-ScriptAnalyzer` is a `pwsh` cmdlet, not a shell command on `PATH`.
- The repo-root `PSScriptAnalyzerSettings.psd1` is auto-applied (PSScriptAnalyzer discovers it in the analyzed directory) and is baked into the image as the house default at `/usr/local/share/powershell/PSScriptAnalyzerSettings.psd1`. It excludes rules that clash with these CLI-style scripts — see the file for the per-rule rationale.
- To override the config for a single run, pass an explicit `-Settings`: `-Settings @{}` for a full unfiltered pass against all default rules, or e.g. `-Settings @{IncludeRules=@('PSReviewUnusedParameter')}` to run one otherwise-excluded rule across the tree. Note that `-IncludeRule` alone does **not** override `ExcludeRules` — the auto-discovered config wins.
