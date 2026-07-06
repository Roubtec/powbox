# 015a companion — portability audit of the 8 shareable skills (2026-07-05)

Pre-implementation audit of both flavors of the 8 presumptively-shareable skills
(claude: `docker/claude/agent-container/skills/<name>/SKILL.md`; codex: same under
`docker/codex/...` + `agents/openai.yaml`). Input for the 015a implementer; not
a task file. Line refs are against the current sources on `main`.
**Lifecycle:** working document only — task 015d deletes it (no `done/`
archival) once the migration lands.

## Verdict: the presumptive 8/2 split holds

All 8 are shareable; none is irreducibly powbox-bound. Effort tiers:

| Skill                    | Edit size (per flavor) | Nature of edits                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
|--------------------------|------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| write-tasks              | 0 lines                | flavors byte-identical; copy verbatim                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| address-tasks-serialized | 0 lines                | zero sandbox coupling (surprise of the audit)                                                                                                                                                                                                                                                                                                                                                                                                                          |
| review-tasks             | 0–1                    | only decision: L45 cross-ref sigil (`write-tasks` vs `$write-tasks`) — keep per-flavor idiom                                                                                                                                                                                                                                                                                                                                                                           |
| rebase-stack             | ~2                     | claude L17 names `address-tasks` in the motivating scenario — adopt codex L17's generalized wording; scrub example subject `01-12 conversion-blocks` (claude L189 / codex L190) which reads like a real internal task name                                                                                                                                                                                                                                             |
| address-review           | ~10–15                 | demote baked `gh-review-threads` from "primary" to "if on PATH" (vanilla GraphQL recipe already in-skill at C232–246, promote it); drop `agent-update` / "older image" phrasing (C118, C191, C222, C243, C248, C285 + codex offsets ~+14)                                                                                                                                                                                                                              |
| resolve-open-questions   | ~10–15                 | `gitcat` → "if available, else `git show <ref>:<path>`" (C206–207, C299, C305–306 / X+~10); `wt-enter` parenthetical (C213–214) → vanilla `git worktree add`; optionally qualify `tasks/` convention refs as repo-convention                                                                                                                                                                                                                                           |
| address-reviews          | ~35–45                 | rewrite Session Bootstrap (C66–68) vanilla: gitignored worktree base, `git worktree prune`, `git ls-remote` probe; replace `wt-enter`/`wt-remove` call sites (C90, C102–104, C114–116, C178) with vanilla equivalents + manual safety checks; fix seeded-skill path bullet (C135), pnpm-store/Chromium bullet (C137); checklist items C202/C204                                                                                                                        |
| address-tasks            | ~70–100 (≈⅓ of file)   | delete/replace "Durability & host isolation" section (C22–33 → ~4 vanilla lines); rewrite Session Bootstrap (C35–51) without `wt-bootstrap`/`shadow-refresh.sh`/`.powbox.yml`/`SHADOW_TMPFS_SIZE`; `wt-enter`/`wt-remove` at ~7 sites (C110–116, C129, C205, C209, C239, C253); `findmnt` → `df` (C89); de-powbox e2e path example (C98), Chromium (C104), `$CONTAINER_NAME` mentions; delete `wf-address-tasks`/"Claude dynamic workflows" parentheticals (C37, C153) |

## Semantic traps — flag for the implementer and reviewer

1. **`wt-remove --force` vs `git worktree remove --force` have OPPOSITE safety
   semantics** (address-tasks C209 / X257; address-reviews C178). The powbox
   helper refuses to destroy uncommitted work even with `--force`; vanilla git
   `--force` destroys it. The public text must say "never force-remove a dirty
   worktree", not translate literally.
2. **"`.git/worktrees` is tmpfs-shadowed, so no `git worktree prune` needed"**
   (address-tasks C210 / X258; address-reviews C181 / X197) is powbox-FALSE on
   plain machines — the advice must be *inverted* (vanilla machines should
   prune), not merely qualified.
3. **Codex flavors carry sentence-per-line reflow drift** vs claude (esp.
   address-tasks, ~180 raw diff lines mostly cosmetic). Recommendation: do NOT
   normalize in 015a (the reviewer diffs migrated files against originals;
   keep the diff = portability edits only). Queue normalization as a follow-up
   in agent-skills if wanted.

## Cross-skill references

- All references are bare-name; plugin namespacing resolves them by description
  matching. One near-hard-coded invocation: claude address-tasks **L243
  `/rebase-stack`** — rephrase to "invoke the rebase-stack skill" (codex's
  `$rebase-stack` at X291/X296 is that harness's normal idiom, keep).
- `enable-worktrees` (STAYS in powbox) is referenced in exactly two places:
  address-tasks C45/X52 and address-reviews C68/X84 — both as the bootstrap
  remedy. Replace with vanilla remediation ("gitignore the worktree base dir"),
  at most an "if available" aside.
- `session-learnings` (STAYS in powbox) is referenced by **no** shareable skill.
- Hard content dependencies (must ship together, all in the migrating set):
  address-tasks ⇄ address-tasks-serialized (prompt contracts inherited by
  reference), address-reviews → address-tasks (worktree machinery "wholesale"),
  address-tasks → rebase-stack (restack step), review-tasks → write-tasks.
- address-review C61 attributes a pattern to `address-tasks-serialized` —
  fine, it migrates too.

## Sensitivity pass (for the PR description)

**No blockers in any of the 16 SKILL.md files or 8 openai.yaml sidecars.** No
client/project names, no private repos other than powbox itself, no emails, no
credentials-adjacent content. Two cosmetic scrubs:
- rebase-stack example `01-12 conversion-blocks` (claude L189 / codex L190) —
  replace with an invented subject.
- "powbox launcher" / `./build.sh all` / `agent-update` mentions leak only the
  existence of powbox tooling (not sensitive) and are deleted by the
  generalization edits anyway.

All openai.yaml sidecars are 4-line interface stubs, clean, migrate unchanged.

## Environment facts verified for 015a execution

- `/ctx/agent-skills` is writable; `gh` auth = Roubtec with ADMIN on
  Roubtec/agent-skills (private); branch `populate-skills` exists, == main
  (a2f4758). `safe.directory` added for /ctx repos in this container.
- `claude` CLI 2.1.201 in-container has the full `plugin marketplace add` /
  `install` / `validate` / `list` command set for the validation step. Use a
  scratch `CLAUDE_CONFIG_DIR` for the install test to avoid touching this
  container's live plugin state (or uninstall after).
- **Task-file correction for 015c:** the plugin state file is
  `~/.claude/plugins/installed_plugins.json` (underscore), not
  `installed-plugins.json`; dir also holds `known_marketplaces.json`, `cache/`,
  `marketplaces/`. Trust disk over the task text.
- jabko branch `add-dev-skill-support` carries only the `.claude/settings.json`
  pointer + a gitignore commit; the `[drop]` cargo commit mentioned in 015e
  step 4 is already gone.
