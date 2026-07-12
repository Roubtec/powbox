# Persist Git Worktree Metadata with Persistent Worktrees

## Why this task exists

Dir-mounted powbox sessions keep task working trees in the persistent per-container `.worktrees` volume, but repository configurations produced by the worktree-enablement workflow tmpfs-shadow `.git/worktrees`, so stopping or recreating a container can preserve a dirty worktree directory while discarding the Git administrative metadata that makes it usable.

The mismatch was identified during review of [agent-skills PR #13](https://github.com/Roubtec/agent-skills/pull/13#discussion_r3562782537): after recreation, the linked worktree's `.git` file points to a missing `.git/worktrees/<name>` entry, `git status` fails, and `wt-bootstrap` may classify and remove the surviving directory as an orphan.

## Scope

- Make Git's per-worktree administrative metadata share the durability and lifecycle of the corresponding persistent `.worktrees` volume in dir-mounted mode.
- Preserve per-agent and per-project isolation so two agent containers for the same repository never share writable worktree metadata.
- Make restart/recreate recovery and orphan pruning distinguish recoverable persisted work from genuine stale directories.
- Update launcher/runtime behavior, worktree helpers, tests, and documentation needed to describe and verify the final design.
- Keep self-hosted mode working, where the clone, worktrees, and metadata already live inside one persistent workspace volume.

Out of scope: changing the agent-skills worktree orchestration protocol, making worktrees host-visible, or making the host repository consume container-created worktree registrations.

## Context and references

- `README.md`, "Workspace Shadow Mounts" and "Git Worktree Parallel Development", currently documents `.worktrees` as a persistent volume and `.git/worktrees` as tmpfs metadata.
- `docs/architecture.md`, "Volumes and Stores", defines the per-container volume ownership model.
- `docs/entrypoint-and-runtime.md` describes shadow setup and the dir-mounted versus self-hosted split.
- `scripts/launch-agent.sh` decides when and how the `agent-wt-*` worktrees volume is mounted.
- `docker/shared/detect-shadows.sh` and `docker/shared/shadow-mounts.sh` create the current `.git/worktrees` tmpfs shadow.
- `docker/shared/wt-bootstrap`, `wt-enter`, and `wt-remove` own worktree registration, recovery, and cleanup semantics.
- Review source: https://github.com/Roubtec/agent-skills/pull/13#discussion_r3562782537

## Target files or areas

- `scripts/launch-agent.sh` and the PowerShell launcher counterpart where volume declarations must remain symmetric.
- `docker/shared/entrypoint-core.sh`, `detect-shadows.sh`, and/or `shadow-mounts.sh` for mounting or restoring durable metadata without exposing it to the host checkout.
- `docker/shared/wt-bootstrap`, `wt-enter`, and `wt-remove` for restart recovery and safe orphan handling.
- `commands/prune-volumes.sh` **and** `commands/prune-volumes.ps1` (parity) plus related volume inventory/migration checks if the design introduces or renames a volume.
- `commands/smoke-test.sh`, `commands/smoke-test.ps1`, and focused pure-shell tests.
- `docker/shared/container-agent.md.tmpl` — the rendered in-container guidance currently tells agents the `.git/worktrees`/`.claude/worktrees` metadata roots are tmpfs shadows (Worktree helpers section); it must describe the new durability model or every new container keeps teaching the old one.
- `docker/claude/agent-container/skills/enable-worktrees/SKILL.md` and `docker/codex/agent-container/skills/enable-worktrees/SKILL.md` — the enablement skills declare the tmpfs shadow topology in `.powbox.yml` and health-check that those roots ARE tmpfs; unchanged, a later `enable-worktrees` run would re-declare the old model and report the new topology as unhealthy.
- `README.md`, `docs/architecture.md`, `docs/entrypoint-and-runtime.md`, and `docs/worktree-node-modules-hardlinks.md` (the latter currently codifies "worktree working dirs persistent, `.git/worktrees` metadata tmpfs" and records the rejection of its `A-coherent` alternative — this task effectively revisits that decision, so the chapter must be updated rather than left authoritatively recommending prune-on-recycle).

## Implementation notes

- Prefer co-locating metadata inside the existing per-container worktrees volume, or an equivalently lifecycle-coupled design, over a separately managed durable resource that can drift from the working-tree volume.
- Do not expose container worktree registrations through the host repository's real `.git/worktrees`; host and container Git state must remain isolated.
- Account for linked-worktree `.git` pointer files, Git's expected common-directory layout, Docker/Podman mount ordering, and the fact that mount destinations under a bind-mounted checkout must not leave host litter.
- Preserve rerun safety: restarting a container must reattach or rediscover valid registrations without rewriting branches or discarding dirty files.
- Migration from containers created before this change must fail safely or provide a clear recreation path; never delete an unmatched persistent worktree merely because its tmpfs metadata disappeared.
- Keep Bash and PowerShell launcher behavior aligned and update volume-staleness detection if the expected mount topology changes.

## Acceptance criteria

- Create a worktree in dir-mounted mode, leave tracked and untracked changes in it, stop/recreate the container, and confirm `git status` works in the same worktree with all changes preserved.
- `wt-bootstrap` after recreation retains recoverable persisted worktrees and prunes only directories proven stale; it never deletes the sole surviving copy of dirty work because metadata was lost.
- Worktree metadata is isolated per agent container and project, persists for exactly as long as its paired working-tree storage, and is removed by the corresponding cleanup/prune workflow.
- The host checkout does not gain container worktree registrations or unexpected `.git/worktrees`/mountpoint litter.
- Self-hosted mode and volatile/non-worktree projects retain their current behavior.
- Existing worktree helpers remain rerun-safe, and launcher parity checks cover Bash and PowerShell.
- Documentation no longer describes persistent working trees paired with ephemeral administrative metadata.

## Validation

- Add a focused pure-shell test for metadata placement, restart recovery inputs, and safe orphan classification where practical.
- Run `shellcheck` and `shfmt -d` on changed shell files.
- Run `pwsh -Command "Invoke-ScriptAnalyzer -Path ."` when PowerShell files change.
- Run the relevant pure-shell helper tests in-container.
- On the host or in Tier 1 CI, build the image and exercise a dir-mounted stop/recreate smoke with a dirty linked worktree, plus the existing self-hosted and worktree smoke coverage.

## Review plan

Reviewer should trace the complete lifecycle from launcher volume creation through entrypoint mounting, `git worktree add`, container recreation, bootstrap recovery, worktree removal, and volume pruning, with particular attention to never deleting dirty work or leaking registrations into the host repository.
