# PowBox Dockerized Development Sandbox

PowBox builds and launches isolated Docker environments for CLI coding agents.

The repo uses a shared Docker base image for common tooling and two thin agent images layered on top of it.

Runtime orchestration is handled by shared Compose files at the repo root.

Image builds are handled by `docker buildx bake` through wrapper scripts so cached builds are the default and clean rebuilds are explicit.

## Layout

- `docker/base/Dockerfile`: shared toolchain image used by both agents (Node.js, Python, PHP, Git, shell utilities, and more)
- `docker/claude/Dockerfile`: thin Claude image on top of the shared base
- `docker/codex/Dockerfile`: thin Codex image on top of the shared base
- `compose.shared.yml`: common runtime service and shared volumes
- `compose.claude.yml`: Claude-specific runtime overlay
- `compose.codex.yml`: Codex-specific runtime overlay
- `docker-bake.hcl`: named Bake targets for `base`, `claude`, `codex`, and `all`
- `commands/`: user-facing host commands for launch, smoke-test, volume pruning, and session history reset
- `shell/`: sourceable shell libraries (`powbox.sh`, `powbox.ps1`) that expose the short helpers (`cc`, `cx`, `agent-*`) from a single profile line
- `scripts/`: shared internal build, launch, and smoke-test helpers
- `docker/shared/container-agent.md.tmpl`: shared agent instruction template (rendered per-agent at startup)
- `docker/claude/agent-container/`: Claude-specific files baked into the image at `/home/node/.agent-container/` (statusline script, statusline settings overlay, `commands/` for slash commands)

## Build Modes

Cached builds are the default.

Use the root build wrappers to rebuild the images you need.

Examples:

```bash
./build.sh base
./build.sh claude --claude-version latest
./build.sh codex --codex-version latest
./build.sh codex --codex-version latest --no-cache
./build.sh base --no-cache --pull
```

## Updating Agent Instructions

Container instructions for both agents are generated from a single shared template (`docker/shared/container-agent.md.tmpl`).
The template is baked into each agent image at build time and rendered with agent-specific variables at container start.

After editing the template, rebuild the affected images for the changes to take effect:

```bash
./build.sh claude
./build.sh codex
# or rebuild everything
./build.sh
```

Alternatively, pass `--build` (or `-Build` in PowerShell) to the launch command to rebuild before starting:

```bash
cc --build
cx --build
```

No volume cleanup is needed — the entrypoint conditionally re-renders the template on container start when the image epoch is greater than or equal to the last-written volume epoch.

## Image-Baked Claude Slash Commands

Repo-agnostic Claude slash commands live in `docker/claude/agent-container/commands/` and are baked into the Claude image.

At container start, the entrypoint seeds them into `$CLAUDE_CONFIG_DIR/commands/` from the same epoch-gated block that re-renders the agent instruction template.
Seeding is no-clobber: existing files are never overwritten, so user-modified copies are always preserved.
To pick up an updated version of an image-shipped command after a rebuild, delete the file from `$CLAUDE_CONFIG_DIR/commands/` and restart the container — the fresh copy will be seeded on next start.

Per-repo `.claude/commands/<name>.md` still takes precedence on bare slash invocations, so any repo can override individual files without losing the rest.
User-added files in the same volume directory are unaffected by image rebuilds.

These do not pre-load into agent context; like all slash commands they are only read when invoked.

## Runtime

Both agent launch flows resolve through the same shared Compose base and the same Compose project name.

The shared GitHub, pnpm, and zsh-history volumes are declared once in the shared Compose configuration.

Shared volume names are kept stable to preserve existing data:

- `agent-gh-config`
- `agent-pnpm-store`
- `agent-zsh-history`

Agent-specific config volumes remain separate:

- `claude-config`
- `codex-config`

Codex requires `OPENAI_API_KEY` set on the host before launching (interactively or headless).
Claude optionally accepts `ANTHROPIC_API_KEY` as a fallback if the OAuth session expires.

Either agent can be started first in a clean Docker environment.

All shared volumes are marked `external` in the Compose files and pre-created by the launch scripts on first use.

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

Patterns are resolved as globs relative to the project root.
Only directories that exist at container start are shadowed.

Auto-detection and `.powbox.yml` patterns are merged and deduplicated.

### Mid-Session Refresh

If you add a new workspace package after the container has started, its `node_modules` will not be shadowed until you run:

```bash
shadow-refresh.sh
```

This re-runs detection and mounts tmpfs over any new directories that were not previously shadowed.
Already-mounted paths are skipped.

### Lifecycle

Shadow mounts are **ephemeral** — they use tmpfs (memory-backed) and are lost when the container stops.
After restarting (or resuming) a container, run `pnpm install` to repopulate subpackage `node_modules` from the shared pnpm store.
With a warm store this typically takes only a few seconds.

The root `node_modules` Docker volume is unaffected and persists across restarts as before.

### Configuration

Each tmpfs mount is capped at **512 MB** by default.
Override the per-mount limit by exporting `SHADOW_TMPFS_SIZE` (any value accepted by `mount -o size=`, e.g. `1g`, `256m`) before launching the container.
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

## Per-Container Ephemeral Agent Settings

The Claude and Codex config volumes (`claude-config`, `codex-config`) are shared across every container of the same flavor, so interactive TUI edits like `/model` or `/effort` would otherwise propagate to the next container that starts.
To keep those edits scoped to the container that made them, the entrypoint hook optionally shadows the agent settings file with a `/dev/shm` copy.

### How it works

When `AGENT_SETTINGS_EPHEMERAL=1` (the default in `compose.claude.yml` and `compose.codex.yml`):

1. The hook seeds `settings.json` / `config.toml` on the volume as before.
2. It copies the seeded file to `/dev/shm/agent-shadow/<name>` (tmpfs).
3. It calls `shadow-agent-config.sh` via scoped sudo to `mount --bind` the tmpfs copy over the volume original.

The agent now reads and writes the tmpfs copy.
The underlying volume file keeps its pre-shadow baseline.
When the container stops, the bind mount is torn down and the tmpfs is gone, leaving the persistent volume untouched.

Set `AGENT_SETTINGS_EPHEMERAL=0` to disable and restore the shared-settings behaviour.

### Trade-off

The shadow covers the entire settings file, not just the model/effort keys, so other persistent edits in that file (e.g. `enabledPlugins` toggled via `/plugins`) also become ephemeral.
Re-seeded keys like `statusLine` and image-baked marketplaces are unaffected because the hook re-applies them on every start.

### Caveat

Bind-mounting a file makes `rename(2)` over it return `EBUSY`.
This assumes the agent CLI persists settings via in-place `writeFileSync`, not write-temp-then-rename.
If a future Claude / Codex release switches to atomic-rename writes, edits will silently fail to persist — disable the feature in that case.

### Security

`shadow-agent-config.sh` is a root-owned, immutable script invoked via scoped sudo.
It refuses to shadow any path outside the allowlist (`/home/node/.claude/settings.json`, `/home/node/.codex/config.toml`) and refuses sources outside `/dev/shm/agent-shadow/`.
It uses the same `CAP_SYS_ADMIN` that `shadow-mounts.sh` requires — no extra privileges are granted.

## Commands

The user-facing command surface lives at the repo root and in `commands/`:

- `build.sh` and `build.ps1` at the repo root for image builds
- `commands/claude-container.*` and `commands/codex-container.*` for launches
- `commands/claude-smoke-test.*` and `commands/codex-smoke-test.*` for smoke tests
- `commands/prune-volumes.ps1` for orphaned `agent-nm-*` cleanup
- `commands/reset-claude-history.*` for wiping Claude session history from the shared `claude-config` volume
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
- `agent-check-updates` — compare baked agent versions against the latest npm releases
- `agent-update-claude`, `agent-update-codex` — rebuild the corresponding image with `--no-cache`
- `agent-reset-claude-history` — wipe per-project Claude session history from the shared `claude-config` volume (credentials and settings preserved); forwards flags like `--dry-run`/`--force` (bash) or `-WhatIf`/`-Force` (PowerShell)

### Environment Variables

Both libraries honour the same variables:

| Variable | Default | Effect |
|---|---|---|
| `POWBOX_ROOT` | auto-detected from the script's location | Path to your PowBox checkout. Only needed if auto-detection fails. |
| `POWBOX_CD_AFTER_LAUNCH` | `1` | When `cc`/`cx` is called with an explicit project path, cd into that path after the container exits. Set to `0` (or `false`/`no`/`off`) to stay in the original directory. |

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

# Rebuild the Claude image with the latest release
agent-update-claude

# Rebuild the Codex image with the latest release
agent-update-codex

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

# Rebuild the Claude image with the latest release
agent-update-claude

# Rebuild the Codex image with the latest release
agent-update-codex

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
docker compose -p powbox -f compose.shared.yml -f compose.claude.yml config
docker compose -p powbox -f compose.shared.yml -f compose.codex.yml config
```

Smoke test the built images with:

```bash
./commands/claude-smoke-test.sh
./commands/codex-smoke-test.sh
```

After launching each agent at least once, `docker volume ls` should show one copy of the shared volumes `agent-gh-config`, `agent-pnpm-store`, and `agent-zsh-history`, plus separate `claude-config` and `codex-config` volumes.

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
- the pnpm store is `/home/node/.local/share/pnpm/store`
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
- the pnpm store is `/home/node/.local/share/pnpm/store`
- working directory is `/workspace/<project>-<hash>`
- `node_modules` is writable by `node`

Codex preserves any existing `config.toml` settings in the `codex-config` volume, but the container now auto-seeds a missing `[tui].status_line` plus a missing top-level `terminal_title` default.
The seeded status line uses Codex-native items for model, current directory, remaining context, 5-hour usage, weekly usage, and used tokens.
`terminal_title` is a separate Codex setting for the terminal window or tab title, not the bottom status line.
The seeded title surfaces current directory, git branch, model, and thread title when the terminal supports title updates.
That means a fresh or reset Codex config starts with a richer native status line and title, while existing user customizations remain untouched.

## License

This project is licensed under the MIT License.

See [LICENSE](LICENSE).
