# Claude Dynamic Workflows (experimental)

Claude-only counterparts to some of the image-baked skills, expressed as
[dynamic workflows](https://code.claude.com/docs/en/workflows) — JavaScript
orchestration scripts the runtime executes in the background, spawning and
sequencing subagents at scale.
Codex has no workflow runtime, so this directory has no Codex sibling; the
entrypoint seeds these into `~/.claude/workflows/` (Claude config volume) only.

This is a **testing batch** to evaluate the shape, seeded alongside — not in
place of — the existing skills. See the open questions at the bottom.

## Why these, and what the workflow shape buys us

A dynamic workflow turns the *control flow* a skill describes in prose into real
code, and — crucially — hands each spawned agent its own git worktree
(`isolation: "worktree"`). The orchestration primitives are `agent(prompt, opts)`,
`parallel(thunks)`, `pipeline(items, ...stages)`, `phase()`, `log()`, and the
`args` global. The script itself does no file/shell/git work and takes no
mid-run user input — every side effect happens inside an agent, and a blocker is
returned, never prompted.

### `address-tasks.js` — supersedes two skills at once

The `address-tasks` skill's dominant constraint is that every subagent shares
the orchestrator's one working tree, which forces strict one-at-a-time
sequencing and is the entire reason `address-tasks-worktrees` exists (≈150 lines
of shadow-mount/worktree bootstrap to claw parallelism back). The runtime's
per-agent worktree isolation removes that constraint structurally, so a single
workflow covers **both** skills: independent tasks run concurrently, the
implementer-finishes-before-its-reviewer rule is just a sequential `await`
inside a per-task function, and the dependency waves / 3-round loop are ordinary
JavaScript.

### `address-review.js` — the verify-loop + conditional publish

`address-review`'s interesting part is its bounded verify-and-loop cycle and a
publish stage gated on flags. That is naturally a workflow. Because workflows
have no mid-run input, this is structurally the skill's `hands-off` mode:
low-stakes ambiguity is decided best-effort and recorded; high-stakes ambiguity
is left open and reported. (A batch-of-PRs front end — today's
`address-reviews-worktrees` — would be one workflow run per PR.)

### Not converted: `rebase-stack`

`rebase-stack` is intentionally left as a skill. It is a single-worktree,
strictly sequential, per-branch procedure whose hard parts are interactive
conflict judgment and up-front user confirmation. The workflow model — no
mid-run input, no script-level shell/file IO, value coming from fanning out
*many* agents — fights all three: you would wrap one sequential agent in a
workflow for no orchestration gain and lose the interactive conflict loop. Its
existing `delegated-fix`/unattended mode already covers the only case a workflow
would want to call it.

## Open questions (for the "where to go from there" conversation)

1. **Namespace overlap.** A workflow and a skill with the same name both answer
   `/address-tasks`. These keep the canonical names for a faithful comparison;
   when promoting, we'd likely retire the Claude skill copies (the Codex skills
   stay).
2. **Runtime worktree semantics.** The conversions assume `isolation: "worktree"`
   plus push-every-commit makes branches/commits durable across the runtime's
   worktree lifecycle, and that a reviewer agent checking out a pushed branch
   sees the implementer's commits. Validate against the live runtime — these are
   the load-bearing assumptions.
3. **Refresh parity.** Seeding is a simple no-clobber file copy (delete the file
   to re-seed). It does not yet participate in `agent-update-skills`' marker /
   refresh / prune flow; wiring that in is the obvious follow-up if the shape
   proves out.
