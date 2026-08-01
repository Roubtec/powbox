# Task 051 — Merge prerequisites for forfeiting skills and workflows to agent-skills

## Why this task exists

Branch `forfeit-skills-and-workflows-to-agent-skills` removes powbox's last in-tree skills (`enable-worktrees`, `session-learnings`, for both harnesses) and the Claude dynamic workflows (`wf-address-review.js`, `wf-address-tasks.js`), making `Roubtec/agent-skills` the single source of truth for all of them.
After that branch, powbox bakes its whole Codex palette from the agent-skills clone and seeds NOTHING for Claude — so merging it before agent-skills actually ships the relocated items would leave containers without those skills (Codex bake missing two skills; Claude losing the workflows entirely).
This file records the hard ordering so the branch is not merged early.

## Merge prerequisites (all in `Roubtec/agent-skills`, all BEFORE merging this branch)

1. **The two `wf-*` workflows ship under `plugins/dev-skills/workflows/`** (`wf-address-review.js`, `wf-address-tasks.js`), delivered by the `dev-skills` plugin. Note the invocation rename: the seeded copies answered bare `/wf-address-tasks` / `/wf-address-review`; the plugin-delivered ones are namespaced `/dev-skills:wf-address-tasks` / `/dev-skills:wf-address-review`. The durable workflow-authoring notes from the deleted `docker/claude/agent-container/workflows/README.md` (runtime availability/`enableWorkflows` gating, `export const meta` first-statement requirement, determinism constraints) should travel with the workflow sources; the powbox-specific worktree contract stays documented in powbox's README "Claude Dynamic Workflows".
2. **`enable-worktrees` and `session-learnings` ship as plugin skills for Claude** (under the dev-skills plugin, invoked `/dev-skills:enable-worktrees`, `/dev-skills:session-learnings`) **and as `codex/dev-skills/skills/` mirrors for Codex** (each with its `agents/openai.yaml`), so the powbox Codex bake and the start-time clone sync pick them up with no powbox-side change.
3. **A marketplace release consumers can pull** — the agent-skills manifests are versionless, so this means the above merged to `main` (every `main` commit is the release the plugin bootstrap and the powbox build fetch).

See agent-skills tasks 012 (the relocation of these skills/workflows into agent-skills) and 014 (the review-cycle extraction those task files are being written alongside).

## Additional couplings the agent-skills side must cover

- **Workflow unit-test coverage moved with the source:** powbox deleted `scripts/test-checkout-cleanliness-report.mjs`, the focused unit test for `wf-address-tasks.js`'s `mainCheckoutSummary` (the non-destructive shared-main-checkout cleanliness report). Agent-skills should adopt an equivalent test next to the workflow it exercises, or that regression guard is lost.
- **The workflows depend on powbox-baked helpers:** `wt-bootstrap`/`wt-enter`/`wt-remove`, `gitcat`, `peer-review-run`, and `gh-review-threads` remain powbox-owned (agent-layer bakes; `gh-review-threads` is itself vendored in agent-skills `plugins/dev-skills/bin/`). The workflow prompts must keep calling these helpers by name rather than restating the mechanics, and a non-powbox plugin consumer without them gets the workflows' documented blocker behavior, not silent fallback.
- **Open powbox tasks re-homed or split:** tasks 041 (peer-review stage in the `wf-*` workflows) and 029a (peer `VERDICT: PASS` notes) had no powbox-side surface left once the workflows moved — every peer-prompt constructor and every `wf-*` edit site is now in agent-skills — so both were deleted here and re-homed there: 041 as agent-skills 014a (the workflow-rendering residue that its 014/015 do not state) and 029a verbatim as agent-skills 015a. Task 047's `wf-check` fixtures must come from the agent-skills copies, and task 043 carries a relocation note adjusting its powbox scope; both stay here because their deliverables (baked helpers, seed markers) remain powbox-owned.

## What needs no coordination

- `agent-update-skills --prune` retires the previously-seeded Claude copies (the two skills, the `wf-*.js` files, and their sidecar markers) from existing config volumes; the updater's orphan sweep handles baked source dirs that no longer exist. See docs/skills-refresh-and-provenance.md "Forfeit update".
- The Codex plugin-clone sync required no interface change: its bake-owned denylist for the two skills was removed, so they now refresh from the clone like every other shared skill.

## Acceptance

- Agent-skills `main` carries (1)-(3) above.
- A host image rebuild (`./build.sh agent`) succeeds and `powbox-provenance` records the agent-skills SHA that includes the relocated items; the baked Codex palette contains `enable-worktrees` and `session-learnings`.
- A fresh Claude session in a rebuilt container lists `/dev-skills:wf-address-tasks`, `/dev-skills:wf-address-review`, `/dev-skills:enable-worktrees`, and `/dev-skills:session-learnings`.
