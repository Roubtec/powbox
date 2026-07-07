# Task 015f — Make the dev-skills plugin available in the FIRST session on a cold claude-config volume

Follow-up to **Task 015c** (deliver the `dev-skills@roubtec` Claude plugin channel, PR #93). Parked in `tasks/deferred/` because the branch is defendable as-is — it meets every 015c acceptance criterion — and the proper fix requires reworking entrypoint ordering around the gh credential helper, which is a deliberate design change too large to fold into a review-fix commit.

## Background — the gap

`docker/shared/entrypoint-claude-hook.sh` spawns `seed-claude-plugins.sh` **detached and backgrounded** (fire-and-forget), then the entrypoint immediately `exec`s the foreground `claude`. On a **cold/fresh `claude-config` volume with network**, the private-marketplace clone + `plugin install` is still running when Claude Code loads its plugin set, and Claude Code only picks up plugins installed after a session has loaded via `/reload-plugins` or a restart.

Net effect: on a brand-new volume, the eight shared skills (`/dev-skills:*`) are **absent for the very first task** — including model-side Skill-tool matching, since nothing is installed yet — until the background install finishes AND the user reloads/restarts. It self-heals from the second session on (the plugin is then present on the persistent volume). It is therefore a **one-time, first-session-only** gap per volume.

The **same root limitation applies to the warm-volume keep-current path**: when a start's `plugin update` pulls a *newer* agent-skills commit, that new version only takes effect at the next session start too (the running session keeps the previously-cached skills), so the session that triggered the update runs the **stale** skills. This is the already-documented "updates apply at the NEXT session start (a restart)" behavior in `seed-claude-plugins.sh`; it shares this task's fix surface (whatever makes a just-installed plugin live also makes a just-updated one live — e.g. a bounded post-auth sync before `exec`, or a `/reload-plugins` hint).

Review threads (same underlying concern, both codex P2): first raised at https://github.com/Roubtec/powbox/pull/93#discussion_r3537771174 and re-raised (with the warm-update facet spelled out) at https://github.com/Roubtec/powbox/pull/93#discussion_r3538614735.

## Why this was deferred (why the branch is defendable)

- The backgrounding is **load-bearing by design**: the private repo is cloned over HTTPS and needs git's gh credential helper, which `entrypoint-core.sh`'s `gh auth setup-git` configures **after** this hook fires. Running the install inline/synchronously here would race or precede auth and fail. The whole "detach + briefly wait for the helper" structure exists to resolve that ordering without blocking startup — a core, documented invariant ("container start must NEVER be blocked or failed by plugin work").
- Task 015c's acceptance criteria only require that, after start on a fresh volume, `claude plugin list` shows the plugin and `/dev-skills:address-review` is invocable — not that it is available in the very first session. The install path already logs "skills available as /dev-skills:<name> next session".
- So closing the gap is a scope-expanding design change, not a cheap fix.

## Goal

Make the eight `/dev-skills:*` skills available in the **first** session on a cold volume with network, without reintroducing the auth-ordering race and without blocking container startup on a slow or offline network.

## Suggested approaches (to weigh, not prescriptive)

1. **Bounded synchronous cold-volume install, after auth.** Move only the *install-if-absent* case to run **after** `gh auth setup-git` in the entrypoint (so the credential helper exists) and **before** `exec`, guarded by a short bound so a slow/offline network still falls back to the background/self-heal path rather than delaying the prompt. Keep the warm-volume keep-current path backgrounded as today. Trade-off: adds a bounded startup delay on first-ever start only.
2. **First-session reload hint.** Keep the fire-and-forget install, but when the background job completes an install during a session, surface a one-line "run `/reload-plugins` to activate the dev-skills plugin" notice (e.g. via the log the user is told to read, or a SessionStart mechanism if one is wired). Cheapest, but relies on the user acting.
3. **Image-baked plugin seed cache** (`CLAUDE_CODE_PLUGIN_CACHE_DIR` / `CLAUDE_CODE_PLUGIN_SEED_DIR`, noted in task 015c). Rejected in 015c while the repo is private (no build-time GitHub auth), but revisit if the agent-skills repo flips public — a baked cache would make the skills present at first load with no entrypoint work.

Confirm the ordering/latency trade-off with the maintainer before implementing option 1, since it touches the never-block-startup invariant.

## Acceptance

- Fresh container + fresh `claude-config` volume + network: the eight `/dev-skills:*` skills are invocable in the **first** session (no manual `/reload-plugins` or restart needed), OR the user is clearly prompted to reload if the chosen approach is hint-based.
- Warm volume where a start's `plugin update` pulls a newer agent-skills commit: that session runs (or is clearly prompted to reload to run) the **updated** skills, not the stale cached ones — the same mechanism that closes the cold-start first-session gap covers this warm-update-staleness case.
- Container start is still never blocked on a slow/offline network (the cold-volume path degrades to the existing background self-heal).
- Warm-volume starts are unchanged (cheap keep-current, no added latency).
- Offline cold start still starts normally and self-heals on a later online start.
