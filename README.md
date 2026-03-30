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
- `claude-container/` and `codex-container/`: agent-specific docs and instruction assets

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

Either agent can be started first in a clean Docker environment.

Docker will create the shared volumes on demand through the merged `powbox` Compose configuration.

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

## Commands

The user-facing command surface lives at the repo root and in `commands/`:

- `build.sh` and `build.ps1` at the repo root for image builds
- `commands/claude-container.*` and `commands/codex-container.*` for launches
- `commands/claude-smoke-test.*` and `commands/codex-smoke-test.*` for smoke tests
- `commands/prune-volumes.ps1` for orphaned `agent-nm-*` cleanup

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

## License

This project is licensed under the MIT License.

See [LICENSE](LICENSE).
