# 015a — Migrate the shareable skills into Roubtec/agent-skills

> **Batch note:** Execute in numeric order: 015a → 015b → 015c → 015d; 015e is a human checklist.
> Run from a powbox repo checkout with read/write access to powbox and https://github.com/Roubtec/agent-skills.

## Why this task exists

The shared dev-workflow skills currently live inside the powbox repo and reach
only powbox containers. They are moving to the standalone
`Roubtec/agent-skills` plugin-marketplace repo so colleagues (who don't use
powbox) can install them as the `dev-skills@agent-skills` Claude Code plugin,
while powbox keeps consuming the same content. This task populates that repo;
tasks 015b–015d rewire powbox afterwards.

## Scope

**In scope:**
- Portability audit of all 10 skills (both flavors) in the powbox repo.
- Copy the shareable set into `Roubtec/agent-skills`, generalizing
  powbox-specific text.
- Sensitivity pass, PR to `agent-skills` main.

**Out of scope:**
- Any change to the powbox repo itself (deletion of migrated sources happens in
  task 015b, after this PR merges).
- Renaming skills or changing their behavior beyond portability edits.

## Context and references

- Target repo: `https://github.com/Roubtec/agent-skills` (currently **private**;
  main = `a2f4758`). Already scaffolded: `.claude-plugin/marketplace.json`
  (marketplace name `agent-skills`, plugin entry `dev-skills` →
  `./plugins/dev-skills`), `plugins/dev-skills/.claude-plugin/plugin.json`
  (name `dev-skills`, **deliberately no `version` field** — Claude Code then
  versions by commit SHA, so every merge to main is a release), empty
  `plugins/dev-skills/skills/` and `codex/dev-skills/skills/` with `.gitkeep`
  placeholders, and a README documenting all of this. Read the README first.
- Source (powbox repo): `docker/claude/agent-container/skills/<name>/SKILL.md`
  (Claude flavors) and `docker/codex/agent-container/skills/<name>/`
  (Codex flavors: `SKILL.md` + `agents/openai.yaml` sidecar).

## Presumptive split (audit may adjust)

- **SHAREABLE — migrate both flavors (8):** `address-review`,
  `address-reviews`, `address-tasks`, `address-tasks-serialized`,
  `rebase-stack`, `resolve-open-questions`, `review-tasks`, `write-tasks`.
- **POWBOX-SPECIFIC — leave in powbox (2):** `enable-worktrees` (edits
  `.powbox.yml`, meaningless outside the sandbox), `session-learnings`
  (powbox retrospectives).

If the audit finds a skill in the shareable set that is irreducibly
powbox-bound, leave it in powbox and record the reasoning in the PR
description rather than forcing a bad generalization.

## Implementation notes

1. **Audit each shareable SKILL.md (both flavors)** for powbox-only
   assumptions: container paths (`/workspace/...`, volume layout), `.powbox.yml`,
   `wt-*` helper scripts, `pg-dev-up`, seeded-skill mechanics, "this container"
   phrasing. Generalize so the skill works for a colleague on a plain
   (non-containerized) machine. Worktree-based skills must degrade gracefully
   to vanilla `git worktree` usage — powbox conveniences may be mentioned as
   optional accelerators ("if available"), never as prerequisites.
2. **Placement:** Claude flavors → `plugins/dev-skills/skills/<name>/SKILL.md`;
   Codex flavors (SKILL.md **and** `agents/openai.yaml`) →
   `codex/dev-skills/skills/<name>/`. Remove the two `.gitkeep` files once real
   content exists. Keep `write-tasks` in both trees even though the flavors are
   currently byte-identical — tree uniformity beats deduplication here.
3. **Flavor parity:** where you generalize text, apply the equivalent edit to
   both flavors so they don't drift further than their deliberate harness
   differences. Check `agents/openai.yaml` contents for powbox references too.
4. **Cross-references between skills:** plugin skills are invoked namespaced
   (`/dev-skills:address-review`), but skill bodies referring to sibling skills
   by bare name ("use address-tasks") still resolve by description matching.
   Verify no skill hard-codes an invocation path that breaks under namespacing;
   also check references to the two skills that STAY in powbox (a shared skill
   telling colleagues to run `enable-worktrees` they don't have needs an
   "if available" qualifier).
5. **Sensitivity pass:** the repo will be flipped public after review. Scan the
   migrated text for anything that shouldn't be published (internal URLs,
   client/project names, credentials-adjacent detail) and list findings — even
   "none found" — in the PR description.
6. History does not migrate (plain copy, not `git filter-repo`); that is
   accepted. The powbox repo retains the history of the originals until task 015b
   deletes them.

## Target files or areas

- `Roubtec/agent-skills`: `plugins/dev-skills/skills/**`,
  `codex/dev-skills/skills/**`, possibly small README touch-ups if the audit
  changes the skill list.
- Powbox repo: **read-only** in this task.

## Acceptance criteria

- A PR against `agent-skills` main containing the 8 migrated skills in both
  flavor trees, `.gitkeep` files removed, no powbox-only prerequisites in any
  migrated SKILL.md.
- Each Codex skill dir carries its `agents/openai.yaml`.
- PR description includes: the final shareable/powbox split with reasoning for
  any deviation from the presumptive split, the list of generalization edits,
  and the sensitivity-pass findings.

## Validation

- `claude plugin marketplace add <local-clone-path>` +
  `claude plugin install dev-skills@agent-skills` against the PR branch clone;
  confirm all 8 skills appear as `/dev-skills:<name>` and one of them executes
  sensibly in a scratch repo outside any powbox container.
- JSON manifests still parse (`jq . .claude-plugin/marketplace.json`).

## Review plan

Reviewer diffs each migrated SKILL.md against its powbox original (expect only
portability/generalization edits), spot-checks flavor parity on two skills, and
reads the sensitivity findings before approving.
