# Task 001a — Detect a stale base layer from powbox source changes (so self-hosted upgrades are hands-off)

Follow-up to **Task 001** (self-hosted `--isolated` mode, PR #54). Parked in `tasks/deferred/` because the branch is defendable as-is and the proper fix is general build tooling, not specific to self-hosted mode.

## Background — the trap

Self-hosted mode's clone path lives entirely in the **base** image layer:

- `docker/base/Dockerfile:253` bakes `seed-workspace.sh` (the clone helper).
- `docker/base/Dockerfile:251` bakes `entrypoint-core.sh`, which gained the `POWBOX_SELF_HOSTED` clone-seeding call (`docker/shared/entrypoint-core.sh:104`).

But the documented upgrade paths only rebuild the **agent** layer:

- `cc --build` / `cx --build` → `build.sh agent` (README "Build Modes").
- `agent-update` rebuilds the base **only** when the *upstream* `node:24-trixie-slim` digest is stale or an image is missing — see `commands/check-updates.sh` and `shell/powbox.sh` (`agent-update`, the `base==stale` branch around `shell/powbox.sh:325`). A powbox-side change to base-layer **source** (Dockerfile / `docker/shared/*`) does **not** mark the base stale.

Net effect on an existing install adopting this feature: a fresh agent image is built on the **old** base, which has no clone step. `--isolated` then creates the `agent-ws-*` volume but the old entrypoint never clones into it, so the agent starts in an empty checkout. A clean first build (base + agent) is unaffected, and the maintainer validated that path end-to-end on the target VPS.

Review thread: https://github.com/Roubtec/powbox/pull/54#discussion_r3408643062 (codex, P2).

## Interim mitigation already shipped on PR #54

README "Self-Hosted Mode → Upgrading an existing install needs a base-image rebuild" tells adopters to run `agent-update-base` or `build.sh all`. This task replaces that manual step with automatic detection.

## Goal

Make `agent-check-updates` / `agent-update` flag the **base** image as stale when the base layer's powbox **source** differs from what the local base image was built from — so adopting any base-layer change (this feature or future ones) triggers the same full `build.sh all --pull`-style rebuild path that an upstream-stale base already does, with no manual intervention.

## Suggested approach (pick one; A is preferred)

**A. Base-source digest, mirroring the existing upstream-digest mechanism.**
- At base build time, compute a digest over the base build inputs (`docker/base/Dockerfile` + the `docker/shared/*` and `docker/base/*` files it `COPY`s) and stamp it as a label, e.g. `powbox.base.source.digest`, alongside the existing `powbox.base.image.id` (`scripts/build-image.{sh,ps1}`, `docker-bake.hcl`, Dockerfile `ARG`/`LABEL`).
- In `check-updates.{sh,ps1}`, recompute the same digest from the working tree and compare against the local base image's label; mismatch ⇒ `base stale`. Keep the existing upstream-digest check as an additional staleness trigger (OR them).
- `agent-update` already rebuilds base + agent when `base==stale`, so no change is needed there beyond the new trigger feeding it.
- Watch the cache-key subtlety documented in `docs/skills-refresh-and-provenance.md` and AGENTS.md "Image provenance": the codex commit is stamped only in the top metadata layer; do not stamp the source digest anywhere that would bust the Codex install layer's cache.

**B. Launcher capability guard (cheaper, narrower — could ship alongside A).**
- Stamp a capability label on the base, e.g. `powbox.base.selfhosted=1` (inherited by the agent image built `FROM` it).
- In `scripts/launch-agent.{sh,ps1}`, when `--isolated`/`-Isolated` is requested, inspect the resolved image for that label and, if absent, **fail fast** with a clear message ("this image's base predates self-hosted mode — rebuild with `agent-update-base` or `build.sh all`") instead of silently starting in an empty workspace.
- This only guards self-hosted specifically; option A generalises to every base-layer change, which is why A is preferred. B turns the silent failure into a loud, actionable one even when someone bypasses the update flow.

## Acceptance

- Editing a base-layer source file (e.g. `docker/shared/seed-workspace.sh`) and running `agent-check-updates` reports the base as stale; `agent-update` then offers the base + agent rebuild.
- Editing only an agent-layer file does **not** mark the base stale (no false positives that force needless full rebuilds).
- `.sh` / `.ps1` parity preserved; lint clean (shellcheck + PSScriptAnalyzer).
- If option B is included: `--isolated` against an image whose base lacks the capability label fails with the actionable message rather than landing in an empty workspace.
- README "Upgrading an existing install needs a base-image rebuild" updated to reflect that detection is now automatic (and the blockquote pointer to this task removed).
