# Task 015h — Keep non-primary Claude plugin network ops behind the firewall

**Status: RESOLVED in PR #95** (fixed in-branch rather than deferred). Originally parked in
`tasks/deferred/` during the 015g review-addressing pass, then pulled forward when the maintainer
chose to fix it directly. Archived here with the chosen approach recorded below.

Follow-up to **Task 015g** (synchronous first-session dev-skills plugin install on cold volumes, PR #95).

## Background — the ordering gap (as found)

`seed-claude-plugins.sh` decided sync-vs-async per plugin state, and two of its branches called
`spawn_background` immediately — the `enabled` warm keep-current branch and the (then-new)
non-primary cold branch. When Claude is **non-primary** (`PRIMARY_AGENT=codex`), the Claude hook
runs from `entrypoint-agent.sh`'s non-primary-seeding loop, which runs **before** it `exec`s
`entrypoint-core.sh` — and `init-firewall.sh` only runs at the **start of `entrypoint-core.sh`**. So
the detached plugin run and the firewall raced: the plugin's network op (`marketplace add`/`install`
/`update`, all to the **public** `Roubtec/agent-skills` over HTTPS) could execute **before** the
firewall's egress rules were installed, violating the ordering invariant that container network work
should not happen ahead of the firewall.

Pre-015g this was masked by accident: the old bootstrap waited for the `gh auth git-credential`
helper, registered by `entrypoint-core.sh` **after** `init-firewall.sh`, which deferred network ops
past the firewall as a side effect. 015g removed that auth-wait (the repo is now public), removing
the implicit gate.

Review thread: https://github.com/Roubtec/powbox/pull/95#discussion_r3543751047 (codex, P1).

## Adjacent-invariant audit (done before the fix)

Swept every pre-firewall seeding path for other network ops: the sibling non-primary hook
`entrypoint-codex-hook.sh` does **no** network work (only local `seed-skills.sh` copies), and
`entrypoint-core.sh` runs the firewall as its first action with nothing network before it. So the
Claude plugin bootstrap was the **sole** violator of the "network only after the firewall" invariant
— which is why the fix below fully closes the gap.

## Chosen approach — move the non-primary spawn past the firewall

Selected by the maintainer (over "skip the non-primary install entirely" and the originally-drafted
"firewall-readiness marker + bounded wait"). It reuses the exact mechanism the primary path already
relies on — sequential ordering inside `entrypoint-core.sh` — instead of adding a marker/wait:

1. **`entrypoint-claude-hook.sh`** — invoke the plugin bootstrap inline **only when Claude is the
   primary agent** (that hook runs from `entrypoint-core.sh`, post-firewall). When Claude is
   non-primary, the hook (running pre-firewall in `entrypoint-agent.sh`) **skips the plugin
   entirely** and logs the hand-off.
2. **`entrypoint-core.sh`** — immediately **after** `init-firewall.sh`, if `PRIMARY_AGENT != claude`
   and `claude` is present, re-invoke `seed-claude-plugins.sh` **detached** (`setsid`,
   `POWBOX_PLUGIN_BACKGROUND=1`, log pointed at `CLAUDE_CONFIG_DIR`). This converges the non-primary
   Claude plugin from the patient background branch — network ops **ordered after the firewall** and
   **off the Codex prompt's critical path**.
3. **`seed-claude-plugins.sh`** — since the primary/non-primary decision now lives entirely in the
   entrypoint layer, the `POWBOX_PLUGIN_ALLOW_SYNC_COLD` gate that 015g added was **removed** and the
   `absent` foreground case simplified back to the plain cold install (only ever reached from the
   post-firewall primary-Claude hook).

### Considered & declined

- **Skip the non-primary install entirely.** Simplest, and the maintainer noted a Codex-primary
  container rarely needs dev-skills (a delegated `claude -p` for a second opinion is unlikely to
  invoke skills). Declined in favour of keeping the skills self-healing for delegated Claude at
  near-zero extra cost.
- **Firewall-readiness marker + bounded wait** (the original 015h draft). Correct but heavier —
  touches the security-critical `init-firewall.sh`, and re-introduces an async wait the "move past
  the firewall" approach avoids entirely.

## Acceptance (met)

- With `PRIMARY_AGENT=codex`, the non-primary Claude plugin's network ops are ordered **after**
  `init-firewall.sh` (spawned from `entrypoint-core.sh` post-firewall), and the skills still land for
  the next in-container Claude session.
- Primary-Claude cold first-session latency unchanged (its hook path is untouched).
- Best-effort throughout: a missing `setsid`/`claude` degrades gracefully and never wedges start.
- `shellcheck --severity=error` clean on the three changed shell files.
