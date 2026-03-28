# Unify Shared Container Base Layer

## Recommendation

Yes.

The container builds are duplicated enough that a shared base layer is worth doing.

The main benefits are faster agent-binary rebuilds, less maintenance overhead, and a clearer separation between "tooling/runtime" concerns and "agent-specific" concerns.

The disk-space win is real but should be treated as secondary, because Docker already deduplicates identical layer contents to some extent.

The biggest practical win will come from keeping all slow, stable setup in a shared cached base and moving only the agent install plus agent-specific assets into the top layers.

The preferred implementation should use a baked shared base image, not just a shared stage inside one always-rebuilt Dockerfile.

That gives the repo two intentional rebuild modes:

- rebuild the shared base image from scratch when the common tooling changes
- rebuild only the thin agent images from scratch when agent binaries change frequently

For this repo, the preferred split should be Compose for runtime and Bake for builds.

That keeps runtime orchestration simple while giving the build path explicit named targets and a clean default-cached plus opt-in-`--no-cache` workflow.

## What Exists Today

The current `claude-container/Dockerfile` and `codex-container/Dockerfile` are almost the same.

Both install the same OS packages, GitHub CLI, `sqlcmd`, `pnpm`, `yq`, Oh My Zsh, shell config, firewall/entrypoint scripts, writable volume mount points, and `pnpm` configuration.

The meaningful Dockerfile differences are:

- Codex adds `bubblewrap`.
- Claude installs `claude` and seeds `CLAUDE.md`.
- Codex installs `@openai/codex` and seeds `AGENTS.md`.
- The config directory names and default commands differ.

The runtime layer is also duplicated.

`entrypoint.sh`, the shell launchers, PowerShell launchers, build scripts, smoke tests, and compose files are all structurally similar with small agent-specific branches.

The current shared-volume story is asymmetric.

`claude-container/docker-compose.yml` creates the shared `gh`, `pnpm`, and `zsh-history` volumes.

`codex-container/docker-compose.yml` references those same volumes with `external: true`, which means Codex currently depends on those volumes already existing.

## Constraints And Observations

Compose `no_cache` applies to all layers declared in the Dockerfile being built, not just its last stage.

That means selective top-layer freshness is only realistic if the top image has its own thin Dockerfile that starts from a separately tagged shared base image.

Both `build.sh` scripts and both `build.ps1` scripts currently force `docker compose build --no-cache`, which defeats most of the value of layer reuse for the explicit build path.

If the repo wants a "fresh but fast" rebuild mode, the build helpers should target a thin top-image Dockerfile whose `FROM` points at a prebuilt local base image tag.

Bake is the better fit for those builds than Compose in this repo, because it lets the scripts expose clear targets such as `base`, `claude`, `codex`, and `all` without overloading the runtime compose files.

If we keep separate compose projects and separate compose files with independent volume ownership, a shared base image alone will not remove the need for `external: true`.

That bonus only becomes realistic if shared named volumes are declared from one common compose file or one common compose project.

## Target Architecture

### 1. One Shared Base Image Plus Thin Agent Images

Create one shared base image and make each agent image a thin wrapper on top of it.

Recommended shape:

- `docker/base/Dockerfile` or equivalent for the common base image
- `docker/claude/Dockerfile` for the Claude top image
- `docker/codex/Dockerfile` for the Codex top image
- `docker-bake.hcl` at repo root to define named build targets

Recommended images:

- `powbox-agent-base:<tag>`: all shared OS packages, GitHub CLI, `sqlcmd`, `pnpm`, `yq`, Oh My Zsh, shared scripts, common env defaults, common writable directories, and `pnpm` global config
- `powbox-claude:<tag>`: `FROM powbox-agent-base:<tag>`, then install Claude and copy Claude-specific instruction assets
- `powbox-codex:<tag>`: `FROM powbox-agent-base:<tag>`, then install Codex and copy Codex-specific instruction assets

This is the most practical way to get a deliberately fresh rebuild of only the thin agent slice while still reusing a prebuilt lower layer image.

The root-only Codex install is not a blocker for this approach.

It simply belongs in the thin Codex Dockerfile before `USER node`.

`bubblewrap` should live in the shared base image.

### 2. Shared Runtime Scaffolding

Move identical scripts and assets into a shared location.

Candidates:

- `init-firewall.sh`
- most of `entrypoint.sh`
- shared `.zshrc`
- common launcher logic for project hashing, container naming, volume repair, and bind mounts

Keep only small agent-specific overlays for:

- config directory names
- host seed directory names
- agent bootstrap logic
- instruction file destination (`CLAUDE.md` vs `AGENTS.md`)
- default command
- Codex-only `OPENAI_API_KEY` warning

The best implementation is either one parameterized shared entrypoint or a shared entrypoint plus tiny per-agent hook scripts.

For this repo, prefer a shared core plus small customized hooks.

Recommended shape:

- `scripts/entrypoint-core.sh`
- `scripts/entrypoint-claude.sh`
- `scripts/entrypoint-codex.sh`

The core should own firewall setup, shared Git/GitHub seeding, common env bootstrapping, and final `exec`.

The hooks should own only the agent-specific config seeding, instruction-file sync, and optional warnings.

### 3. Shared Compose Base

Introduce a shared compose file that owns the common declarations.

That base compose file should define:

- the shared named volumes
- common service options such as `stdin_open`, `tty`, `init`, `cap_add`, workspace bind mount, `pnpm` store mount, `gh` mount, and `zsh` history mount

Then keep thin per-agent compose overlays that define only:

- service name
- build target or image tag
- agent-specific config volume
- agent-specific environment variables
- agent default command

This is the part that can remove the `external: true` workaround, because both agents would resolve shared volumes from the same merged compose configuration instead of one agent piggybacking on the other agent's volume names.

### 4. Thin Agent-Specific Wrappers

Retain separate `claude-container` and `codex-container` entry points for usability if that still matters, but make them wrappers around shared scripts and shared compose fragments.

This preserves the current UX while removing most duplicated implementation.

### 5. Separate Build Modes

Treat "refresh the shared toolchain" and "refresh just the agent binary" as two separate workflows.

Recommended workflows:

- `default build`: cached Bake build for `base`, `claude`, `codex`, or `all`
- `base rebuild`: Bake build of `base` with `--pull --no-cache`
- `agent rebuild`: Bake build of `claude` or `codex` with `--no-cache`, using the already-built local base tag

This gives a fast clean rebuild path for frequent agent updates without paying the full apt/bootstrap cost every time.

Recommended commands:

- cached base build: `docker buildx bake base`
- cached Claude build: `docker buildx bake claude`
- cached Codex build: `docker buildx bake codex`
- fresh base rebuild: `docker buildx bake --pull --no-cache base`
- fresh Claude rebuild: `docker buildx bake --no-cache claude`
- fresh Codex rebuild: `docker buildx bake --no-cache codex`

The wrapper scripts should hide these details and expose a simpler interface such as:

- `./build.sh base`
- `./build.sh claude`
- `./build.sh codex`
- `./build.sh all`
- `./build.sh codex --no-cache`

## Detailed Work Plan

### Phase 0: Baseline And Scope Lock

Document the current duplicated surfaces before editing anything.

Tasks:

- Diff the two Dockerfiles and classify each difference as either "must remain agent-specific" or "safe to share".
- Diff `entrypoint.sh`, launcher scripts, build scripts, smoke tests, and assets in the same way.
- Record current build timings for:
  - clean Claude build
  - clean Codex build
  - cached Claude rebuild after only version arg change
  - cached Codex rebuild after only version arg change
- Record current image sizes and shared layer reuse using `docker image ls` and `docker history`.

Exit criteria:

- We know exactly which lines are shared versus agent-specific.
- We have before/after metrics to justify the refactor.

### Phase 1: Extract The Shared Base Image And Thin Agent Images

Build the shared base image first, then split the two agent images into thin overlays, without changing launcher UX yet.

Tasks:

- Create a base-image Dockerfile and two thin agent Dockerfiles.
- Add `docker-bake.hcl` with targets for `base`, `claude`, `codex`, and `all`.
- Move all shared apt packages into the base image.
- Put `bubblewrap` in the shared base image unless image size testing proves it is materially harmful.
- Move shared shell/bootstrap setup into the base image.
- Move shared writable-directory creation into the base image.
- Copy shared scripts and shared `.zshrc` from one canonical location.
- Keep only the agent binary install and agent instruction asset copy in the thin agent Dockerfiles.
- Keep version args target-specific in those thin Dockerfiles:
  - `CLAUDE_CODE_VERSION`
  - `CODEX_VERSION`
- Tag the shared base image explicitly so agent builds can `FROM` it directly.

Proposed target names:

- `base`
- `claude`
- `codex`
- `all`

Proposed image tags:

- `powbox-agent-base:latest`
- `powbox-claude:latest`
- `powbox-codex:latest`

Implementation note:

If the repo later wants a single-file build graph for maintainability, it can still use one multi-stage source Dockerfile internally and export a tagged base target.

But the operational goal should remain the same: a separately buildable and separately tagged shared base image that thin agent images can consume.

Exit criteria:

- The shared base image can be rebuilt independently.
- Both agent images build from that base image.
- Changing only `CLAUDE_CODE_VERSION` rebuilds only the thin Claude image layers.
- Changing only `CODEX_VERSION` rebuilds only the thin Codex image layers.

### Phase 2: Extract Shared Runtime Scripts

After the image graph is unified, remove duplicated runtime scripts.

Tasks:

- Create a shared `entrypoint-core.sh` plus thin Claude and Codex wrappers.
- Parameterize config paths, host seed paths, instruction-source path, instruction-destination filename, and optional warning behavior through env vars.
- Keep agent-specific seeding logic pluggable.
- Preserve Codex's filtered `rsync` seed behavior for `~/.codex`.
- Preserve Claude's simpler copy behavior unless there is a reason to harden it similarly.
- Deduplicate the identical firewall script.
- Deduplicate the identical `.zshrc`.

Exit criteria:

- Shared runtime behavior lives in one place.
- Agent-specific runtime differences are explicit and small.
- The entrypoint structure is easier to reason about than one fully generic shell script.

### Phase 3: Unify Compose Ownership Of Shared Volumes

This phase addresses the `external: true` annoyance.

Tasks:

- Create a shared compose base file with common volume declarations and common service fragments.
- Make both agent launch paths compose against that base plus a thin agent overlay.
- Ensure the shared volumes are declared once in the merged compose configuration.
- Keep agent-specific config volumes separate:
  - `claude-config`
  - `codex-config`
- Keep the shared volumes common:
  - GitHub auth/config
  - `pnpm` store
  - `zsh` history

Important nuance:

If the repository keeps completely separate compose projects for each agent, Docker will still treat shared volumes as externally managed from the point of view of at least one project.

To remove `external: true`, both launch flows need to resolve through the same compose project or the same merged compose config that declares those volumes directly.

Recommended shape:

- `compose.shared.yml`
- `compose.claude.yml`
- `compose.codex.yml`

Then launch with:

- Claude: `docker compose -f compose.shared.yml -f compose.claude.yml ...`
- Codex: `docker compose -f compose.shared.yml -f compose.codex.yml ...`

Recommended project-name behavior:

- set one stable shared compose project name in the wrapper scripts, for example `powbox`
- keep container names explicit in the wrapper scripts as they are today

Exit criteria:

- Neither agent compose overlay needs `external: true` for the shared volumes.
- Starting Codex first works without a prior Claude run.
- Starting Claude first works without a prior Codex run.

### Phase 4: Unify Launchers And Build Helpers

Once the image and compose layout are stable, remove the script duplication.

Tasks:

- Extract shared shell launcher logic into one helper used by both agent entry scripts.
- Extract shared PowerShell launcher logic into one helper used by both Windows entry scripts.
- Extract shared build helper logic into one helper with agent-specific parameters.
- Switch build helpers from `docker compose build` to `docker buildx bake`.
- Make cached builds the default behavior.
- Add an explicit `--no-cache` flag for the build scripts.
- Add an explicit base rebuild command that refreshes the shared base with `--pull --no-cache`.
- Add an explicit quick agent rebuild command that rebuilds only the thin agent image with `--no-cache`.
- Deduplicate smoke tests where possible.

Recommended CLI shape:

- `./build.sh base`
- `./build.sh claude`
- `./build.sh codex`
- `./build.sh all`
- `./build.sh codex --no-cache`
- `./build.sh base --no-cache --pull`

Exit criteria:

- The user-facing scripts remain separate and readable.
- The implementation logic is shared.
- Full base refreshes and quick thin-image refreshes are both first-class workflows.
- The default build path uses cache.

### Phase 5: Documentation And Migration

Update repo documentation after the implementation lands.

Tasks:

- Update the root `README.md` to describe the shared base-layer architecture.
- Update both agent-specific READMEs so they describe the new compose/build layout.
- Document that shared volumes are now first-class and no longer depend on Claude being initialized first, if Phase 3 achieves that.
- Document the new build behavior and the new way to force a clean rebuild.

Exit criteria:

- The repo docs match the new structure.
- A new contributor can understand which files are shared and which are agent-specific.

## Risks And Tradeoffs

### Bubblewrap In The Shared Base

Including `bubblewrap` in the shared base slightly fattens the Claude image.

That is probably an acceptable trade, because it buys a simpler base image and better cache reuse.

If size measurements show otherwise, the fallback is a second shared target such as `agent-base` and `codex-base`, but that should be avoided unless the data justifies the added complexity.

### Compose As A Build Orchestrator

Compose can support a split "base build" and "top-image build" approach if those are separate builds against separate Dockerfiles or separately tagged targets.

Compose cannot selectively disable cache for only the final stage inside one Dockerfile build.

For this repo, prefer Bake for builds and Compose for runtime.

That keeps the configuration understandable:

- Bake owns image production
- Compose owns running containers, volumes, and capabilities

### Over-Parameterizing The Entrypoint

A single giant generic entrypoint can become harder to reason about than two small scripts.

Prefer a shared core plus small agent hooks instead of turning every branch into an environment-variable matrix.

### Compose Refactors Can Break Existing Muscle Memory

Even if the underlying compose structure changes, the current `claude-container.sh` and `codex-container.sh` UX should stay stable.

Do not force users to learn a new raw compose invocation unless there is a strong reason.

### Disk Savings May Be Smaller Than Expected

The maintenance and rebuild wins are strong.

The disk-space win may be moderate rather than dramatic because Docker already shares identical content-addressed layers.

The refactor is still justified, but the repo should not sell this as a massive storage optimization without measurement.

## Validation Checklist

After implementation, verify all of the following:

- Claude image builds from the shared base image.
- Codex image builds from the shared base image.
- The shared base image can be rebuilt cleanly on its own.
- A clean Claude rebuild can reuse the prebuilt shared base image.
- A clean Codex rebuild can reuse the prebuilt shared base image.
- Cached builds still work through the wrapper scripts without extra flags.
- Claude launch still seeds host config correctly.
- Codex launch still seeds host config correctly and still filters transient state.
- GitHub CLI auth persists across both containers.
- Shared `pnpm` store still works.
- Shared `zsh` history still works.
- The per-project `node_modules` overlay still gets repaired to `node:node`.
- Codex still has working `bubblewrap`.
- The firewall startup still runs correctly.
- Starting either agent first works without manual volume preparation.

## Suggested Order Of Execution

1. Land Phase 1 first with a separately tagged shared base image.
2. Add the Bake targets and dual rebuild workflows in Phase 4 as soon as Phase 1 is stable enough to exercise.
3. Measure the rebuild improvement.
4. Land Phase 2 next.
5. Land Phase 3 only after the image split is stable, because the compose-volume change is operationally riskier than the image-layer change.
6. Finish with docs in Phase 5.

## Success Criteria

This refactor is successful if:

- most shared logic exists in one canonical place
- agent version bumps only rebuild thin top images
- the repo supports both full base refreshes and fast thin-image refreshes
- the default build path remains cached, with `--no-cache` only when explicitly requested
- the compose setup no longer has order-dependent shared-volume behavior
- the user-facing launch commands remain as simple as they are today
