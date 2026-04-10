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
- `commands/`: user-facing host commands for launch, smoke-test, and volume pruning
- `scripts/`: shared internal build, launch, and smoke-test helpers
- `docker/shared/container-agent.md.tmpl`: shared agent instruction template (rendered per-agent at startup)

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
shadow-refresh
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
Override the per-mount limit with the `SHADOW_TMPFS_SIZE` environment variable (any value accepted by `mount -o size=`, e.g. `1g`, `256m`).
If a mount fills up, `pnpm install` will fail with a clear `ENOSPC` error — raise the limit and re-run.

### Security

`shadow-mounts.sh` is a root-owned, immutable script invoked via scoped sudo.
It refuses to mount outside `/workspace/`.
tmpfs mounts are container-namespace-scoped and invisible to the host — not an escape vector.

The container requires **`CAP_SYS_ADMIN`** (granted in `compose.shared.yml`) because Docker's default seccomp profile blocks the `mount` syscall without it.
This capability is scoped to the sudoers-allowed `shadow-mounts.sh` script — the `node` user cannot invoke arbitrary mount commands.

## Commands

The user-facing command surface lives at the repo root and in `commands/`:

- `build.sh` and `build.ps1` at the repo root for image builds
- `commands/claude-container.*` and `commands/codex-container.*` for launches
- `commands/claude-smoke-test.*` and `commands/codex-smoke-test.*` for smoke tests
- `commands/prune-volumes.ps1` for orphaned `agent-nm-*` cleanup
- `commands/check-updates.*` for checking whether newer agent releases are available

## PowerShell Profile Shortcuts

Add the following to your `$PROFILE` (`notepad $PROFILE`) to get short commands that default to the current working directory.

Set `$env:POWBOX_ROOT` to wherever you cloned this repo, then reload your profile (`& $PROFILE`).

```powershell
# PowBox agent shortcuts — adjust path to your checkout
$env:POWBOX_ROOT = "C:\Code\powbox"

function cc {
    param(
        [string]$ProjectPath = (Get-Location).Path,
        [switch]$Build,
        [switch]$Detach,
        [switch]$Shell,
        [switch]$Persist,
        [switch]$Resume,
        [switch]$Volatile,
        [string]$Ctx = ""
    )
    & "$env:POWBOX_ROOT\commands\claude-container.ps1" `
        -ProjectPath $ProjectPath `
        -Build:$Build -Detach:$Detach -Shell:$Shell `
        -Persist:$Persist -Resume:$Resume -Volatile:$Volatile `
        -Ctx $Ctx
}

function cx {
    param(
        [string]$ProjectPath = (Get-Location).Path,
        [switch]$Build,
        [switch]$Detach,
        [switch]$Shell,
        [switch]$Persist,
        [switch]$Resume,
        [switch]$Volatile,
        [string]$Exec = "",
        [string]$Ctx = ""
    )
    & "$env:POWBOX_ROOT\commands\codex-container.ps1" `
        -ProjectPath $ProjectPath `
        -Build:$Build -Detach:$Detach -Shell:$Shell `
        -Persist:$Persist -Resume:$Resume -Volatile:$Volatile `
        -Exec $Exec -Ctx $Ctx
}

function agent-prune-volumes {
    & "$env:POWBOX_ROOT\commands\prune-volumes.ps1" @args
}

function agent-prune-stopped {
    $claudeNames = docker ps -a --format "{{.Names}}" --filter "status=exited" --filter "name=claude-"
    if ($claudeNames) {
        docker rm $claudeNames
    }
    $codexNames = docker ps -a --format "{{.Names}}" --filter "status=exited" --filter "name=codex-"
    if ($codexNames) {
        docker rm $codexNames
    }
}

function agent-prune {
    agent-prune-stopped
    agent-prune-volumes
}

function agent-check-updates {
    & "$env:POWBOX_ROOT\commands\check-updates.ps1" @args
}

function agent-update-claude {
    & "$env:POWBOX_ROOT\build.ps1" -Target claude -NoCache
}

function agent-update-codex {
    & "$env:POWBOX_ROOT\build.ps1" -Target codex -NoCache
}

function cc-list {
 docker ps -a --filter "name=claude-" --format "table {{.ID}}`t{{.Names}}`t{{.Status}}`t{{.Image}}"
}

function cx-list {
 docker ps -a --filter "name=codex-" --format "table {{.ID}}`t{{.Names}}`t{{.Status}}`t{{.Image}}"
}

function agent-list {
 docker ps -a --filter "name=claude-" --filter "name=codex-" --format "table {{.ID}}`t{{.Names}}`t{{.Status}}`t{{.Image}}"
}

function agent-volumes {
 docker volume ls --filter "name=claude-config" --filter "name=codex-config" --filter "name=agent-" --format "table {{.Name}}`t{{.Driver}}`t{{.Mountpoint}}"
}
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

All flags accepted by `commands/claude-container.ps1` and `commands/codex-container.ps1` are forwarded by these functions, so `-Build`, `-Detach`, `-Persist`, `-Resume`, `-Volatile`, and `-Ctx` all work as documented.

To move the repo later, update only the `$env:POWBOX_ROOT` line and reload your profile.

## Bash Profile Shortcuts

Add the following to `~/.bashrc` or `~/.zshrc` to get the same short commands on Linux, macOS, or WSL.

Set `POWBOX_ROOT` to wherever you cloned this repo, then reload your shell (`source ~/.bashrc` or `source ~/.zshrc`).

```bash
# PowBox agent shortcuts — adjust path to your checkout
export POWBOX_ROOT="$HOME/code/powbox"

# Injects $PWD when called without a path so bare flags like --shell still work.
cc() {
    if [ $# -eq 0 ] || [[ "$1" == -* ]]; then
        "$POWBOX_ROOT/commands/claude-container.sh" "$PWD" "$@"
    else
        "$POWBOX_ROOT/commands/claude-container.sh" "$@"
    fi
}

cx() {
    if [ $# -eq 0 ] || [[ "$1" == -* ]]; then
        "$POWBOX_ROOT/commands/codex-container.sh" "$PWD" "$@"
    else
        "$POWBOX_ROOT/commands/codex-container.sh" "$@"
    fi
}

agent-prune-volumes() {
    "$POWBOX_ROOT/commands/prune-volumes.sh"
}

agent-prune-stopped() {
    claude_names=$(docker ps -a --format "{{.Names}}" --filter "status=exited" --filter "name=claude-")
    if [ -n "$claude_names" ]; then
        docker rm $claude_names 2>/dev/null
    fi

    codex_names=$(docker ps -a --format "{{.Names}}" --filter "status=exited" --filter "name=codex-")
    if [ -n "$codex_names" ]; then
        docker rm $codex_names 2>/dev/null
    fi
}

agent-prune() {
    agent-prune-stopped
    agent-prune-volumes
}

agent-check-updates() {
    "$POWBOX_ROOT/commands/check-updates.sh" "$@"
}

agent-update-claude() {
    "$POWBOX_ROOT/build.sh" claude --no-cache
}

agent-update-codex() {
    "$POWBOX_ROOT/build.sh" codex --no-cache
}

cc-list() {
    docker ps -a --filter "name=claude-" --format $'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}'
}

cx-list() {
    docker ps -a --filter "name=codex-" --format $'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}'
}

agent-list() {
    docker ps -a --filter "name=claude-" --filter "name=codex-" --format $'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}'
}

agent-volumes() {
    docker volume ls --filter "name=claude-config" --filter "name=codex-config" --filter "name=agent-" --format $'table {{.Name}}\t{{.Driver}}\t{{.Mountpoint}}'
}
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

All flags accepted by `commands/claude-container.sh` and `commands/codex-container.sh` are forwarded, so `--build`, `--detach`, `--persist`, `--resume`, `--volatile`, and `--ctx` all work as documented.

To move the repo later, update only the `POWBOX_ROOT` line and reload your shell.

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

## License

This project is licensed under the MIT License.

See [LICENSE](LICENSE).
