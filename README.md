# PowBox Dockerized Development Sandbox

PowBox builds and launches isolated Docker environments for CLI coding agents.

The repo now uses a shared Docker base image for common tooling and two thin agent images layered on top of it.

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
- `scripts/`: shared build, launch, and smoke-test helpers
- `claude-container/` and `codex-container/`: user-facing wrappers and agent-specific instruction assets

## Build Modes

Cached builds are the default.

Use the root build wrappers or the agent-specific wrappers to rebuild the images you need.

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

That means the shared GitHub, pnpm, and zsh-history volumes are declared once and no longer rely on one agent creating them before the other starts.

Shared volume names are kept stable to preserve existing data:

- `claude-gh-config`
- `claude-pnpm-store`
- `claude-zsh-history`

Agent-specific config volumes remain separate:

- `claude-config`
- `codex-config`

## Agent Wrappers

The existing wrapper entry points remain available:

- `claude-container/build.sh`, `claude-container/claude-container.sh`, and PowerShell equivalents
- `codex-container/build.sh`, `codex-container/codex-container.sh`, and PowerShell equivalents

Those wrappers now delegate to the shared root-level implementation.

## Validation

Host-side Docker validation steps live in [tasks/unify-base-layer-host-testing.md](tasks/unify-base-layer-host-testing.md).

## License

This project is licensed under the MIT License.

See [LICENSE](LICENSE).
