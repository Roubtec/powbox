# 015d — Roll out the split-custody model: prune, verify, document

## Why this task exists

Tasks 015a–015c changed where skills live and how they arrive; existing persistent
volumes still carry stale seeded copies of the 8 migrated Claude skills, and
the powbox docs still describe the old single-channel model. This task
finishes the migration: retire the stale copies, verify the end state on all
channels, and document the new custody split.

## Scope

**In scope:**
- Pruning migrated Claude skills from existing claude-config volumes.
- End-to-end verification of both palettes (Claude and Codex).
- Documentation updates across powbox.

**Out of scope:**
- The human follow-through steps (repo visibility flip, colleague onboarding,
  jabko branch merge) — see task 015e.

## Context and references

- **Prerequisites:** tasks 015a–015c merged; image rebuilt from the new main.
- `commands/update-skills.sh` classifies volume items that carry the
  `.powbox-seeded` marker but are no longer baked as **orphans**; `--prune`
  removes them. After task 015b the 8 migrated Claude skills are exactly that.
- Target end state per channel:
  - **Claude in powbox:** `/dev-skills:<name>` × 8 (plugin) +
    `/enable-worktrees`, `/session-learnings` (seeded, unnamespaced) — **no
    duplicates**.
  - **Codex in powbox:** unchanged 10-skill palette, all seeded.
  - **Colleagues:** plugin only (validated in task 015e).

## Implementation notes

1. **Prune:** rebuild (`build.sh agent`), then run
   `commands/update-skills.sh --dry-run` (expect: the 8 migrated Claude skills
   listed as orphans, the 2 powbox-specific ones as refresh candidates, Codex
   side refresh-only), then `--prune`. Any CONFLICT lines (unmarked items
   shadowing baked names) must be investigated, not adopted blindly.
2. **Duplicate check:** in a fresh container on the pruned volume, confirm the
   8 skills appear ONLY namespaced. A leftover unnamespaced copy means a prune
   miss or an unmarked (user-authored) copy — resolve per update-skills.sh's
   conflict semantics.
3. **Docs to update** (grep for the migrated skill names and for "skills" in
   powbox docs to catch stragglers):
   - `README` sections describing skills/seeding.
   - `commands/update-skills.sh` header comment (its "what this manages"
     story now excludes plugin-delivered skills).
   - `docker/shared/container-agent.md.tmpl` if it lists or explains skills.
   - Document the model: **plugin channel** = shared Claude skills
     (`dev-skills@agent-skills`, SHA-versioned, merge-to-main = release);
     **bake + seed channel** = all Codex flavors + powbox-specific Claude
     skills; where each is edited (agent-skills repo vs powbox repo) and how
     each updates (marketplace update at session start vs update-skills.sh).
   - Note the invocation change (`/address-review` → `/dev-skills:address-review`).
4. **Delete `tasks/015a-portability-audit.md`** (do not move it to `done/`) —
   it was a pre-implementation working document for task 015a and is not to be
   preserved once the migration has landed.

## Target files or areas

Powbox repo docs and comments; existing claude-config volume (prune);
no functional code expected beyond what 015a–015c landed.

## Acceptance criteria

- `update-skills.sh --prune` retires exactly the 8 migrated Claude skills;
  re-running reports a clean plan (0 orphans, 0 conflicts).
- Fresh container verification passes for both palettes as described above.
- Docs describe the split-custody model accurately; no doc still claims the
  migrated skills are baked/seeded for Claude.

## Validation

- The verification transcript (ls of volume skill dirs before/after prune,
  skill listing inside a fresh container for both agents) is attached to the
  PR.
- `rg -l 'address-review|address-tasks|rebase-stack'` over powbox docs returns
  only files updated to the new model.

## Review plan

Reviewer replays the dry-run/prune on their own volume, checks the duplicate
test, and reads the docs diff for accuracy of the two-channel description.
