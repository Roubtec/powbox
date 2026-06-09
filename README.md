# PowBox Dockerized Development Sandbox

PowBox builds and launches isolated Docker environments for CLI coding agents.

The repo uses a shared Docker base image for common tooling and a single unified agent image layered on top of it that ships both the Claude Code and Codex binaries. Which agent runs is chosen at container start via the `PRIMARY_AGENT` env var; both agents are seeded so either can invoke the other in-container.

Runtime orchestration is handled by shared Compose files at the repo root.

Image builds are handled by `docker buildx bake` through wrapper scripts so cached builds are the default and clean rebuilds are explicit.

## Quick Start

Get from a fresh clone to a working PowBox in three steps.

**Prerequisites:** Docker Desktop or Docker Engine with a working `docker buildx`. `npm` on the host `PATH` is recommended — it is used to check for newer agent releases (without it the agent images still build, but version-staleness checks report `(unknown)`). Codex also needs `OPENAI_API_KEY` exported before launching; Claude can optionally use `ANTHROPIC_API_KEY`.

1. **Clone the repo** somewhere stable — your shell profile will point at this path:

   ```bash
   git clone https://github.com/Roubtec/powbox.git ~/code/powbox
   ```

2. **Load the shell helpers** by adding one line to your shell profile, then reloading it. `POWBOX_ROOT` is auto-detected from the file's own location, so no extra configuration is needed.

   Bash / zsh — add to `~/.bashrc` or `~/.zshrc`, then `source` it:

   ```bash
   source "$HOME/code/powbox/shell/powbox.sh"
   ```

   PowerShell — add to `$PROFILE` (`notepad $PROFILE`), then reload with `& $PROFILE`:

   ```powershell
   . "C:\path\to\powbox\shell\powbox.ps1"
   ```

   This exposes the `cc`, `cx`, and `agent-*` helpers in your shell.

3. **Build the images** with `agent-update`. It prints an update report and then prompts before doing anything. On a machine with no images yet, everything shows as stale, so confirming performs the first full build (base + the unified agent image):

   ```bash
   agent-update
   ```

That's it — you now have a functioning PowBox. Launch an agent in any project directory:

```bash
cc ~/projects/myapp      # Claude
cx ~/projects/myapp      # Codex
```

Re-run `agent-update` any time to pick up newer agent releases or a refreshed base image; it only rebuilds what is actually stale. See [Profile Shortcuts](#profile-shortcuts) for the full helper reference and [Build Modes](#build-modes) for invoking builds directly.

## Layout

- `docker/base/Dockerfile`: shared toolchain image (Node.js, Python, PHP, PostgreSQL 16, Git, shell utilities, and more) used by the unified agent image
- `docker/agent/Dockerfile`: the unified `powbox-agent:latest` image on top of the shared base; installs both the Codex and Claude binaries (Codex below Claude — see [Build Modes](#build-modes)) plus the per-agent seed assets and the entrypoint
- `compose.shared.yml`: common runtime service and shared volumes
- `compose.agent.yml`: agent runtime overlay — mounts both config volumes and passes both API keys and `PRIMARY_AGENT`, all on a single `agent` service pointing at `powbox-agent:latest`
- `docker-bake.hcl`: named Bake targets for `base`, `agent`, and `all`
- `commands/`: user-facing host commands for launch, smoke-test, volume pruning, session history reset, and baked-skill refresh
- `shell/`: sourceable shell libraries (`powbox.sh`, `powbox.ps1`) that expose the short helpers (`cc`, `cx`, `agent-*`) from a single profile line
- `scripts/`: shared internal build, launch, and smoke-test helpers
- `docker/shared/container-agent.md.tmpl`: shared agent instruction template (rendered per-agent at startup)
- `docker/shared/entrypoint-agent.sh`: the unified entrypoint — selects the primary agent, seeds every agent at startup, then hands off to `entrypoint-core.sh`
- `docker/shared/entrypoint-{claude,codex}-hook.sh`: per-agent config-seeding hooks, run in full for every agent at startup
- `docker/claude/agent-container/`: Claude-specific seed assets baked into the image at `/home/node/.agent-container/claude/` (statusline script, statusline settings overlay, `skills/` for reusable Claude skills)
- `docker/codex/agent-container/`: Codex-specific seed assets baked into the image at `/home/node/.agent-container/codex/` (`skills/` for reusable Codex skills)

## Build Modes

Cached builds are the default.

Use the root build wrappers to rebuild the images you need. Build targets are `base`, `agent`, and `all`.

Both `--claude-version` and `--codex-version` feed the single `agent` image. The Dockerfile installs Codex below Claude, so bumping the Claude version (the common, frequent case) busts only the Claude layer and the cheap asset/entrypoint layers above it, while the Codex layer underneath is reused from cache. Bumping the Codex version rebuilds the Claude layer on top as a side effect — an accepted, rarer cost. `agent-update` exploits this by pinning each binary's version per build (see [Profile Shortcuts](#profile-shortcuts)).

Examples:

```bash
./build.sh base
./build.sh agent
./build.sh agent --claude-version latest
./build.sh agent --codex-version latest
./build.sh agent --codex-version latest --no-cache
./build.sh base --no-cache --pull
```

## Updating Agent Instructions

Container instructions for both agents are generated from a single shared template (`docker/shared/container-agent.md.tmpl`).
The template is baked into the unified image once per agent (at `/home/node/.agent-container/<agent>/agent.md.tmpl`) and rendered with agent-specific variables at container start.

After editing the template, rebuild the agent image for the changes to take effect:

```bash
./build.sh agent
# or rebuild everything (base + agent)
./build.sh
```

Alternatively, pass `--build` (or `-Build` in PowerShell) to the launch command to rebuild before starting:

```bash
cc --build
cx --build
```

No volume cleanup is needed — the entrypoint conditionally re-renders the template on container start when the image epoch is greater than or equal to the last-written volume epoch.

## Image-Baked Agent Skills

Repo-agnostic skills are baked into the unified image, one tree per agent. They are designed to provide the same functionality across both agents, even though the per-agent SKILL.md files differ where the underlying mechanics differ (e.g. Claude uses its `Agent` tool with `subagent_type: "general-purpose"`; Codex uses its built-in `worker` / `explorer` subagent types).

Per-agent sources (each copied into the image under `/home/node/.agent-container/<agent>/skills/`, which each agent's setup hook reads via `AGENT_SEED_DIR`):

- Claude — `docker/claude/agent-container/skills/`
- Codex — `docker/codex/agent-container/skills/` (each skill additionally ships an `agents/openai.yaml` for UI labels and default prompts)

At container start, the entrypoint seeds the baked skills into each agent's user-level skills directory from the same epoch-gated block that re-renders the agent instruction template (every agent is seeded, not just the primary one):

- Claude — `$CLAUDE_CONFIG_DIR/skills/` (backed by the `claude-config` volume)
- Codex — `$HOME/.agents/skills/` (backed by the `codex-config` volume via a `~/.agents → ~/.codex/agents` symlink seeded by the entrypoint)

Seeding is no-clobber at the skill-directory level: existing skill folders are never overwritten, so user-modified copies are preserved.
This also means a rebuilt image with updated skill text does *not* replace the stale copies already on the volumes. To push the latest baked skills onto the volumes after a rebuild, run `agent-update-skills` (or `commands/update-skills.*` directly) — it copies each baked skill over the volume copy in one throwaway container, so you no longer need to enter a container, delete skills by hand, exit, and relaunch to re-seed. It works whether or not any agent containers are running (they share the volumes); skills you authored on the volume that are not baked into the image are left untouched. See [Refreshing Skills](#refreshing-skills) below.

Every skill powbox seeds carries a hidden `.powbox-seeded` ownership marker (recording the image build epoch and the powbox commit that built it). The marker means *"powbox owns this copy"*: the refresher may overwrite or prune a marked skill, while a folder **without** the marker is treated as user-authored and is never touched. To adopt a seeded skill as your own (fork-and-keep), delete its `.powbox-seeded` (or rename the folder), and powbox leaves it alone for good.

Per-repo skills (e.g. `.claude/skills/<name>/` or `.agents/skills/<name>/`) still take precedence at invoke time, so any repo can override an individual skill without losing the rest.
User-added skills in the same volume directory are unaffected by image rebuilds.

Each agent discovers these skills at startup and includes their `SKILL.md` frontmatter in the model-visible skills list, where the description drives implicit invocation. Both agents also accept the explicit invocation form (Claude: `/<skill-name>`; Codex: `$<skill-name>`).

#### Claude Dynamic Workflows (experimental)

`docker/claude/agent-container/workflows/` holds Claude-only [dynamic workflows](https://code.claude.com/docs/en/workflows) — JavaScript orchestration scripts that the runtime executes in the background, spawning and sequencing subagents at scale. They are a testing-batch reimagining of the orchestration-heavy skills (`address-tasks`, `address-review`): the control flow becomes code instead of prose. The two converted workflows use **different worktree strategies** (the runtime's built-in `isolation: "worktree"` is deliberately *not* used — it can't honor powbox's `.worktrees/$CONTAINER_NAME/<slug>` convention and starts each agent from the default branch): `address-tasks` fans out, so its agents create and reuse explicit `.worktrees/$CONTAINER_NAME/<slug>` worktrees like the `address-tasks-worktrees` skill; `address-review` is a single-PR sequential pipeline, so every stage shares the one checkout on the PR branch. Codex has no workflow runtime, so there is no Codex sibling; the Claude entrypoint hook seeds these `.js` files into `~/.claude/workflows/` (no-clobber file copy, not yet part of the `.powbox-seeded` refresh flow). See [the directory README](docker/claude/agent-container/workflows/README.md) for the conversion rationale, the worktree decision, and open questions.

### Refreshing Skills

Because seeding is no-clobber, editing a skill in this repo and rebuilding the image is not enough — the volumes still hold the previously-seeded copy. `commands/update-skills.*` closes that gap by copying the freshly baked skills over the volume copies in a single throwaway container, replacing the old manual dance (enter a container, delete skills, exit, relaunch to re-seed).

It seeds from whatever is in `powbox-agent:latest`, so rebuild the image first (e.g. `cc <project> --build`, `agent-update`, or `build.sh agent`) so the baked skills reflect your edits. The config volumes are shared by every agent container, so this works whether or not any containers are running — a running agent picks up a refreshed skill the next time that skill is invoked (restart it for certainty).

The command prints a plan (how many skills it will seed and refresh), then applies it. Using the `.powbox-seeded` ownership marker it also handles two edge cases:

- **Conflicts** — an *unmarked* folder whose name collides with a baked skill is ambiguous (a legacy seed from before markers, or a skill you authored/forked). It is **never overwritten silently**; it is reported and left untouched. Resolve it with `--adopt-all` (take the baked version and start tracking it) — but only if it is a stale seed, not your own work; otherwise rename your folder first.
- **Obsolete seeds** — a *marked* skill that is no longer baked into the image is reported, and removed only with `--prune`.

With a terminal attached you are prompted before adopting or pruning; the flags pre-approve those non-interactively. Skills you authored (no marker) are never reported, adopted, or pruned.

```bash
# Preview the plan (seed / refresh / conflicts / obsolete) without changing anything
./commands/update-skills.sh --dry-run

# Refresh the baked skills onto both config volumes (prompts before adopt/prune on a TTY)
./commands/update-skills.sh

# Non-interactive: also drop obsolete seeds and take baked versions of conflicts
./commands/update-skills.sh --prune --adopt-all
```

On PowerShell the flags are `-DryRun`, `-Prune`, `-AdoptAll`:

```powershell
.\commands\update-skills.ps1 -DryRun
.\commands\update-skills.ps1
.\commands\update-skills.ps1 -Prune -AdoptAll
```

If you are using the profile shortcuts described below, the same script is exposed as `agent-update-skills` (flags forwarded). `agent-update` also offers to run it for you right after a successful image rebuild.

### Image provenance

Each image records the powbox commit it was built from, so you can tell whether a running image predates repo changes even when the agent binaries themselves are current. Because the build is layered, a piecemeal-updated image can carry up to **three** distinct commits: the base image has its own parent, and the Claude layer can be rebuilt without touching the Codex layer below it.

The commit that built each layer is recorded two ways:

- **Image labels** `powbox.commit.{base,codex,claude}` (plus `powbox.{codex,claude}.version`) for host-side `docker image inspect`. The host helper `agent-image-info` prints them alongside your working-tree HEAD, and `agent-update` shows the same block before asking to rebuild.
- **Baked files** `/home/node/.powbox/{base,codex,claude}.commit` for in-container reading. The `powbox-provenance` command prints them; an agent in the container can diff the building commit against the powbox repo (`git -C <powbox-repo> diff <claude-commit>..HEAD`).

The Codex commit is special: stamping it inside the Codex install layer would bust that layer's cache on every commit (defeating the Codex-below-Claude ordering), so the build script computes it — using `HEAD` when that layer rebuilds and carrying the previous value forward when it is reused — and records it only in the top metadata layer. A `-dirty` suffix marks an image built from an uncommitted worktree. No automated decision is made from these commits; they are introspection only.

## Runtime

Both agent launch flows resolve through the same shared Compose base and the same Compose project name.

The shared GitHub and zsh-history volumes are declared once in the shared Compose configuration.

Shared volume names are kept stable to preserve existing data:

- `agent-gh-config`
- `agent-zsh-history`

The launcher also creates **per-project** volumes, keyed by project so a project's Claude and Codex containers share them:

- `agent-nm-<project>` → the root `node_modules`
- `agent-wt-<project>` → the `.worktrees` tree, which **also holds the per-project pnpm store** (`.worktrees/.pnpm-store`)

> The pnpm store moved from a single shared `agent-pnpm-store` volume to a per-project store inside each `agent-wt-<project>` volume so that worktree `pnpm install` can **hardlink** package files from it instead of copying them (the store and the worktree `node_modules` must share one mount — see [Git Worktree Parallel Development](#git-worktree-parallel-development)). The old shared `agent-pnpm-store` volume is no longer mounted and can be removed with `prune-volumes`.

Agent-specific state volumes remain separate, and both are always mounted regardless of which agent is primary (required so the primary agent can invoke the other in-container — see [Cross-Agent Delegation](#cross-agent-delegation)):

- `claude-config` → `/home/node/.claude`
- `codex-config` → `/home/node/.codex`

`cc` and `cx` still produce distinct, separately-resumable containers per project — the launcher selects the primary agent via `PRIMARY_AGENT` and keeps the per-agent container-name prefix (`claude-` / `codex-`), so Claude and Codex sessions on the same repo never collide.

Both API keys are always passed through to the container — `OPENAI_API_KEY` for Codex and the optional `ANTHROPIC_API_KEY` for Claude — so that whichever agent is primary, a delegated peer invocation of the other agent can still authenticate.
Codex requires `OPENAI_API_KEY` set on the host before launching (interactively or headless); Claude optionally accepts `ANTHROPIC_API_KEY` as a fallback if the OAuth session expires.

Either agent can be started first in a clean Docker environment.

All shared volumes are marked `external` in the Compose files and pre-created by the launch scripts on first use.

### Cross-Agent Delegation

Because the unified image ships both agent binaries on `PATH` and the entrypoint seeds every agent's config at startup, the running primary agent can invoke the other agent directly inside the same container — no Docker-in-Docker, no mounted socket, no sibling container.

This is intended for delegated sub-tasks such as asking the other agent for an independent review, or handing it a self-contained piece of work.
The peer runs against its own seeded config (login, skills, instruction file) and shares the same `/workspace` bind mount, so it sees the same files.
The in-container instruction file (`CLAUDE.md` for Claude, `AGENTS.md` for Codex) renders a "Delegating to another agent" section listing each peer's executable and autonomy flag (e.g. `claude --dangerously-skip-permissions`, `codex --dangerously-bypass-approvals-and-sandbox`).

## Nested Containers (rootless Podman)

The image ships **rootless [Podman](https://podman.io/)** so an in-sandbox agent can build, run, and orchestrate its own containers — databases, Adminer, whole service stacks — for projects whose dev workflow depends on them. A `docker` shim and `podman compose` mean `docker` / `docker compose` commands and project scripts work unchanged.

This is deliberately **not** Docker-in-Docker or a mounted host socket — both of which would hand a runaway agent the keys to the host. Podman runs as the unprivileged `node` user through a user namespace, so the blast radius stays inside the container: no privileged daemon, no host socket. As a bonus, rootless Podman NATs nested containers' outbound traffic through this container's network namespace, so they **inherit the egress firewall** — nested containers reach the public internet but not your LAN or host, just like the agent.

- **Persistence:** a per-container `agent-podman-<agent>-<project>` volume backs Podman's storage at `/home/node/.local/share/containers`, so pulled images and `podman volume`s (e.g. a database's data) survive container restarts. It's keyed per outer container (agent + project), not just per project, so a project's Claude and Codex containers can run concurrently without two Podman instances sharing — and corrupting — one graphroot.
- **Shared image cache:** a single global `agent-podman-imagestore` volume (layered under every per-container graphroot via Podman's `additionalimagestores`) holds a small curated set of common dev images — `postgres`, `redis`, `mariadb`, `adminer` — so they resolve instantly without a per-container pull. Agent containers mount it **read-only**; it is populated by a dedicated, short-lived writer the launcher spawns on each launch (the only context that mounts it read-write), so a runaway agent in one project can't poison the cache every other project reads. Seeding is idempotent and quick once populated. Override the curated set with `POWBOX_IMAGE_STORE_IMAGES`; to force a refresh, remove the `agent-podman-imagestore` volume and relaunch.
- **Access pattern:** reach a nested service from the agent via its **published port on `localhost`**; container-to-container (e.g. within a compose stack) uses service names over netavark/aardvark-dns.
- **Storage driver:** fuse-overlayfs when `/dev/fuse` is available, otherwise the slower `vfs` driver. The driver is **pinned per `agent-podman-*` volume on first init** (recorded on the volume) and honoured on every later launch — it is not re-chosen each start, so a store first initialised on `vfs` (or moved to a host without `/dev/fuse`) won't silently flip; switching needs a clean store (`podman system reset` or dropping the volume).
- **Devices:** rootless Podman needs two host devices — `/dev/fuse` (overlay storage driver) and `/dev/net/tun` (nested-container networking; without it default `podman run` can't bring up its network). Both are passed through under the single `POWBOX_PODMAN` gate: `auto` attaches each when the host exposes it, `on` forces both (Docker Desktop), `off` skips both.

The ceiling: GUI apps, phone emulators, and non-headless browsers are the signal to move that workload to a dedicated VM. See [docs/rootless-podman.md](docs/rootless-podman.md) for design notes and a validation procedure.

## Per-Project Workspace Paths

Each project is mounted at `/workspace/<project>-<hash>` inside the container instead of a shared `/workspace` path.
This gives every project a unique absolute path, which prevents tools that cache by path (Claude project memory, build caches, etc.) from colliding across projects.
The container's working directory is set to the project-specific path automatically.

## Read-Only Context Volume

Pass `--ctx <path>` to mount a host directory as a read-only volume at `/ctx` inside the container.
This is useful for giving the agent access to reference code, data sources, or other content without allowing modifications.

```bash
./commands/claude-container.sh ~/projects/myapp --ctx ~/datasets/reference
```

The volume is only present when `--ctx` is specified; otherwise `/ctx` is an empty directory.

### Context Changes on Resume

When reusing a stopped container (the default, or with `--persist`), the launch script compares the requested `--ctx` mount against what the container was originally created with.
If the value differs (including going from no context to a new path, or switching between paths), the stopped container is removed and recreated with the updated mount.
Persistent state in named volumes (agent config, GitHub CLI, pnpm store, etc.) is unaffected by this recreation.

Omitting `--ctx` is treated as "keep whatever is already mounted" — the container is reused as-is without recreation.
To explicitly clear a previously mounted context, use `--volatile` to force a fresh container.

Using the explicit `--resume` / `-Resume` flag always resumes the container exactly as originally created — any `--ctx` / `-Ctx` value passed alongside is ignored (a warning is printed).
To apply a ctx change, omit `--resume` and let the script auto-detect and recreate as needed.

## Workspace Shadow Mounts

When the host OS differs from the container OS (e.g. Windows host, Linux container), Node.js native binaries compiled for one platform break on the other.
The root `node_modules` is already handled by a per-project Docker volume, but monorepo subpackages each have their own `node_modules` that would otherwise be shared through the bind mount.

At container start, the entrypoint auto-detects workspace subpackages and mounts tmpfs over each nested `node_modules` directory.
This shadows the host content inside the container so that `pnpm install` (or `npm install`) writes Linux-native binaries into an ephemeral filesystem that never touches the host.

### Auto-Detection

The entrypoint scans for workspace declarations in this order:

1. **pnpm** — reads `pnpm-workspace.yaml` `packages` globs
2. **npm / yarn** — reads `package.json` `workspaces` array (or `workspaces.packages`)
3. **`.powbox.yml`** — reads custom `shadow` glob patterns (see below)

All matched directories get a tmpfs overlay.
If none of these files exist, the feature is a no-op.

### Custom Shadow Paths (`.powbox.yml`)

For paths that auto-detection does not cover, add a `.powbox.yml` to the project root:

```yaml
shadow:
  - packages/*/node_modules       # same as what auto-detect would find
  - tools/legacy-build/vendor     # non-standard path
```

Patterns are resolved relative to the project root.
A pattern containing glob metacharacters (`*`, `?`, `[`, `]`) is expanded as a glob, and only directories that exist at container start are shadowed.
A literal path (no glob metacharacters) is shadowed even if it does not exist yet — it is created and tmpfs-mounted at startup. This lets committed declarations for gitignored, fresh-checkout-absent directories take effect without a manual `mkdir`.
In both cases a pattern that resolves outside the workspace root is rejected.

Auto-detection and `.powbox.yml` patterns are merged and deduplicated.

### Git Worktree Parallel Development

Shadowed literal paths make the container a clean home for git-worktree-based parallel development — for example an orchestrator that creates one worktree per task under `.worktrees/`. Declare the worktree scaffolding in `.powbox.yml`:

```yaml
shadow:
  - .worktrees          # worktree working trees
  - .claude/worktrees   # harness-native worktrees (EnterWorktree / agent isolation)
  - .git/worktrees      # per-worktree git metadata
```

These directories are gitignored and absent on a fresh checkout. `.claude/worktrees` and `.git/worktrees` are literal shadow paths, so they are auto-created and tmpfs-shadowed at startup — no manual `mkdir` or `shadow-refresh.sh` needed. (Literal paths under `.git/` are only auto-created when `.git` is a real directory — the normal main checkout. If the container's workspace is itself a *linked* worktree, where `.git` is a file pointing into the main repo, the `.git/worktrees` entry is skipped with a diagnostic instead of creating a bogus `.git/` tree.)

**`.worktrees` is backed by a volume, not tmpfs.** The launcher mounts the per-project `agent-wt-<project>` ext4 volume at `.worktrees`, so that mount (not a tmpfs shadow) is what shadows the host path. The `.worktrees` entry in `.powbox.yml` is then a harmless **fallback**: `shadow-mounts.sh` skips it because the path is already a mountpoint, so existing `.powbox.yml` files keep working unchanged, and `.worktrees` still gets tmpfs-shadowed if the container is ever launched without the volume.

**Why a volume.** The volume also holds the pnpm store at `.worktrees/.pnpm-store`. Because the store and every `.worktrees/<task>/node_modules` live under that **one mount**, `pnpm install` inside a worktree **hardlinks** package files from the store instead of copying them — `link(2)` only works within a single mount, so co-location is the whole point. Worktree installs drop from a full ~425 MB–1.1 GB copy to tens of MB of metadata, there is **no shared 2 GB cap**, and many worktrees can install concurrently. The volume is on the Docker VM's ext4 (disk, hundreds of GB), not RAM.

**Durability model.** The common `.git` directory (commit objects and branch refs) is *not* shadowed, so it lives on the host bind mount and survives container recycle: committed work is durable. The `.worktrees` **volume persists** across recycles too — keeping the pnpm store warm — but the per-worktree `.git/worktrees/<name>` metadata is ephemeral tmpfs. So after a recycle a leftover `.worktrees/<owner>/<task>` working dir can be orphaned (its `.git` pointer dangles); the `address-tasks-worktrees` bootstrap prunes such orphans while preserving `.pnpm-store`. Shadowing `.git/worktrees` also keeps the host's (Windows-absolute-path) worktree registrations out of the container, and vice-versa. Because the volume is project-keyed, the project's Claude and Codex containers share it; each namespaces its worktrees under `.worktrees/$CONTAINER_NAME/` and prunes only its own subdir, so one agent's cleanup can never delete the other's in-progress worktrees.

**Discipline.** Commit and push often. Since only the common `.git` persists to the host, push committed work to the remote, then `git pull` on the host to sync — a worktree's uncommitted working-tree changes are not durable.

**tmpfs sizing (the other two roots, and the `.worktrees` fallback).** `.claude/worktrees` and `.git/worktrees` are tmpfs and share the `SHADOW_TMPFS_SIZE` cap (default 2g) — they hold metadata and are tiny, so this rarely matters. The old constraint where *all worktrees' `node_modules`* shared one 2g tmpfs only applies in the fallback path where `.worktrees` itself is tmpfs (launched without the volume); there, many parallel `pnpm install`s can exhaust it and fail with `ENOSPC` — relaunch with a larger `SHADOW_TMPFS_SIZE` (see [Configuration](#configuration)), or with the worktrees volume.

### Mid-Session Refresh

If you add a new workspace package after the container has started, its `node_modules` will not be shadowed until you run:

```bash
shadow-refresh.sh
```

This re-runs detection and mounts tmpfs over any new directories that were not previously shadowed.
Already-mounted paths are skipped.

### Lifecycle

Subpackage shadow mounts are **ephemeral** — they use tmpfs (memory-backed) and are lost when the container stops.
After restarting (or resuming) a container, run `pnpm install` to repopulate subpackage `node_modules` from the per-project pnpm store.
With a warm store this typically takes only a few seconds.

The root `node_modules` (`agent-nm-<project>`) and the `.worktrees` tree with its pnpm store (`agent-wt-<project>`) are **Docker volumes**, not tmpfs — they persist across restarts, so the store stays warm and worktree installs stay cheap.

### Configuration

Each tmpfs mount is capped at **2 GB** by default.
Because tmpfs allocates lazily, this ceiling bounds the worst case and does not reserve memory up front — an empty or lightly used mount costs almost nothing.
Override the per-mount limit by exporting `SHADOW_TMPFS_SIZE` (any value accepted by `mount -o size=`, e.g. `4g`, `512m`) before launching the container.
Both `shadow-mounts.sh` invocations (`entrypoint-core.sh` and `shadow-refresh.sh`) pass `--preserve-env=SHADOW_TMPFS_SIZE` to sudo so the override is honoured.
If a mount fills up, `pnpm install` will fail with a clear `ENOSPC` error — raise the limit and re-run.

### Security

`shadow-mounts.sh` is a root-owned, immutable script invoked via scoped sudo.
It refuses to mount outside `/workspace/`.
tmpfs mounts are container-namespace-scoped and invisible to the host — not an escape vector.

The container requires **`CAP_SYS_ADMIN`** (granted in `compose.shared.yml`) because Docker's default seccomp profile blocks the `mount` syscall without it.
Note that `CAP_SYS_ADMIN` is granted to the container as a whole by Docker — sudoers restricts which commands may be run via `sudo`, but does not scope a Linux capability to a single script.
The `node` user cannot invoke arbitrary commands as root (sudo is scoped), but any process in the container holds `CAP_SYS_ADMIN` for its lifetime.
`shadow-refresh.sh` requires this capability mid-session, so it cannot be dropped after startup.

## Commands

The user-facing command surface lives at the repo root and in `commands/`:

- `build.sh` and `build.ps1` at the repo root for image builds
- `commands/claude-container.*` and `commands/codex-container.*` for launches
- `commands/smoke-test.*` for smoke-testing the unified agent image
- `commands/prune-volumes.*` for orphaned `agent-nm-*` / `agent-wt-*` / `agent-podman-*` cleanup
- `commands/reset-claude-history.*` for wiping Claude session history from the shared `claude-config` volume
- `commands/update-skills.*` for re-seeding the image-baked skills onto the `claude-config` / `codex-config` volumes, with `--prune`/`--adopt-all` to drop obsolete seeds and resolve unmarked name-collisions (its in-container worker is `docker/shared/update-skills-incontainer.sh`; the shared copy logic and `.powbox-seeded` marker live in `docker/shared/seed-skills.sh`, also used by the entrypoint hooks)
- `commands/check-updates.*` for checking whether newer agent releases are available

## Resuming Sessions

Session resumption is opt-in via `--continue` / `-Continue` on `cc` and `cx` (and on the underlying `commands/*-container.*` scripts).
Without the flag, both agents start a fresh session — useful because resumed sessions inherit the prior run's inference-duration stats and other counters that `/clear` does not reset.
Pass the flag when you want to pick up an interrupted session (for example after a forced reboot or crash).

The flag decision is baked into the container's CMD at creation time.
When the requested flag value differs from what the stopped container was created with, the launcher recreates the container — the same recycling mechanism used for `--ctx` / `-Ctx` changes.
Persistent state in named volumes (agent config, GitHub CLI, pnpm store, etc.) is unaffected by this recreation.
If the container is already running with a different flag value, the launcher attaches to the existing process and warns that the flag is ignored; stop and relaunch to apply the change.

Per-agent behavior when `--continue` is set:

- **Claude** — the launcher checks `~/.claude/projects/<slug>/` inside the container and passes `--continue` when history is present; when no history exists it falls back to a plain `claude` launch (bare `claude --continue` would otherwise exit with "No conversation found").
- **Codex** — the launcher passes `resume --last`. Codex filters that to the current working directory and falls through to a fresh interactive session when no resumable session exists there.

The `codex exec ...` path (`--exec` / `-Exec`) stays non-resuming regardless of `--continue`, so one-shot tasks do not unexpectedly attach to prior interactive history.
`--shell` / `-Shell` likewise ignores `--continue` — the container opens a plain zsh.

Use `/clear` inside Claude to discard the resumed context without touching other projects, or run the reset script below for a full wipe across all projects.

Using the explicit `--resume` / `-Resume` flag always restarts the container exactly as originally created — any `--continue` value passed alongside is ignored (a warning is printed), same as `--ctx`.

### Wiping Session History

`commands/reset-claude-history.*` prunes per-project conversation history, todo state, and shell snapshots from the shared `claude-config` volume.
Credentials (`.credentials.json`) and user settings (`settings.json`) are preserved, so no re-auth is required after a reset.

The script refuses to run if any container currently has the `claude-config` volume mounted — stop running Claude containers first (`agent-list` / `cc-list` help identify them).

```bash
# Preview what would be deleted
./commands/reset-claude-history.sh --dry-run

# Prune with a confirmation prompt
./commands/reset-claude-history.sh

# Prune without prompting (for scripted use)
./commands/reset-claude-history.sh --force
```

On PowerShell, use `-WhatIf` for a preview and `-Force` to skip the confirmation prompt:

```powershell
.\commands\reset-claude-history.ps1 -WhatIf
.\commands\reset-claude-history.ps1
.\commands\reset-claude-history.ps1 -Force
```

If you are using the profile shortcuts described below, the same script is exposed as `agent-reset-claude-history` — all flags (`--dry-run`/`--force` on bash, `-WhatIf`/`-Force` in PowerShell) are forwarded.

## Profile Shortcuts

The repo ships a pair of shell libraries — `shell/powbox.sh` (bash/zsh) and `shell/powbox.ps1` (PowerShell) — that define all the short commands (`cc`, `cx`, `agent-prune`, `agent-list`, etc.). Dot-source or `source` the appropriate file from your shell profile and pull updates with `git pull`; there is nothing to copy-paste per release.

Functions exposed by both libraries:

- `cc`, `cx` — launch Claude or Codex in the current directory (or a given path), forwarding every flag to the underlying `commands/*-container.*` script
- `cc-list`, `cx-list`, `agent-list` — list agent containers
- `agent-volumes` — list agent-related Docker volumes
- `agent-prune-stopped`, `agent-prune-volumes`, `agent-prune` — cleanup helpers
- `agent-check-updates` — compare baked agent versions against the latest npm releases, and the base image's recorded source digest against the current `node:24-trixie-slim` registry digest
- `agent-update` — show the full update report, then (only when something is stale) prompt for confirmation before rebuilding. A stale base triggers a full `build.sh all --pull --no-cache` (base + the agent image on top); otherwise the unified image is rebuilt once with each binary's version pinned, so only the stale agent's layer (plus the cheap layers above it) rebuilds while the unchanged binary's layer is reused from cache — no `--no-cache`. On confirmation it re-checks, so an update you approve in another terminal while the prompt waits is still picked up. A missing or unlabeled image counts as stale, so this also bootstraps a machine that has no images yet. After a successful rebuild it offers (on a TTY) to re-seed skills from the fresh image via `agent-update-skills`.
- `agent-update-claude`, `agent-update-codex` — rebuild the unified image bumping just that agent to its latest release, pinning the other binary to its baked version so only the affected layers rebuild (no `--no-cache`)
- `agent-update-base` — re-pull the upstream base image and rebuild the shared substrate layers with the latest package versions, then rebuild the agent image on top (`build.sh all --pull --no-cache`)
- `agent-reset-claude-history` — wipe per-project Claude session history from the shared `claude-config` volume (credentials and settings preserved); forwards flags like `--dry-run`/`--force` (bash) or `-WhatIf`/`-Force` (PowerShell)
- `agent-update-skills` — re-seed the image-baked skills onto the `claude-config` / `codex-config` volumes, overriding the startup no-clobber so a rebuilt image's updated skill text replaces the stale volume copies. Skills are tracked by a `.powbox-seeded` ownership marker, so it refreshes only powbox's own copies and leaves user-authored skills alone. Flags: `--dry-run`/`-DryRun` (preview the plan), `--prune`/`-Prune` (remove obsolete seeds no longer baked), `--adopt-all`/`-AdoptAll` (take the baked version of unmarked name-collisions); on a TTY it prompts before pruning/adopting. Rebuild the image first so the baked skills are current.
- `agent-image-info` — print the powbox commit that built each layer of `powbox-agent:latest` (base / codex / claude/top) from the image's `powbox.commit.*` labels, plus your working-tree HEAD, so a stale image is obvious even when the agent binaries are current. In-container, the baked `powbox-provenance` command prints the same from `/home/node/.powbox/*.commit`. See [Image provenance](#image-provenance).

### Environment Variables

Both libraries honour the same variables:

| Variable | Default | Effect |
|---|---|---|
| `POWBOX_ROOT` | auto-detected from the script's location | Path to your PowBox checkout. Only needed if auto-detection fails. |
| `POWBOX_CD_AFTER_LAUNCH` | `1` | When `cc`/`cx` is called with an explicit project path, cd into that path after the container exits. Set to `0` (or `false`/`no`/`off`) to stay in the original directory. |
| `POWBOX_PODMAN` | `auto` | Whether to pass the host devices rootless Podman needs into the agent: `/dev/fuse` (fuse-overlayfs `overlay` storage driver; absence falls back to the slower `vfs`) and `/dev/net/tun` (nested-container networking; absence breaks default `podman run`). `auto` attaches each device when the launcher's host shell can see it; `on` forces both (use when the Docker daemon/VM has them but the host shell doesn't, e.g. Docker Desktop); `off` skips both. (`POWBOX_FUSE` is a deprecated alias for this variable.) |

Export/assign these before sourcing the library — or before calling `cc`/`cx` — to change behavior without editing the script.

### PowerShell

Add one line to your `$PROFILE` (`notepad $PROFILE`) and reload with `& $PROFILE`:

```powershell
# Optional: only needed if auto-detection fails.
# $env:POWBOX_ROOT = "C:\path\to\powbox"

. "C:\path\to\powbox\shell\powbox.ps1"
```

Common usage:

```powershell
# Launch Claude in the current folder
cc

# Launch Claude in a specific folder, opening a shell instead
cc C:\Projects\MyApp -Shell

# Launch Codex in the current folder
cx

# Run Codex headless
cx -Exec "fix the failing tests"

# Launch either agent with a read-only reference volume at /ctx
cc -Ctx C:\Docs\specs

# Prune orphaned node_modules volumes (dry run first)
agent-prune-volumes -WhatIf
agent-prune-volumes

# Remove all stopped agent containers
agent-prune-stopped

# Full cleanup: remove stopped containers and prune orphaned volumes
agent-prune

# Check for newer agent releases
agent-check-updates

# Review the update report and confirm before rebuilding stale images
agent-update

# Bump just Claude to its latest release (rebuilds only the Claude layers)
agent-update-claude

# Bump just Codex to its latest release (rebuilds Codex + the Claude layer above)
agent-update-codex

# Re-pull the base image and rebuild the shared substrate with latest packages
agent-update-base

# Re-seed updated baked skills onto the config volumes (preview, then apply)
agent-update-skills -DryRun
agent-update-skills
# Also drop obsolete seeds and take baked versions of unmarked name-collisions
agent-update-skills -Prune -AdoptAll

# List Claude containers
cc-list

# List Codex containers
cx-list

# List all agent containers
agent-list

# List agent volumes
agent-volumes
```

All flags accepted by `commands/claude-container.ps1` and `commands/codex-container.ps1` are forwarded by these functions, so `-Build`, `-Detach`, `-Persist`, `-Resume`, `-Continue`, `-Volatile`, and `-Ctx` all work as documented.

### Bash / zsh

Add one line to `~/.bashrc` or `~/.zshrc` and reload with `source ~/.bashrc` (or `source ~/.zshrc`):

```bash
# Optional: only needed if auto-detection fails.
# export POWBOX_ROOT="$HOME/path/to/powbox"

source "$HOME/path/to/powbox/shell/powbox.sh"
```

Common usage:

```bash
# Launch Claude in the current folder
cc

# Launch Claude in a specific folder, opening a shell instead
cc ~/projects/myapp --shell

# Launch Codex in the current folder
cx

# Run Codex headless
cx --exec "fix the failing tests"

# Launch either agent with a read-only reference volume at /ctx
cc --ctx ~/docs/specs

# Prune orphaned node_modules volumes (prompts for confirmation)
agent-prune-volumes

# Remove all stopped agent containers
agent-prune-stopped

# Full cleanup: remove stopped containers and prune orphaned volumes
agent-prune

# Check for newer agent releases
agent-check-updates

# Review the update report and confirm before rebuilding stale images
agent-update

# Bump just Claude to its latest release (rebuilds only the Claude layers)
agent-update-claude

# Bump just Codex to its latest release (rebuilds Codex + the Claude layer above)
agent-update-codex

# Re-pull the base image and rebuild the shared substrate with latest packages
agent-update-base

# Re-seed updated baked skills onto the config volumes (preview, then apply)
agent-update-skills --dry-run
agent-update-skills
# Also drop obsolete seeds and take baked versions of unmarked name-collisions
agent-update-skills --prune --adopt-all

# List Claude containers
cc-list

# List Codex containers
cx-list

# List all agent containers
agent-list

# List agent volumes
agent-volumes
```

All flags accepted by `commands/claude-container.sh` and `commands/codex-container.sh` are forwarded, so `--build`, `--detach`, `--persist`, `--resume`, `--continue`, `--volatile`, and `--ctx` all work as documented.

To move the repo later, either rely on auto-detection (update the `source` / dot-source path) or update `POWBOX_ROOT` to the new path and reload your profile.

## Host Validation

Host-side validation requires Docker Desktop or Docker Engine with a working `docker buildx`.

Inspect the named Bake targets and tags with:

```bash
docker buildx bake --file docker-bake.hcl --print
```

Render the merged runtime config with:

```bash
docker compose -p powbox -f compose.shared.yml -f compose.agent.yml config
```

Smoke test the built image with:

```bash
./commands/smoke-test.sh
```

This runs three stages: a fast presence sweep over every expected CLI; a `pg-dev-up` functional test that stands up a throwaway PostgreSQL cluster and connects through the emitted `DATABASE_URL` (exercising role/db creation, URL encoding, and host binding — things the presence check alone can't); and a rootless-Podman engine test that runs the image with the launch-time device + security wiring and exercises a nested container run, a bridge published port, and the `podman compose` subcommand (so a base/Podman bump that regresses the engine is caught — see [docs/rootless-podman.md](docs/rootless-podman.md)). On a host that cannot expose `/dev/net/tun` (e.g. the Docker Desktop VM under the default `auto`), the Podman stage still validates the static engine wiring (engine present, the `containers.conf` drop-in, `podman info`, the `compose` subcommand) but skips only the nested-run/published-port checks; force the full check with `POWBOX_PODMAN=on`. A genuinely broken image (missing engine, dropped drop-in) fails the stage on any host. Skip the DB stage with `POWBOX_SMOKE_SKIP_DB=1` and the Podman stage with `POWBOX_SMOKE_SKIP_PODMAN=1` — these are independent, so set both for a Stage 1 tools-only presence sweep (PowerShell: `.\commands\smoke-test.ps1 -SkipDb -SkipPodman`).

After launching each agent at least once, `docker volume ls` should show one copy of the shared volumes `agent-gh-config` and `agent-zsh-history`, the per-project `agent-nm-<project>` and `agent-wt-<project>` volumes, a per-container `agent-podman-<agent>-<project>` Podman store, plus separate `claude-config` and `codex-config` volumes.

## Runtime Sanity Check

Launch an interactive shell with `--shell --volatile` to verify the container environment.

### Claude

```bash
./commands/claude-container.sh /path/to/project --shell --volatile
```

Inside the container:

```bash
whoami
echo "$CLAUDE_CONFIG_DIR"
claude --version
gh --version
pnpm config get store-dir
pwd
ls -ld node_modules
```

Expected results:

- user is `node`
- `CLAUDE_CONFIG_DIR` is `/home/node/.claude`
- the pnpm store is per-project at `/workspace/<project>-<hash>/.worktrees/.pnpm-store` (co-located with worktrees so installs hardlink)
- working directory is `/workspace/<project>-<hash>`
- `node_modules` is writable by `node`

### Codex

```bash
./commands/codex-container.sh /path/to/project --shell --volatile
```

Inside the container:

```bash
whoami
echo "$CODEX_CONFIG_DIR"
codex --version
bwrap --version
gh --version
pnpm config get store-dir
pwd
ls -ld node_modules
```

Expected results:

- user is `node`
- `CODEX_CONFIG_DIR` is `/home/node/.codex`
- `bwrap` is available
- the pnpm store is per-project at `/workspace/<project>-<hash>/.worktrees/.pnpm-store` (co-located with worktrees so installs hardlink)
- working directory is `/workspace/<project>-<hash>`
- `node_modules` is writable by `node`

Codex preserves any existing `config.toml` settings in the `codex-config` volume, but the container now auto-seeds a missing `[tui].status_line` plus a missing top-level `terminal_title` default.
The seeded status line uses Codex-native items for model, current directory, remaining context, 5-hour usage, weekly usage, and used tokens.
`terminal_title` is a separate Codex setting for the terminal window or tab title, not the bottom status line.
The seeded title surfaces current directory, git branch, model, and thread title when the terminal supports title updates.
That means a fresh or reset Codex config starts with a richer native status line and title, while existing user customizations remain untouched except for compatibility migrations such as replacing Codex's removed `context-remaining-percent` status item with `context-remaining`.

## License

This project is licensed under the MIT License.

See [LICENSE](LICENSE).
