# Task 015g — Make the dev-skills plugin available in the FIRST session on a cold claude-config volume

Follow-up to **Task 015c** (deliver the `dev-skills@roubtec` Claude plugin channel, PR #93).

**Status (2026-07-08): approach decided; now actionable (moved out of `tasks/deferred/`).**
`Roubtec/agent-skills` is now **public** (task 015e step 2), which removes the
auth-ordering constraint that forced the plugin install to be backgrounded. That
both makes the synchronous fix below cheap **and** renders a block of private-repo
scaffolding vestigial — so this task delivers the first-session fix **and** retires
that scaffolding together.

## Background — the gap (mechanism unchanged)

`docker/shared/entrypoint-claude-hook.sh` spawns `seed-claude-plugins.sh`
**detached and backgrounded** (fire-and-forget), then the entrypoint immediately
`exec`s the foreground `claude`. On a **cold/fresh `claude-config` volume with
network**, the `marketplace add` + `plugin install` is still running when Claude
Code loads its plugin set.

Verified against the Claude Code **2.1.202** binary (do not re-derive):

- Plugins are enumerated from `~/.claude/plugins/installed_plugins.json` **once, at
  session start**; nothing re-scans the installed-plugins tree mid-session (the only
  auto-reload, `setupPluginHookHotReload`, is a *settings* subscription that
  refreshes plugin **hooks** alone).
- Each `SKILL.md` is read from disk **once at that startup scan**; both its **body**
  and its **metadata** (name/description/when_to_use) are captured into an in-memory
  command object, and invocation replays that **cached** copy with only variable
  substitution — the file is **not** re-read at invoke time.
- Therefore a plugin that becomes installed **after** the session started is
  **completely invisible** — no slash command, no model-side Skill-tool description,
  no body — until the user runs **`/reload-plugins`** (not `/reload-skills`: a
  brand-new plugin must first be re-enumerated from `installed_plugins.json`, which
  only `/reload-plugins` does). That reload reads current on-disk state and does
  **not** wait for the install, so it only helps **after** the background install
  has fully completed.

Net effect: on a brand-new volume the eight `/dev-skills:*` skills are **absent for
the entire first session** until the background install finishes **and** the user
runs `/reload-plugins` — a race the user can lose on a slow first boot. It
self-heals from the second session on (the plugin is then present on the persistent
volume and loads natively at the startup scan). The volume is effectively
permanent, so this is a **one-time, first-boot-only** gap — but it is the
"not available out of the box" pain we want to remove.

The warm-volume keep-current path shares this load model: a start whose
`plugin update` pulls a newer agent-skills commit only takes effect at the **next**
session start. Per maintainer decision (2026-07-08) this **one-session staleness is
accepted** — the user knows to run `/reload-plugins` a little after session start
when they have just changed skill wording upstream. This task does **not** try to
make a mid-session *update* live.

## What changed — the repo is public now

The **only** reason `seed-claude-plugins.sh` was backgrounded was an auth-ordering
race: a **private** HTTPS clone needs git's `gh` credential helper, which
`entrypoint-core.sh:137` (`gh auth setup-git`) registers **after** the Claude hook
fires at `entrypoint-core.sh:18`. The whole "detach + wait up to `AUTH_WAIT` for the
helper" structure existed solely to bridge that.

A **public** repo clones **anonymously** — no credential helper, no ordering
dependency. So:

- the cold install can run **synchronously in the hook** (at `entrypoint-core.sh:18`,
  before `exec` at `:391`; the firewall is already up at `:5`, so egress works) with
  **no entrypoint reordering** and **no auth dependency**; and
- the auth-wait machinery becomes **dead code** to remove.

## The solution (decided)

Split the two cases; make **only the cold case synchronous**.

1. **`absent` (cold volume) → synchronous, bounded, before `exec claude`.** Run
   `marketplace add` + `plugin install` in the **foreground** of the entrypoint hook,
   so the plugin is present when Claude does its startup scan and the eight
   `/dev-skills:*` skills are live in the **first** session with **no
   `/reload-plugins` and no restart**. Bound it (suggest a
   `POWBOX_PLUGIN_COLD_INSTALL_BOUND`, ~45–60s); on timeout/failure, **detach the
   remaining work to the existing background self-heal** and let the entrypoint
   proceed — container start is **never** blocked, and the worst case is today's
   behavior (skills arrive next session, or on a user `/reload-plugins` once the
   background install lands).
2. **`enabled` (warm keep-current) → stays async/backgrounded**, exactly as today
   (self-forked to the background so it never adds start latency). One-session update
   staleness is accepted (above).
3. **`disabled` → unchanged.** Respect a deliberate user opt-out; never re-enable.

Recommended structure (non-prescriptive): the hook calls `seed-claude-plugins.sh`
**synchronously** (drop the `setsid … &` wrapper). Inside the script, after the
(locked) `plugin_state` query: for `absent`, do the bounded install in the
foreground; for `enabled`, self-background the keep-current (`setsid … &`) and return
immediately so the entrypoint continues to `exec`. Keep the whole cold
check-then-mutate under the existing `flock` (`run_locked` / `converge_plugin_state`)
— concurrent cold containers on the shared volume still race.

## Cleanup scope — retire the now-vestigial private-repo scaffolding

Fold into this task (each justified solely by the public flip):

- **Remove** `wait_for_github_auth`, `gh_git_helper_ready`, the
  `AUTH_WAIT` / `POWBOX_PLUGIN_AUTH_WAIT` bound, and the "WHY BACKGROUNDED + WHY IT
  WAITS FOR AUTH" rationale block in `seed-claude-plugins.sh`. A public clone needs
  no credential helper, so there is nothing to wait for.
- **Rewrite** the large detach-for-auth-ordering comment in
  `entrypoint-claude-hook.sh` (~lines 95–132): the cold path no longer detaches, and
  the warm path backgrounds for **latency only**, not auth.
- **Update** `docs/entrypoint-and-runtime.md`: the first-session cold-volume caveat
  it now documents is closed by the synchronous cold install; drop the "waits for the
  gh credential helper" description.
- **Keep (explicitly NOT private-repo infra):**
  - `flock` cross-container serialization — the `claude-config` volume is still
    shared; the race is independent of repo visibility.
  - `CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE=1` — protects persistent
    installed state on a failed warm refresh; it is about state integrity, not
    offline usability.
  - `GIT_TERMINAL_PROMPT=0` — fail-fast belt-and-suspenders; a public clone will not
    prompt, but keep it.
- **Sibling task:** the CI-auth `015f` (on task/015b, PR #92) is **resolved** by the
  same public flip and has been archived to `tasks/done/` with no code change.
  Cross-referenced here to explain the numbering: that retired CI-auth task keeps
  `015f`, so this cold-volume follow-up is renumbered `015g` to avoid clashing with it.

**Assumption:** this task takes the 015e public flip as the plan of record and
permanent. If `agent-skills` were ever re-privatized, the credential-helper wait
would have to return — out of scope here.

### Review threads subsumed by this task (PR #93)

Three P2 concerns raised in review on #93 are resolved by this task's rewrite — the
first two by the scaffolding removal above, the third by the synchronous cold-install
solution — not by a patch on #93. They are deferred here rather than fixed on #93
because any fix on #93 would be thrown away when this task lands (it deletes the very
`gh_git_helper_ready` / `wait_for_github_auth` / `AUTH_WAIT` code the first two
critique, and replaces the backgrounded cold path the third critiques). The bots
re-raised all three on a later review round (current unresolved thread IDs below);
the earlier, now-resolved threads that first raised them are noted for provenance:

- **`gh_git_helper_ready` false-positive** — `seed-claude-plugins.sh:84-85`
  (discussions r3540512091 and r3540528814 this round; re-raise of resolved
  r3539665707). The check accepts any global `gh auth git-credential`
  helper, so a host `.gitconfig` copied into the container (`entrypoint-core.sh` seeds
  `GIT_CONFIG_GLOBAL` from the host copy before running its own `gh auth setup-git`)
  that carries an absolute helper path such as `/opt/homebrew/bin/gh auth
  git-credential` reads as "auth ready" — even though that path does not exist in the
  container — so the private clone starts with a broken helper, fails, and does not
  retry after the container-local helper is installed. Removing `gh_git_helper_ready`
  (public repo → no helper needed) removes the false-positive entirely.
- **No same-boot retry after slow pre-auth startup** — `seed-claude-plugins.sh:198`
  (discussion r3540528816 this round; re-raise of resolved r3539665715). When
  `gh auth setup-git` has not run within `AUTH_WAIT`
  (e.g. a large or root-owned workspace whose pre-auth heal/safe.directory loop exceeds
  the 25s default), the single install attempt runs with `GIT_TERMINAL_PROMPT=0` before
  the helper exists, fails, and only self-heals on the next start. Making the cold
  install synchronous with no auth dependency (public repo) removes the timing window
  and the need for an in-boot retry.
- **Cold plugin installed after Claude starts (first-session invisibility)** —
  `entrypoint-claude-hook.sh:135` (discussion r3540528818 this round; re-raise of the
  earlier resolved cold-install threads r3537771174 / r3538614735). Because the hook
  detaches `seed-claude-plugins.sh` and then `exec`s Claude, a cold-volume install can
  still be running during Claude's startup plugin scan, so the `/dev-skills:*` skills
  are absent until a manual `/reload-plugins` or a restart. This is precisely the gap
  this task closes: the synchronous, bounded cold install before `exec claude`
  (solution step 1) makes the skills live in the first session with no reload.

## Logging

Because the cold install is now **synchronous before the TUI starts**, its output
appears on the normal terminal *before* Claude grabs the alternate screen buffer —
so a single concise status line ("installing dev-skills plugin… done") is fine and
even helpful. Keep everything else as debug to
`$AGENT_CONFIG_DIR/.powbox-plugin-bootstrap.log`. Do **not** invest in mid-session
user hints: a backgrounded job's stdout cannot pierce the alternate buffer (it is
visible only after session end), so hint-based approaches are useless here.

## Acceptance

- **Cold volume + network:** on a fresh container with a fresh `claude-config`
  volume, the eight `/dev-skills:*` skills are invocable in the **first** session —
  both as `/dev-skills:<name>` slash commands **and** via model-side Skill-tool
  description matching — with **no** `/reload-plugins` or restart.
- **Never-block preserved:** on a slow/offline cold start the synchronous install is
  bounded and degrades to the background self-heal; the container prompt is never
  wedged.
- **Warm starts unchanged:** cheap async keep-current, no added latency; the
  one-session update staleness is accepted and documented (user reloads).
- **Offline cold start** still starts normally and self-heals on a later online
  start (skills are irrelevant offline — the CLI cannot reach the API anyway).
- **Cleanup verified:** no code path waits on or requires the `gh` credential helper
  for the agent-skills clone; `wait_for_github_auth` / `gh_git_helper_ready` /
  `AUTH_WAIT` are gone; `flock`, `CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE=1`,
  and `GIT_TERMINAL_PROMPT=0` remain; `docs/entrypoint-and-runtime.md` reflects the
  synchronous cold-install model.
