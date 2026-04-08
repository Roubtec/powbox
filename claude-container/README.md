# Claude Code Docker Container

Run Claude Code in an isolated Docker container with a shared toolchain base image and a thin Claude-specific top image.

The runtime path is shared with the Codex container.

Compose handles runtime configuration.

Bake handles image builds.

## Quick Start

Run these commands from the repo root.

Build the Claude image:

```bash
./build.sh claude --claude-version latest
```

```powershell
.\build.ps1 -Target claude -ClaudeVersion latest
```

Build a specific Claude version:

```bash
./build.sh claude --claude-version 2.1.81
```

```powershell
.\build.ps1 -Target claude -ClaudeVersion 2.1.81
```

Force a fresh top-image rebuild without rebuilding the shared base:

```bash
./build.sh claude --claude-version 2.1.81 --no-cache
```

```powershell
.\build.ps1 -Target claude -ClaudeVersion 2.1.81 -NoCache
```

Launch Claude for a project:

```bash
./commands/claude-container.sh /path/to/project
```

```powershell
.\commands\claude-container.ps1 C:\Projects\MyProject
```

Open `zsh` instead of Claude:

```bash
./commands/claude-container.sh /path/to/project --shell
```

```powershell
.\commands\claude-container.ps1 C:\Projects\MyProject -Shell
```

## Build Architecture

The Claude image is `powbox-claude:latest`.

It is built from the shared base image `powbox-agent-base:latest`.

The shared base contains the common Debian packages, GitHub CLI, `sqlcmd`, `pnpm`, `yq`, Oh My Zsh, firewall logic, shared entrypoint core, and common writable directories.

The Claude top image adds only the Claude binary plus the shared container instruction template (rendered to `CLAUDE.md` at startup).

## Launch Behavior

The launcher creates per-project containers named `claude-<project>-<hash>`.

Each project is bind-mounted at `/workspace/<project>-<hash>` so that tools which key on absolute paths (such as Claude's project memory) keep per-project state isolated.

It mounts a per-project `agent-nm-<project>-<hash>` volume at `/workspace/<project>-<hash>/node_modules`.

It seeds `~/.claude`, `gh` config, and `~/.gitconfig` on first use when those host paths exist.

It runs through the shared Compose files at the repo root:

- `compose.shared.yml`
- `compose.claude.yml`

## Volumes

Persistent volumes:

- `claude-config` for Claude auth and config
- `agent-gh-config` for shared GitHub CLI auth
- `agent-pnpm-store` for the shared pnpm store
- `agent-zsh-history` for shared shell history
- `agent-nm-<project>-<hash>` for per-project Linux `node_modules`

The shared volumes are declared as `external` in `compose.shared.yml` and pre-created automatically by the launch scripts (`cc` / `claude-container.sh` / `claude-container.ps1`) when they do not yet exist.

If you run `docker compose` directly (without the launch scripts), Docker Compose will **not** create external volumes for you — the shared volumes must already exist. Use `docker volume create <name>` for each shared volume before running Compose directly.

## Smoke Test

```bash
./commands/claude-smoke-test.sh
```

```powershell
.\commands\claude-smoke-test.ps1
```

The default image under test is `powbox-claude:latest`.

## Runtime Sanity Check

Launch an interactive shell with `./commands/claude-container.sh /path/to/project --shell --volatile`.

Inside the container, these checks should hold:

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
