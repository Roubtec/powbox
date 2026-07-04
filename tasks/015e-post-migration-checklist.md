# 015e — Post-migration checklist (human follow-through)

## Why this task exists

The remaining steps are decisions and validations only Ruben (or a colleague)
can perform — they gate publishing the skills and switching jabko (and future
shared repos) onto the plugin. Kept as a checklist so nothing lands out of
order.

## Ordered checklist

1. **Sensitivity review (Ruben):** read the task-015a PR's sensitivity findings
   and skim the migrated skill texts as they'd appear publicly.
2. **Flip visibility (Ruben):**
   `gh repo edit Roubtec/agent-skills --visibility public` — only after step 1.
   (Everything keeps working while private, too; public just removes the gh-auth
   requirement for colleagues. The powbox fetch/install paths from tasks 015b–015c
   work unchanged either way.)
3. **Colleague onboarding validation (one colleague, on jabko branch
   `add-dev-skill-support`):**
   - Open the repo in Claude Code, trust it → expect a prompt to install the
     `agent-skills` marketplace + `dev-skills` plugin (driven by the
     `.claude/settings.json` already on that branch).
   - Confirm `/dev-skills:address-review` (and one more skill) invocable.
   - **Empirical check of the undocumented path:** decline the prompt once,
     restart, note whether it re-prompts; then re-enable via `/plugin` →
     Discover (or `claude plugin install dev-skills@agent-skills`). Record
     what actually happens — this behavior is not documented and we advise
     colleagues based on this observation.
   - Enable marketplace auto-update: `/plugin` → Marketplaces → `agent-skills`
     → Enable auto-update.
4. **Merge the jabko branch** `add-dev-skill-support` — **only after** the
   plugin is populated (task 015a merged) and step 3 passes; before that, the
   settings would prompt collaborators to install an empty/broken plugin.
   Before merging, drop the `[drop]`-marked commit carrying these task files
   (e.g. `git rebase` it away or revert it) — they are transport cargo, not
   jabko content.
5. **Announce to colleagues:** install one-liner
   (`claude plugin marketplace add Roubtec/agent-skills && claude plugin
   install dev-skills@agent-skills`), the auto-update toggle, the namespaced
   invocation form, and the opt-out escape hatch
   (`"dev-skills@agent-skills": false` in `.claude/settings.local.json` —
   note: project-scope `true` beats user-settings `false`; only the local
   override wins).
6. **Future shared repos:** copy the same `.claude/settings.json` block
   (`extraKnownMarketplaces` + `enabledPlugins`) — that is the entire per-repo
   cost of the model.

## Acceptance criteria

All six steps checked off; observations from step 3's decline/re-enable
experiment recorded (a note in the agent-skills README is a good home).
