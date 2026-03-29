# Codex CLI Docker Container

Run Codex CLI in an isolated Docker container with a shared toolchain base image and a thin Codex-specific top image.

The current runtime path is shared with the Claude container.

Compose handles runtime configuration.

Bake handles image builds.

Set `OPENAI_API_KEY` on the host before launching Codex interactively or in headless mode.

## Quick Start

Build the Codex image:

```bash
./build.sh
```

```powershell
.\build.ps1
```

Build a specific Codex version:

```bash
./build.sh 0.1.0
```

```powershell
.\build.ps1 0.1.0
```

Force a fresh top-image rebuild without rebuilding the shared base:

```bash
./build.sh 0.1.0 --no-cache
```

```powershell
.\build.ps1 0.1.0 -NoCache
```

Launch Codex for a project:

```bash
./codex-container.sh /path/to/project
```

```powershell
.\codex-container.ps1 C:\Projects\MyProject
```

Run headless mode:

```bash
./codex-container.sh /path/to/project --exec "fix the failing tests"
```

```powershell
.\codex-container.ps1 C:\Projects\MyProject -Exec "fix the failing tests"
```

Open `zsh` instead of Codex:

```bash
./codex-container.sh /path/to/project --shell
```

```powershell
.\codex-container.ps1 C:\Projects\MyProject -Shell
```

## Build Architecture

The Codex image is `powbox-codex:latest`.

It is built from the shared base image `powbox-agent-base:latest`.

The shared base contains the common Debian packages, GitHub CLI, `sqlcmd`, `pnpm`, `yq`, Oh My Zsh, firewall logic, shared entrypoint core, common writable directories, and `bubblewrap`.

The Codex top image adds only the Codex CLI package plus the container-scoped `AGENTS.md` asset.

## Launch Behavior

The launcher keeps the existing user-facing behavior.

It still creates per-project containers named `codex-<project>-<hash>`.

It still mounts a per-project `agent-nm-<project>-<hash>` volume at `/workspace/node_modules`.

It still seeds `~/.codex`, `gh` config, and `~/.gitconfig` on first use when those host paths exist.

It now runs through the shared Compose files at the repo root:

- `compose.shared.yml`
- `compose.codex.yml`

## Volumes

Persistent volumes:

- `codex-config` for Codex config
- `claude-gh-config` for shared GitHub CLI auth
- `claude-pnpm-store` for the shared pnpm store
- `claude-zsh-history` for shared shell history
- `agent-nm-<project>-<hash>` for per-project Linux `node_modules`

The shared volumes are declared by the shared Compose base, so Codex no longer needs `external: true` declarations for them.

Codex can now be the first launcher in a clean Docker environment without any manual volume preparation.

## Smoke Test

```bash
./smoke-test.sh
```

```powershell
.\smoke-test.ps1
```

The default image under test is `powbox-codex:latest`.

## Runtime Sanity Check

Launch an interactive shell with `./codex-container.sh /path/to/project --shell --volatile`.

Inside the container, these checks should hold:

```bash
whoami
echo "$CODEX_CONFIG_DIR"
codex --version
bwrap --version
gh --version
pnpm config get store-dir
ls -ld /workspace/node_modules
```

Expected results:

- user is `node`
- `CODEX_CONFIG_DIR` is `/home/node/.codex`
- `bwrap` is available
- the pnpm store is `/home/node/.local/share/pnpm/store`
- `/workspace/node_modules` is writable by `node`
