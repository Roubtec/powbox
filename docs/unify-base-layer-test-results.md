# Unify Base Layer Host Test Results

## Environment

Date: 2026-03-29.

Host OS: Windows.

Docker Desktop: 4.62.0.

Docker Engine: 29.2.1.

Docker Buildx: v0.31.1-desktop.1.

This host did not have a usable `bash` in `PATH`, and WSL `bash` was unavailable, so the host validation used the PowerShell wrappers and direct `docker` commands instead of the `.sh` wrappers.

`OPENAI_API_KEY` was unset on the host, so Codex authentication-dependent runtime flows were not fully exercised.

## Repo Fixes Made During Validation

The temporary host-testing checklist contained durable knowledge that was not yet preserved in the permanent docs, so the validation notes were folded into the root README plus the Claude and Codex READMEs.

`scripts/launch-agent.ps1` had an actual Windows regression: interpolated bind-mount strings such as `$agentHostConfigDir:/home/node/...` caused a PowerShell parser error before Docker was invoked.

That regression was fixed by switching those interpolations to `${agentHostConfigDir}:...`.

`docker-bake.hcl` also lacked a default Bake group, so `docker buildx bake --file docker-bake.hcl --print` failed until a `default` group pointing at `all` was added.

## Checklist Results

### 1. Confirm The New Layout Exists

Status: pass.

Verified present:

- `docker/base/Dockerfile`
- `docker/claude/Dockerfile`
- `docker/codex/Dockerfile`
- `docker-bake.hcl`
- `compose.shared.yml`
- `compose.claude.yml`
- `compose.codex.yml`
- `scripts/build-image.sh`
- `scripts/launch-agent.sh`

### 2. Inspect Bake Targets

Status: pass after fix.

`docker buildx bake --file docker-bake.hcl --print` now works and shows `base`, `claude`, and `codex`.

Resolved tags:

- `powbox-agent-base:latest`
- `powbox-claude:latest`
- `powbox-codex:latest`

### 3. Build The Shared Base

Status: pass.

Fresh base rebuild command:

```powershell
.\build.ps1 -Target base -NoCache -Pull
```

Fresh rebuild time: 108.98s.

The image was created successfully as `powbox-agent-base:latest`.

The build only targeted the base image and did not try to build the Claude or Codex top images.

First follow-up cached base build time: 83.02s.

That first cached rerun unexpectedly rebuilt most of the base again on this host.

Second cached base build time: 1.14s.

The second cached rerun was fully cached, so steady-state cached behavior is good even though the first post-`--no-cache` rerun was not.

### 4. Build The Thin Agent Images

Status: pass.

First Claude build on top of the prebuilt base:

```powershell
.\claude-container\build.ps1 -Version latest
```

Time: 43.81s.

First Codex build on top of the prebuilt base:

```powershell
.\codex-container\build.ps1 -Version latest
```

Time: 16.00s.

Fresh Claude top-image rebuild:

```powershell
.\claude-container\build.ps1 -Version latest -NoCache
```

Time: 40.30s.

Fresh Codex top-image rebuild:

```powershell
.\codex-container\build.ps1 -Version latest -NoCache
```

Time: 15.24s.

Steady-state cached Claude rebuild time: 1.15s.

Steady-state cached Codex rebuild time: 1.26s.

Both thin images build successfully from the prebuilt base image.

Both thin rebuild paths are materially cheaper than the 108.98s fresh base rebuild.

### 5. Smoke Test The Images

Status: pass.

Commands used:

```powershell
.\claude-container\smoke-test.ps1
.\codex-container\smoke-test.ps1
```

Both smoke tests passed.

That confirms the common toolchain is present in both images, and confirms that Codex still includes `bwrap`.

### 6. Verify Compose Runtime Wiring

Status: pass.

Commands used:

```powershell
docker compose -p powbox -f compose.shared.yml -f compose.claude.yml config
docker compose -p powbox -f compose.shared.yml -f compose.codex.yml config
```

Both merged configs rendered successfully.

The shared volumes are declared directly in the merged config.

Neither merged path relies on `external: true` for `gh`, `pnpm`, or `zsh-history`.

### 7. Verify Volume Creation Order Is Gone

Status: pass for the shared volumes.

There were pre-existing shared volumes on this host from older compose projects, so they were removed to get a clean first-launch test.

Codex-first clean launch:

```powershell
@('exit') | .\codex-container\codex-container.ps1 . -Shell -Volatile
```

Codex created `agent-gh-config`, `agent-pnpm-store`, and `agent-zsh-history` itself through the shared `powbox` compose config.

Claude-first clean launch:

```powershell
@('exit') | .\claude-container\claude-container.ps1 . -Shell -Volatile
```

Claude also created the shared volumes itself through the same shared `powbox` compose config.

After recreation, the shared volume labels show `com.docker.compose.project=powbox`.

That is the important runtime regression check, and it passed.

### 8. Verify Shared Volumes And Per-Agent Volumes

Status: pass with migration caveat.

After launcher runs, `docker volume ls` showed one copy of the shared volumes:

- `agent-gh-config`
- `agent-pnpm-store`
- `agent-zsh-history`

Agent-specific config volumes also exist separately:

- `claude-config`
- `codex-config`

The project-specific Linux `node_modules` volume was also present as `agent-nm-powbox-6de8ac5a6cdd`.

Migration caveat: `claude-config` and `codex-config` already existed on this host from the older `claude-container` and `codex-container` compose projects, so the new `powbox` launchers emit compose warnings about those old labels even though the launches still succeed.

### 9. Verify Claude Runtime Behavior

Status: pass.

Direct runtime sanity check output:

- user: `node`
- `CLAUDE_CONFIG_DIR`: `/home/node/.claude`
- `claude --version`: `2.1.86`
- `gh --version`: `2.89.0`
- `pnpm` store: `/home/node/.local/share/pnpm/store`
- `/workspace/node_modules`: owned by `node:node`

The PowerShell launcher also starts successfully after the interpolation fix, and it prints the expected firewall banner.

### 10. Verify Codex Runtime Behavior

Status: pass with auth caveat.

Direct runtime sanity check output:

- user: `node`
- `CODEX_CONFIG_DIR`: `/home/node/.codex`
- `codex --version`: `0.117.0`
- `bwrap --version`: `0.8.0`
- `gh --version`: `2.89.0`
- `pnpm` store: `/home/node/.local/share/pnpm/store`
- `/workspace/node_modules`: owned by `node:node`

The PowerShell launcher starts successfully after the interpolation fix, prints the expected firewall banner, and warns when `OPENAI_API_KEY` is missing.

Codex authentication-dependent behavior was not fully exercised because `OPENAI_API_KEY` was unset on the host.

### 11. Verify Shared pnpm And GitHub State

Status: not fully verified.

The shared volume layout is correct, but cross-agent authenticated `gh` state and a real shared `pnpm add` flow were not exercised as part of this pass.

That would need either an intentionally seeded `gh` auth state, a disposable authenticated environment, or explicit user guidance on whether it is safe to reuse existing auth volumes for that check.

### 12. Verify Fresh Top Rebuilds Stay Thin

Status: pass.

Fresh base rebuild: 108.98s.

Fresh Claude top rebuild: 40.30s.

Fresh Codex top rebuild: 15.24s.

The base rebuild is still the expensive path.

Both thin-image rebuilds are substantially cheaper than a full base rebuild, especially Codex.

### 13. Regression Checks

Status: partially verified.

Verified:

- `claude-container.ps1 -Build -Shell -Volatile`
- `codex-container.ps1 -Build -Shell -Volatile`
- PowerShell wrappers call the shared logic correctly after fixing `scripts/launch-agent.ps1`
- firewall startup banner appears on both launchers

Not fully exercised in this pass:

- `.sh` wrappers on this Windows host, because `bash` was unavailable
- `codex-container.ps1 -Exec "task"`, because `OPENAI_API_KEY` was unset
- `--resume`, `--detach`, and `--persist`
- `gh auth setup-git` behavior in a guaranteed non-git workspace

## Resulting Images

Resulting image sizes from `docker images`:

- `powbox-agent-base:latest`: 1.27GB
- `powbox-claude:latest`: 1.57GB
- `powbox-codex:latest`: 1.68GB

## Overall Assessment

The shared-base refactor is working on this host.

The base image builds successfully.

Both thin agent images build successfully on top of that base.

Both smoke tests pass.

The shared volumes can now be created by either agent first through the shared `powbox` compose configuration.

The two host-only regressions found during validation were the missing default Bake target and the broken PowerShell wrapper interpolation, and both were fixed during this pass.

The main remaining caveats are migration warnings for old pre-refactor config volumes and the untested auth-dependent Codex and GitHub flows.
