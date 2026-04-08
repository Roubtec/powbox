# Codex CLI Docker Container

Run Codex CLI in an isolated Docker container with a shared toolchain base image and a thin Codex-specific top image.

The runtime path is shared with the Claude container.

Compose handles runtime configuration.

Bake handles image builds.

Set `OPENAI_API_KEY` on the host before launching Codex interactively or in headless mode.

## Quick Start

Run these commands from the repo root.

Build the Codex image:

```bash
./build.sh codex --codex-version latest
```

```powershell
.\build.ps1 -Target codex -CodexVersion latest
```

Build a specific Codex version:

```bash
./build.sh codex --codex-version 0.1.0
```

```powershell
.\build.ps1 -Target codex -CodexVersion 0.1.0
```

Force a fresh top-image rebuild without rebuilding the shared base:

```bash
./build.sh codex --codex-version 0.1.0 --no-cache
```

```powershell
.\build.ps1 -Target codex -CodexVersion 0.1.0 -NoCache
```

Launch Codex for a project:

```bash
./commands/codex-container.sh /path/to/project
```

```powershell
.\commands\codex-container.ps1 C:\Projects\MyProject
```

Run headless mode:

```bash
./commands/codex-container.sh /path/to/project --exec "fix the failing tests"
```

```powershell
.\commands\codex-container.ps1 C:\Projects\MyProject -Exec "fix the failing tests"
```

Open `zsh` instead of Codex:

```bash
./commands/codex-container.sh /path/to/project --shell
```

```powershell
.\commands\codex-container.ps1 C:\Projects\MyProject -Shell
```

## Build Architecture

The Codex image is `powbox-codex:latest`.

It is built from the shared base image `powbox-agent-base:latest`.

The shared base contains the common Debian packages, GitHub CLI, `sqlcmd`, `pnpm`, `yq`, Oh My Zsh, firewall logic, shared entrypoint core, common writable directories, and `bubblewrap`.

The Codex top image adds only the Codex CLI package plus the shared container instruction template (rendered to `AGENTS.md` at startup).

## Launch Behavior

The launcher creates per-project containers named `codex-<project>-<hash>`.

Each project is bind-mounted at `/workspace/<project>-<hash>` so that tools which key on absolute paths keep per-project state isolated.

It mounts a per-project `agent-nm-<project>-<hash>` volume at `/workspace/<project>-<hash>/node_modules`.

It seeds `~/.codex`, `gh` config, and `~/.gitconfig` on first use when those host paths exist.

It runs through the shared Compose files at the repo root:

- `compose.shared.yml`
- `compose.codex.yml`

## Volumes

Persistent volumes:

- `codex-config` for Codex config
- `agent-gh-config` for shared GitHub CLI auth
- `agent-pnpm-store` for the shared pnpm store
- `agent-zsh-history` for shared shell history
- `agent-nm-<project>-<hash>` for per-project Linux `node_modules`

The shared volumes are declared as `external` in `compose.shared.yml` and pre-created automatically by the launch scripts (`cx` / `codex-container.sh` / `codex-container.ps1`) when they do not yet exist.

If you run `docker compose` directly (without the launch scripts), Docker Compose will **not** create external volumes for you — the shared volumes must already exist. Use `docker volume create <name>` for each shared volume before running Compose directly.

## Smoke Test

```bash
./commands/codex-smoke-test.sh
```

```powershell
.\commands\codex-smoke-test.ps1
```

The default image under test is `powbox-codex:latest`.

## Runtime Sanity Check

Launch an interactive shell with `./commands/codex-container.sh /path/to/project --shell --volatile`.

Inside the container, these checks should hold:

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
