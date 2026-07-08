# Task 015h — Keep non-primary Claude plugin network ops behind the firewall

Follow-up to **Task 015g** (synchronous first-session dev-skills plugin install on cold volumes, PR #95). Parked in `tasks/deferred/` because the branch is defendable as-is: the *primary*-Claude cold-install path — the actual subject of 015g — is firewall-safe, and the residual gap below only affects **non-primary** Claude (i.e. `PRIMARY_AGENT=codex`) containers, targets a **hardcoded public** GitHub repo, and a correct fix needs a new firewall-readiness signal (a design decision that re-introduces a small async wait 015g otherwise removed) — too much to fold into a review-fix commit.

## Background — the ordering gap

`seed-claude-plugins.sh` decides sync-vs-async per plugin state. Two of its branches call `spawn_background` **immediately** (fire-and-forget), and that detached run does network work (`claude plugin marketplace add`/`install`, or `marketplace update`/`plugin update`) as soon as it starts:

- the `enabled` warm keep-current branch in `main()` (`spawn_background`), and
- the new **non-primary cold** branch — `absent` with `ALLOW_SYNC_COLD != 1` — added by 015g.

When Claude is **non-primary** (`PRIMARY_AGENT=codex`), this hook runs from `entrypoint-agent.sh`'s non-primary-seeding loop, which runs **before** it `exec`s `entrypoint-core.sh` — and `init-firewall.sh` only runs at the **start of `entrypoint-core.sh`**. So the detached plugin run and the firewall race: the plugin's network op can execute **before** the firewall's egress rules are installed, violating the defense-in-depth ordering that container network work should not happen ahead of the firewall.

Pre-015g this was masked by accident: the old bootstrap waited for the `gh auth git-credential` helper (`wait_for_github_auth`), and that helper is registered by `entrypoint-core.sh` **after** `init-firewall.sh`, so the wait deferred network ops past the firewall as a side effect. 015g removed that auth-wait (the repo is now public and needs no credentials), which also removed the implicit firewall gate for the non-primary case.

Review thread: https://github.com/Roubtec/powbox/pull/95#discussion_r3543751047 (codex, P1).

## Why deferral is safe (scope of the residual risk)

- **Primary Claude is unaffected.** Its hook runs from `entrypoint-core.sh` **after** `init-firewall.sh`, so the synchronous cold install 015g adds already runs post-firewall.
- **Low practical exposure.** The only network target is the hardcoded **public** `Roubtec/agent-skills` clone over HTTPS to `github.com`; `init-firewall.sh` blocks only private/LAN/CGNAT ranges (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `100.64/10`, IPv6 ULA/link-local) and always allows public egress — so the plugin op reaches the same destination whether it runs before or after the firewall, and never touches a blocked range. The concern is the ordering **invariant**, not a currently-exploitable hole.
- **Branch builds and covers its main paths**, so 015g is defendable while this is tracked separately.

The 015g source comments that describe the non-primary case have been corrected on the PR branch to state the ordering is not yet guaranteed and to point here, rather than implying that backgrounding alone keeps network ops behind the firewall.

## Goal

Guarantee that **no** plugin network op runs before `init-firewall.sh` has installed the egress rules, in every start configuration — including non-primary Claude seeded from `entrypoint-agent.sh`.

## Suggested approach

**Preferred — a firewall-ready marker the pre-firewall background run waits on.**
- Have `init-firewall.sh` write a readiness marker once its rules are applied (e.g. `touch` a well-known path such as `/run/powbox/firewall-ready`, created before the final "Firewall active" echo). Confirm the path is writable by the entrypoint's privileged firewall step and readable by the unprivileged `node` background run, and that it is per-boot (tmpfs/`/run`), not persisted across restarts.
- When `seed-claude-plugins.sh` spawns a background run **from a pre-firewall context**, pass a flag (e.g. `POWBOX_PLUGIN_WAIT_FIREWALL=1`). The entrypoint knows this context: the Claude hook is invoked from `entrypoint-agent.sh`'s non-primary loop (before the firewall) vs. `entrypoint-core.sh` (after). Set the flag only for the non-primary/pre-firewall invocation so the primary path keeps its current immediate behavior.
- In the background branch, when that flag is set, wait (bounded, best-effort — mirror the old `wait_for_github_auth` shape and bounds) for the marker before any network op; proceed anyway on timeout so an unexpectedly-missing marker never wedges self-heal.
- Keep the wait **out** of the primary-Claude foreground path (already post-firewall) so cold first-session latency is unchanged.

**Alternative — gate at the entrypoint.** Defer the non-primary Claude plugin *network* seeding until after `entrypoint-core.sh` has run the firewall (e.g. a post-firewall hook that runs the seed for already-seeded non-primary agents). Heavier: `entrypoint-core.sh` currently runs only the **primary** agent's setup hook, so this needs a new post-firewall non-primary seeding step.

## Acceptance

- With `PRIMARY_AGENT=codex` and a **cold** `claude-config` volume, the `dev-skills@roubtec` plugin's first network op is observably ordered **after** `init-firewall.sh` (e.g. asserted in a smoke test via timestamps in the bootstrap log vs. the firewall's "Firewall active" line, or a marker check), while the skills still land for the next in-container Claude session.
- The `enabled` warm keep-current path in a non-primary/pre-firewall start likewise waits for the firewall before `marketplace update`/`plugin update`.
- **Primary-Claude cold first-session latency is unchanged** (no new wait on that path).
- A missing/never-written firewall marker degrades to today's behavior (best-effort, self-heals next start) and never wedges start.
- Lint clean (shellcheck); the plugin-bootstrap smoke coverage exercises the non-primary ordering.
