# 086 — Point delegated peer reviews at `peer-review-run` in the container instructions

**Relates to:** the "Delegating to another agent" section of `docker/shared/container-agent.md.tmpl`, the `AGENT_ONESHOT` fragments in `docker/shared/entrypoint-agent.sh`, `docker/shared/peer-review-run`, and README "Cross-Agent Delegation".

## Why this task exists

`peer-review-run` exists so that launching a peer review takes no thought and is right every time: the prompt goes in from a file on stdin, the provider runs under a supervised deadline, its process tree is reaped, and the caller gets one normalized result. The README and `docs/architecture.md` describe it. The instruction file an agent actually receives does not contain its name. An agent working in some other project never reads powbox's README, so all it learns is the raw one-shot form of each peer.

Agents therefore hand-roll peer launches and rediscover, one session at a time, the hazards the helper already solves:

- The printed `codex exec` form, started as a background command, waits on a stdin that never closes, because Codex reads piped stdin as part of the prompt. It looks like a slow review until someone notices that it never started.
- A hand-launched peer has no deadline and no completion signal, so it gets stopped by process-name pattern, which can also hit an unrelated process or a poller left behind by an earlier session.
- A reviewer told to read a pull request's threads, or to fetch anything, cannot: the read-only Codex sandbox has no network. Nothing in the instructions or in the helper's own header says so.

Long review batches in more than one project lost time to each of these.

## Goal

An agent that wants a second opinion on a change reaches for `peer-review-run` without weighing alternatives, because the text it always loads names the helper as the way to run a delegated review. Any raw one-shot form that stays printed is safe to paste into a background command exactly as written. The instructions say that a read-only Codex peer is offline, so whatever it needs from the network has to be put into its prompt.

## Direction and constraints

- Strengthen the single path, rather than adding guidance around the raw forms. The raw forms stay legitimate for sub-tasks that are not reviews. Once the helper is the named route for reviews, ask how much review-specific detail in each fragment still earns its place.
- The helper serves every provider through one interface, and the `AGENT_ONESHOT` fragments reach an agent only through `${AGENT_PEERS}`, with Muse listed only when it is baked. The pointer therefore belongs in the shared template text, not in each fragment.
- Do not restate the helper's usage. Its header already carries the wait-budget pairings. At most, point at them: a helper call killed by the harness's foreground cap returns no result and may leave its provider running, and that is the one thing a caller cannot learn from the result.
- Check every printed one-shot form for the open-stdin hazard instead of assuming it is Codex-only.
- Say how to stop a peer in one clause: wait on the helper or on a PID you recorded, never on a pattern.
- State the offline sandbox where the helper documents itself as well, since a caller assembling a review prompt reads that.
- The always-loaded text is already long, so this addition has to be short. Task 092 restructures that text and treats this pointer as part of what stays always loaded.
- Landmine: suites and smoke stages read the template and the rendered instruction files (`scripts/test-stage-agent-template.sh`, `scripts/test-rm-prompt-bypass.sh`, Tier 1's seeded-template check). The README and `docs/architecture.md` describe the delegation text too.
- Launch recipes inside the skills live in `Roubtec/agent-skills` and are out of scope here.
