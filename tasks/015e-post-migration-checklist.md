# 015e — Post-migration checklist (human follow-through)

## Why this task exists

The remaining steps are decisions and validations only Ruben (or a colleague)
can perform — they gate publishing the skills and switching jabko (and future
shared repos) onto the plugin. Kept as a checklist so nothing lands out of
order.

**Current state (2026-07-08, near end of the 015 run):** tasks 015a–015d are
merged; 015g (PR #95, open) delivers the powbox-side first-session fix and makes
the public flip (step 2) load-bearing. Step 2 is already done (see below). The
015g and prior-PR fixes do **not** change the colleague-facing steps (3–6): those
exercise Claude Code's own native marketplace/plugin install and prompt behavior,
which powbox's entrypoint changes never touch — a colleague installs the plugin
from their own `.claude/settings.json`, not through the powbox entrypoint.

## Ordered checklist

1. **Sensitivity review (Ruben):** read the task-015a PR's sensitivity findings
   and skim the migrated skill texts as they'd appear publicly.
2. **Flip visibility (Ruben): ✅ done 2026-07-08.**
   `gh repo edit Roubtec/agent-skills --visibility public` (was gated on step 1).
   Confirmed public this run (`gh repo view Roubtec/agent-skills` →
   `isPrivate:false`). Public removes the gh-auth requirement for colleagues
   cloning the marketplace.
   **This is now load-bearing, not cosmetic** (changed expectation): task 015g
   made powbox's cold first-session plugin install an *anonymous* clone and
   deleted the private-repo auth-wait scaffolding, so the powbox install path no
   longer "works unchanged either way" — re-privatizing `agent-skills` would
   reintroduce the auth-ordering problem 015g removed. Treat the public flip as
   permanent (per 015g's stated assumption); if the repo ever must go private
   again, the credential-helper wait has to come back first.
3. **Colleague onboarding validation (one colleague, on jabko branch
   `add-dev-skill-support`):**
   - Open the repo in Claude Code, trust it → expect a prompt to install the
     `roubtec` marketplace + `dev-skills` plugin (driven by the
     `.claude/settings.json` already on that branch).
   - Confirm `/dev-skills:address-review` (and one more skill) invocable.
   - **Empirical check of the undocumented path:** decline the prompt once,
     restart, note whether it re-prompts; then re-enable via `/plugin` →
     Discover (or `claude plugin install dev-skills@roubtec`). Record
     what actually happens — this behavior is not documented and we advise
     colleagues based on this observation.
   - Enable marketplace auto-update: `/plugin` → Marketplaces → `roubtec`
     → Enable auto-update.
4. **Merge the jabko branch** `add-dev-skill-support` — **only after** step 3
   passes (the plugin-populated precondition — task 015a merged — is already
   satisfied as of this run); before that, the settings would prompt collaborators
   to install an empty/broken plugin.
   (Verified 2026-07-05: the `[drop]`-marked transport-cargo commit is already
   gone from the branch — it now carries only the `.claude/settings.json`
   pointer and a gitignore commit, so no rebase is needed before merging.)
5. **Announce to colleagues:** install one-liner
   (`claude plugin marketplace add Roubtec/agent-skills && claude plugin
   install dev-skills@roubtec`), the auto-update toggle, the namespaced
   invocation form, and the opt-out escape hatch
   (`"dev-skills@roubtec": false` in `.claude/settings.local.json` —
   note: project-scope `true` beats user-settings `false`; only the local
   override wins).
6. **Future shared repos:** copy the same `.claude/settings.json` block
   (`extraKnownMarketplaces` + `enabledPlugins`) — that is the entire per-repo
   cost of the model.

## Acceptance criteria

All six steps checked off; observations from step 3's decline/re-enable
experiment recorded (a note in the agent-skills README is a good home).
