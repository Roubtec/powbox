# Codex CLI Docker Container

Run [OpenAI Codex CLI](https://github.com/openai/codex) in an isolated Docker container with full autonomous permissions. Your host system stays safe — Codex can only affect the mounted project workspace and its own container filesystem.

The image is currently built on `node:24-slim`.

Common development tooling is baked into the image; the table below shows what is on `PATH`.

| Tool group | Included |
|------------|----------|
| Core runtime | `codex`, `node`, `npm`, `pnpm`, `python3`, `pip3` |
| Git/GitHub | `git`, `gh`, `ssh` |
| Shell and inspection | `zsh`, `jq`, `fzf`, `less`, `tree`, `file`, `htop`, `shellcheck`, `shfmt`, `strace`, `lsof` |
| Build and patching | `make`, `patch`, `gcc`/`g++` via `build-essential` |
| Archives and transfer | `wget`, `zip`, `unzip`, `rsync`, `bzip2`, `xz`, `zstd` |
| Data and config | `sqlcmd`, `sqlite3`, `yq`, `envsubst`, `bc`, `xxd` |
| Network debugging | `ping`, `nc` |
| File navigation | `fd`, `bat` |
| Sandbox support | `bubblewrap` (`bwrap`) |

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows, macOS, or Linux)
- `OPENAI_API_KEY` environment variable set on your host (your OpenAI API key)
- [GitHub CLI](https://cli.github.com/) authenticated on your host (`gh auth login`) — optional, for git/GitHub operations

## Quick Start

### 1. Build the image

Latest:

```powershell
.\build.ps1
```

```bash
./build.sh
```

With a specific Codex CLI version:

```powershell
.\build.ps1 0.1.0
```

```bash
./build.sh 0.1.0
```

### 2. Launch a container for your project

**PowerShell (recommended on Windows):**

```powershell
.\codex-container.ps1 C:\Projects\MyProject
```

**Bash (Git Bash, WSL, Linux, macOS):**

```bash
./codex-container.sh /path/to/my-project
```

Codex starts in `/workspace` with `--dangerously-bypass-approvals-and-sandbox` — full autonomy inside the container.
By default, the launcher will reuse a matching stopped container for the current project if one exists; otherwise it creates a persistent one.
The image also installs Debian `bubblewrap` so Codex can find `/usr/bin/bwrap` for its Linux sandbox backend and avoid the startup warning about falling back to the vendored copy.

### 3. Headless mode (fire-and-forget)

```powershell
.\codex-container.ps1 C:\Projects\MyProject -Exec "fix the failing tests"
```

```bash
./codex-container.sh /path/to/my-project --exec "fix the failing tests"
```

This runs `codex exec "task"` inside the container — Codex completes the task and exits without interactive input.

### 4. Open a shell instead of Codex

```powershell
.\codex-container.ps1 C:\Projects\MyProject -Shell
```

```bash
./codex-container.sh /path/to/my-project --shell
```

### 5. Smoke test the image

PowerShell:

```powershell
.\smoke-test.ps1
```

Bash:

```bash
./smoke-test.sh
```

Both scripts run a disposable container and verify that the main CLI tools are callable on `PATH`.
On success, they print a single confirmation line stating that all expected CLI tools were found.

## Usage

### Launch script options

| Flag         | PowerShell           | Bash                            | Description                                       |
|--------------|----------------------|---------------------------------|---------------------------------------------------|
| Project path | First positional arg | First positional arg            | Directory to mount as `/workspace` (default: `.`) |
| Build image  | `-Build`             | `--build`                       | Build/rebuild the image before launching          |
| Detach       | `-Detach`            | `--detach`                      | Run in background                                 |
| Shell        | `-Shell`             | `--shell`                       | Open zsh instead of Codex CLI                     |
| Exec         | `-Exec "task"`       | `--exec "task"`                 | Run headless `codex exec` with the given task     |
| Volatile     | `-Volatile`          | `--volatile`                    | Create a one-shot container that is removed on exit |
| Persist      | `-Persist`           | `--persist`                     | Leave the container stopped instead of removing it on exit |
| Resume       | `-Resume`            | `--resume`                      | Restart and attach to the previously persisted container |

### Multiple projects simultaneously

Each project gets its own container and shares node_modules volumes with Claude containers:

```powershell
.\codex-container.ps1 C:\Projects\Frontend    # → container: codex-frontend-<hash>
.\codex-container.ps1 C:\Projects\Backend     # → container: codex-backend-<hash>
```

All containers share the same image, pnpm store, zsh history, GitHub CLI credentials, and per-project node_modules.

### Container-wide Codex instructions

The file `assets/container-agents.md` is baked into the image and copied into the `codex-config` volume as `AGENTS.md` on every container startup. Codex CLI reads `~/.codex/AGENTS.md` as its user-level instructions, so every session automatically knows about the available tooling, `gh` auth preferences, filesystem layout, and network constraints.

To update the instructions: edit `assets/container-agents.md`, rebuild the image, and start any container. Because the `codex-config` volume is shared, the entrypoint copy from one container makes the updated file visible to all containers immediately. New Codex sessions in any container will read the new version.

The source file is named `container-agents.md` (not `AGENTS.md`) so that AI agents working on this repo from the host do not pick it up as project instructions.

### Running pnpm inside the container

The container has its own Linux-native pnpm store and node_modules. `/workspace/node_modules` is shadowed by a per-project Docker volume, so the container sees Linux-appropriate packages and binaries there instead of the host's `node_modules`. That per-project `agent-nm-<project>-<hash>` volume persists across container recreation and is shared with Claude containers for the same project, so installs done inside either tool are reused.

The image pins pnpm's store to `/home/node/.local/share/pnpm/store` and uses `package-import-method=copy`, so running `pnpm install` inside the container does not create a repo-local `.pnpm-store` under `/workspace`.

### Suspending a live session

If you want to keep the active Codex process alive and come back later, the safest option is to detach from the running container rather than stop it.

- `docker stop <container-name>` stops the container and ends the Codex process.
- If the container is still running, `docker attach <container-name>` reconnects to the existing TTY session.
- Docker's default detach sequence is `Ctrl+P`, then `Ctrl+Q`. That leaves the container running without terminating Codex.

### PowerShell `cx` command

If you want to launch from any PowerShell session with a short command, add a function like this to your PowerShell profile:

```powershell
function cx {
 & 'C:\path\to\powbox\codex-container\codex-container.ps1' @args
}

function cx-list {
 docker ps -a --filter "name=codex-" --format "table {{.Names}}`t{{.Status}}`t{{.Image}}"
}

function cx-prune-volumes {
 & 'C:\path\to\powbox\codex-container\codex-container-prune-volumes.ps1' @args
}
```

Open your profile with:

```powershell
notepad $PROFILE
```

Then paste the function, save, and reload the profile:

```powershell
. $PROFILE
```

After that, these will work from any folder:

```powershell
cx
cx -Shell
cx -Volatile
cx -Exec "refactor the auth module"
cx C:\Projects\OtherRepo
cx-list
cx-prune-volumes
```

## Updating Codex CLI

Rebuild the image to pull the latest version:

```powershell
.\build.ps1
```

```bash
./build.sh
```

This rebuilds the `node:24-slim`-based image and runs `--no-cache` to ensure fresh packages. Named volumes (Codex config, GitHub CLI config, pnpm store, node_modules, zsh history) are preserved across rebuilds.

## What's mounted

| Host path              | Container path               | Mode | Purpose                        |
|------------------------|------------------------------|------|--------------------------------|
| Your project directory | `/workspace`                 | rw   | Source code (shared with host) |
| `~/.gitconfig`         | `/home/node/.gitconfig-host` | ro   | Seed for container git config  |
| `gh` CLI config        | `/home/node/.config/gh-host` | ro   | First-run seed for GitHub auth |

On first run, if your host `~/.codex` exists, it is mounted read-only and copied into the persistent Docker volume at `/home/node/.codex`. If your host gh config exists, it is likewise copied into `/home/node/.config/gh`. After that, Codex and gh state live in Docker rather than continuing to write back into the host config directories.

### Named volumes (managed by Docker)

| Volume                       | Container path                       | Purpose                      | Shared with Claude |
|------------------------------|--------------------------------------|------------------------------|--------------------|
| `codex-config`               | `/home/node/.codex`                  | Codex config/preferences     | No                 |
| `claude-gh-config`           | `/home/node/.config/gh`              | GitHub CLI auth/config       | Yes                |
| `claude-pnpm-store`          | `/home/node/.local/share/pnpm/store` | Shared pnpm cache            | Yes                |
| `agent-nm-<project>-<hash>`  | `/workspace/node_modules`            | Per-project Linux packages   | Yes                |
| `claude-zsh-history`         | `/home/node/.zsh_history_dir`        | Persistent shell history     | Yes                |

Shared volumes allow seamless switching between Claude Code and Codex CLI containers on the same project without reinstalling packages or re-authenticating GitHub.

## Security model

- **Filesystem isolation**: Codex can only affect `/workspace` (your project) and the container's own filesystem. It cannot reach your host's home directory, other projects, or system files.
- **Network firewall**: Private/local networks are blocked (10.x, 172.16.x, 192.168.x, link-local). Public internet is fully open for web research, npm, GitHub, etc.
- **Permissions**: `--dangerously-bypass-approvals-and-sandbox` is safe here because the container + firewall provides the isolation boundary.

### Blast radius

| Scenario                             | Impact                                 | Recovery          |
|--------------------------------------|----------------------------------------|-------------------|
| Codex deletes workspace files        | Host project files affected (rw mount) | `git checkout`    |
| Codex wipes node_modules             | Named volume cleared                   | `pnpm install`    |
| Codex destroys container filesystem  | Container-only, ephemeral              | Restart container |
| Codex tries to access local network  | Blocked by firewall                    | N/A               |

## Troubleshooting

### "permission denied" on shell scripts

Ensure LF line endings. The `.gitattributes` file enforces this, but if you cloned before it was added:

```bash
git add --renormalize .
```

### gh / git auth not working

Make sure `gh auth login` is completed on your host if you want an initial seed. On Windows, the host gh config path is `%APPDATA%\GitHub CLI\`.

### OPENAI_API_KEY not set

If you see the warning at container startup, ensure the environment variable is set on your host:

```bash
export OPENAI_API_KEY="paste-your-openai-api-key-here"
```

```powershell
$env:OPENAI_API_KEY = "paste-your-openai-api-key-here"
```

The key is passed through at runtime and never stored in the image.

### Firewall not applying

The container needs `NET_ADMIN` and `NET_RAW` capabilities (set in `docker-compose.yml`). Verify with:

```bash
iptables -L OUTPUT -n  # inside the container
```

### Revalidate the image after Dockerfile changes

After rebuilding, run one of these smoke tests:

```powershell
.\smoke-test.ps1
```

```bash
./smoke-test.sh
```

You can also point them at a different image tag:

```powershell
.\smoke-test.ps1 my-image:tag
```

```bash
./smoke-test.sh my-image:tag
```

## Maintenance

### List Codex containers

```powershell
docker ps -a --filter "name=codex-" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
```

### Remove a persisted project container

```powershell
docker rm codex-<project>-<hash>
```

### Remove a project's container-local node_modules volume

```powershell
docker volume rm agent-nm-<project>-<hash>
```

### Prune orphaned node_modules volumes

To remove `agent-nm-*` volumes that no longer have any matching Claude or Codex container:

```powershell
.\codex-container-prune-volumes.ps1
```

Preview only:

```powershell
.\codex-container-prune-volumes.ps1 -WhatIf
```

This is intentionally conservative: it only targets per-project `agent-nm-*` node_modules volumes, not shared auth, history, or pnpm cache volumes. It checks both `claude-*` and `codex-*` containers as potential keepers.

### Prune the shared pnpm cache volume

```powershell
docker volume rm claude-pnpm-store
```

This affects cache reuse across all projects and tools, but it does not remove source code from your mounted workspaces.
