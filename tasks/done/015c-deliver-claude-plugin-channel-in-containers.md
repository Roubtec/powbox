# 015c — Deliver the dev-skills Claude plugin channel in powbox containers

## Why this task exists

Powbox containers deliberately consume the shared Claude skills through the
**same channel as colleagues** — the `dev-skills@roubtec` plugin — so the
distribution path is dogfooded where it can be fixed fastest. This task makes
every powbox container install and keep current that plugin automatically.

## Scope

**In scope:**
- Install-if-absent of the marketplace + plugin for Claude at container start.
- A keep-current mechanism (startup refresh and/or marketplace auto-update).
- Idempotency and offline tolerance.

**Out of scope:**
- The image bake / Codex path (task 015b).
- Pruning old seeded copies and docs (task 015d).

## Context and references

- **Prerequisites:** tasks 015a (content merged) and 015b (bake rewired) — a
  container built from task 015b's image no longer seeds the 8 skills, so this
  task is what brings them back, namespaced.
- Verified plugin facts (current official docs, code.claude.com/docs):
  - Headless CLI: `claude plugin marketplace add Roubtec/agent-skills`,
    `claude plugin install dev-skills@roubtec` (user scope by default),
    `claude plugin marketplace update roubtec` (refreshes marketplace
    metadata AND updates installed plugins from it), `claude plugin update
    <plugin>@<marketplace>`.
  - State lives under `~/.claude/plugins/` (`cache/`,
    `known_marketplaces.json`, `installed_plugins.json` — underscore, not
    hyphen; verified on CLI 2.1.201) — i.e. on the persistent claude-config
    volume, so installation is once per volume, not per container start.
  - No `version` field in the manifests → commit-SHA versioning: every new
    commit on agent-skills main is detected as an update.
  - Auto-update is per-marketplace, OFF by default for third-party
    marketplaces, toggled via `/plugin` → Marketplaces; when on, updates apply
    at session start. Its on-disk representation is **not documented** — if you
    enable it programmatically, first verify the schema by toggling it in the
    UI once and diffing `~/.claude/plugins/` state; don't guess.
  - Docs also offer `CLAUDE_CODE_PLUGIN_CACHE_DIR` / `CLAUDE_CODE_PLUGIN_SEED_DIR`
    for image-baked plugin caches. **Prefer the entrypoint install instead**:
    the repo is private for now, GitHub auth exists at entrypoint time via the
    gh credential helper but not at image-build time, and the entrypoint path
    keeps working unchanged when the repo flips public. If you choose the seed
    dir anyway, document the trade-off.
- Powbox integration point: `docker/shared/entrypoint-claude-hook.sh` (runs at
  container start; verify it runs AFTER the gh credential helper is configured
  — check `entrypoint-core.sh` / `entrypoint-agent.sh` ordering).

## Implementation notes

1. **Install-if-absent, in the claude entrypoint hook:** if
   `dev-skills@roubtec` is not installed **and enabled** (check
   `claude plugin list`, which reports enable status —
   `installed_plugins.json` alone only proves registration, not enablement),
   run the idempotent `marketplace add` + `plugin install` (+ enable if the
   plugin is registered but never enabled) sequence; decide and document
   whether a plugin the user deliberately disabled is re-enabled or respected.
   Every step must be best-effort: bounded by a timeout (a few seconds each), all
   failures logged to stderr with a clear "skills plugin unavailable, will
   retry next start" message, **never** failing container start.
2. **Keep-current:** when the plugin IS already installed, run a non-blocking
   `claude plugin marketplace update roubtec` (same timeout/tolerance
   rules). Running it in the background so the container prompt isn't delayed
   is acceptable — decide and document. Additionally enable marketplace
   auto-update if a supported programmatic path exists (see caveat above);
   otherwise note in the hook comment that auto-update can be toggled once per
   volume via `/plugin`.
3. **Idempotency:** repeated container starts on a warm volume must be no-ops
   (fast path: plugin present and enabled + update check). A cold/new claude-config volume
   must converge to installed on first start with network, and self-heal on a
   later start if the first attempt happened offline.
4. Namespacing note for docs/comments: skills arrive as
   `/dev-skills:<name>`; the model-side Skill-tool matching by description is
   unaffected. Users' muscle memory of `/address-review` changes — worth one
   line in the hook comment and the task-015d docs.

## Target files or areas

Powbox repo: `docker/shared/entrypoint-claude-hook.sh` (primary), possibly a
small shared helper in `docker/shared/`, Dockerfile only if the seed-dir
approach is chosen.

## Acceptance criteria

- Fresh container + fresh claude-config volume + network: after start,
  `claude plugin list` (or `installed_plugins.json`) shows
  `dev-skills@roubtec`, and `/dev-skills:address-review` is invocable.
- Same container restarted: hook takes the fast path (observably cheap; no
  reinstall).
- Container started with GitHub unreachable (e.g. firewall test or bogus
  DNS): starts normally, logs the skip, and installs on a later start with
  network.
- New agent-skills commit on main → next container session picks it up (via
  the startup update and/or auto-update), verifiable by a text change landing
  in the installed skill.

## Validation

Exercise all four acceptance scenarios against a locally built image; capture
the hook's log lines for each in the PR description.

## Review plan

Reviewer reads the hook diff for the failure modes (timeout, no network, half
-installed state), confirms container start is never blocked, and re-runs the
cold-volume scenario.
