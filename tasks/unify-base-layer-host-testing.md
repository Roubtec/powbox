# Unify Base Layer Host Testing

## Purpose

Use this checklist on a host machine that has Docker installed.

The container used for implementation does not include Docker, so the final validation has to happen on the host.

## Preconditions

- Docker Desktop or Docker Engine is installed and running.
- `docker buildx version` works.
- The repo checkout is on the branch containing the shared-base refactor.
- If you plan to test Codex interactively, `OPENAI_API_KEY` is set on the host.

## 1. Confirm The New Layout Exists

Verify these files are present:

- `docker/base/Dockerfile`
- `docker/claude/Dockerfile`
- `docker/codex/Dockerfile`
- `docker-bake.hcl`
- `compose.shared.yml`
- `compose.claude.yml`
- `compose.codex.yml`
- `scripts/build-image.sh`
- `scripts/launch-agent.sh`

## 2. Inspect Bake Targets

Run:

```bash
docker buildx bake --file docker-bake.hcl --print
```

Expected result:

- targets named `base`, `claude`, and `codex` are present
- images are tagged as `powbox-agent-base:latest`, `powbox-claude:latest`, and `powbox-codex:latest`

## 3. Build The Shared Base

Cached build:

```bash
./build.sh base
```

Fresh build:

```bash
./build.sh base --no-cache --pull
```

Expected result:

- `powbox-agent-base:latest` exists locally
- the build completes without trying to build the Claude or Codex top images

Verify:

```bash
docker image inspect powbox-agent-base:latest >/dev/null
```

## 4. Build The Thin Agent Images

Cached builds:

```bash
./build.sh claude --claude-version latest
./build.sh codex --codex-version latest
```

Fresh top-image rebuilds:

```bash
./build.sh claude --claude-version latest --no-cache
./build.sh codex --codex-version latest --no-cache
```

Expected result:

- both top images build successfully from the prebuilt base image
- the top-image rebuilds are meaningfully faster than a full base rebuild

Verify:

```bash
docker image inspect powbox-claude:latest >/dev/null
docker image inspect powbox-codex:latest >/dev/null
```

## 5. Smoke Test The Images

Run:

```bash
(cd claude-container && ./smoke-test.sh)
(cd codex-container && ./smoke-test.sh)
```

Expected result:

- Claude image resolves `claude`, `gh`, `pnpm`, `sqlcmd`, and the rest of the common toolchain
- Codex image resolves `codex`, `bwrap`, `gh`, `pnpm`, `sqlcmd`, and the rest of the common toolchain

## 6. Verify Compose Runtime Wiring

Run:

```bash
docker compose -p powbox -f compose.shared.yml -f compose.claude.yml config
docker compose -p powbox -f compose.shared.yml -f compose.codex.yml config
```

Expected result:

- both commands render a valid merged config
- the shared volumes are declared directly in the merged config
- neither path depends on `external: true` for `gh`, `pnpm`, or `zsh-history`

## 7. Verify Volume Creation Order Is Gone

This is the most important runtime regression check.

Remove any existing shared volumes first if you are working in a disposable environment:

```bash
docker volume rm agent-gh-config agent-pnpm-store agent-zsh-history 2>/dev/null || true
```

Then start Codex first:

```bash
(cd codex-container && ./codex-container.sh . --shell --volatile)
```

Expected result:

- the container starts successfully
- Docker creates the shared volumes automatically

Exit the shell.

Then start Claude first in the same clean environment:

```bash
(cd claude-container && ./claude-container.sh . --shell --volatile)
```

Expected result:

- the container also starts successfully
- there is no order dependency between the two agents

## 8. Verify Shared Volumes And Per-Agent Volumes

After running both launchers, inspect volumes:

```bash
docker volume ls
```

Expected result:

- shared volumes exist once:
  - `agent-gh-config`
  - `agent-pnpm-store`
  - `agent-zsh-history`
- agent-specific config volumes exist separately:
  - `claude-config`
  - `codex-config`
- the project-specific `agent-nm-<project>-<hash>` volume exists

## 9. Verify Claude Runtime Behavior

Run:

```bash
(cd claude-container && ./claude-container.sh . --volatile)
```

Inside the container, verify:

```bash
whoami
echo "$CLAUDE_CONFIG_DIR"
claude --version
gh --version
pnpm config get store-dir
ls -l /workspace/node_modules
```

Expected result:

- user is `node`
- `CLAUDE_CONFIG_DIR` points to `/home/node/.claude`
- tools are present
- pnpm store points to `/home/node/.local/share/pnpm/store`
- `/workspace/node_modules` is writable by `node`

## 10. Verify Codex Runtime Behavior

Run:

```bash
(cd codex-container && ./codex-container.sh . --shell --volatile)
```

Inside the container, verify:

```bash
whoami
echo "$CODEX_CONFIG_DIR"
codex --version
bwrap --version
gh --version
pnpm config get store-dir
ls -l /workspace/node_modules
```

Expected result:

- user is `node`
- `CODEX_CONFIG_DIR` points to `/home/node/.codex`
- `bwrap` is available
- `/workspace/node_modules` is writable by `node`

## 11. Verify Shared pnpm And GitHub State

Optional but useful:

1. Start one agent shell.
2. Run `gh auth status`.
3. Install a small package in a test repo with `pnpm add`.
4. Exit.
5. Start the other agent on the same repo.
6. Confirm `gh auth status` still works and the project `node_modules` content is already present.

Expected result:

- GitHub CLI auth is shared
- per-project Linux `node_modules` is shared
- shared pnpm cache remains external to the workspace tree

## 12. Verify Fresh Top Rebuilds Stay Thin

Capture timings for:

```bash
time ./build.sh base --no-cache --pull
time ./build.sh codex --codex-version latest --no-cache
time ./build.sh claude --claude-version latest --no-cache
```

Expected result:

- base rebuild is the expensive path
- Claude and Codex top-image rebuilds are materially cheaper than the base rebuild

## 13. Regression Checks

Check these edge cases before calling the work complete:

- `claude-container.sh --build` still works
- `codex-container.sh --build` still works
- `codex-container.sh --exec "task"` still works
- `--resume`, `--detach`, `--volatile`, and `--persist` still behave as expected
- PowerShell wrappers still call the shared logic correctly on Windows
- `gh auth setup-git` does not fail when `/workspace` is not a git repo
- firewall startup still blocks private ranges and keeps public internet reachable

## Completion Criteria

The refactor is ready when:

- both agent images build successfully from the shared base
- shared volumes are created without order dependence
- both launchers preserve their previous user-facing behavior
- Codex still has `bubblewrap`
- smoke tests pass
- fresh top-image rebuilds are fast enough to justify the split
