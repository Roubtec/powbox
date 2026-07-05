# 014a — Honor `shadow:` overrides in `.powbox.local.yml` (container-side schema parity)

> Follow-up to task 014 (resolution of its OQ-6). Execute **after** 014 so the
> local file's name and merge semantics are settled and documented — **and** so
> the host-side YAML mini-parser 014 introduces is available, since the
> project-classification change below reuses it to detect a `shadow:` key. The
> container-side shadow work is otherwise independent.

## Why this task exists

Task 014 introduces `.powbox.local.yml` with the promise of a **shared schema**
with `.powbox.yml`: any setting can be committed or kept user-local. Task 014
only implements the host-side `ctx:` section. The other schema section,
`shadow:`, is parsed **container-side** by `docker/shared/detect-shadows.sh` —
so without this task, a `shadow:` list in the local file is silently ignored
and the shared-schema promise is broken. This task closes that gap.

Real use cases: a user experimenting with extra shadow paths before committing
them, or locally disabling a repo's committed shadows (`shadow: []`) to debug
a mount problem — all without touching the committed `.powbox.yml`.

## Scope

**In scope:**

- `docker/shared/detect-shadows.sh`: read `.powbox.local.yml` in addition to
  `.powbox.yml`, applying the merge rule settled in 014 (**top-level section
  clobber**): if the local file exists **and has a `shadow:` key**, its list
  wholly replaces the committed one — including the present-but-empty case
  (`shadow: []` locally disables all committed custom shadows). If the local
  file is absent or has no `shadow:` key, the committed file applies as today.
- Host launchers' **project classification** check: a repo whose
  `.powbox.local.yml` declares a **`shadow:` key** (a real powbox opt-in) must
  be classified as a powbox project so the `agent-nm`/`agent-wt` volumes mount,
  even with no committed `.powbox.yml`
  (`scripts/launch-agent.sh:421-428`, `scripts/launch-agent.ps1:255-262`).
  **Do not** key this on the mere *existence* of `.powbox.local.yml`: task 014
  makes it the normal home for a `ctx:`-only list (mounting arbitrary reference
  folders into an otherwise non-dev workspace), and those users must not
  silently acquire the `node_modules`/`.worktrees` project volumes. Detect the
  `shadow:` key with the host-side mini-parser 014 already ships (this task runs
  after 014); a committed `.powbox.yml` stays a project marker exactly as today.
- Unit tests in `scripts/test-detect-shadows.sh` covering the new precedence.
- Docs: README "Workspace Shadow Mounts" auto-detection list (step 3 mentions
  `.powbox.yml` only) and any `docs/` page describing shadow detection.

**Out of scope:**

- The `ctx:` section and all other host-side parsing (task 014). This task's
  *only* host-side addition is the `shadow:`-key check that gates project
  classification, reusing 014's mini-parser.
- Any new schema sections or a generic merge engine — this is one section,
  one rule.
- Changes to the `enable-worktrees` skill's behavior (it verifies the
  *committed* file, which remains correct). Add a one-line note in its
  SKILL.md only if it reads naturally; otherwise skip.

## Context and references

- **Parser to extend:** `docker/shared/detect-shadows.sh:59-127` — the
  `.powbox.yml` block: `yq -r '.shadow[]? // empty'` feeds a loop that
  validates each pattern (glob vs literal split, workspace-root containment,
  symlink-escape rejection, `.git/` literal guards). All of that validation
  must apply **identically** to patterns sourced from the local file — only
  the *source selection* changes.
- **Key-presence detection:** `yq 'has("shadow")'` distinguishes
  present-but-empty from absent — required for the clobber rule. The
  container ships `yq`, so no mini-parser is needed here (unlike 014's
  host side).
- **Call sites (no changes expected):** `docker/shared/entrypoint-core.sh:189`
  (startup detection) and `docker/shared/pnpm-shadow-doctor:163` (mid-session
  re-detection before installs) both invoke `detect-shadows.sh <workspace>`,
  so both pick up the new behavior for free.
- **Bake location:** `docker/base/Dockerfile:355` and
  `scripts/base-source-files.txt:30` — the script is baked into the **base**
  image, so shipping this requires a base-image rebuild (`build.sh` /
  `build.ps1`), not just an agent-image rebuild.
- **Test harness:** `scripts/test-detect-shadows.sh` — runs directly against
  the repo copy of the script (bash + yq + jq, all in the agent image); no
  image build needed to iterate.
- **Merge semantics decision:** task 014, OQ-2 resolution (top-level section
  clobber; a local section replaces the committed section wholesale).

## Implementation notes

- Restructure the `.powbox.yml` block minimally: pick the **source file and
  list** first (local-with-key → local list; else committed file if present),
  then run the existing validation loop unchanged over that list. Prefer
  factoring the loop body over duplicating it.
- The local file sits in the workspace bind mount, so the container reads it
  directly — nothing new is mounted.
- **Self-hosted mode:** the workspace is a fresh git clone and the local file
  is gitignored, so it will simply be absent → committed behavior. No special
  casing; just don't break on absence.
- **Mid-session edits** to the local file take effect on the next
  `pnpm`-wrapper re-detection or `shadow-refresh.sh` run — same
  characteristics as editing `.powbox.yml` today; no new docs promise needed
  beyond a sentence.
- Emit one informational line to stderr when a local override is in effect
  (e.g. `detect-shadows: shadow list overridden by .powbox.local.yml`), so a
  confusing "why isn't my committed shadow applied?" session is diagnosable
  from the startup log.
- Keep the script `shellcheck`-clean and matching its existing style (tabs,
  guard comments explaining *why*).

## Acceptance criteria

1. Local file with a `shadow:` list ⇒ exactly that list is emitted (validated
   as today); committed `shadow:` entries are ignored, and an informational
   override line is printed to stderr.
2. Local file present but **without** a `shadow:` key ⇒ committed `.powbox.yml`
   behavior, unchanged.
3. Local `shadow: []` ⇒ zero custom shadows even when the committed file
   declares some (pnpm/npm workspace auto-detection is unaffected).
4. No local file ⇒ byte-for-byte today's behavior (existing tests still pass).
5. Containment/security validation rejects a local entry escaping the
   workspace root exactly as it does for committed entries.
6. A repo whose only powbox file is a `.powbox.local.yml` **declaring a
   `shadow:` key** is classified as a powbox project by both host launchers
   (nm/wt volumes mount); a `.powbox.local.yml` carrying only a `ctx:` list (no
   `shadow:` key, no committed `.powbox.yml`) is **not** classified as a
   project.
7. README auto-detection docs mention the local override and the empty-list
   disable trick.

## Validation

- Extend `scripts/test-detect-shadows.sh` with cases for acceptance criteria
  1–5 (override, no-key fallback, empty-list disable, absence, containment on
  local entries); the full suite passes.
- `shellcheck` passes on `detect-shadows.sh`; `Invoke-ScriptAnalyzer` passes
  on `launch-agent.ps1` for the classification tweak.
- Manual: rebuild the base image, launch against a repo with a local-only
  `shadow:` entry, and confirm the tmpfs mount exists in the container
  (`mount | grep <path>`) and the override notice appears in the startup log.

## Review plan

Reviewer should check: (1) the source-selection change did not weaken any of
the existing validation paths (containment, `.git/` guards, glob gating);
(2) present-but-empty vs absent-key is genuinely distinguished (`has("shadow")`,
not `// empty` coalescing); (3) both launchers' classification checks were
updated symmetrically and gate on a `shadow:` **key** rather than the mere
existence of `.powbox.local.yml` (a `ctx:`-only local file must not classify as
a project); (4) new tests fail against the pre-change script.
