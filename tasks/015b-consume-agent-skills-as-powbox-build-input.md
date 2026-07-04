# 015b — Consume agent-skills as a powbox build input

## Why this task exists

With the shared skills now living in `Roubtec/agent-skills` (task 015a), powbox
must stop being their home and start being a consumer: the Codex flavors and
the two powbox-specific skills keep flowing through the existing image-bake +
volume-seed machinery, while the 8 migrated Claude flavors leave the bake
entirely (they arrive via the plugin channel in task 015c).

## Scope

**In scope:**
- Fetching `Roubtec/agent-skills` main during the powbox image build.
- Baking `codex/dev-skills/skills/*` into the image's Codex seed dir alongside
  the remaining in-tree powbox-specific Codex skills.
- Removing the 8 migrated skills from the **Claude** bake.
- Deleting the migrated skill sources from the powbox tree.

**Out of scope:**
- Installing/updating the Claude plugin inside containers (task 015c).
- Pruning already-seeded volumes and doc updates (task 015d).

## Context and references

- **Prerequisite:** task 015a's PR is merged to `agent-skills` main.
- Powbox paths: `docker/claude/agent-container/skills/`,
  `docker/codex/agent-container/skills/`, `docker/shared/seed-skills.sh`,
  `docker/shared/entrypoint-{claude,codex}-hook.sh`,
  `docker/shared/update-skills-incontainer.sh`, `build.sh` (target `agent`,
  image `powbox-agent:latest`).
- The seed/refresh machinery keys on what is baked into the image: items it
  seeded carry a `.powbox-seeded` marker, and marked items **no longer baked**
  are classified as orphans that `commands/update-skills.sh --prune` removes.
  Removing the 8 Claude skills from the bake is what makes task 015d's prune work
  — no changes to the classification logic should be needed.

## Implementation notes

1. **Fetch mechanism — prefer host-side fetch in `build.sh`:** the repo is
   currently **private**, so a `RUN git clone` inside the Dockerfile would need
   credentials plumbed into the build; instead, have `build.sh agent` (which
   runs on the host where gh auth exists) shallow-clone/refresh
   `Roubtec/agent-skills` main into a build-context staging dir (gitignored),
   which the Dockerfile `COPY`s. Do **not** use a git submodule. Record the
   baked agent-skills commit SHA (e.g. a file in the image next to the seed
   dirs, or via the existing `powbox-provenance` mechanism) so a container can
   tell which snapshot it carries. Document the mechanism where build.sh is
   documented. Note in a comment that the clone URL keeps working unchanged
   when the repo later flips public.
2. **Codex bake:** the image's Codex seed dir must end up containing the union
   of `agent-skills:codex/dev-skills/skills/*` (8 skills) and the in-tree
   powbox-specific Codex skills (`enable-worktrees`, `session-learnings`) —
   same 10-name palette on the codex-config volume as before, same seed and
   refresh behavior. Watch for name collisions in the union step (there should
   be none after task 015a; fail the build loudly if one appears).
3. **Claude bake:** only `enable-worktrees` and `session-learnings` remain
   baked for Claude. The 8 migrated names must NOT be baked — that is the
   signal update-skills.sh uses to retire the stale volume copies.
4. **Source deletion:** remove the 8 migrated skills from BOTH
   `docker/claude/agent-container/skills/` and
   `docker/codex/agent-container/skills/` in the same PR, so the repo can't
   drift from agent-skills. The 2 powbox-specific skills stay in-tree in both
   flavor dirs.
5. If any powbox script enumerates skill names statically (check
   `container-agent.md.tmpl`, docs, tests), update those references — but the
   docs rewrite proper is task 015d.

## Target files or areas

Powbox repo: `build.sh`, `docker/agent/Dockerfile` (or wherever the skill
dirs are COPYed), `docker/claude/agent-container/skills/`,
`docker/codex/agent-container/skills/`, `.gitignore` (staging dir), possibly
`docker/shared/powbox-provenance`.

## Acceptance criteria

- `build.sh agent` succeeds from a clean checkout and produces an image whose
  Codex seed dir contains all 10 skills (8 from agent-skills + 2 in-tree) and
  whose Claude seed dir contains exactly `enable-worktrees` and
  `session-learnings`.
- The build fails with a clear message if the agent-skills fetch fails
  (no silent stale/empty seed dirs).
- The baked agent-skills commit SHA is discoverable from inside a container.
- The 8 migrated skill sources are deleted from both powbox flavor dirs.

## Validation

- Build the image; `docker run --rm --entrypoint ls powbox-agent:latest
  <claude-seed-dir> <codex-seed-dir>` shows the expected sets.
- Start a fresh container with a **throwaway** codex-config volume: all 10
  Codex skills seed with `.powbox-seeded` markers.
- `commands/update-skills.sh --dry-run` against existing volumes reports the 8
  migrated Claude skills as orphans (do not prune yet — that is task 015d).

## Review plan

Reviewer checks the fetch mechanism (credentials never baked into the image,
build fails loudly on fetch errors), verifies the seed-dir contents of a built
image, and confirms the source deletions match exactly the set migrated in
task 015a.
