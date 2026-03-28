# Claude Code Docker Container

Run Claude Code in an isolated Docker container with a shared toolchain base image and a thin Claude-specific top image.

The current runtime path is shared with the Codex container.

Compose handles runtime configuration.

Bake handles image builds.

## Quick Start

Build the Claude image:

```bash
./build.sh
```

```powershell
.\build.ps1
```

Build a specific Claude version:

```bash
./build.sh 2.1.81
```

```powershell
.\build.ps1 2.1.81
```

Force a fresh top-image rebuild without rebuilding the shared base:

```bash
./build.sh 2.1.81 --no-cache
```

```powershell
.\build.ps1 2.1.81 -NoCache
```

Launch Claude for a project:

```bash
./claude-container.sh /path/to/project
```

```powershell
.\claude-container.ps1 C:\Projects\MyProject
```

Open `zsh` instead of Claude:

```bash
./claude-container.sh /path/to/project --shell
```

```powershell
.\claude-container.ps1 C:\Projects\MyProject -Shell
```

## Build Architecture

The Claude image is `powbox-claude:latest`.

It is built from the shared base image `powbox-agent-base:latest`.

The shared base contains the common Debian packages, GitHub CLI, `sqlcmd`, `pnpm`, `yq`, Oh My Zsh, firewall logic, shared entrypoint core, and common writable directories.

The Claude top image adds only the Claude binary plus the container-scoped `CLAUDE.md` asset.

## Launch Behavior

The launcher keeps the existing user-facing behavior.

It still creates per-project containers named `claude-<project>-<hash>`.

It still mounts a per-project `agent-nm-<project>-<hash>` volume at `/workspace/node_modules`.

It still seeds `~/.claude`, `gh` config, and `~/.gitconfig` on first use when those host paths exist.

It now runs through the shared Compose files at the repo root:

- `compose.shared.yml`
- `compose.claude.yml`

## Volumes

Persistent volumes:

- `claude-config` for Claude auth and config
- `claude-gh-config` for shared GitHub CLI auth
- `claude-pnpm-store` for the shared pnpm store
- `claude-zsh-history` for shared shell history
- `agent-nm-<project>-<hash>` for per-project Linux `node_modules`

The shared volumes are declared by the shared Compose base, so Claude no longer owns their lifecycle on behalf of Codex.

## Smoke Test

```bash
./smoke-test.sh
```

```powershell
.\smoke-test.ps1
```

The default image under test is `powbox-claude:latest`.

## More Validation

Use [tasks/unify-base-layer-host-testing.md](/workspace/tasks/unify-base-layer-host-testing.md) for full host-side Docker validation.
