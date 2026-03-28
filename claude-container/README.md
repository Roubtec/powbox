# Claude Code Docker Container

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in an isolated Docker container with full autonomous permissions. Your host system stays safe — Claude can only affect the mounted project workspace and its own container filesystem.

The image is currently built on `node:24-slim`.

Common development tooling is baked into the image; the table below shows what is on `PATH`. `azure-cli` is intentionally not included.

| Tool group | Included |
|------------|----------|
| Core runtime | `claude`, `node`, `npm`, `pnpm`, `python3`, `pip3` |
| Git/GitHub | `git`, `gh`, `ssh` |
| Shell and inspection | `zsh`, `jq`, `fzf`, `less`, `tree`, `file`, `htop`, `shellcheck`, `shfmt`, `strace`, `lsof` |
| Build and patching | `make`, `patch`, `gcc`/`g++` via `build-essential` |
| Archives and transfer | `wget`, `zip`, `unzip`, `rsync`, `bzip2`, `xz`, `zstd` |
| Data and config | `sqlcmd`, `sqlite3`, `yq`, `envsubst`, `bc`, `xxd` |
| Network debugging | `ping`, `nc` |
| File navigation | `fd`, `bat` |

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows, macOS, or Linux)
- An authenticated Claude Code session on your host is optional. If `~/.claude` exists, the container imports it on first run.
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

With a specific Claude Code version:

```powershell
.\build.ps1 2.1.81
```

```bash
./build.sh 2.1.81
```

On Windows PowerShell, you can also call Docker directly to trigger a build without the wrapper script:

```powershell
docker compose build --build-arg CLAUDE_CODE_VERSION=latest --no-cache
```

### 2. Launch a container for your project

**PowerShell (recommended on Windows):**

```powershell
.\claude-container.ps1 C:\Projects\MyProject
```

**Bash (Git Bash, WSL, Linux, macOS):**

```bash
./claude-container.sh /path/to/my-project
```

Claude Code starts in `/workspace` with `--dangerously-skip-permissions` — full autonomy inside the container.
By default, the launcher will reuse a matching stopped container for the current project if one exists; otherwise it creates a persistent one.

### 3. Open a shell instead of Claude

```powershell
.\claude-container.ps1 C:\Projects\MyProject -Shell
```

```bash
./claude-container.sh /path/to/my-project --shell
```

### 4. Smoke test the image

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

On Windows, `./smoke-test.sh` expects Git Bash, WSL, or another Bash-capable environment. If you are in plain PowerShell, use `./smoke-test.ps1`.

## Usage

### Launch script options

| Flag         | PowerShell           | Bash                 | Description                                       |
|--------------|----------------------|----------------------|---------------------------------------------------|
| Project path | First positional arg | First positional arg | Directory to mount as `/workspace` (default: `.`) |
| Build image  | `-Build`             | `--build`            | Build/rebuild the image before launching          |
| Detach       | `-Detach`            | `--detach`           | Run in background                                 |
| Shell        | `-Shell`             | `--shell`            | Open zsh instead of Claude Code                   |
| Volatile     | `-Volatile`          | `--volatile`         | Create a one-shot container that is removed on exit |
| Persist      | `-Persist`           | `--persist`          | Leave the container stopped instead of removing it on exit |
| Resume       | `-Resume`            | `--resume`           | Restart and attach to the previously persisted container |

### Multiple projects simultaneously

Each project gets its own container and node_modules volume:

```powershell
.\claude-container.ps1 C:\Projects\Frontend    # → container: claude-frontend-<hash>
.\claude-container.ps1 C:\Projects\Backend     # → container: claude-backend-<hash>
```

All containers share the same image, pnpm store, zsh history, and credentials.

The default workflow is persistent: if a matching project container exists, the launcher resumes it; if not, it creates one. Use `-Volatile` or `--volatile` when you want the old disposable `--rm` behavior.
`-Resume` and `--resume` still exist, but they are now mainly explicit overrides rather than the normal path.
Resume restarts the container with the command it was originally created with. If you want to switch between Claude and `zsh`, recreate the container in the mode you want.

### Container-wide Claude instructions

The file `assets/container-claude.md` is baked into the image and copied into the `claude-config` volume as `CLAUDE.md` on every container startup. Claude Code reads it as its user-level `CLAUDE.md`, so every session automatically knows about the available tooling, `gh` auth preferences, filesystem layout, and network constraints.

To update the instructions: edit `assets/container-claude.md`, rebuild the image, and start any container. Because the `claude-config` volume is shared, the entrypoint copy from one container makes the updated file visible to all containers immediately. New Claude sessions in any container will read the new version; already-running conversations won't reload it mid-session.

The source file is named `container-claude.md` (not `CLAUDE.md`) so that Claude Code agents working on this repo from the host do not pick it up as project instructions.

### Running pnpm inside the container

The container has its own Linux-native pnpm store and node_modules. `/workspace/node_modules` is shadowed by a per-project Docker volume, so the container sees Linux-appropriate packages and binaries there instead of the host's `node_modules`. That per-project `node_modules` volume persists across container recreation, so installs done inside the container are reused for that project and can speed subsequent work. The image pins pnpm's store to `/home/node/.local/share/pnpm/store` and uses `package-import-method=copy`, so running `pnpm install` inside the container does not create a repo-local `.pnpm-store` under `/workspace`.
This still works in `-Volatile` / `--volatile` mode because the container and the `node_modules` volume are different Docker objects. The launcher always mounts the same per-project named volume, `agent-nm-<project>-<hash>`, into `/workspace/node_modules`. Removing the container with `--rm` deletes only the container; it does not delete that named volume.
We use `copy` intentionally because `/workspace` is a host bind mount while the pnpm store is a Docker volume. Those are separate filesystems inside the container, so pnpm's default hard-link import mode cannot safely link packages across that boundary and may fall back to a project-local store. Copy mode keeps the shared store external and avoids polluting the repo.
The pnpm store is shared across container instances on purpose. That store is just a content-addressable cache, so different projects can reuse downloaded package data safely while still keeping separate project-local `node_modules` volumes.

### Suspending a live session

If you want to keep the active Claude process alive and come back later, the safest option is to detach from the running container rather than stop it.

- `docker stop <container-name>` stops the container and ends the Claude process, so the interactive session is gone.
- `docker pause <container-name>` freezes the container in memory and `docker unpause <container-name>` resumes it, but long pauses can be fragile for interactive networked tools because timers and connections may time out.
- If the container is still running, `docker attach <container-name>` reconnects to the existing TTY session.

If you are attached directly to the running container, Docker's default detach sequence is `Ctrl+P`, then `Ctrl+Q`. That leaves the container running without terminating Claude.

### PowerShell `cc` command

If you want to launch from any PowerShell session with a short command, add a function like this to your PowerShell profile:

```powershell
function cc {
 & 'C:\path\to\powbox\claude-container\claude-container.ps1' @args
}

function cc-list {
 docker ps -a --filter "name=claude-" --format "table {{.Names}}`t{{.Status}}`t{{.Image}}"
}

function cc-prune-volumes {
 & 'C:\path\to\powbox\claude-container\claude-container-prune-volumes.ps1' @args
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
cc
cc -Shell
cc -Volatile
cc C:\Projects\OtherRepo
cc-list
cc-prune-volumes
```

Because the launcher defaults `ProjectPath` to `.`, `cc` uses the current working directory unless you pass a different path.
`cc-list` gives you a quick view of saved and running Claude-related containers without retyping the `docker ps -a` filter.
`cc-prune-volumes` removes orphaned `agent-nm-*` volumes that do not correspond to any existing Claude container. It supports PowerShell's standard `-WhatIf` switch.

## Updating Claude Code

Rebuild the image to pull the latest version:

```powershell
.\build.ps1
```

```bash
./build.sh
```

This rebuilds the `node:24-slim`-based image and runs `--no-cache` to ensure fresh packages. Named volumes (Claude config, GitHub CLI config, pnpm store, node_modules, zsh history) are preserved across rebuilds.

## What's mounted

| Host path              | Container path               | Mode | Purpose                        |
|------------------------|------------------------------|------|--------------------------------|
| Your project directory | `/workspace`                 | rw   | Source code (shared with host) |
| `~/.gitconfig`         | `/home/node/.gitconfig-host` | ro   | Seed for container git config  |
| `gh` CLI config        | `/home/node/.config/gh-host` | ro   | First-run seed for GitHub auth |

On first run, if your host `~/.claude` exists, it is mounted read-only and copied into the persistent Docker volume at `/home/node/.claude`. If your host gh config exists, it is likewise copied into `/home/node/.config/gh`. After that, Claude and gh state live in Docker rather than continuing to write back into the host config directories.

### Named volumes (managed by Docker)

| Volume                       | Container path                       | Purpose                    |
|------------------------------|--------------------------------------|----------------------------|
| `claude-config`              | `/home/node/.claude`                 | Claude auth/config/state   |
| `claude-gh-config`           | `/home/node/.config/gh`              | GitHub CLI auth/config     |
| `claude-pnpm-store`          | `/home/node/.local/share/pnpm/store` | Shared pnpm cache          |
| `agent-nm-<project>-<hash>` | `/workspace/node_modules`            | Per-project Linux packages |
| `claude-zsh-history`         | `/home/node/.zsh_history_dir`        | Persistent shell history   |

The pnpm store lives outside `/workspace`, so package installs inside the container should not add `.pnpm-store` noise to the mounted project tree. The launcher also repairs the per-project `node_modules` volume mount point to `node:node` before startup so package managers can write there consistently.

Separate-lifecycle resources to be aware of:

- `agent-nm-<project>-<hash>` volumes: per-project Linux `node_modules`; safe to prune if you are fine reinstalling packages inside the container.
- `claude-pnpm-store`: shared package cache for all projects; safe to prune, but all projects lose cached package downloads.
- `claude-config`: Claude auth/config state; pruning it logs Claude out in the container.
- `claude-gh-config`: GitHub CLI auth/config state; pruning it removes in-container gh login state.
- `claude-zsh-history`: shared shell history.
- Stopped `claude-*` containers: persist container metadata and command state, but not image updates.

## Claude auth persistence

Claude auth is now persisted in the Docker named volume `claude-config`, so it survives:

- `docker compose run --rm`
- image rebuilds
- version updates installed by rebuilding the image

If you already have a host Claude login, the first container start seeds the volume from host `~/.claude`. If you do not, just log in once inside the container and that login will remain in the volume for future runs.

GitHub CLI auth is now persisted in the Docker named volume `claude-gh-config` with the same behavior. If you log in with `gh auth login` inside the container, that login will survive future container runs and image rebuilds.

## Security model

- **Filesystem isolation**: Claude can only affect `/workspace` (your project) and the container's own filesystem. It cannot reach your host's home directory, other projects, or system files.
- **Network firewall**: Private/local networks are blocked (10.x, 172.16.x, 192.168.x, link-local). Public internet is fully open for web research, npm, GitHub, etc.
- **Permissions**: `--dangerously-skip-permissions` is safe here because the container + firewall provides the isolation boundary. This is the [officially recommended approach](https://github.com/anthropics/claude-code/tree/main/.devcontainer) for containerized Claude Code.

### Blast radius

| Scenario                             | Impact                                 | Recovery          |
|--------------------------------------|----------------------------------------|-------------------|
| Claude deletes workspace files       | Host project files affected (rw mount) | `git checkout`    |
| Claude wipes node_modules            | Named volume cleared                   | `pnpm install`    |
| Claude destroys container filesystem | Container-only, ephemeral              | Restart container |
| Claude tries to access local network | Blocked by firewall                    | N/A               |

## Troubleshooting

### "permission denied" on shell scripts

Ensure LF line endings. The `.gitattributes` file enforces this, but if you cloned before it was added:

```bash
git add --renormalize .
```

### gh / git auth not working

Make sure `gh auth login` is completed on your host if you want an initial seed. On Windows, the host gh config path is `%APPDATA%\GitHub CLI\`.

The host `.gitconfig` is mounted read-only and copied into a container-local global git config at startup before `gh auth setup-git` runs. Host gh config, if present, is also copied once into the writable `claude-gh-config` Docker volume. That keeps host config unchanged while still allowing GitHub HTTPS auth inside the container.

### Quick sanity checks with zsh

`docker exec` runs inside an existing container, so it sees the same `/workspace` mount that container was started with.

Plain `docker run` starts a brand new container from the image. If you do not pass a `-v ...:/workspace` mount yourself, `/workspace` is just the image's default working directory inside the container, not your host project.

If you want to test auth state without launching the full interactive Claude session, pass a shell command with `-lc`:

```powershell
docker run --rm --entrypoint /bin/zsh claude-code-dev:latest -lc "claude --version"
docker run --rm --entrypoint /bin/zsh claude-code-dev:latest -lc "gh auth status"
```

Without `-lc`, zsh treats the quoted text as a script filename instead of a command. This fails:

```powershell
docker run --rm --entrypoint /bin/zsh claude-code-dev:latest "gh auth status"
```

If you want plain `docker run` to inspect the same kind of mounted workspace as the launcher scripts, pass the mount explicitly:

```powershell
docker run --rm --entrypoint /bin/zsh -v "${PWD}:/workspace" claude-code-dev:latest -lc "pwd; ls"
```

To find the generated container name from the launcher scripts, list running containers:

```powershell
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
```

To include stopped containers as well:

```powershell
docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
```

The launcher names containers like `claude-<project>-<hash>`. Once you have the name, use `docker exec` against that running container.

If you already have a container running, check state inside it with:

```powershell
docker exec -it <container-name> zsh -lc "claude --version"
docker exec -it <container-name> zsh -lc "gh auth status"
docker exec -it <container-name> zsh -lc "git config --global --get-regexp credential"
```

To verify whether the mounted workspace is seen as a git repository inside the container:

```powershell
docker exec -it <container-name> zsh -lc "cd /workspace && git rev-parse --is-inside-work-tree"
```

That command may fail for perfectly valid non-repo workspaces. Container startup no longer depends on `/workspace` being a git repository.

### Firewall not applying

The container needs `NET_ADMIN` and `NET_RAW` capabilities (set in `docker-compose.yml`). Verify with:

```bash
iptables -L OUTPUT -n  # inside the container
```

### OAuth session expired

If you want to re-import host credentials, remove the `claude-config` volume and start the container again. Otherwise, log in once inside the container and that login will persist in the volume.

### Claude says npm install is deprecated

The image now uses Claude Code's native installer during `docker build`, not the deprecated npm package. Version pinning still works via `CLAUDE_CODE_VERSION`, for example:

```powershell
.\build.ps1 stable
.\build.ps1 2.1.81
```

```bash
./build.sh stable
./build.sh 2.1.81
```

### Extra developer tooling in the image

See the tool table near the top of this document for the current image contents. `azure-cli`, `git-delta`, and `bun` are intentionally omitted.

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

A successful run prints a single confirmation line. If a tool is missing, the script exits non-zero and Docker surfaces the failing command.

## Maintenance

### List Claude containers

To list only Claude-related containers:

```powershell
docker ps -a --filter "name=claude-" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
```

### Remove a persisted project container

If you want to discard one saved project container and let the launcher recreate it next time:

```powershell
docker rm claude-<project>-<hash>
```

### Remove a project's container-local node_modules volume

If you want to force a clean reinstall for one project:

```powershell
docker volume rm agent-nm-<project>-<hash>
```

### Prune orphaned node_modules volumes

To remove `agent-nm-*` volumes that no longer have any matching Claude container:

```powershell
.\claude-container-prune-volumes.ps1
```

Preview only:

```powershell
.\claude-container-prune-volumes.ps1 -WhatIf
```

This is intentionally conservative: it only targets per-project `node_modules` volumes, not shared auth, history, or pnpm cache volumes.

### Prune the shared pnpm cache volume

If the shared package cache grows larger than you want, remove it and let pnpm repopulate it as needed:

```powershell
docker volume rm claude-pnpm-store
```

This affects cache reuse across projects, but it does not remove source code from your mounted workspaces.
