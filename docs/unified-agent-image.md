# Unified Multi-Agent Image — Specification

Status: approved design, pending implementation.

This document specifies merging the per-agent images (`powbox-claude`, `powbox-codex`) into a single `powbox-agent` image that ships both agent binaries, so the chosen agent is selected at runtime rather than baked into the image. It is the reference for the implementation commits that follow.

## Motivation

Today we build two images that share a common base but differ only in which agent binary is installed and which seeding/entrypoint logic runs (`docker/claude/Dockerfile`, `docker/codex/Dockerfile`). The split is shallow: `entrypoint-core.sh` is already agent-agnostic, the agent-specific shims just export five `AGENT_*` variables, and the config trees (`~/.claude`, `~/.codex`, `~/.agents`) are disjoint.

Unifying yields three benefits:

- **One maintenance surface** for the growing set of harnesses (more are planned).
- **In-container cross-invocation without Docker-in-Docker.** With both binaries present, an agent that wants to delegate (e.g. Claude asking Codex for a review, or vice versa) simply runs the other executable inside the same container — no mounted Docker socket, no sibling container, no breach of the firewall isolation in `init-firewall.sh`.
- **A clear path to add future harnesses** as one binary + one hook + one skills tree + one registry entry, with no image/source split.

The accepted cost: updating either agent binary rebuilds the single image. See "Image layering" for how layer ordering keeps the common case (frequent Claude updates) cheap to pull anyway.

## Goals

- Single image `powbox-agent` containing both the Claude Code and Codex binaries.
- Agent identity becomes a runtime concern: env var + container-name prefix + launched CMD + resume branch.
- Both config volumes are mounted on every launch regardless of which agent is primary.
- The entrypoint seeds **both** agents' configs at startup so either can run immediately.
- The top-level agent prompt template advertises both agent executables so each agent knows it can call the other.
- `cc` / `cx` remain the user-facing entry points and keep producing distinct, separately-resumable containers per project.

## Non-goals (explicitly deferred or rejected)

- **Volume unification** (one `agent-home` volume with `.claude` / `.codex` / `.agents` subpaths) is deferred to a later, independent change. Both existing volumes stay separate for now and are simply both mounted.
- **Separate slimmed tags** (e.g. a Codex-only lower-layer image). Rejected for now: it contradicts the unified premise (both binaries always present, so either can invoke the other), and plain Docker layer reuse already delivers the only bandwidth win that matters — see "Image layering". Revisit only if a future harness is both heavy and genuinely optional at runtime.
- **In-container shims/aliases** (e.g. wrapper `cc`/`cx` inside the container). Rejected: the agents already know each other's real executable names; aliases would be redundant and confusing.

## Target architecture

### Image layering

A single image, single tag `powbox-agent:latest`, built on the existing `powbox-agent-base`.

Install order matters for pull cost. Docker invalidates every layer **above** a changed layer, and a client pulls only layers whose digest it lacks. Therefore install the **more frequently updated, larger** binary on top:

1. base (`powbox-agent-base`)
2. Codex install layer (infrequent updates)
3. Claude install layer (frequent, larger updates)
4. shared seeding assets: both hooks, both skills trees, both statusline assets, prompt template, build epoch.

Consequence:

- **Claude updates** (the common case) change only the top layer → clients pull only the Claude layer. Codex layer underneath is reused. This is the bandwidth win, achieved with one image and one tag.
- **Codex updates** (rare) change the lower layer → the Claude layer above rebuilds and both are pulled. Unavoidable with any single-image stacking, and accepted.

Each binary install is its own layer keyed by its own build arg (`CLAUDE_CODE_VERSION`, `CODEX_VERSION`) so that edits to hooks/skills do not trigger binary reinstalls.

### Entrypoint: seed both, exec one

The entrypoint must seed both agents unconditionally, then exec the primary agent's CMD. This is required — without it, a delegated invocation of the non-primary agent would hit an unseeded config (no instruction render, no `config.toml` migration, no `~/.agents` symlink, no seeded skills).

Plan:

- Replace the two shims (`entrypoint-claude.sh`, `entrypoint-codex.sh`) with a single `entrypoint-agent.sh` that:
  1. Reads `PRIMARY_AGENT` (`claude` | `codex`) from the environment.
  2. Runs **every** registered agent's setup hook. The hooks are already idempotent, no-clobber, and `build-epoch`-gated, so re-running both is cheap and safe.
  3. Exports the primary agent's `AGENT_*` variables (`AGENT_CONFIG_DIR`, `AGENT_NAME`, `AGENT_AUTONOMY_FLAG`, `AGENT_INSTRUCTION_FILE`).
  4. `exec /usr/local/bin/entrypoint-core.sh "$@"`.
- `entrypoint-core.sh` is unchanged (still ends with `exec "$@"`).
- The per-agent hooks (`entrypoint-{claude,codex}-hook.sh`) are retained as-is but invoked from the unified shim against each agent's `AGENT_CONFIG_DIR`. Each hook must remain runnable for a non-primary agent (it must not assume it owns the rendered top-level instruction file).

The instruction-file render (`CLAUDE.md` vs `AGENTS.md`) and statusline settings belong to the **primary** agent only; peer seeding is limited to config dir, skills, symlink, and `config.toml` migration.

### Volumes: both mounted from day 1

Every launch mounts both config volumes regardless of primary agent:

- `claude-config` → `/home/node/.claude`
- `codex-config` → `/home/node/.codex` (with `~/.agents` → `~/.codex/agents` as today)

This is a hard requirement for cross-invocation. The shared volumes (`agent-gh-config`, `agent-pnpm-store`, `agent-zsh-history`) and per-project `node_modules` volume are unchanged.

### Compose

Collapse `compose.claude.yml` and `compose.codex.yml` so both config volumes and both API-key env vars (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) are present on the single `agent` service, all pointing at `powbox-agent:latest`. `compose.shared.yml` is otherwise unchanged. The launcher supplies `PRIMARY_AGENT` and the CMD.

### Build orchestration

- `docker-bake.hcl`: replace the `claude` and `codex` targets with a single `agent` target (dockerfile `docker/agent/Dockerfile`, tag `powbox-agent:latest`, args `CLAUDE_CODE_VERSION` + `CODEX_VERSION`). Keep the `base` target. Update the `all`/`default` groups.
- `scripts/build-image.sh`: targets become `base | agent | all`. Keep `--claude-version` / `--codex-version` (both feed the one image). `--pull` still applies only to the upstream base.

### Launcher and macros

`cc` / `cx` stay as the user-facing entry points. Agent identity is runtime-only:

- `launch-agent.sh` keeps its `<claude|codex>` first argument, but now:
  - Always uses `powbox-agent:latest` via the merged compose.
  - Passes `PRIMARY_AGENT=$AGENT` into the container.
  - Keeps `CONTAINER_NAME="${AGENT}-${PROJECT_NAME}"` so Claude and Codex sessions on the same repo remain distinct and separately resumable.
  - Keeps the per-agent CMD and the resume/continue branch keyed on `$AGENT` (Claude history pre-flight vs `codex resume --last`, `--exec` for codex, etc.).
  - Always ensures both `claude-config` and `codex-config` volumes exist (today it conditionally creates only one).
- The wrapper scripts (`commands/{claude,codex}-container.{sh,ps1}`) and the `cc`/`cx` functions in `shell/powbox.{sh,ps1}` need no behavioral change beyond pointing at the unified image path.

### Prompt template: advertise the peer agent

`docker/shared/container-agent.md.tmpl` must tell each agent that the other executable is present and callable in-container. Add a short "Delegating to another agent" section listing the peer executable(s) and their autonomy flags (e.g. `claude --dangerously-skip-permissions`, `codex --dangerously-bypass-approvals-and-sandbox`), framed as "available for delegated sub-tasks such as reviews."

Because the peer list is the same for every agent now, it can be rendered from the agent registry rather than hardcoded per-agent, so adding a future harness updates every agent's prompt automatically. Exact mechanism (new `${AGENT_PEERS}`-style substitution vs a static block) is an implementation detail to settle in the relevant commit.

## Cross-invocation behavior

- An agent delegates by invoking the peer's real executable name directly (no shim). Both binaries are on `PATH`.
- Both configs are already seeded at container start, so the peer runs without first-run setup latency.
- Both volumes persist independently, so a delegated peer session shares the same logins and skills the user would get launching that agent directly.

## Migration and backward compatibility

- The `claude-config` and `codex-config` volumes are reused unchanged; existing logins, skills, and history carry over.
- Old images `powbox-claude` / `powbox-codex` become obsolete after cutover; the launcher must not reference them. Document a one-line cleanup (`docker image rm`) in the README, non-destructive to volumes.
- `README.md` and `AGENTS.md` (Architecture, Key Paths, Entrypoint sections) must be updated to describe the single image, the dual-seed entrypoint, and both-volumes-always-mounted.

## Future work

- Volume unification via subpath mounts from one named volume (`agent-home/{claude,codex,agents}`), once the single image is stable.
- A first-class agent registry (table of name → binary, install layer, config dir, hook, skills dir, autonomy flag, instruction file) to drive the Dockerfile, entrypoint, prompt template, and launcher from one source as more harnesses are added.
- Reconsider split tags only if a future harness is heavy and runtime-optional.

## Implementation order

1. Add `docker/agent/Dockerfile` (base → Codex layer → Claude layer → shared assets) and the unified `entrypoint-agent.sh`; keep both hooks.
2. Update `docker-bake.hcl` and `scripts/build-image.sh` for the single `agent` target.
3. Merge compose files; mount both config volumes; thread `PRIMARY_AGENT`.
4. Update `launch-agent.sh` (image, env, both-volume ensure) and verify `cc`/`cx` unchanged in behavior.
5. Update the prompt template to advertise the peer agent.
6. Update `README.md` and `AGENTS.md`.
7. Remove the obsolete `docker/claude` and `docker/codex` Dockerfiles and per-agent compose files.
