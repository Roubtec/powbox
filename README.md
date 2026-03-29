# PowBox Dockerized Development Sandbox

PowBox builds and launches isolated Docker environments for CLI coding agents.

The repo uses a shared Docker base image for common tooling and two thin agent images layered on top of it.

Runtime orchestration is handled by shared Compose files at the repo root.

Image builds are handled by `docker buildx bake` through wrapper scripts so cached builds are the default and clean rebuilds are explicit.

## Layout

- `docker/base/Dockerfile`: shared toolchain image used by both agents
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
