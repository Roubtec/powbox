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
code. The orchestration primitives are `agent(prompt, opts)`, `parallel(thunks)`,
`pipeline(items, ...stages)`, `phase()`, `log()`, and the `args` global. The
script itself does no file/shell/git work and takes no mid-run user input —
every side effect happens inside an agent, and a blocker is returned, never
prompted.

The division of labor is three layers, each owning what it is best at:

| Layer | Owns | Form |
|-------|------|------|
| workflow script | control flow: waves, round caps, dependency gating, throttling | deterministic JS |
| spawned agents | judgment: implement, review, decide, write PR bodies | prompts |
| `wt-*` helpers | mechanics: worktree lifecycle, root-safety checks, rerun-safe git plumbing | image-baked shell (`wt-bootstrap`, `wt-enter`, `wt-remove`) |

The helpers are the same scripts the `*-worktrees` skills call (baked by the
base image from `docker/shared/`), so the hard-won mechanics exist exactly
once: a prompt asks an agent to run `wt-enter <slug> <branch> <base>`, not to
re-derive the lifecycle from prose. Workflows therefore **require an image
new enough to bake the `wt-*` helpers**; the bootstrap stage detects an older
image and reports a blocker instead of falling back to hand-rolled git.

### Worktrees: explicit convention, not runtime `isolation`

The runtime offers `agent(..., { isolation: "worktree" })`, but these workflows
deliberately **do not use it**. Per the
[worktrees docs](https://code.claude.com/docs/en/worktrees) it creates a fresh
temporary worktree per agent at a runtime-chosen path (default
`.claude/worktrees/`), started from the repository's **default branch**, with no
documented `agent()` option, env var, or setting to redirect it. That breaks two
things powbox needs:

1. **It cannot honor the `.worktrees/$CONTAINER_NAME/<slug>` convention** — the
   per-container subdir on the persistent project volume that carries the pnpm
   hardlink store and lets a Claude and a Codex container share one repo without
   a peer's prune reaping live work. Runtime worktrees would land in the
   tmpfs-shadowed `.claude/worktrees/` (full package copies, a shared ~2 GB cap).
2. **A separate worktree per agent, started from the default branch, hides an
   implementer's commits from its reviewer.**

So `address-tasks.js` manages worktrees itself, through the same `wt-*` helpers
the `address-tasks-worktrees` skill calls: a bootstrap agent runs `wt-bootstrap`
(root-safety checks, container-scoped orphan prune, remote probe — one JSON
result), then each task gets **one** explicit worktree under
`.worktrees/$CONTAINER_NAME/<slug>`, resolved rerun-safely by `wt-enter`:
created off the base by its first implementer, reused by that task's reviewer
and every later round. Stages that must not create work (reviewer, PR) call
`wt-enter` *without* a base, so a missing branch is an error rather than a
silent empty checkout. Cross-task parallelism comes from `parallel()` over
distinct worktrees; cross-stage commit visibility comes from sharing the
on-disk worktree, not the remote.

`address-review.js` is a single-PR, strictly sequential pipeline with no
fan-out, so it needs no worktree at all — every stage runs on the PR branch in
the one working tree, which is the simplest way to keep the fixer's commits
visible to the reviewer and publisher.

### `address-tasks.js` — the fan-out implement/review loop

The `address-tasks` skill's dominant constraint is that every subagent shares
the orchestrator's one working tree, which forces strict one-at-a-time
sequencing; `address-tasks-worktrees` exists to claw parallelism back with its
own worktree-per-task bootstrap. This workflow folds both into one: it runs the
same explicit `.worktrees/$CONTAINER_NAME/<slug>` worktree-per-task model (see
"Worktrees" above), but expresses the orchestration — dependency waves gated on
their prerequisites, the 3-round implement→review→fix loop, "implementer
finishes before its reviewer" — as deterministic JavaScript rather than prose.
Independent tasks run concurrently via `parallel()` over distinct worktrees.

It also ports the skill's **adaptive throttling** ("finish over fan-out") as
code: wave width is the minimum of the dependency-derived size, a hard cap, and
a storage cap computed from `wt-bootstrap`'s `availBytes`; an over-wide wave is
run in sub-batches and the throttling decision is reported in the summary.

**It does not yet fully supersede `address-tasks-worktrees`.** This conversion
stops after per-task PR creation; it omits that skill's post-batch
`review-stack/...` construction — the integration-conflict check and recommended
merge-order artifact for batches with two or more mergeable branches. Adding
that final phase (it would delegate to `rebase-stack` in a subagent) is tracked
as follow-up work before this could replace the skill outright.

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
2. **Agent worktree management under the runtime.** `address-tasks.js` has its
   agents run `wt-enter` / `cd` themselves (see "Worktrees" above) rather than
   using runtime isolation. The load-bearing assumption is that a
   workflow-spawned agent runs in the repo working directory with a shared
   filesystem — so one agent's explicit worktree persists for the next agent of
   the same task to `cd` into. That matches how `Agent`-tool subagents behave in
   the same container, but should be confirmed against the live workflow runtime.
3. **Refresh parity.** Seeding is a simple no-clobber file copy (delete the file
   to re-seed). It does not yet participate in `agent-update-skills`' marker /
   refresh / prune flow; wiring that in is the obvious follow-up if the shape
   proves out.
