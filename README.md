# PowBox Dockerized Development Sandbox

PowBox builds and launches isolated Docker environments for CLI coding agents.

The repo uses a shared Docker base image for common tooling and a single unified agent image layered on top of it that ships both the Claude Code and Codex binaries. Which agent runs is chosen at container start via the `PRIMARY_AGENT` env var; both agents are seeded so either can invoke the other in-container.

Runtime orchestration is handled by shared Compose files at the repo root.

Image builds are handled by `docker buildx bake` through wrapper scripts so cached builds are the default and clean rebuilds are explicit.

## Quick Start

Get from a fresh clone to a working PowBox in three steps.

**Prerequisites:** Docker Desktop or Docker Engine with a working `docker buildx`. `npm` on the host `PATH` is recommended — it is used to check for newer agent releases (without it the agent images still build, but version-staleness checks report `(unknown)`). Codex also needs `OPENAI_API_KEY` exported before launching; Claude can optionally use `ANTHROPIC_API_KEY`.

1. **Clone the repo** somewhere stable — your shell profile will point at this path:

   ```bash
   git clone https://github.com/Roubtec/powbox.git ~/code/powbox
   ```

2. **Load the shell helpers** by adding one line to your shell profile, then reloading it. `POWBOX_ROOT` is auto-detected from the file's own location, so no extra configuration is needed.

   Bash / zsh — add to `~/.bashrc` or `~/.zshrc`, then `source` it:

   ```bash
   source "$HOME/code/powbox/shell/powbox.sh"
   ```

   PowerShell — add to `$PROFILE` (`notepad $PROFILE`), then reload with `& $PROFILE`:

   ```powershell
   . "C:\path\to\powbox\shell\powbox.ps1"
   ```

   This exposes the `cc`, `cx`, and `agent-*` helpers in your shell.

3. **Build the images** with `agent-update`. It prints an update report and then prompts before doing anything. On a machine with no images yet, everything shows as stale, so confirming performs the first full build (base + the unified agent image):

   ```bash
   agent-update
   ```

That's it — you now have a functioning PowBox. Launch an agent in any project directory:

```bash
cc ~/projects/myapp      # Claude
cx ~/projects/myapp      # Codex
```

Re-run `agent-update` any time to pick up newer agent releases or a refreshed base image; it only rebuilds what is actually stale. See [Profile Shortcuts](#profile-shortcuts) for the full helper reference and [Build Modes](#build-modes) for invoking builds directly.

## Layout

- `docker/base/Dockerfile`: shared toolchain image (Node.js, Python, PHP, Go, .NET SDK 8, PostgreSQL 16, OPA, Git, shell utilities, and more) used by the unified agent image
- `docker/agent/Dockerfile`: the unified `powbox-agent:latest` image on top of the shared base; installs both the Codex and Claude binaries (Codex below Claude — see [Build Modes](#build-modes)) plus the per-agent seed assets and the entrypoint
- `compose.shared.yml`: common runtime service and shared volumes
- `compose.agent.yml`: agent runtime overlay — mounts both config volumes and passes both API keys and `PRIMARY_AGENT`, all on a single `agent` service pointing at `powbox-agent:latest`
- `compose.selfhosted.yml`: [self-hosted mode](#self-hosted-mode---isolated) overlay — replaces the host workspace bind mount with a per-instance named volume the container clones into itself (added to the `-f` chain only with `--isolated`)
- `docker-bake.hcl`: named Bake targets for `base`, `agent`, and `all`
- `commands/`: user-facing host commands for launch, smoke-test, volume pruning, session history reset, and baked-skill refresh
- `shell/`: sourceable shell libraries (`powbox.sh`, `powbox.ps1`) that expose the short helpers (`cc`, `cx`, `agent-*`) from a single profile line
- `scripts/`: shared internal build, launch, and smoke-test helpers
- `docker/shared/container-agent.md.tmpl`: shared agent instruction template (rendered per-agent at startup)
- `docker/shared/entrypoint-agent.sh`: the unified entrypoint — selects the primary agent, seeds every agent at startup, then hands off to `entrypoint-core.sh`
- `docker/shared/entrypoint-{claude,codex}-hook.sh`: per-agent config-seeding hooks, run in full for every agent at startup
- `docker/claude/agent-container/`: Claude-specific seed assets baked into the image at `/home/node/.agent-container/claude/` (statusline script, statusline settings overlay, settings defaults; no skills or workflows — those all arrive via the `dev-skills@roubtec` plugin)
- (the Codex seed dir `/home/node/.agent-container/codex/` has no in-tree source anymore: its `skills/` are copied entirely from the `Roubtec/agent-skills` staging clone at build time)
- `docs/`: deep-dive design chapters (architecture, entrypoint & runtime, worktree `node_modules` hardlinks, skills refresh & provenance, rootless Podman, the [smoke tests](docs/smoke-tests.md)) — referenced from the relevant README section and from [AGENTS.md](AGENTS.md), read on demand rather than front-loaded

## Build Modes

Cached builds are the default.

Use the root build wrappers to rebuild the images you need. Build targets are `base`, `agent`, and `all`.

Both `--claude-version` and `--codex-version` feed the single `agent` image. The Dockerfile installs Codex directly on the base, stable shared-linter layers above it, and Claude above those, so bumping the Claude version (the common, frequent case) busts only the Claude layer and the cheap asset/entrypoint layers above it, while the Codex and linter layers underneath are reused from cache. Bumping the Codex version rebuilds the linter and Claude layers on top as a side effect — an accepted, rarer cost. `agent-update` exploits this by pinning each agent binary's version per build (see [Profile Shortcuts](#profile-shortcuts)).

Examples:

```bash
./build.sh base
./build.sh agent
./build.sh agent --claude-version latest
./build.sh agent --codex-version latest
./build.sh agent --codex-version latest --no-cache
./build.sh base --no-cache --pull
```

### Iterating on a baked script without a rebuild

The shared helper scripts in `docker/shared/` (e.g. `entrypoint-core.sh`, `seed-workspace.sh`, `fix-workspace-perms.sh`) are `COPY`d into the **base** image at `/usr/local/bin/`, so the normal way to test an edit is a base rebuild (~13 min). For a faster behavioral loop on a single script, bind-mount your host copy over the baked path with a raw `docker run` instead of rebuilding:

```bash
# Drive one baked script directly against the current image, with your edit live.
docker run --rm \
  -v "$PWD/docker/shared/seed-workspace.sh:/usr/local/bin/seed-workspace.sh:ro" \
  --entrypoint /usr/local/bin/seed-workspace.sh \
  powbox-agent:latest <args...>
```

This is how the self-hosted smoke test exercises `seed-workspace.sh` (`scripts/smoke-test-selfhosted.sh`, Stage B). It validates one script in isolation, not the full entrypoint chain — once the behavior looks right, do a real `./build.sh base` before relying on it.

## Updating Agent Instructions

Container instructions for both agents are generated from a single shared template (`docker/shared/container-agent.md.tmpl`).
The template is baked into the unified image once per agent (at `/home/node/.agent-container/<agent>/agent.md.tmpl`) and rendered with agent-specific variables at container start.

After editing the template, rebuild the agent image for the changes to take effect:

```bash
./build.sh agent
# or rebuild everything (base + agent)
./build.sh
```

Alternatively, pass `--build` (or `-Build` in PowerShell) to the launch command to rebuild before starting:

```bash
cc --build
cx --build
```

No volume cleanup is needed — the entrypoint conditionally re-renders the template on container start when the image epoch is greater than or equal to the last-written volume epoch.

## Agent Skills

Every skill both agents use lives in the [`Roubtec/agent-skills`](https://github.com/Roubtec/agent-skills) repo — the single source of truth. That includes `enable-worktrees` and `session-learnings`, which used to live in this repo as powbox-specific skills and were forfeited to agent-skills along with the `wf-*` Claude dynamic workflows. Skills still reach the agents through **two delivery channels**, split by runtime rather than by source ownership.

| Channel | Delivers | Source of truth | How it updates |
|---|---|---|---|
| **Plugin** | the full shared skill palette (and the `wf-*` dynamic workflows) to Claude as the `dev-skills@roubtec` plugin, and — synced from the same marketplace clone — Codex's copies of the skills | `Roubtec/agent-skills` | `dev-skills@roubtec` marketplace plugin — installed/refreshed by a detached post-firewall bootstrap at every agent-container start (only the short-lived image-store writer skips it); on primary-Claude launches a short bounded wait before the agent launches means a warm refresh usually applies **this** session (a Codex prompt never uses the plugin, so it does not wait — the refresh lands next session; cold volume: first session needs `/reload-plugins` or a restart). The same detached bootstrap **also syncs the Codex copies** of the skills from the plugin's freshly-refreshed marketplace clone into the codex-config volume (a local, no-network sync ordered after the clone refresh; SHA-gated to a byte-for-byte no-op when unchanged), so Codex converges on the same `agent-skills` commit at the same container-recycle cadence instead of the image-bake cadence |
| **Bake + seed** | the full Codex skill palette, as the offline/first-boot baseline | `Roubtec/agent-skills` (fetched in full at build time) | baked into the image, seeded onto the codex-config volume, refreshed by `agent-update-skills` |

The shared palette is: `address-review`, `address-tasks`, `address-tasks-serialized`, `address-reviews`, `enable-worktrees`, `rebase-stack`, `resolve-open-questions`, `review-tasks`, `session-learnings`, `write-tasks`.

**Why the split:** the skills are consumed by colleagues too (outside powbox), so they are released from a single repo (`Roubtec/agent-skills`) as a Claude marketplace plugin — one source of truth, one release channel. Codex has no plugin runtime, so its copies are carried by the image bake (baseline) and kept current by the start-time clone sync.

### End state per agent

- **Claude in powbox:** the whole palette as `/dev-skills:<name>` (plugin), plus the `wf-*` workflows as `/dev-skills:wf-<name>` — nothing baked or seeded.
- **Codex in powbox:** the same palette, all seeded from the bake and refreshed by the clone sync.
- **Colleagues (Claude outside powbox):** the plugin only.

**Invocation note:** the plugin skills are namespaced — `/dev-skills:address-review`, `/dev-skills:session-learnings`, and so on. Implicit invocation is unaffected: each skill's `SKILL.md` description still drives the model-side Skill-tool match, prefix or not. On Codex the seeded skills keep their bare form (`$address-review`, `$enable-worktrees`, ...). A `claude-config` volume seeded before the forfeit can still carry the old unnamespaced Claude copies of `enable-worktrees`/`session-learnings` (and seeded `wf-*.js` workflows); `agent-update-skills --prune` retires them.

### Plugin channel — the whole Claude palette (skills and `wf-*` workflows)

At container start `entrypoint-core.sh` launches `/usr/local/bin/seed-claude-plugins.sh` (baked from `docker/shared/seed-claude-plugins.sh`; best-effort, bounded) — immediately **after** the firewall init and fully **detached**, on every launch, whether Claude is the primary agent or not (the one exception is the short-lived image-store **writer** container, `POWBOX_IMAGE_STORE_ROLE=writer`, which is reaped as soon as its seeding command exits and so never spawns it): it adds the `Roubtec/agent-skills` marketplace and installs the `dev-skills@roubtec` plugin the first time, then on every later start refreshes it to keep it current — running `claude plugin marketplace update roubtec` **and** the follow-up `claude plugin update dev-skills@roubtec` (a marketplace refresh alone only updates the catalog listing; the `plugin update` is what pulls the new skills into the installed cache). The agent-skills manifests carry no version field, so **every commit on `main` is a new SHA-version** — merging a change to `agent-skills` main *is* the release. No claude CLI invocation ever runs on the entrypoint's critical path — the detachment is load-bearing, because the claude CLI hangs when invoked with the container TTY as stdin (see `seed-claude-plugins.sh`). Freshness is still usually same-session: on primary-Claude launches the entrypoint ends with a short bounded wait (up to `POWBOX_PLUGIN_WAIT` seconds, default 4; `0` disables) polling for the detached run's done-marker, and since the refresh overlaps the rest of startup, a typical warm keep-current (~2–3s) finishes inside that window — before Claude enumerates plugins — so its updates apply **this** session. Past the cap the session starts on the volume's current plugin state: a **cold** (fresh) `claude-config` volume's install usually outlives the window, so the first session lacks the `/dev-skills:*` skills — run `/reload-plugins` (or restart) once the bootstrap finishes, typically within seconds — and a slow warm refresh lands one session late. A deliberately disabled plugin is respected and never re-enabled; an offline start logs a skip and self-heals on a later online start. Progress goes to `.powbox-plugin-bootstrap.log` on Claude's config volume (`$CLAUDE_CONFIG_DIR`, i.e. `~/.claude`).

**Codex piggybacks the same channel.** The plugin bootstrap keeps a full clone of the `Roubtec/agent-skills` marketplace on the shared `claude-config` volume (`~/.claude/plugins/marketplaces/roubtec/`) and refreshes it every start — and that clone carries `codex/dev-skills/skills/`, Codex's copies of the same shared palette (including `enable-worktrees` and `session-learnings`, which arrive via the clone like every other skill since the forfeit). So `entrypoint-core.sh` chains `/usr/local/bin/sync-codex-skills.sh` (baked from `docker/shared/sync-codex-skills.sh`) directly after the detached plugin run: a **local** sync from that freshly-refreshed clone into the codex-config volume's skill dir (`~/.codex/agents/skills/`), with no network op of its own. It runs as a **separate** process ordered after the clone refresh, so Claude's bounded plugin wait — which fires on the plugin run's own done-marker before the sync starts — never gates on it; Codex needs no wait anyway, because it observes skill-file changes live and picks up a mid-session refresh. The sync reuses the `.powbox-seeded` marker semantics of the bake + seed channel below: it only overwrites a skill powbox owns (marker present), never a user-adopted copy (marker deleted), and it only ever touches skills the clone carries. It is **SHA-gated**: each refreshed marker records the synced `agent-skills` commit as `agent_skills_commit=<sha>` plus `channel=plugin-clone`, alongside the `source=Roubtec/agent-skills#codex/dev-skills/skills/<name>` upstream path every seeded item carries, and a start where the clone HEAD already matches writes nothing (Codex warns loudly when skill files change under a running session, so an unchanged palette must be a byte-for-byte no-op). Best-effort: a cold `claude-config` volume with no clone yet logs a skip and leaves the image-baked Codex copies in place. Its progress appends to the same `.powbox-plugin-bootstrap.log`.

### Bake + seed channel — the Codex palette

The Codex skill palette is baked into the unified image as the offline/first-boot baseline (Codex has no plugin runtime). The source is `Roubtec/agent-skills` in full: `scripts/build-image.*` fetches `codex/dev-skills/skills/` from that repo's main at build time (into the gitignored `.agent-skills-src` staging dir) and copies it to `/home/node/.agent-container/codex/skills/`, which the Codex setup hook reads via `AGENT_SEED_DIR`; each skill ships an `agents/openai.yaml` for UI labels and default prompts. The agent-skills snapshot SHA is recorded on the image (`powbox-provenance` / `/home/node/.powbox/agent-skills.commit`). Nothing is baked or seeded for Claude anymore — its skills and workflows all come from the plugin channel above.

At container start, the Codex entrypoint hook seeds the baked skills into `$HOME/.agents/skills/` (backed by the `codex-config` volume via a `~/.agents → ~/.codex/agents` symlink seeded by the entrypoint) from the same epoch-gated block that re-renders the agent instruction template.

Seeding is no-clobber at the skill-directory level: existing skill folders are never overwritten, so user-modified copies are preserved.
This also means a rebuilt image with updated skill text does *not* replace the stale copies already on the volume. To push the latest baked skills onto the volume after a rebuild, run `agent-update-skills` (or `commands/update-skills.*` directly) — it copies each baked skill over the volume copy in one throwaway container, so you no longer need to enter a container, delete skills by hand, exit, and relaunch to re-seed. It works whether or not any agent containers are running (they share the volumes); skills you authored on the volume that are not baked into the image are left untouched. In practice the start-time clone sync (plugin channel above) usually refreshes the Codex copies first anyway. See [Refreshing Skills](#refreshing-skills) below.

Every skill powbox seeds carries a hidden `.powbox-seeded` ownership marker (recording the image build epoch, the powbox commit that built it, and the item's upstream source as `source=<owner>/<repo>#<path>` — e.g. `source=Roubtec/agent-skills#codex/dev-skills/skills/<name>` — so one `cat` tells you where to fix a defect you find in a seeded skill). The marker means *"powbox owns this copy"*: the refresher may overwrite or prune a marked skill, while a folder **without** the marker is treated as user-authored and is never touched. To adopt a seeded skill as your own (fork-and-keep), delete its `.powbox-seeded` (or rename the folder), and powbox leaves it alone for good. A `claude-config` volume seeded before the custody changes still carries stale marked Claude copies — the 8 shared skills (pre-015b seeds) and, since the forfeit, `enable-worktrees`, `session-learnings`, and the `wf-*.js` workflows; `agent-update-skills --prune` retires exactly them (they are marked but no longer baked), leaving the plugin as their only Claude source.

Per-repo skills (e.g. `.claude/skills/<name>/` or `.agents/skills/<name>/`) still take precedence at invoke time, so any repo can override an individual skill without losing the rest.
User-added skills in the same volume directory are unaffected by image rebuilds.

Each agent discovers its skills at startup and includes their `SKILL.md` frontmatter in the model-visible skills list, where the description drives implicit invocation. Codex accepts the explicit bare form (`$<skill-name>`); Claude invokes everything under the plugin namespace (`/dev-skills:<skill-name>`, e.g. `/dev-skills:address-review`), per the "Invocation note" above.

### Claude Dynamic Workflows

The `wf-*` Claude-only [dynamic workflows](https://code.claude.com/docs/en/workflows) — JavaScript orchestration scripts the runtime executes in the background, spawning and sequencing subagents at scale, reimagining the orchestration-heavy skills (`address-tasks`, `address-review`) as code instead of prose — live in `Roubtec/agent-skills` (`plugins/dev-skills/workflows/`) and are delivered by the `dev-skills@roubtec` plugin, invoked namespaced (`/dev-skills:wf-address-tasks`, `/dev-skills:wf-address-review`). Powbox no longer bakes or seeds them (it used to seed them into `~/.claude/workflows/`; `agent-update-skills --prune` retires those seeded copies and their `.<name>.js.powbox-seeded` sidecar markers from older volumes). Codex has no workflow runtime, so there is no Codex sibling.

What stays powbox's to document is the worktree contract the workflows depend on. The runtime's built-in `agent(..., { isolation: "worktree" })` is deliberately **not** used: it creates a fresh temporary worktree per agent at a runtime-chosen path (default `.claude/worktrees/`, a tmpfs shadow here), started from the repository's default branch — so it can't honor powbox's `.worktrees/$CONTAINER_NAME/<slug>` convention (the per-container subdir on the project's `.worktrees` storage, which on a JS/powbox launch also carries the pnpm hardlink store, and which bounds what the `wt-*` helpers reap — see [Git Worktree Parallel Development](#git-worktree-parallel-development) for what that subdir does and does not isolate), and a separate default-branch worktree per agent would hide an implementer's commits from its reviewer. Instead `wf-address-tasks` has its agents create and reuse explicit convention worktrees through the same image-baked `wt-bootstrap`/`wt-enter`/`wt-remove` helpers the `address-tasks` skill uses — the workflow owns control flow (waves, round caps, gating) as deterministic JS, spawned agents own judgment, and the baked helpers own the git/worktree mechanics — while `wf-address-review` is a single-PR sequential pipeline, so every stage shares the one checkout on the PR branch. The workflows therefore require an image new enough to bake the `wt-*` helpers; their bootstrap stage detects an older image and reports a blocker instead of hand-rolling git.

Two read-only helpers on the image's `PATH` support workflow iteration without changing the harness: `wf-check <script.js>` validates the runtime's first-statement literal `meta` contract with matching pinned parser/walker packages and compiles the rest as a strict parameterless async body whose hooks are runtime globals (so top-level `await`/`return` and local hook-name bindings are accepted while syntax errors retain source line numbers), including the compiler pass that reserves `__wRg$` identifier names and rejects `await using`; `wf-status <runId-or-transcript-dir>` combines the run snapshot, `journal.jsonl`, and agent files into best-effort phase/agent/final-return status. The snapshot and journal are Claude-owned formats, so a killed run can legitimately show unknown labels or no final return; missing and truncated artifacts become warnings rather than making status inspection fail.

### Refreshing Skills

This covers the **bake + seed channel only** — today, the Codex palette. All Claude skills and the `wf-*` workflows are delivered by the `dev-skills@roubtec` plugin (see above), which the detached entrypoint bootstrap installs on a cold volume and refreshes at each later agent-container start (a warm refresh usually finishes within the entrypoint's short bounded wait and applies to the imminent session; a cold install or slow refresh lands next session start, or after `/reload-plugins`); `update-skills.*` neither seeds nor refreshes anything for Claude, and on a `claude-config` volume seeded before the custody changes it reports every previously-seeded Claude item — the 8 shared skills, `enable-worktrees`, `session-learnings`, and the `wf-*.js` workflows — as obsolete seeds that `--prune` removes (the orphan sweep runs even though the image no longer carries any baked Claude source dirs).

Because seeding is no-clobber, editing a skill in this repo and rebuilding the image is not enough — the volumes still hold the previously-seeded copy. `commands/update-skills.*` closes that gap by copying the freshly baked skills over the volume copies in a single throwaway container, replacing the old manual dance (enter a container, delete skills, exit, relaunch to re-seed).

It seeds from whatever is in `powbox-agent:latest`, so rebuild the image first (e.g. `cc <project> --build`, `agent-update`, or `build.sh agent`) so the baked skills reflect your edits. The config volumes are shared by every agent container, so this works whether or not any containers are running — a running agent picks up a refreshed skill the next time that skill is invoked (restart it for certainty).

The command prints a plan (how many skills it will seed and refresh), then applies it. Using the `.powbox-seeded` ownership marker it also handles two edge cases:

- **Conflicts** — an *unmarked* folder whose name collides with a baked skill is ambiguous (a legacy seed from before markers, or a skill you authored/forked). It is **never overwritten silently**; it is reported and left untouched. Resolve it with `--adopt-all` (take the baked version and start tracking it) — but only if it is a stale seed, not your own work; otherwise rename your folder first.
- **Obsolete seeds** — a *marked* skill that is no longer baked into the image is reported, and removed only with `--prune`.

With a terminal attached you are prompted before adopting or pruning; the flags pre-approve those non-interactively. Skills you authored (no marker) are never reported, adopted, or pruned.

```bash
# Preview the plan (seed / refresh / conflicts / obsolete) without changing anything
./commands/update-skills.sh --dry-run

# Refresh the baked skills onto both config volumes (prompts before adopt/prune on a TTY)
./commands/update-skills.sh

# Non-interactive: also drop obsolete seeds and take baked versions of conflicts
./commands/update-skills.sh --prune --adopt-all
```

On PowerShell the flags are `-DryRun`, `-Prune`, `-AdoptAll`:

```powershell
.\commands\update-skills.ps1 -DryRun
.\commands\update-skills.ps1
.\commands\update-skills.ps1 -Prune -AdoptAll
```

If you are using the profile shortcuts described below, the same script is exposed as `agent-update-skills` (flags forwarded). `agent-update` also offers to run it for you right after a successful image rebuild.

### Image provenance

Each image records the powbox commit it was built from, so you can tell whether a running image predates repo changes even when the agent binaries themselves are current. Because the build is layered, a piecemeal-updated image can carry up to **three** distinct commits: the base image has its own parent, and the Claude layer can be rebuilt without touching the Codex layer below it.

The commit that built each layer is recorded two ways:

- **Image labels** `powbox.commit.{base,codex,claude}` (plus `powbox.{codex,claude}.version`) for host-side `docker image inspect`. The host helper `agent-image-info` prints them alongside your working-tree HEAD, and `agent-update` shows the same block before asking to rebuild.
- **Baked files** `/home/node/.powbox/{base,codex,claude}.commit` for in-container reading. The `powbox-provenance` command prints them; an agent in the container can diff the building commit against the powbox repo (`git -C <powbox-repo> diff <claude-commit>..HEAD`).

The Codex commit is special: stamping it inside the Codex install layer would bust that layer's cache on every commit (defeating the Codex-below-Claude ordering), so the build script computes it — using `HEAD` when that layer rebuilds and carrying the previous value forward when it is reused — and records it only in the top metadata layer. A `-dirty` suffix marks an image built from an uncommitted worktree. No automated decision is made from these commits; they are introspection only.

## Runtime

Both agent launch flows resolve through the same shared Compose base and the same Compose project name.

The shared GitHub and zsh-history volumes are declared once in the shared Compose configuration.

Shared volume names are kept stable to preserve existing data:

- `agent-gh-config`
- `agent-zsh-history`

The launcher also creates **per-container** volumes, keyed by the full container name (agent + project) so a project's Claude and Codex containers each get their own copy (not shared):

- `agent-nm-<agent>-<project>` → the root `node_modules` (mounted for JS/powbox projects: `package.json`, `pnpm-workspace.yaml`, committed `.powbox.yml`, or `.powbox.local.yml` with a top-level `shadow:` key; a ctx-only local config does not trigger it)
- `agent-wt-<agent>-<project>` → the `.worktrees` tree, which **also holds the durable per-worktree git metadata** (`.worktrees/.gitworktrees`, bind-mounted over `.git/worktrees` so worktrees survive container recreation), the **per-container pnpm store** (`.worktrees/.pnpm-store`, JS/powbox gate only), **the Go caches** — shared `GOMODCACHE`/`GOCACHE` (`.worktrees/.gomodcache`, `.worktrees/.gocache`) plus per-worktree golangci-lint analysis caches (`.worktrees/.golangci-cache/…`) — **the shared NuGet global packages folder** (`.worktrees/.nuget`, `NUGET_PACKAGES`), and **the opt-in ccache compiler cache** (`.worktrees/.ccache`, `CCACHE_DIR`) so worktrees and expensive package/build caches survive container recreation. Mounted for the same JS/powbox gate, repos with root `go.mod`, and .NET repos with a solution/project file at the root or exactly one directory below it; matching is case-insensitive, dot-prefixed direct children count, and inaccessible, symlink, or reparse-point children are skipped. A Go- or .NET-only repo gets this volume without the `node_modules` one, so no empty `node_modules/` dir appears in the host folder. The bounded .NET predicate avoids a recursive repository scan. A layout whose only solution/project markers are deeper is not auto-detected: adding a root solution keeps the .NET-only volume shape, while opting in via `.powbox.yml` uses the broader JS/powbox gate and therefore also mounts `agent-nm-*`.

In [self-hosted mode](#self-hosted-mode---isolated) these two are replaced by a single per-**instance** `agent-ws-<container>` volume that holds the whole clone (the workspace, `node_modules`, `.worktrees`, and the stores/caches as subdirs); it is keyed per container, like the Podman storage volume below.

> The pnpm store moved from a single shared `agent-pnpm-store` volume to a per-container store inside a JS/powbox project's `agent-wt-<agent>-<project>` volume so that worktree `pnpm install` can **hardlink** package files from it instead of copying them (the store and the worktree `node_modules` must share one mount — see [Git Worktree Parallel Development](#git-worktree-parallel-development)). The old shared `agent-pnpm-store` volume is no longer mounted and can be removed with `prune-volumes`.

Agent-specific state volumes remain separate, and both are always mounted regardless of which agent is primary (required so the primary agent can invoke the other in-container — see [Cross-Agent Delegation](#cross-agent-delegation)):

- `claude-config` → `/home/node/.claude`
- `codex-config` → `/home/node/.codex`

`cc` and `cx` still produce distinct, separately-resumable containers per project — the launcher selects the primary agent via `PRIMARY_AGENT` and keeps the per-agent container-name prefix (`claude-` / `codex-`), so Claude and Codex sessions on the same repo never collide.

Both API keys are always passed through to the container — `OPENAI_API_KEY` for Codex and the optional `ANTHROPIC_API_KEY` for Claude — so that whichever agent is primary, a delegated peer invocation of the other agent can still authenticate.
Codex requires `OPENAI_API_KEY` set on the host before launching (interactively or headless); Claude optionally accepts `ANTHROPIC_API_KEY`. The key is not a *standby* credential waiting for the OAuth session to lapse: Claude Code checks `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` ahead of the stored login with no fall-through, so headless `claude -p` uses a key that merely carries a value — which is exactly why `peer-review-run` clears all three with `env -u` when it wants the subscription session. An interactive session additionally asks you to approve a detected key, so there it wins only once approved.
Claude's statusline resolves the account by asking `claude --safe-mode auth status --json` rather than reading a cached name. It shows the local part of the account address when one is available, otherwise names the credential source in play (`api key`, `env token`, `key helper`, `managed key`, or whatever else the CLI reports), and shows nothing when neither resolves — an opaque key maps to no identity without a network round trip. One caveat: the probe reports credential *precedence*, not the approval outcome described above, so a key you declined still reads as `api key` while the session actually runs on the login. It never names the wrong *account*, but the source label can overstate. The answer is cached per `session_id` (falling back to a stable key derived from which credentials are present, when a payload carries none) and refreshed at most once per ten minutes, so the ~0.5s probe does not run on every render. That behavior reaches an existing container only after you delete `~/.claude/statusline-command.sh`, which is seeded no-clobber.

Either agent can be started first in a clean Docker environment.

All shared volumes are marked `external` in the Compose files and pre-created by the launch scripts on first use.

### Shell

The default shell (`$SHELL`) is **bash**. The agent harnesses' Bash tools spawn `$SHELL` non-interactively, and the models' command prior is bash/POSIX — word-splitting on unquoted expansions, 0-indexed arrays — so running those one-shot calls under zsh just wasted turns on no-word-split and 1-indexed-array surprises. The agent path gains nothing from zsh's interactive features, so bash is the right default for it.

`zsh` is still installed and is what a human gets: it is the login shell and what `--shell` opens. The baked `~/.bashrc` and `~/.zshrc` only shape interactive sessions (history, completion, prompt) and share the `agent-zsh-history` volume; both shells inherit `PATH`, `EDITOR`, and the rest from the image environment, so changing the default shell does not change the toolchain.

### Cross-Agent Delegation

Because the unified image ships both agent binaries on `PATH` and the entrypoint seeds every agent's config at startup, the running primary agent can invoke the other agent directly inside the same container — no Docker-in-Docker, no mounted socket, no sibling container.

This is intended for delegated sub-tasks such as asking the other agent for an independent review, or handing it a self-contained piece of work.

**Credential policy for a delegated peer.** A logged-in subscription session is primary and an inherited env credential is the fallback — the reverse of the raw precedence described under [Runtime](#runtime), and powbox's own policy rather than Claude Code's behavior. `peer-review-run` is what enforces it: when a `.credentials.json` login exists it attempts that first, with `env -u` clearing all three env credentials, and retries once in key mode only if that attempt comes back `unavailable` (an expired session or a session limit) while an env credential is available. Other verdict-less outcomes — `forfeited`, `timeout`, an unclassified failure — do not switch modes, and with no login on disk it starts in key mode. **One deliberate exception:** a `settings.json` `apiKeyHelper` outranks the stored login and is not cleared by `env -u`, so a configured helper still wins over the "primary" subscription session. That is left as-is on purpose. The `env -u` clearing exists to stop a *stray or stale* inherited credential from stranding an otherwise-working login as `unavailable`; a helper someone configured deliberately is not that, and honoring it is the reasonable reading of the user's intent. `docker/shared/peer-review-run` and [docs/architecture.md](docs/architecture.md) cite this paragraph as the policy's home.

The peer runs against its own seeded config (login, skills, instruction file) and shares the same `/workspace` tree — the host bind mount in dir-mounted mode, the per-instance workspace volume under [`--isolated`](#self-hosted-mode---isolated) — so it sees the same files.
The in-container instruction file (`CLAUDE.md` for Claude, `AGENTS.md` for Codex) renders a "Delegating to another agent" section listing each peer's executable and autonomy flag (e.g. `claude --dangerously-skip-permissions`, `codex --dangerously-bypass-approvals-and-sandbox`), its non-interactive one-shot form, and the best-effort semantics for delegated opinions (missing binary / failed login / exhausted usage = no opinion, not an error).

For the specific case of a **delegated peer review**, the baked `peer-review-run` helper (on `PATH`) wraps that invocation in one bidirectional, provider-neutral command: `peer-review-run --provider <claude|codex> --worktree <ABS_DIR> --prompt-file <FILE> --artifact-root <ABS_DIR> [--base <REF>] [--timeout <SECONDS>] [--model <ID>] [--effort <LEVEL>]` runs the opposite agent read-only against a worktree with a literal (stdin-fed) prompt, supervises its process group under a timeout, retries a transient failure once, and prints one versioned JSON result (`schema powbox.peer-review-run/v1`) whose `outcome` is `passed | issues | unavailable | timeout | forfeited | failed`. Review strength is pinned per invocation rather than inherited — `--effort` defaults to `high` for both providers and `--model` to `opus` for claude — because the shared Claude/Codex config volumes are rewritten by every container's `/model`, so an unpinned peer reviewed at whatever tier someone last selected elsewhere. The result echoes the `model` and `effort` actually used, so a caller can verify the pin instead of assuming it. It owns the artifact/prompt/cleanup mechanics peer loops used to hand-write; a peer result supplements but does not replace a fresh reviewer, and no peer opinion is required for publication. Details and the `agent-skills` adoption boundary: [docs/architecture.md](docs/architecture.md) → "Rules the file map does not state".

**Configured Codex model, preserved.** Codex has no rolling alias to default to, and the adapter's own `--ignore-user-config` — which is what stops the reviewed worktree steering its own reviewer — also discards the top-level `model` your `/model` selection wrote into `$CODEX_HOME/config.toml`. So when you pass no `--model`, the helper reads just that root `model` back and re-applies it as `-m`, and nothing else from that file crosses. It refuses to do even that when a root `profile` or a root `model_provider` is set: the bare name is then meaningless without the configuration the helper deliberately does not forward, so the run degrades to the CLI default with a warning and `model:null` rather than reviewing with something you did not pick. Any unreadable, unparseable or unusable config degrades the same honest way instead of failing the review — including a value the reader cannot hand back verbatim, such as one carrying a newline — while no config at all, or one with no root `model`, is simply the unconfigured case: no `-m`, `model:null`, and nothing on stderr. An explicit `--model` wins and skips the lookup entirely — and an explicit *empty* one (`--model ""`, the shape a caller produces by forwarding an unset variable) is a usage error rather than an omission, so it is rejected instead of quietly taking that lookup. `--effort` stays independent of all of this: a configured `model_reasoning_effort` never overrides the level you asked for.

**Relaying the peer's prose.** For a `passed` or `issues` outcome the result carries `reviewFile`, the absolute path of `<artifactDir>/review.txt` — the peer's complete final review message as plain text, identical for both providers. Read the review from there; do not open `provider.stdout`, construct Codex's final-message filename, or parse a provider-native JSON envelope. The provider-native artifacts stay in `artifactDir` unchanged for debugging and audit — `review.txt` is an additional consumption surface, not a replacement for them. Two consequences worth knowing: the helper now needs `python3` (baked into the image; it writes and verifies that file, and its absence exits 70 before any provider is launched), and a `passed` review whose `review.txt` cannot be created or verified is **discarded** — the helper exits 70 with no result rather than pointing you at prose it could not prove.

## Nested Containers (rootless Podman)

The image ships **rootless [Podman](https://podman.io/)** so an in-sandbox agent can build, run, and orchestrate its own containers — databases, Adminer, whole service stacks — for projects whose dev workflow depends on them. A `docker` shim and `podman compose` mean `docker` / `docker compose` commands and project scripts work unchanged.

This is deliberately **not** Docker-in-Docker or a mounted host socket — both of which would hand a runaway agent the keys to the host. Podman runs as the unprivileged `node` user through a user namespace, so the blast radius stays inside the container: no privileged daemon, no host socket. As a bonus, rootless Podman NATs nested containers' outbound traffic through this container's network namespace, so they **inherit the egress firewall** — nested containers reach the public internet but not your LAN or host, just like the agent.

- **Persistence:** a per-container `agent-podman-<agent>-<project>` volume backs Podman's storage at `/home/node/.local/share/containers`, so pulled images and `podman volume`s (e.g. a database's data) survive container restarts. It's keyed per outer container (agent + project), not just per project, so a project's Claude and Codex containers can run concurrently without two Podman instances sharing — and corrupting — one graphroot.
- **Shared image cache:** a single global `agent-podman-imagestore` volume (layered under every per-container graphroot via Podman's `additionalimagestores`) holds a small curated set of common dev images — `postgres`, `redis`, `mariadb`, `adminer` — so they resolve instantly without a per-container pull. Agent containers mount it **read-only**; it is populated by a dedicated, short-lived writer the launcher spawns on each launch (the only context that mounts it read-write), so a runaway agent in one project can't poison the cache every other project reads. Seeding is idempotent and quick once populated. Override the curated set with `POWBOX_IMAGE_STORE_IMAGES`; to force a refresh, remove the `agent-podman-imagestore` volume and relaunch.
- **Access pattern:** reach a nested service from the agent via its **published port on `localhost`**; container-to-container (e.g. within a compose stack) uses service names over netavark/aardvark-dns.
- **Container health checks:** Compose/`podman run` health checks are supported, but the sandbox has **no systemd**, so Podman never fires the *periodic* check on its own — a service's health status stays at `starting` until the check is run explicitly (`podman healthcheck run <container>`). Also, `podman-compose` shell-wraps exec-form checks (`["CMD", …]` → `/bin/sh -c …`), so a **distroless** service needs a shell-reachable check binary. See [docs/rootless-podman.md](docs/rootless-podman.md) "Compose health-check behavior" for the validated scope; the Podman smoke stage guards it.
- **Storage driver:** fuse-overlayfs when `/dev/fuse` is available, otherwise the slower `vfs` driver. The driver is **pinned per `agent-podman-*` volume on first init** (recorded on the volume) and honoured on every later launch — it is not re-chosen each start, so a store first initialised on `vfs` (or moved to a host without `/dev/fuse`) won't silently flip; switching needs a clean store (`podman system reset` or dropping the volume).
- **Devices:** rootless Podman needs two host devices — `/dev/fuse` (overlay storage driver) and `/dev/net/tun` (nested-container networking; without it default `podman run` can't bring up its network). Both are passed through under the single `POWBOX_PODMAN` gate: `auto` attaches each when the host exposes it, `on` forces both (Docker Desktop), `off` skips both.

If `auto` cannot see devices that the Docker daemon or VM can still expose, force the Podman device overlays from your PowerShell profile before sourcing the PowBox helpers:

```powershell
$env:POWBOX_PODMAN = 'on'
```

There is no reliable host-wide environment variable for `/dev/fuse`; the thorough check is to ask Docker to pass the device into a throwaway container and verify it is a character device:

```bash
docker run --rm --device /dev/fuse alpine sh -lc 'test -c /dev/fuse && echo yes || echo no'
```

The ceiling: GUI apps, phone emulators, and non-headless browsers are the signal to move that workload to a dedicated VM. See [docs/rootless-podman.md](docs/rootless-podman.md) for design notes and a validation procedure.

## Per-Project Workspace Paths

Each project is mounted at `/workspace/<project-slug>` inside the container instead of a shared `/workspace` path.
This gives every project a unique absolute path, which prevents tools that cache by path (Claude project memory, build caches, etc.) from colliding across projects.
The container's working directory is set to the project-specific path automatically.

## Host File Ownership (dir-mounted mode)

In dir-mounted mode the agent runs as the in-container `node` user (uid 1000) but edits the host tree in place. On **Windows/WSL and macOS** this just works — those bind mounts honour writes from any container uid regardless of the displayed owner. On a **native-Linux host** the bind mount keeps its host uid/gid, so if the repo is owned by someone other than uid 1000 the agent cannot write the working tree or `.git`, and every `git pull`/`commit`/`checkout` and file edit fails with `EACCES`.

PowBox heals this automatically at container start with a narrowly-scoped, sudo-allowlisted root helper (`docker/shared/fix-workspace-perms.sh`), gated on a write-probe **plus** a scan for nested `root`-owned (uid 0) files so it stays a no-op whenever `node` can already write the whole tree (every Windows/WSL/macOS launch, and uid-matched Linux hosts):

- **Root-owned tree** (a repo under `/root`, or powbox run as root) — the first launch `chown`s it to `node:node`; safe and one-time (root keeps host-side access, later launches skip the step).
- **Mixed ownership** (a `node`-owned root hiding nested `root`-owned files, e.g. after a host-side `sudo git pull`) — a nested-uid-0 scan catches what the write-probe misses and re-owns only those entries, so `git commit`/`add` self-heal without a manual `chown -R`.
- **Tree owned by another non-root host uid** — **not** chowned (that would strip a real host user of their own repo): the launch warns and leaves host state untouched. Resolve it by `chown`-ing the repo to uid 1000 on the host, or use [self-hosted mode](#self-hosted-mode---isolated) (`--isolated`), which clones into a private node-owned volume and never touches the host tree.
- **Host source is a system or home directory** (`/`, `/root`, `/home/<user>`, your `$HOME`, a bare `/etc`/`/usr`/`/var`/…) — **the startup ownership heal is skipped** (not chowned). A `cc`/`cx` accidentally launched from `~` bind-mounts your whole home tree as the "project"; chowning it to `node` would re-own `~/.ssh` and its parent and break `sshd`'s StrictModes chain, locking you out of the host. The mount still happens (so a deliberate launch there isn't blocked), but the ownership heal is skipped with a loud warning — node may be unable to write that tree, a recoverable inconvenience rather than a host lockout. A genuine project *nested* under such a directory (`/home/you/code/app`, `/opt/app`, `/var/www/html`) is unaffected and heals normally.

In every case the chown claims only `root`-owned entries and never descends into the nested `node_modules` / `.worktrees` volumes. The full probe-and-call decision (and the extracted `heal-workspace-perms.sh` unit that the dir-mount smoke stage exercises) is detailed in [docs/entrypoint-and-runtime.md](docs/entrypoint-and-runtime.md); the behavior is regression-guarded by the dir-mount stage of the smoke test (see [Host Validation](#host-validation)).

## Self-Hosted Mode (`--isolated`)

By default PowBox runs in **dir-mounted** mode: it bind-mounts your host working directory at `/workspace/<slug>` and the agent edits it in place, so you watch and co-edit live.
**Self-hosted** mode (`--isolated`) is an opt-in second mode in which the container **clones the repo into a private per-instance volume itself** instead of bind-mounting a host directory.

The point is to run **many containers for the same repo at once**, each on its own independent checkout — isolation stronger than git worktrees, with no host filesystem shared between containers. Because the host never sees the working tree, the deliverable is a **pushed branch / PR** via the container's `gh` auth (egress = push/PR).

| Aspect | Dir-mounted (default) | Self-hosted (`--isolated`) |
|---|---|---|
| Workspace source | Host bind mount at `/workspace/<slug>` | `git clone` into a per-instance volume |
| Identity discriminator | `SHA256(host path)` | `--name <label>`, else a timestamp |
| Many per repo at once | No (same path → same container) | Yes (each `--name`/timestamp is a new instance) |
| How work leaves | Host sees edits live | `git push` / open a PR from inside |
| node_modules / .worktrees | Separate shadow volumes | Plain subdirs of the one workspace volume |
| Session history | Per host path | Per instance (distinct cwd slug) |

### Usage

The repo is a **required** input in this mode (the container must know what to clone) — an `owner/repo` slug or a clone URL. Give it as the positional argument or with `--repo`; if you omit it while standing inside a git repo, the launcher infers it from `git remote get-url origin`.

Concrete recipe — self-hosted `--isolated` launch against the `main` branch of `Roubtec/agent-skills`, named `skills` (substitute repo/branch/name for your own; run either command as needed):

```bash
cc --isolated Roubtec/agent-skills --name skills --ref main
cx --isolated Roubtec/agent-skills --name skills --ref main
```

```bash
# Two named instances of the same repo, running concurrently on independent checkouts:
cc --isolated owner/repo --name feature-a
cc --isolated owner/repo --name feature-b

# Explicit --repo form (and an unnamed, ephemeral-by-nature instance):
cc --isolated --repo https://github.com/owner/repo.git

# Infer the repo from the origin of the repo you are standing in:
cd ~/code/myrepo && cc --isolated

# Start on a non-default branch; the agent then cuts its own task branch:
cc --isolated owner/repo --name hotfix --ref release/2.x

# Re-seed an existing named instance from a fresh clone (wipes its working tree):
cc --isolated owner/repo --name feature-a --reclone
```

Flags (`cc`/`cx`, the `commands/*-container.*` scripts, and `scripts/launch-agent.*`):

- `--isolated` / `-Isolated` — select self-hosted mode (default stays dir-mounted).
- `--repo <spec>` / `-Repo <spec>` — the repo to clone (`owner/repo` or a URL). The positional argument is re-interpreted as this in self-hosted mode; `--repo` is the explicit form and wins.
- `--name <label>` / `-Name <label>` — instance discriminator. **Named instances are deterministic and reusable**: the same `--name` re-attaches the same clone and the same Claude session history across launches (amortising the clone). **Unnamed instances get a fresh timestamp every launch** — a new clone and fresh history each time (inherently single-session).
- `--ref <ref>` / `-Ref <ref>` — branch, tag, **or commit SHA** to check out on first clone (default: the repo's default branch). Applied as a post-clone `git checkout`, so an unresolvable ref does not fail the clone — the container stays on the default branch and prints a warning to confirm where you landed. Only the **first** clone honours it; a reused/`--resume`d container keeps whatever is checked out (use `--reclone` to re-clone at a new ref, or just switch branches inside the container).
- `--reclone` / `-Reclone` (alias `--fresh` / `-Fresh`) — wipe the instance's working tree and re-seed from a fresh clone. On an existing stopped container this recreates it so the clone step re-runs; the `agent-ws-*` volume itself is kept and re-cloned into.

### How it works

- **One workspace volume.** A per-instance `agent-ws-<container>` volume is mounted at `/workspace/<slug>` and holds the clone plus `node_modules`, `.worktrees`, and the pnpm store, Go/NuGet caches, and ccache as ordinary subdirectories. The separate `agent-nm-*` / `agent-wt-*` shadow volumes are **not** created in this mode (there is no host filesystem underneath to shadow). Because the store, the worktrees, and the root `node_modules` now share **one** mount, `pnpm install` **hardlinks** everywhere — including the root `node_modules`, which falls back to copying in dir-mounted mode (separate mount → `link(2)` `EXDEV`).
- **Identity.** `PROJECT_NAME = <repo-slug>[-<name-slug>]-<instance-hash>` (`instance-hash = SHA256(label-or-timestamp)[:12]`, the same hash shape as the dir-mounted name). The `name-slug` is cosmetic legibility for `cc-list`; the hash — which folds in the **raw** `--name`, the repo, and the **agent** — owns identity, so names that slugify alike stay distinct and a `cc`/`cx` pair on the same repo + name gets distinct clones and session history (no peer agent can resume one clone's history against the other's tree). `--ref` is **excluded** from the hash (volatile — relaunching the same name with a new ref reuses the one container). Containers carry `powbox.instance-name` / `powbox.repo` / `powbox.ref` labels so `cc-list` can reconstruct the resume command. Full rationale: [docs/architecture.md](docs/architecture.md) → "Project Identity".
- **Shared auth, isolated workspace.** The config volumes (`claude-config`, `codex-config`, `agent-gh-config`, `agent-zsh-history`) stay globally shared — no re-auth per container, skills seeded once. Only the workspace and the per-container Podman storage are per-instance.
- **Worktrees still work.** The `.worktrees/<container>/<slug>` convention and the `wt-bootstrap`/`wt-enter`/`wt-remove` helpers work unchanged; they just root in the one workspace volume (which hardlinks better). `wt-bootstrap`'s root-safety check recognises self-hosted mode and verifies the workspace volume itself is container-local rather than expecting per-directory tmpfs shadows.

### Upgrading an existing install needs a base-image rebuild

The clone helper (`seed-workspace.sh`) and the entrypoint logic that runs it live in the **base** image layer (`docker/base/Dockerfile`), not the agent layer.

Rebuilding only the agent image — the common `cc --build` / `cx --build` path, and `agent-update` when just an agent binary changed — therefore layers a new agent on an **old base** that has no clone step, so `--isolated` would create the workspace volume but the entrypoint never clones into it (you land in an empty checkout).

This is detected automatically. The base image records a digest over its own powbox build inputs — the base Dockerfile plus every file it `COPY`s (`powbox.base.recipe.digest`; see `scripts/base-source-files.txt`). `agent-check-updates` recomputes that digest from the working tree and flags the base **stale** whenever a base-layer source file changed (adopting self-hosted mode, or any future base-layer change), exactly like a stale **upstream** base; `agent-update` then offers the full base + agent rebuild with no manual step. Editing only an agent-layer file does not trigger it, so ordinary agent updates are not forced into a needless full rebuild. A first-time build (`agent-update` on a machine with no images) already builds base + agent, so it is unaffected.

As a backstop, `--isolated` / `-Isolated` also refuses to launch against an image whose base lacks the self-hosted capability label (`powbox.base.selfhosted`, inherited from the base) — it fails fast with a rebuild instruction (`agent-full-rebuild` / `build.sh all`) instead of starting you in an empty workspace, so even a launch that bypasses `agent-update` fails loudly rather than silently.

### gh auth must be ready before the clone

The clone (and any private-repo access) depends on `gh` credentials, so the entrypoint establishes `gh auth` **before** cloning. There is deliberately **no clone/auth failsafe and no retry** — `gh auth` is a one-time manual setup that holds until the token expires. If `gh` is not authenticated when a self-hosted launch needs to clone, the container **announces it loudly** and drops to a plain `zsh` (rather than execing the agent into an empty workspace), stating the three remedies:

1. use normal (dir-mounted) mode instead, or
2. fix it once in that shell (`gh auth login`) and relaunch the same command, or
3. seed the shared `agent-gh-config` volume from an already-authenticated machine.

### Lifecycle and cleanup

Self-hosted containers are **not** auto-removed (`--rm`) by default — an ephemeral container removed before the agent pushes would lose work. They and their `agent-ws-*` / `agent-podman-*` volumes accumulate, especially unnamed/timestamped ones, so tear down with the prune tooling: `agent-prune-stopped` removes stopped agent containers, and `agent-prune-volumes` then drops orphaned `agent-ws-*` volumes whose container is gone (alongside the existing `agent-nm-*` / `agent-wt-*` / `agent-podman-*` pruning). `agent-prune` does both.

Self-hosted containers are flagged in `cc-list` / `cx-list` / `agent-list` with a trailing `[self-hosted name=<--name as entered> repo=<spec> ref=<ref>]` marker (they otherwise share the `claude-` / `codex-` name prefix with dir-mounted ones) — enough to read off the instance and reconstruct its resume command (`cc --isolated <repo> --name <name>`) without an inspect. The `cci <name>` / `cxi <name>` shortcuts do that lookup for named Claude/Codex instances and complain if the name matches more than one repo. The `name=` is the **raw** `--name` (from the `powbox.instance-name` label), so two names that slugify to the same container-name shape are still told apart; empty fields are omitted, and a pre-label container shows a bare `[self-hosted]`. They also carry a `powbox.self-hosted=true` label, so `docker ps --filter label=powbox.self-hosted=true` lists just them.

### Known limitations

- A local-only repo with no fetchable remote cannot be used in this mode — the container clones over the network via `gh`/HTTPS, so there must be something to clone. Use dir-mounted mode for purely-local trees.
- There is no host⇄container sync; egress is push/PR by design (syncing back to the host would defeat the isolation goal).

## Context Mounts

Pass `--ctx <path>` to mount host directories under `/ctx/<basename>` inside the container.
This is useful for giving the agent access to reference code, data sources, or other content as read-only by default; add `:rw` only when the agent should be allowed to modify that source.

```bash
./commands/claude-container.sh ~/projects/myapp --ctx ~/datasets/reference
./commands/claude-container.sh ~/projects/myapp --ctx ~/datasets/reference --ctx specs=~/docs/specs:rw
```

```powershell
.\commands\claude-container.ps1 C:\Code\myapp -Ctx C:\Data\reference,specs=C:\Docs\specs:rw
```

The first bash example makes the host folder available read-only at `/ctx/reference`.
Repeat `--ctx` in bash, or pass a native PowerShell string array with `-Ctx A,B`.
Each CLI value uses `[name=]path[:ro|:rw]`: the mode defaults to `ro`, and `name=` sets the `/ctx/<name>` target alias.
The CLI form overrides any configured context for that launch.
CLI relative paths resolve from the caller's current directory, not from the workspace root.
If a path contains `=`, prefix it with a separator such as `./fixtures=a`, `/data/run=1/refs`, or `C:\x=y`; a bare single segment like `fixtures=a` is interpreted as alias `fixtures` pointing at path `a`.

For persistent per-workspace context, add a `ctx:` list to `.powbox.local.yml` in the workspace root.
The file is user-local and should be ignored by git; the launcher warns if it exists in a git repo and `git check-ignore -q .powbox.local.yml` does not ignore it.

```yaml
# .powbox.local.yml
ctx:
  - ~/projects/reference-repo:rw
  - docs/specs
  - path: ../shared-style-guide
    name: style-guide
    mode: ro
```

Each entry mounts at `/ctx/<name>` where `name:` is the explicit alias or the source folder basename.
Short form accepts a trailing `:ro` or `:rw` mode suffix and defaults to `ro`; long form accepts `path:`, optional `name:`, and optional `mode:`.
Config paths may start with `~` and relative paths resolve from the workspace root; environment variables are left literal.
Missing configured paths warn and are skipped, and duplicate target names warn and skip later entries; use `name:` to disambiguate.

Committed `.powbox.yml` can also contain `ctx:` using the same schema.
Top-level sections merge by clobber: `.powbox.local.yml` replaces `.powbox.yml` for any section it defines, so local `ctx: []` is an explicit empty context set rather than an append.

### Context Changes on Resume

When reusing a stopped container (the default, or with `--persist`), the launcher compares a hash of the derived ctx mount set against the `powbox.ctx-hash` label recorded when the container was created.
If the desired set differs (including switching paths, aliases, modes, CLI/config source, or going to explicit `ctx: []`), the stopped container is removed and recreated with the updated mounts.
Persistent state in named volumes (agent config, GitHub CLI, pnpm store, etc.) is unaffected by this recreation.

Omitting `--ctx` and having no effective `ctx:` key is treated as "keep whatever is already mounted" — the container is reused as-is without recreation.
To explicitly clear a previously mounted context on a stopped container, use `ctx: []`; use `--volatile` when you want a fresh container regardless of labels.

Using the explicit `--resume` / `-Resume` flag always resumes the container exactly as originally created — any `--ctx` / `-Ctx` value or configured `ctx:` is ignored, and launcher migrations for frozen mounts or environment (including persistent `NUGET_PACKAGES` wiring) are skipped (warnings are printed).
To apply a ctx change, omit `--resume` and let the script auto-detect and recreate as needed.

## Workspace Shadow Mounts

When the host OS differs from the container OS (e.g. Windows host, Linux container), build output produced for one platform breaks on the other.
The root `node_modules` is already handled by a per-container Docker volume, but monorepo subpackages each have their own `node_modules` that would otherwise be shared through the bind mount.
.NET projects have the same problem for a different reason: MSBuild bakes **absolute** paths into `obj/`, so a container restore writes `/workspace/<slug>/.worktrees/.nuget/` into `obj/project.assets.json` while a host Visual Studio build writes `C:\Users\<user>\.nuget\packages\` — each silently clobbering the other's restore graph.

At container start, the entrypoint auto-detects these directories and mounts tmpfs over each one.
This shadows the host content inside the container so that `pnpm install` (or `dotnet build`) writes Linux-native output into an ephemeral filesystem that never touches the host.

### Auto-Detection

The entrypoint scans for project declarations in this order:

1. **pnpm** — reads `pnpm-workspace.yaml` `packages` globs → each package's `node_modules`
2. **npm / yarn** — reads `package.json` `workspaces` array (or `workspaces.packages`) → each package's `node_modules`
3. **.NET** — finds `*.csproj` / `*.fsproj` / `*.vbproj` (case-insensitively, so a Windows-authored `Legacy.CSPROJ` counts) → each project's `bin` and `obj`
4. **`.powbox.yml` / `.powbox.local.yml` with `shadow:`** — reads custom `shadow` glob patterns (see below)

All matched directories get a tmpfs overlay.
If none of these declarations exist, the feature is a no-op.

The .NET scan prunes `node_modules`, `.git`, `.worktrees`, `.claude`, and `bin`/`obj` themselves, so it stays cheap (~0.16s on a 1700-directory monorepo) and skips both worktree roots (`.worktrees` and `.claude/worktrees`) — those live in container-local mounts with no host counterpart to collide with.
Unlike the workspace globs, `bin`/`obj` are emitted as **literal** paths, so they are created and shadowed even on a fresh clone where no build has run yet; the cost is an empty `bin`/`obj` mountpoint dir appearing for a project that has never been built (or one that redirects output via `ArtifactsPath`), which every standard .NET template already gitignores.
An existing `bin`/`obj` that is a **symlink** is skipped rather than followed — this scan is derived from repo content rather than declared by you, so resolving `app/bin -> ../src` would let the tree itself decide to mask real source for the whole session. Declare such a path in `.powbox.yml` if you genuinely want its target shadowed.
For the same reason an existing `bin`/`obj` holding **Git-tracked** files is left alone: a project that redirects its output (`ArtifactsPath`, `OutputPath`) can legitimately keep tracked scripts or fixtures there, and masking them would make them read as deleted for the session while any edit landed in a tmpfs that dies with the container. Real build output is gitignored by every standard .NET template, so only genuinely disposable directories are shadowed. A `bin`/`obj` that belongs to a repository nested inside the workspace — a submodule, or a nested clone, whether it sits at the `bin` itself or above it — is judged by that repository rather than by the outer one. If the workspace is a Git repo whose index cannot be read, existing `bin`/`obj` are left alone rather than masked on a guess; a folder that is not a repo at all shadows as usual. (Declare the path in `.powbox.yml` if you want it shadowed anyway.)
A .NET project added mid-session is picked up by re-running `shadow-refresh.sh` in dir-mounted mode (there is no `dotnet` wrapper equivalent to the `pnpm` one below), so run it before your first build of a new project.

### Mid-Session Packages

Auto-detection runs once, at container start, so it only shadows the subpackages that exist then.
A package scaffolded *during* a session (create `packages/foo`, write its `package.json`, then `pnpm install`) is not shadowed yet, so its `node_modules` would be created and populated straight onto the host bind mount — re-introducing the exact Linux/host binary and ownership mix this feature exists to prevent, and breaking the host's own `pnpm install` with `EACCES`.

To close that race, `pnpm` (and its `pn` short alias) is a thin wrapper baked into the image: before any node_modules-writing subcommand (`install`, `add`, `update`, …) it re-runs detection so a freshly added package's `node_modules` is tmpfs-shadowed *before* pnpm writes into it, then delegates to the real pnpm.
Detection is idempotent, so already-shadowed paths are skipped and the steady-state cost is one cheap scan; the wrapper always execs the real pnpm, so neither a shadow failure (e.g. no mount capability) nor a deliberate skip ever blocks the command — self-hosted mode is the latter: there is no host filesystem to shadow, so the wrapper returns before refreshing and `shadow-refresh.sh` itself exits 0 without mounting.
You can still run `shadow-refresh.sh` by hand at any time — it mirrors the entrypoint's own skip conditions, exiting 0 without mounting when `POWBOX_SELF_HOSTED=1` (`--isolated`) or `POWBOX_IMAGE_STORE_ROLE=writer`, so it is always safe to run. That safety rests on those explicit guards: the container holds `CAP_SYS_ADMIN` in both modes and nothing downstream re-checks emptiness, so an unguarded hand-run would successfully tmpfs over a populated directory rather than fail ([docs/entrypoint-and-runtime.md](docs/entrypoint-and-runtime.md)).

One case the wrapper cannot fully fix is scaffolding a JS project mid-session in a folder that was launched as **non-dev** (no `package.json`, `pnpm-workspace.yaml`, committed `.powbox.yml`, or `.powbox.local.yml` with a top-level `shadow:` key at launch, so the launcher mounted no isolated root `node_modules` volume for it; a local config with only `ctx:` still counts as non-dev). The wrapper can re-shadow a new subpackage but cannot retrofit the missing **root** mount, so a root `pnpm install` there would still land `node_modules` on the host bind mount. Rather than do this silently, the wrapper prints one loud warning and proceeds — relaunch the agent (the folder now has a `package.json`, so the next launch mounts an isolated volume).

### Custom Shadow Paths (`.powbox.yml` / `.powbox.local.yml`)

For paths that auto-detection does not cover, add a `.powbox.yml` to the project root:

```yaml
shadow:
  - packages/*/node_modules       # same as what auto-detect would find
  - tools/legacy-build/vendor     # non-standard path
```

Use `.powbox.local.yml` for machine-local experiments or overrides that should not be committed.
If `.powbox.local.yml` has a top-level `shadow:` key, its list replaces the committed `.powbox.yml` shadow list wholesale; `shadow: []` locally disables committed custom shadows while leaving auto-detection active — from `pnpm-workspace.yaml` and `package.json`, and from `*.csproj`/`*.fsproj`/`*.vbproj` (matched case-insensitively) for the .NET `bin`/`obj` scan.

Patterns are resolved relative to the project root.
A pattern containing glob metacharacters (`*`, `?`, `[`, `]`) is expanded as a glob, and only directories that exist at container start are shadowed.
A literal path (no glob metacharacters) is shadowed even if it does not exist yet — it is created and tmpfs-mounted at startup. This lets committed declarations for gitignored, fresh-checkout-absent directories take effect without a manual `mkdir`.
In both cases a pattern that resolves outside the workspace root is rejected.

Auto-detection and the effective custom shadow list are merged and deduplicated.

### Git Worktree Parallel Development

Shadowed literal paths make the container a clean home for git-worktree-based parallel development — for example an orchestrator that creates one worktree per task under `.worktrees/`. Declare the worktree scaffolding in `.powbox.yml`:

```yaml
shadow:
  - .worktrees          # worktree working trees
  - .claude/worktrees   # harness-native worktrees (EnterWorktree / agent isolation)
  - .git/worktrees      # per-worktree git metadata
```

These directories are gitignored and absent on a fresh checkout. `.claude/worktrees` and `.git/worktrees` are literal shadow paths, so they are auto-created and container-localized at startup — no manual `mkdir` or `shadow-refresh.sh` needed. (Literal paths under `.git/` are only auto-created when `.git` is a real directory — the normal main checkout. If the container's workspace is itself a *linked* worktree, where `.git` is a file pointing into the main repo, the `.git/worktrees` entry is skipped with a diagnostic instead of creating a bogus `.git/` tree.)

**`.worktrees` is a volume, not tmpfs — and its git metadata rides along.** The launcher mounts the per-container `agent-wt-<agent>-<project>` ext4 volume at `.worktrees` (it also holds the pnpm store at `.worktrees/.pnpm-store`), so worktree `pnpm install` **hardlinks** from the store instead of copying — installs drop from a full ~425 MB–1.1 GB copy to tens of MB, with no shared 2 GB cap, and many worktrees install concurrently. The `.worktrees` line in `.powbox.yml` is then a harmless fallback (tmpfs only if launched without the volume). `.git/worktrees` is **bind-mounted from `.worktrees/.gitworktrees` inside that same volume**, so per-worktree git administrative metadata shares the working trees' durability: a linked worktree — including its uncommitted changes — survives a container stop/recreate, and `git status` still works after recycle, instead of the working dir surviving while its metadata (formerly tmpfs) was discarded. The bind stays container-local: it hides the host's own `.git/worktrees` and keeps container registrations off the host. Only `.claude/worktrees` (harness-native working trees) stays a tmpfs shadow under the `SHADOW_TMPFS_SIZE` cap (see [Configuration](#configuration)). Without the volume (the fallback launch) `.git/worktrees` falls back to tmpfs too.

**Discipline.** Commit and push often. Uncommitted changes in a worktree now survive a container recycle (its metadata is durable), but only the common `.git` syncs to the **host** — so push committed work to the remote and `git pull` on the host to make it visible there.

**Rewriting history.** Never force-push with raw `git push --force`/`-f`; use `git push --force-with-lease` (ideally the exact `--force-with-lease=<branch>:<sha>`) so a concurrent push to the old tip isn't silently clobbered. The entrypoint additionally sets `push.useForceIfIncludes=true` in the container-local git config (never the host's `.gitconfig-host`), which requires the remote tip being overwritten to have actually been integrated locally first — closing a gap where a background fetch in this shared clone silently advances a remote-tracking ref and defeats a bare lease. It hardens `--force-with-lease` only and does nothing for raw `--force`, so the no-raw-force rule above is what carries the protection; keeping one writer per PR branch remains the strongest safeguard. See [AGENTS.md](AGENTS.md) "Git History Rewrites" for the full convention.

**Shared-checkout boundaries.** The per-`$CONTAINER_NAME` subdir scopes the *worktrees*, not the main working tree: two agent harnesses invoked inside one container (e.g. Claude delegating to its in-container Codex peer) share that container's `.worktrees` volume **and** the repository's main checkout. Two *separate* agent containers instead get separate per-container `.worktrees` volumes, and [`--isolated`](#self-hosted-mode---isolated) gives each instance a full private clone when a stronger boundary is wanted. Because the main checkout is shared, a broad recovery command run there — `git reset --hard`, or especially `git clean -fdx`, which ignores `.gitignore` and so would also wipe another in-container worker's `.worktrees` scaffolding along with any uncommitted main-checkout files — can discard a concurrent peer's work. Such commands are not prohibited; the safe habit is to scope cleanup to your own worktree (`git -C <your-worktree> …`), commit meaningful checkpoints, and, if you must reset or clean the shared main checkout, pause or finish sibling work first. The `wf-address-tasks` workflow adds a non-destructive backstop: it snapshots the main checkout's `git status --porcelain` at its start and end and reports any dirt without ever modifying it.

The mechanical lifecycle is handled by image-baked helpers on `PATH` — `wt-bootstrap`, `wt-enter`, `wt-remove` (plus `gitcat` for cross-branch reads, `gh-review-threads` for a concurrency-safe, PR-scope-checked review-thread fetch, and `dc-enter`/`dc-remove` for a **disposable clone** — the safe-to-wreck place to verify a claim empirically, which a worktree cannot be because it shares `.git`) — which the worktree skills and workflows call rather than re-deriving git plumbing. Orphan reaping never deletes work: a dir that is no longer a live worktree is removed only when empty, and otherwise preserved under `.worktrees/.orphaned/`. The measured copy→hardlink rationale, the durable-metadata/orphan-handling model, and tmpfs sizing are detailed in [docs/worktree-node-modules-hardlinks.md](docs/worktree-node-modules-hardlinks.md).

`wt-remove` removes a worktree but never work, and that guarantee holds **with `--force` too** — the inversion of vanilla `git worktree remove --force`. It refuses whenever git has left an operation *it itself tracks* in progress in that worktree (a rebase on either backend, a `git am`, a merge, a cherry-pick, a revert, a multi-commit cherry-pick/revert sequence, a bisect, or a conflicted `git notes merge`), refuses on uncommitted changes, and refuses when the worktree's own git metadata cannot be located or read, or when `git status` itself fails, so its state cannot be established — an unknown state is treated as unsafe to delete, and a status command that fails is not evidence of a clean tree merely because it printed nothing. `git status` is clean for several of those operations (a bisect, an `am`, a rebase paused at a `break`, a sequence stopped on an empty patch, any conflict resolved back to HEAD's content) and reports nothing whatsoever for a notes merge, whose conflict lives entirely in the worktree's administrative git dir, so they are detected from the same per-worktree state git itself consults rather than from the porcelain, and they are checked *before* the uncommitted-changes case so that a worktree stopped on an open conflict is told which operation it is in rather than just that it is dirty. "The same state git consults" means both of the places git keeps it: the on-disk state files, *and* the ref backend, because `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `NOTES_MERGE_PARTIAL` and `NOTES_MERGE_REF` are pseudo-refs and leave no file at all under the `reftable` ref storage — a file-only probe fails open there, and did (measured: a conflicted `git notes merge` in a `reftable` worktree was removed). The ref lookup is itself two questions, because one of those markers is a *symbolic* ref: `NOTES_MERGE_REF` points at the notes ref being merged, and `show-ref --verify` answers what a name resolves to rather than whether it exists, so a notes ref deleted while the merge is unconcluded reads as "absent" — with no marker file to fall back on under `reftable`, that fell open too (measured), and `git symbolic-ref` is asked alongside it. Neither lookup DWIMs the way `rev-parse` would, so a repository that merely holds a *branch* named after one of these markers is not refused for it; and a lookup that fails outright — a ref storage git cannot read at all, *or* a marker name that is there while the object it points at is not (a pseudo-ref outliving a `git gc --prune=now` makes `show-ref` exit 128 in an otherwise perfectly readable repository) — is refused under its own name, as an unknown state, rather than reaching the uncommitted-changes case and being reported as dirt. Both the state and the porcelain are read through the worktree's own git dir, resolved from the repository's registrations — never as `git -C <worktree>`, which resolves upward into the enclosing checkout for a worktree that has lost its `.git` pointer and would then report on a different tree entirely. A refusal names which operation is in flight, and the state marker it was found by, and points at inspection only — `git -C <path> status`, plus `git -C <path> bisect log` when a bisect is what was found — never at `--abort`, `bisect reset`, `git notes merge --commit/--abort` or anything else that would discard or conclude it; vanilla `git worktree remove --force` remains the honest way to ask for a mid-operation worktree to be thrown away. `--force` is still passed through to git once those checks pass, for e.g. ignored build artifacts. The guard set and its git-source justification are pinned case by case, against real git, in `scripts/test-wt-orphan-safety.sh`.

"What git tracks" is the exact limit of that promise, and one shape falls outside it: an unconcluded `git merge --squash`, which git does not record as an operation at all — there is no `MERGE_HEAD`, and `git merge --abort` answers "There is no merge to abort". Guarding its `SQUASH_MSG` marker was measured and rejected, because the marker *outlives* the operation: `git restore --staged --worktree .` abandons a squash merge without clearing `SQUASH_MSG`, leaving it beside a fully clean tree that git treats as idle — a fresh `git merge` from there starts and succeeds — so guarding it would refuse worktrees holding nothing in flight, which is the failure mode the whole exclusion list exists to prevent. In practice a squash's staged result makes the porcelain non-empty and the uncommitted-changes refusal holds it; only a squash whose result equals HEAD's own content slips through with a clean status, and what is lost there is its pending commit message, not work. Both directions — the false refusal avoided and the one shape knowingly removed — are pinned in `scripts/test-wt-orphan-safety.sh`, so changing the trade-off means changing a test.

### Mid-Session Refresh

If you add a new workspace package after the container has started, its `node_modules` will not be shadowed until you run:

```bash
shadow-refresh.sh
```

This re-runs detection and mounts tmpfs over any new directories that were not previously shadowed.
Already-mounted paths are skipped.
It has an effect only where startup would have shadowed: in the two modes that decline to shadow — `--isolated`, and the dir-mounted image-store **writer** container — it skips itself and exits 0 without mounting, so running it there is a harmless no-op ([Mid-Session Packages](#mid-session-packages)).

### Lifecycle

Subpackage shadow mounts are **ephemeral** — they use tmpfs (memory-backed) and are lost when the container stops.
After restarting (or resuming) a container, run `pnpm install` to repopulate subpackage `node_modules` from the per-container pnpm store.
With a warm store this typically takes only a few seconds.

The root `node_modules` (`agent-nm-<agent>-<project>`) and the `.worktrees` tree with its pnpm store (`agent-wt-<agent>-<project>`) are **Docker volumes**, not tmpfs — they persist across restarts, so the store stays warm and worktree installs stay cheap.

A shadow whose target does not exist yet (a `.powbox.yml` literal, or any `bin`/`obj` on a never-built .NET project) needs a **mountpoint directory** underneath the tmpfs, and only that directory outlives the container.
`shadow-mounts.sh` runs as root, so it hands each directory it creates the uid/gid of the nearest existing ancestor — the host owner of the checkout on a bind mount.
Without that, a native-Linux host would be left with empty root-owned `bin`/`obj` directories it could neither populate nor delete after the container stopped, breaking the next host-side `dotnet build`.

Because those subpackage shadows come back **empty** after a restart while the persistent root `node_modules` still carries pnpm's workspace-state cache (`.pnpm-workspace-state-v1.json`), pnpm would otherwise report "Already up to date" and skip relinking them — leaving `vitest`/`tsc`/`eslint` and other per-package `.bin` entries unresolvable until a manual fix. To avoid this **empty-shadow trap**, the entrypoint drops that cache file at container start, so the first `pnpm install` after a restart does a real, relinking install and self-heals automatically. If subpackage binaries are ever still missing — a `pnpm install` reports "Already up to date" yet the per-package `.bin` entries don't resolve, e.g. because something repopulated the cache mid-session — run `pnpm-shadow-doctor` to detect the trap and `pnpm-shadow-doctor --fix` to repair it (it removes the stale cache file and reinstalls to relink the shadows).

### Configuration

Each tmpfs mount is capped at **2 GB** by default.
Because tmpfs allocates lazily, this ceiling bounds the worst case and does not reserve memory up front — an empty or lightly used mount costs almost nothing.
Override the per-mount limit by exporting `SHADOW_TMPFS_SIZE` (any value accepted by `mount -o size=`, e.g. `4g`, `512m`) before launching the container.
Both `shadow-mounts.sh` invocations (`entrypoint-core.sh` and `shadow-refresh.sh`) pass `--preserve-env=SHADOW_TMPFS_SIZE` to sudo so the override is honoured.
If a mount fills up, `pnpm install` will fail with a clear `ENOSPC` error — raise the limit and re-run.

### Security

`shadow-mounts.sh` is a root-owned, immutable script invoked via scoped sudo.
It refuses to mount outside `/workspace/`.
tmpfs mounts are container-namespace-scoped and invisible to the host — not an escape vector.

The container requires **`CAP_SYS_ADMIN`** (granted in `compose.shared.yml`) because Docker's default seccomp profile blocks the `mount` syscall without it.
Note that `CAP_SYS_ADMIN` is granted to the container as a whole by Docker — sudoers restricts which commands may be run via `sudo`, but does not scope a Linux capability to a single script.
The `node` user cannot invoke arbitrary commands as root (sudo is scoped), but any process in the container holds `CAP_SYS_ADMIN` for its lifetime.
`shadow-refresh.sh` requires this capability mid-session, so it cannot be dropped after startup.

## Commands

The user-facing command surface lives at the repo root and in `commands/`:

- `build.sh` and `build.ps1` at the repo root for image builds
- `commands/claude-container.*` and `commands/codex-container.*` for launches
- `commands/smoke-test.*` for smoke-testing the unified agent image
- `commands/prune-volumes.*` for orphaned `agent-nm-*` / `agent-wt-*` / `agent-ws-*` / `agent-podman-*` cleanup
- `commands/reset-claude-history.*` for wiping Claude session history from the shared `claude-config` volume
- `commands/update-skills.*` for re-seeding the image-baked skills onto the `claude-config` / `codex-config` volumes, with `--prune`/`--adopt-all` to drop obsolete seeds and resolve unmarked name-collisions (its in-container worker is `docker/shared/update-skills-incontainer.sh`; the shared copy logic and `.powbox-seeded` marker live in `docker/shared/seed-skills.sh`, also used by the entrypoint hooks)
- `commands/check-updates.*` for checking whether newer agent releases are available

## Resuming Sessions

Session resumption is opt-in via `--continue` / `-Continue` on `cc` and `cx` (and on the underlying `commands/*-container.*` scripts).
Without the flag, both agents start a fresh session — useful because resumed sessions inherit the prior run's inference-duration stats and other counters that `/clear` does not reset.
Pass the flag when you want to pick up an interrupted session (for example after a forced reboot or crash).

The flag decision is baked into the container's CMD at creation time.
When the requested flag value differs from what the stopped container was created with, the launcher recreates the container — the same recycling mechanism used for `--ctx` / `-Ctx` changes.
Persistent state in named volumes (agent config, GitHub CLI, pnpm store, etc.) is unaffected by this recreation.
If the container is already running with a different flag value, the launcher attaches to the existing process and warns that the flag is ignored; stop and relaunch to apply the change.

Per-agent behavior when `--continue` is set:

- **Claude** — the launcher checks `~/.claude/projects/<slug>/` inside the container and passes `--continue` when history is present; when no history exists it falls back to a plain `claude` launch (bare `claude --continue` would otherwise exit with "No conversation found").
- **Codex** — the launcher passes `resume --last`. Codex filters that to the current working directory and falls through to a fresh interactive session when no resumable session exists there.

The `codex exec ...` path (`--exec` / `-Exec`) stays non-resuming regardless of `--continue`, so one-shot tasks do not unexpectedly attach to prior interactive history.
`--shell` / `-Shell` likewise ignores `--continue` — the container opens a plain zsh.

Use `/clear` inside Claude to discard the resumed context without touching other projects, or run the reset script below for a full wipe across all projects.

Using the explicit `--resume` / `-Resume` flag always restarts the container exactly as originally created — any `--continue` value passed alongside is ignored (a warning is printed), same as `--ctx`.

### Wiping Session History

`commands/reset-claude-history.*` prunes per-project conversation history, todo state, and shell snapshots from the shared `claude-config` volume.
Credentials (`.credentials.json`) and user settings (`settings.json`) are preserved, so no re-auth is required after a reset.

The script refuses to run if any container currently has the `claude-config` volume mounted — stop running Claude containers first (`agent-list` / `cc-list` help identify them).

```bash
# Preview what would be deleted
./commands/reset-claude-history.sh --dry-run

# Prune with a confirmation prompt
./commands/reset-claude-history.sh

# Prune without prompting (for scripted use)
./commands/reset-claude-history.sh --force
```

On PowerShell, use `-WhatIf` for a preview and `-Force` to skip the confirmation prompt:

```powershell
.\commands\reset-claude-history.ps1 -WhatIf
.\commands\reset-claude-history.ps1
.\commands\reset-claude-history.ps1 -Force
```

If you are using the profile shortcuts described below, the same script is exposed as `agent-reset-claude-history` — all flags (`--dry-run`/`--force` on bash, `-WhatIf`/`-Force` in PowerShell) are forwarded.

## Profile Shortcuts

The repo ships a pair of shell libraries — `shell/powbox.sh` (bash/zsh) and `shell/powbox.ps1` (PowerShell) — that define all the short commands (`cc`, `cx`, `agent-prune`, `agent-list`, etc.). Dot-source or `source` the appropriate file from your shell profile and pull updates with `git pull`; there is nothing to copy-paste per release.

Functions exposed by both libraries:

- `cc`, `cx` — launch Claude or Codex in the current directory (or a given path), forwarding every flag to the underlying `commands/*-container.*` script. Add `--isolated`/`-Isolated` (with a repo positional or `--repo`/`-Repo`) for [self-hosted mode](#self-hosted-mode---isolated); the positional is then a repo spec, not a path, so the cd-after-launch is suppressed
- `cci`, `cxi` — resume a named self-hosted Claude or Codex instance by `--name`/`-Name` alone, using the stored repo label to reconstruct the isolated launch; if the name is ambiguous across repos, they list the matches and stop
- `cc-list`, `cx-list`, `agent-list` — list agent containers (self-hosted ones get a trailing `[self-hosted name=… repo=… ref=…]` marker so you can resume an instance by its `--name` without an inspect)
- `agent-volumes` — list agent-related Docker volumes
- `agent-prune-stopped`, `agent-prune-volumes`, `agent-prune` — cleanup helpers
- `agent-check-updates` — compare baked agent versions against the latest npm releases, and the base image's recorded source digest against the current `node:24-trixie-slim` registry digest
- `agent-update` — show the full update report, then (only when something is stale) prompt for confirmation before rebuilding. A stale base triggers a full `build.sh all --pull --no-cache` (base + the agent image on top); otherwise the unified image is rebuilt once with each binary's version pinned, so only the stale agent's layer (plus the cheap layers above it) rebuilds while the unchanged binary's layer is reused from cache — no `--no-cache`. On confirmation it re-checks, so an update you approve in another terminal while the prompt waits is still picked up. A missing or unlabeled image counts as stale, so this also bootstraps a machine that has no images yet. After a successful rebuild it offers (on a TTY) to re-seed skills from the fresh image via `agent-update-skills`.
- `agent-update --refresh` (PowerShell: `-Refresh`) — rebuild even when nothing is stale: the full stack (base + agent) is rebuilt from the current repo state, cached and without `--pull`, with every current binary pinned to its baked version — the way to pick up powbox recipe changes (a changed Dockerfile layer busts its own cache by content, so no `--no-cache` is needed; unchanged layers are reused). When updates *are* pending, `--refresh` takes them too and widens the rebuild to the full stack.
- `agent-full-rebuild` — the nuclear option: re-pull the upstream base image and rebuild everything from scratch with the latest package and agent versions (`build.sh all --pull --no-cache`), for when the images are in an unknown state and you want a clean slate. For plain recipe changes `agent-update --refresh` is much faster. (To rebuild with one agent held at a specific version, call the build script directly: `build.sh agent --claude-version <v> --codex-version <v>`.)
- `agent-reset-claude-history` — wipe per-project Claude session history from the shared `claude-config` volume (credentials and settings preserved); forwards flags like `--dry-run`/`--force` (bash) or `-WhatIf`/`-Force` (PowerShell)
- `agent-update-skills` — re-seed the image-baked skills onto the `claude-config` / `codex-config` volumes, overriding the startup no-clobber so a rebuilt image's updated skill text replaces the stale volume copies. Skills are tracked by a `.powbox-seeded` ownership marker, so it refreshes only powbox's own copies and leaves user-authored skills alone. Flags: `--dry-run`/`-DryRun` (preview the plan), `--prune`/`-Prune` (remove obsolete seeds no longer baked), `--adopt-all`/`-AdoptAll` (take the baked version of unmarked name-collisions); on a TTY it prompts before pruning/adopting. Rebuild the image first so the baked skills are current.
- `agent-image-info` — print the powbox commit that built each layer of `powbox-agent:latest` (base / codex / claude/top) from the image's `powbox.commit.*` labels, plus your working-tree HEAD, so a stale image is obvious even when the agent binaries are current. In-container, the baked `powbox-provenance` command prints the same from `/home/node/.powbox/*.commit`. See [Image provenance](#image-provenance).

### Environment Variables

Both libraries honour the same variables:

| Variable | Default | Effect |
|---|---|---|
| `POWBOX_ROOT` | auto-detected from the script's location | Path to your PowBox checkout. Only needed if auto-detection fails. |
| `POWBOX_CD_AFTER_LAUNCH` | `1` | When `cc`/`cx` is called with an explicit project path, cd into that path after the container exits. Set to `0` (or `false`/`no`/`off`) to stay in the original directory. |
| `POWBOX_PODMAN` | `auto` | Whether to pass the host devices rootless Podman needs into the agent: `/dev/fuse` (fuse-overlayfs `overlay` storage driver; absence falls back to the slower `vfs`) and `/dev/net/tun` (nested-container networking; absence breaks default `podman run`). `auto` attaches each device when the launcher's host shell can see it; `on` forces both (use when the Docker daemon/VM has them but the host shell doesn't, e.g. Docker Desktop); `off` skips both. (`POWBOX_FUSE` is a deprecated alias for this variable.) |

Export/assign these before sourcing the library — or before calling `cc`/`cx` — to change behavior without editing the script.

### PowerShell

Add one line to your `$PROFILE` (`notepad $PROFILE`) and reload with `& $PROFILE`:

```powershell
# Optional: only needed if auto-detection fails.
# $env:POWBOX_ROOT = "C:\path\to\powbox"

. "C:\path\to\powbox\shell\powbox.ps1"
```

Common usage:

```powershell
# Launch Claude in the current folder
cc

# Launch Claude in a specific folder, opening a shell instead
cc C:\Projects\MyApp -Shell

# Launch Codex in the current folder
cx

# Run Codex headless
cx -Exec "fix the failing tests"

# Self-hosted: clone the repo into a private volume (see "Self-Hosted Mode")
cc -Isolated owner/repo -Name feature-a

# Resume that named self-hosted Claude instance later
cci feature-a

# Launch either agent with a read-only reference folder at /ctx/specs
cc -Ctx C:\Docs\specs

# Prune orphaned node_modules volumes (dry run first)
agent-prune-volumes -WhatIf
agent-prune-volumes

# Remove all stopped agent containers
agent-prune-stopped

# Full cleanup: remove stopped containers and prune orphaned volumes
agent-prune

# Check for newer agent releases
agent-check-updates

# Review the update report and confirm before rebuilding stale images
agent-update

# Rebuild the full stack from the current repo state (cached) even with no updates
agent-update -Refresh

# Nuclear: re-pull the base and rebuild everything from scratch
agent-full-rebuild

# Re-seed updated baked skills onto the config volumes (preview, then apply)
agent-update-skills -DryRun
agent-update-skills
# Also drop obsolete seeds and take baked versions of unmarked name-collisions
agent-update-skills -Prune -AdoptAll

# List Claude containers
cc-list

# List Codex containers
cx-list

# List all agent containers
agent-list

# List agent volumes
agent-volumes
```

All flags accepted by `commands/claude-container.ps1` and `commands/codex-container.ps1` are forwarded by these functions, so `-Build`, `-Detach`, `-Persist`, `-Resume`, `-Continue`, `-Volatile`, and `-Ctx` all work as documented.

### Bash / zsh

Add one line to `~/.bashrc` or `~/.zshrc` and reload with `source ~/.bashrc` (or `source ~/.zshrc`):

```bash
# Optional: only needed if auto-detection fails.
# export POWBOX_ROOT="$HOME/path/to/powbox"

source "$HOME/path/to/powbox/shell/powbox.sh"
```

Common usage:

```bash
# Launch Claude in the current folder
cc

# Launch Claude in a specific folder, opening a shell instead
cc ~/projects/myapp --shell

# Launch Codex in the current folder
cx

# Run Codex headless
cx --exec "fix the failing tests"

# Self-hosted: clone the repo into a private volume (see "Self-Hosted Mode")
cc --isolated owner/repo --name feature-a

# Launch either agent with a read-only reference folder at /ctx/specs
cc --ctx ~/docs/specs

# Prune orphaned node_modules volumes (prompts for confirmation)
agent-prune-volumes

# Remove all stopped agent containers
agent-prune-stopped

# Full cleanup: remove stopped containers and prune orphaned volumes
agent-prune

# Check for newer agent releases
agent-check-updates

# Review the update report and confirm before rebuilding stale images
agent-update

# Rebuild the full stack from the current repo state (cached) even with no updates
agent-update --refresh

# Nuclear: re-pull the base and rebuild everything from scratch
agent-full-rebuild

# Re-seed updated baked skills onto the config volumes (preview, then apply)
agent-update-skills --dry-run
agent-update-skills
# Also drop obsolete seeds and take baked versions of unmarked name-collisions
agent-update-skills --prune --adopt-all

# List Claude containers
cc-list

# List Codex containers
cx-list

# List all agent containers
agent-list

# List agent volumes
agent-volumes
```

All flags accepted by `commands/claude-container.sh` and `commands/codex-container.sh` are forwarded, so `--build`, `--detach`, `--persist`, `--resume`, `--continue`, `--volatile`, and `--ctx` all work as documented.

To move the repo later, either rely on auto-detection (update the `source` / dot-source path) or update `POWBOX_ROOT` to the new path and reload your profile.

## Host Validation

Host-side validation requires Docker Desktop or Docker Engine with a working `docker buildx`.

Inspect the named Bake targets and tags with:

```bash
docker buildx bake --file docker-bake.hcl --print
```

Render the merged runtime config with:

```bash
docker compose -p powbox -f compose.shared.yml -f compose.agent.yml config
```

Smoke test the built image with:

```bash
./commands/smoke-test.sh
```

The run is layered: a hermetic tier of eight unit-suite entries (Stages 0a, 0b, 0d and 0f–0j, over eight distinct `scripts/test-*.sh` files) that needs no root, host database, nested engine, relaunch cycle or network but runs inside the image — seven entries target **baked** artifacts and Stage 0i targets the routed pnpm-wrapper source under its required `/workspace` contract — then six image/host stages: tool presence and key image config, a `pg-dev-up` functional test plus the daemon-backed scoped suite, the rootless-Podman engine, self-hosted (`--isolated`) launch, native-Linux dir-mount ownership, and the durable worktree-metadata recreate lifecycle.
Stages self-skip rather than fail when the host cannot provide what they need (no `/dev/net/tun`, no root-owned fixture, no `mount --bind` privilege), and five of the six — Stages 2 through 6 — can be skipped explicitly with `POWBOX_SMOKE_SKIP_DB`, `POWBOX_SMOKE_SKIP_PODMAN`, `POWBOX_SMOKE_SKIP_SELFHOSTED`, `POWBOX_SMOKE_SKIP_DIRMOUNT`, or `POWBOX_SMOKE_SKIP_WORKTREE_META` (PowerShell: `.\commands\smoke-test.ps1 -SkipDb -SkipPodman -SkipSelfHosted -SkipDirMount -SkipWorktreeMeta`); Stage 1 has no skip variable, being the presence sweep the later stages assume and the residue that remains when all five are set — an end-of-run banner lists the skips so a partial run is not reported as a full one, with a narrow exception the chapter below names. See [docs/smoke-tests.md](docs/smoke-tests.md) for the orientation the scripts do not give you: what each stage is for, which entries run the `/repo` source and which the baked artifact, which stages reach the network and what a failed pull or clone costs, and which self-skips the banner cannot see. For what an individual stage asserts, read that stage's script.

After launching each agent at least once, `docker volume ls` should show one copy of the shared volumes `agent-gh-config` and `agent-zsh-history`, the per-container `agent-nm-<agent>-<project>` and `agent-wt-<agent>-<project>` volumes (for a dir-mounted JS/powbox project; a Go- or boundedly detected .NET-only repo gets only the latter, a non-dev folder neither, and `--isolated` an `agent-ws-<container>` volume instead), a per-container `agent-podman-<agent>-<project>` Podman store, plus separate `claude-config` and `codex-config` volumes.

## Runtime Sanity Check

Launch an interactive shell with `--shell --volatile` to verify the container environment.

### Claude

```bash
./commands/claude-container.sh /path/to/project --shell --volatile
```

Inside the container:

```bash
whoami
echo "$CLAUDE_CONFIG_DIR"
claude --version
gh --version
pnpm config get store-dir
pwd
ls -ld node_modules
```

Expected results:

- user is `node`
- `CLAUDE_CONFIG_DIR` is `/home/node/.claude`
- the pnpm store is per-container at `/workspace/<project>-<hash>/.worktrees/.pnpm-store` (co-located with worktrees so installs hardlink)
- working directory is `/workspace/<project>-<hash>`
- `node_modules` is writable by `node`

### Codex

```bash
./commands/codex-container.sh /path/to/project --shell --volatile
```

Inside the container:

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
- the pnpm store is per-container at `/workspace/<project>-<hash>/.worktrees/.pnpm-store` (co-located with worktrees so installs hardlink)
- working directory is `/workspace/<project>-<hash>`
- `node_modules` is writable by `node`

Codex preserves any existing `config.toml` settings in the `codex-config` volume, but the container now auto-seeds a missing `[tui].status_line` plus a missing top-level `terminal_title` default.
The seeded status line uses Codex-native items for model, current directory, remaining context, 5-hour usage, weekly usage, and used tokens.
`terminal_title` is a separate Codex setting for the terminal window or tab title, not the bottom status line.
The seeded title surfaces current directory, git branch, model, and thread title when the terminal supports title updates.
That means a fresh or reset Codex config starts with a richer native status line and title, while existing user customizations remain untouched except for compatibility migrations such as replacing Codex's removed `context-remaining-percent` status item with `context-remaining`.

Claude likewise preserves existing `settings.json` values in the `claude-config` volume, and the container seeds one no-clobber default: a missing `respondToBashCommands` is set to `false`.
That keeps a fresh Claude config's `!` bash commands context-only — their output feeds your next prompt instead of triggering a reply after each one (Claude Code's pre-2.1.186 behavior).
Unlike the status line above, this default never re-asserts: set `respondToBashCommands` to `true` yourself and your choice survives every restart.

## House Lint and Format Configuration

Three repo-root files state the house Markdown and shell style instead of leaving each contributor and editor to infer it.
PowerShell's house rules live separately in `PSScriptAnalyzerSettings.psd1` — see AGENTS.md "PowerShell Linting".
The two checks below differ in reach: Markdown lint is local-only, while `shfmt` also runs as an advisory Tier 0 step — so read this section alongside "Continuous Integration" rather than as part of it.

`.markdownlint.jsonc` carries the Markdown rule set — shared in spirit with the other Roubtec projects, with powbox-specific deviations noted inline — and `.markdownlint-cli2.jsonc` carries only the ignore globs for generated, vendored and container-local trees.
Run it with `markdownlint-cli2 "**/*.md"`; the agent image bakes `markdownlint-cli2` 0.23.2, and a repository pin or wrapper stays authoritative wherever one exists.
Markdown lint is **not** a CI gate today: no workflow lints this repo's Markdown, so its findings are advisory until someone adds the step.
Tier 1's smoke test does invoke `markdownlint-cli2`, but only to probe that the binary is baked at its pinned version — it lints a throwaway file, never the repository.
The tree is not clean under this config yet (81 findings across 26 files as of this commit), so compare against the base branch rather than expecting a zero exit — the same "not yet normalized" caveat the `shfmt` step carries.

`.editorconfig` states the shell indentation convention (`indent_style = tab` for `*.sh`), which is the form `shfmt` itself reads.
Tier 0's advisory `shfmt` step runs `shfmt -d` with no style-override flags over the scripts a PR changes.
The declaration records the convention `shfmt` already applies by default rather than changing what it checks, so editors and `shfmt` agree on the same style.
See AGENTS.md "Validating Changes" for the `docker/shared/` extensionless-helper exception, and `.editorconfig`'s own comment for the handful of scripts that predate the convention.

## Continuous Integration

GitHub Actions validate powbox on `ubuntu-latest` — a hosted native-Linux VM
running a first-class Docker daemon (not Docker Desktop on Windows/WSL) — so the
build / mount / identity / exec-bit defect class that Windows/WSL masks (git there
ignores filemode, the bind mount reports `0755`, uid semantics differ) is caught
automatically on PRs instead of during a manual VPS stand-up. Two layered
workflows keep cost proportional to the change:

- **Tier 0 — every PR except a `non-code`-labelled one** (`.github/workflows/native-linux-ci.yml`, about a minute, no
  Docker): static guards — an exec-bit check (`scripts/check-exec-bits.sh`, the
  PR #51 class), `shellcheck` (error severity) over all `*.sh`, an advisory
  `shfmt` on the scripts a PR changes, and `Invoke-ScriptAnalyzer`
  (PSScriptAnalyzer, using `PSScriptAnalyzerSettings.psd1`) over all `*.ps1` —
  plus `scripts/run-pure-shell-tests.sh`, which discovers and runs in parallel
  every native-Linux-hermetic `scripts/test-*.sh` source suite not explicitly
  routed to Tier 1. The current 14-suite set is `test-claude-hook-skew.sh`,
  `test-context-mount-config.sh`, `test-detect-shadows.sh`,
  `test-peer-review-run.sh`, `test-podman-compose-healthcheck.sh`,
  `test-seed-marker-source.sh`, `test-sensitive-host-path.sh`,
  `test-shadow-mounts-chown.sh`, `test-shadow-refresh-guard.sh`,
  `test-smoke-probe-wrapper.sh`, `test-sync-codex-skills.sh`,
  `test-wf-check.sh`, `test-wf-status.sh`, and `test-wt-orphan-safety.sh`.
  A new suite is selected automatically; a
  suite-named log heading makes any non-zero exit obvious. The detect-shadows
  suite needs the jq-compatible filters provided by **jq-backed python-yq**, so
  the job installs it into a throwaway venv from
  `.github/requirements/python-yq.txt` — the whole dependency closure pinned and
  SHA256-verified via `pip --require-hashes`, the same pinned-and-hashed contract
  as the `shfmt` step — and puts it ahead of the runner image's preinstalled
  mikefarah Go `yq`, which cannot parse the detect-shadows filters.
  The Podman-health-check suite only requires the `yq -r` operations that its
  behavioral capability probe exercises; any implementation that passes that
  probe works, including mikefarah `yq` v4.45.1.
  The source `wf-check` suite needs the helper's exact Acorn 8.15.0 and
  acorn-walk 8.3.4 pins, so the job installs them without lifecycle scripts in a
  throwaway npm prefix and exposes only those private module paths to the test.
  Four suites are explicitly routed to Tier 1 instead: `test-gh-review-threads.sh`
  and `test-dc-helpers.sh` need their separately fetched/baked helpers
  (`gh-review-threads`, and the `dc-enter`/`dc-remove` pair),
  `test-pnpm-shadow-wrapper.sh` needs the image's writable `/workspace`
  production root, and `test-pg-dev-up-scoped.sh` starts real PostgreSQL daemons
  using the baked server binaries. Deliberate Stage 0 repeats target baked artifacts; Tier 0
  targets `/repo` source, so those are two-target checks rather than duplicate runs.
- **Tier 1 — only on image-affecting paths** (`.github/workflows/native-linux-build.yml`):
  builds the agent image and runs `./commands/smoke-test.sh` under
  `POWBOX_SMOKE_REQUIRE_IMAGE=1`, so an absent image is a hard error instead of a
  run whose image-gated checks self-skip into a false green. That flag reaches
  only the image-dependent skips — the hosted runner still exposes no
  `/dev/net/tun`, so Stage 3's nested half self-skips there and a green Tier 1 is
  a partial smoke (see "What CI covers vs. what stays VPS-only" below). A
  second, stricter smoke step then runs `scripts/smoke-test-worktree-metadata.ps1`
  directly, because the Bash umbrella never invokes the PowerShell mirror and
  this runner is the only automated configuration where its Stage 6
  mountpoint-ownership assertions have teeth (see
  [docs/smoke-tests.md](docs/smoke-tests.md) → "The PowerShell mirror"). It
  triggers on `docker/**`, Dockerfiles, `compose*.yml`, `docker-bake.hcl`,
  `build.*`, and the `scripts/launch-agent.*` / `scripts/build-image.*` /
  `scripts/smoke-test*` / `commands/smoke-test.*` entrypoints and the four
  `scripts/test-*.sh` suites routed to Tier 1 above; skill/docs PRs run
  Tier 0 only, and it carries the same `non-code` label gate as Tier 0 — though
  only Tier 0 subscribes to `labeled`/`unlabeled`, so toggling the label
  re-evaluates Tier 0 at once, while Tier 1 reads its gate only on the next
  `opened`/`synchronize`/`reopened` event and an already-queued or running Tier 1
  is not called off (there the gate is belt-and-suspenders anyway: a docs PR
  never matches the paths above). The expensive base image is cached (a `docker
  save` tarball keyed on its inputs) so the common Tier-1 run rebuilds only the
  agent layers.

### What CI covers vs. what stays VPS-only

The hosted runner is a native-Linux environment, so it covers the build,
exec-bit, file ownership, and container-identity wiring end to end. It does
**not** reproduce a few host-specific behaviors, which stay manually
VPS-validated (the VPS remains the backstop either way):

- **Egress firewall against real CGNAT ranges** and the netcup cloud-firewall
  interplay (PR #52's class) — hosted-runner networking differs.
- **FUSE / overlay storage performance** characteristics.
- **Nested rootless Podman that needs `/dev/net/tun` + `/dev/fuse`** — unreliable
  on hosted runners, so the smoke test's Podman stage self-skips its nested-run
  checks there and validates only the static engine wiring.
- **Long-lived-host behavior** (a persistent VPS over time).

Fuller coverage of the first and third items is possible later by pointing the
same Tier-1 workflow at a **self-hosted runner** (which can expose
`/dev/net/tun` + `/dev/fuse` and, with `NET_ADMIN`, exercise the firewall) — more
setup and a maintained runner, but the workflow itself runs there unchanged.

## License

This project is licensed under the MIT License.

See [LICENSE](LICENSE).
