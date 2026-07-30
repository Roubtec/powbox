# Task 045 — Container docs: tell the truth about --isolated workspaces and the shared scratchpad

## Why this task exists

Two places where the container guidance says something an agent can act on incorrectly:

1. **Workspace kind.** `docker/shared/container-agent.md.tmpl` says the host filesystem is reachable "through the bind mount under `/workspace`" and the file-layout table calls `/workspace/<project-slug>` "bind-mounted from host" unconditionally. In a self-hosted `--isolated` workspace that path is a Docker **volume** (`agent-ws-*`) and nothing written there reaches the user's disk. An agent reasoning from this prose (rather than from `POWBOX_WORKSPACE_HOST_PATH`, which the `session-learnings` skill correctly checks) chooses "local file" transport for artifacts the user then cannot reach — observed in an isolated kalm2 container, caught only by the user's instinct to say "use ferry".
2. **Scratchpad sharing.** The harness system prompt describes the scratchpad as "session-specific, isolated from the user's project", and nothing in powbox's guidance warns that it is **one directory shared by every concurrently running subagent in the session**. Fixed-name scratch files have produced real cross-contamination: two parallel reviewers both writing `<scratchpad>/verify.log` (one validated the other's worktree), and parallel PR fixers clobbering each other's `threads.json`. The skills get hygiene rules upstream (agent-skills), but the container docs are where an agent looks first.

## Scope

Included, all in `docker/shared/container-agent.md.tmpl` (and README if it repeats the claims):

- Qualify the bind-mount statements: dir-mounted mode is a host bind mount; `--isolated` mode is a container-local volume with **no host visibility**; name `POWBOX_WORKSPACE_HOST_PATH` (set and non-empty ⇒ host bind mount; unset ⇒ container-local) as the authoritative runtime signal, in both the intro paragraph and the file-layout table rows for `/workspace/<project-slug>`.
- Add a short "Scratchpad discipline" note near the delegation/worktree guidance: the session scratchpad is shared across all concurrent subagents; any artifact written there by parallel work MUST have a per-task unique name (worktree slug, PR number, or PID suffix) or live in a per-task subdirectory; fixed names like `verify.log` / `threads.json` are how parallel runs silently read each other's output.
- Check whether the template is the right single place or whether `docker/claude/agent-container/` seeds a separate CLAUDE.md fragment that repeats the bind-mount claim; sweep all copies.

Out of scope:

- Harness changes (per-subagent scratchpad namespacing is an upstream Claude Code concern).
- Skill-level hygiene rules (tasked in `Roubtec/agent-skills`).

## Context and references

- `docker/shared/container-agent.md.tmpl:3` (intro), `:67` (layout table) — the unconditional bind-mount claims.
- `docker/claude/agent-container/skills/session-learnings/SKILL.md` step 3 — the env-var check the prose should point at (the skill is already correct; the docs contradict it).
- README "Self-Hosted Mode" — the isolated-mode reference to link.

## Target files or areas

- `docker/shared/container-agent.md.tmpl`
- README.md (only if it repeats the claims)

## Implementation notes

- Keep the additions tight — this template loads into every session's context; a sentence each in the intro and table, and a 3–4 line scratchpad note, is the right budget.
- The template is rendered with `envsubst`-style substitution; plain prose additions are safe, but do not introduce `${...}` sequences that look like variables.

## Acceptance criteria

- No remaining unconditional "bind-mounted from host" claim about `/workspace/<project-slug>`; `POWBOX_WORKSPACE_HOST_PATH` is named as the check.
- The scratchpad-sharing warning with the unique-name rule is present.
- All copies/fragments repeating the claim are updated.

## Validation

- `grep -rn 'bind-mounted from host' docker/ README.md` shows only qualified statements.
- Template renders (container start path) without substitution errors — covered by dirmount smoke on a rebuilt image; in-container, eyeball the rendered `/home/node/.claude/CLAUDE.md` shape against the template diff.

## Review plan

Reviewer confirms the prose now matches the `session-learnings` skill's env-var logic, and that the scratchpad note gives the concrete failure mode (shared dir, fixed filename) rather than a vague caution.
