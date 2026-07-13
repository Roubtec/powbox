# Task 021: Runtime refresh for the Codex shared-skill palette

## Problem

The two agents' shared dev-workflow skills now update on different clocks, and on longer-lived images the disparity will bite unexpectedly.
Claude's 8 shared skills arrive via the `dev-skills@roubtec` plugin, which the detached entrypoint bootstrap (`seed-claude-plugins.sh`, PR #102) installs and keeps current at **every container start** — so Claude tracks `agent-skills` main at container-recycle cadence.
Codex's copies of the same 8 skills are fetched **only at image build time** (`scripts/build-image.sh` shallow-clones `Roubtec/agent-skills`; `docker/agent/Dockerfile` bakes `codex/dev-skills/skills/` and stamps `AGENT_SKILLS_COMMIT`) and seeded no-clobber by `entrypoint-codex-hook.sh` — so Codex tracks the **image rebuild** cadence.
A skill fix merged to `agent-skills` main reaches every Claude session within one container recycle, while Codex keeps running the version baked weeks ago until someone rebuilds the image and runs `agent-update-skills`.

## Goal

Give Codex a start-time refresh of the 8 shared skills so both agents converge on `agent-skills` main at the same cadence, without adding a second network fetch or blocking startup.

## Key insight: the fetch already happens

The Claude plugin bootstrap keeps a full clone of `Roubtec/agent-skills` on the shared claude-config volume at `~/.claude/plugins/marketplaces/roubtec/`, and that clone contains `codex/dev-skills/skills/` (verified in a live container).
So the Codex refresh is a **local sync** from that clone into `~/.codex/skills/` — no network ops of its own, and it inherits the plugin channel's freshness (the bootstrap runs `marketplace update` every start).

## Design requirements

1. **Placement/invocation:** run inside (or chained directly after) the same detached run `entrypoint-core.sh` spawns for `seed-claude-plugins.sh` — post-firewall, `setsid`, stdin `</dev/null`, stdio to the bootstrap log — so the sync is ordered AFTER the clone refresh and can never touch the entrypoint's critical path. Never invoke the claude CLI from any new code path without detached stdio (see the TTY-hang note in `seed-claude-plugins.sh`).
2. **No wait needed:** unlike Claude (plugins enumerate once at session start), Codex observes skill-file changes live — a refresh landing mid-session is picked up. Do NOT extend the `POWBOX_PLUGIN_WAIT` bounded wait to Codex; the detached sync is sufficient.
3. **Ownership semantics:** reuse the `seed-skills.sh` primitives / marker rules. Only overwrite a skill whose `.powbox-seeded` marker is present (powbox owns that copy); a marker-less (user-adopted) skill is never touched. Match by name against the clone's `codex/dev-skills/skills/*` so the refresh can only ever touch the 8 shared skills — the 2 powbox-specific Codex skills stay exclusively bake-owned.
4. **Churn avoidance:** Codex warns loudly when skill files change under a running session, so sync only when content actually differs (compare the clone's HEAD SHA against a SHA recorded in the marker, or `rsync -c`); an unchanged palette must be a byte-for-byte no-op. Prefer per-skill atomic replace (stage + rename) over in-place file rewrites to keep the mid-session window minimal.
5. **Provenance:** stamp refreshed markers with the `agent-skills` commit SHA actually synced (`git -C <clone> rev-parse HEAD`), not the image build epoch, so `agent-update-skills` and humans can see which channel last wrote the copy.
6. **Concurrency:** the codex-config volume is shared by every powbox container (same as claude-config) — serialize the check-then-mutate with an flock on that volume, mirroring `seed-claude-plugins.sh`'s `run_locked`.
7. **Best-effort:** clone missing (cold claude-config volume, plugin disabled, or bootstrap failed) → log a skip and leave the baked copies in place; never exit non-zero into the entrypoint.

## Open decision to resolve during implementation

Interaction with `agent-update-skills` (the bake+seed refresher): after this task, a Codex skill on the volume may be NEWER than the image bake, and today the updater force-refreshes marked skills from the image — silently rolling the palette back to the bake.
Decide and document the precedence, e.g. teach the updater to skip a marker whose recorded source is the plugin-clone channel with a newer SHA, or accept last-writer-wins and note that the next container start re-syncs forward again (cheap, since the sync is a local no-op-when-unchanged).
The second option is likely sufficient — call it out in `docs/skills-refresh-and-provenance.md` either way.

## Acceptance criteria

- A container start with a warm claude-config volume brings `~/.codex/skills/` shared skills to the same `agent-skills` commit the Claude plugin serves, with zero added startup latency (detached; verify no new foreground CLI/network calls).
- A user-adopted skill (marker deleted) survives untouched; the 2 powbox-specific Codex skills are never candidates.
- Unchanged palette → no file writes (verify mtimes stable across two consecutive syncs).
- Cold claude-config volume → logged skip, baked skills intact.
- `shellcheck -x` and `shfmt -d` clean; docs updated (`docs/entrypoint-and-runtime.md` plugin bullet, README "Agent Skills" channel table — the plugin channel row grows a "also syncs the Codex copies" note — and `docs/skills-refresh-and-provenance.md` for the precedence decision).

## References

- `docker/shared/seed-claude-plugins.sh` — the detached bootstrap this piggybacks on (PR #102: TTY-hang rationale, flock pattern, done-marker).
- `docker/shared/seed-skills.sh` — marker semantics and copy primitives to reuse.
- `docker/shared/update-skills-incontainer.sh` + `docs/skills-refresh-and-provenance.md` — the bake+seed refresher this must stay coherent with.
- `scripts/build-image.sh` (agent-skills fetch) and `docker/agent/Dockerfile` (`AGENT_SKILLS_COMMIT`) — the build-time channel that remains the fallback source.
