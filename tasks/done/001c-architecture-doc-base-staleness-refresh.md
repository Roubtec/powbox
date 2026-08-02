# Task 001c — Refresh the stale base-staleness paragraph in docs/architecture.md (mirror the shipped 001a detection)

Follow-up to **Task 001a** (automatic base-source staleness detection, PR #81). Task 001a shipped
the `powbox.base.recipe.digest` mechanism and updated `README.md`, but a sibling doc that describes
the *same* base-staleness behaviour was left behind and now contradicts reality and links to a moved
file. 001a's acceptance criterion 5 named only the README, so this fell outside its explicit scope —
but it is a genuine doc regression introduced alongside that feature, so it is tracked here.

## Background — what 001a actually shipped

`agent-check-updates` / `agent-update` now flag the **base** image as stale when a base-layer powbox
**source** file changes, not just when the upstream `node:24-trixie-slim` digest moves:

- The base image stamps a `powbox.base.recipe.digest` label computed over its own build inputs — the
  base Dockerfile plus every file it `COPY`s (manifest: `scripts/base-source-files.txt`; computed by
  `scripts/base-source-digest.{sh,ps1}`; passed via `docker-bake.hcl` `POWBOX_BASE_RECIPE_DIGEST` and
  stamped as a `LABEL` in the base's final metadata layer, `docker/base/Dockerfile`).
- `commands/check-updates.{sh,ps1}` recompute that digest from the working tree, compare it to the
  local base image's label, and OR a mismatch into base staleness **alongside** the pre-existing
  upstream-digest check.
- `shell/powbox.sh` `agent-update` already rebuilds base + agent when the base row is `stale`, so the
  new trigger feeds the existing full-rebuild path with no manual step.
- As a backstop, `--isolated` / `-Isolated` also refuses to launch against an image whose base lacks
  the `powbox.base.selfhosted` capability label.

The **correct, updated description** already lives in `README.md` under
"Upgrading an existing install needs a base-image rebuild" (the "This is detected automatically…"
paragraph). That is the source of truth this task should mirror.

## The problem

`docs/architecture.md`, in the **"Bundled Go toolchain"** section, still carries the pre-001a
description (the "Upgrading an existing install" bullet, currently the last bullet of that section):

- It states the update helpers **"currently derive base staleness from the upstream
  `node:24-trixie-slim` digest only"** — **false** as of PR #81; a base-layer source change now also
  marks the base stale.
- It prescribes the manual workaround **"Rebuild the stack once with `agent-update --refresh` (or
  `agent-full-rebuild` / `build.sh all`)"** as still-necessary, when detection is now automatic.
- It links to **`../tasks/deferred/001a-selfhosted-base-rebuild-detection.md`** — a **broken path**:
  001a was promoted out of `tasks/deferred/` and (after review) archived to `tasks/done/`. This is
  the only remaining reference in the repo to that stale path.

The Go-toolchain framing of the bullet (an agent-layer rebuild landing on an old base with no
`go`/`golangci-lint`) is still a valid motivating example — the fix is to correct the *mechanism and
status*, not to delete the Go angle.

## Goal

Update the `docs/architecture.md` "Upgrading an existing install" bullet so it matches the shipped
behaviour: base staleness is now detected automatically from base-layer **source** changes (via the
recipe digest), the manual `agent-update --refresh` step is no longer required to pick up a base-layer
change, and the broken `tasks/deferred/001a` link is fixed or removed. Keep it consistent with the
`README.md` "detected automatically" paragraph without duplicating it verbatim (a short pointer to the
README section is fine).

## Suggested approach

1. In `docs/architecture.md`, rewrite the "Upgrading an existing install" bullet in the "Bundled Go
   toolchain" section to:
   - Drop the "currently … upstream digest **only**" claim; state that a base-layer source change
     (e.g. a Go/`golangci-lint` bump in the base Dockerfile) now marks the base **stale**
     automatically, so `agent-update` offers the base + agent rebuild without a manual flag.
   - Keep the Go-toolchain motivating example (agent-only rebuild would otherwise land on an old base
     lacking the new toolchain) but frame it as the thing detection now catches, not a standing trap.
   - Reference `powbox.base.recipe.digest` / `scripts/base-source-files.txt` briefly, or point to the
     README "Upgrading an existing install needs a base-image rebuild" section for the full mechanism,
     rather than repeating it.
2. Fix the dangling link: either point it at the shipped feature's new home
   (`../tasks/done/001a-selfhosted-base-rebuild-detection.md`) or, preferably, drop the
   "tracks … so this becomes hands-off" future-tense clause entirely since the work has shipped, and
   link to the README section instead.
3. Grep the repo once more for any other `tasks/deferred/001a` or "upstream … digest only" references
   and fix any stragglers (at review time, `docs/architecture.md:55` was the only one).

## Acceptance

- `docs/architecture.md` no longer claims base staleness derives from the upstream digest **only**, and
  no longer prescribes `agent-update --refresh` as a required manual step to adopt a base-layer change;
  it describes the automatic recipe-digest detection (or points to the README section that does).
- No broken link remains: `grep -rn "tasks/deferred/001a" docs/ README.md` returns nothing, and any
  retained link resolves to an existing file (`tasks/done/001a-selfhosted-base-rebuild-detection.md`).
- The Go-toolchain example is preserved (not collateral-deleted); the paragraph reads consistently with
  the `README.md` "detected automatically" wording.
- No code changes; docs-only. No lint impact.
