# 003 — Add native-Linux CI (build + smoke) so native-only defects stop reaching main

## Why this task exists

powbox has **no automated native-Linux check** (`gh pr view 54/55` → `statusCheckRollup: []`). An entire class of defects only manifests on a real Linux host with real Docker and only surfaces through manual VPS testing:

- PR #51 — shell-script exec bits not committed (`./build.sh` → Permission denied on a fresh Linux clone).
- PR #52 — egress firewall regression.
- PR #54 — a self-hosted smoke check (`smoke-test-selfhosted.sh` Stage B single-mount hardlink) that had **never executed** and failed the first time it ran on the VPS.
- PR #55 — dir-mounted root-owned repo unwritable by the `node` agent.

Windows/WSL — the primary dev environment — masks all of them (git ignores filemode; the bind mount reports 755; uid semantics differ). Each regression currently costs a human a VPS stand-up, an SSH session, a ~13 min image rebuild, and a hand-run smoke pass. Reviews go green with real native-Linux breakage in the diff.

A hosted `ubuntu-latest` runner is itself a real native-Linux host with full unvirtualized Docker, so it reproduces exactly the build / mount / identity / exec-bit class above — automatically, on every relevant PR, with none of the host's "approve every command" friction and without tying up a developer machine or the VPS.

## Scope

Included: one or more GitHub Actions workflows under `.github/workflows/` that validate powbox on `ubuntu-latest`, structured in two tiers so cost tracks change type (see Implementation notes).

Out of scope (stays manual / VPS, document the boundary — do not attempt in hosted CI):

- Real egress-firewall behavior against CGNAT ranges, and netcup cloud-firewall interplay.
- FUSE / overlay storage performance characteristics.
- **Nested** rootless-Podman that needs `/dev/net/tun` + `/dev/fuse` — unreliable on hosted runners; the Podman stage's nested-run checks already self-skip when those devices are absent, so CI exercises the static engine wiring only.
- Long-lived-host behavior.

These remain VPS-validated, or move into CI later via a self-hosted runner (the same workflow runs there unchanged — see the alternative in Implementation notes).

## Context and references

- Origin: an agent-session retrospective (2026-06-14) that found `statusCheckRollup: []` on PRs #54/#55 and a never-executed self-hosted smoke check.
- Existing workflow (do not disturb its triggers): `.github/workflows/claude.yml` (the `@claude` responder).
- Smoke entrypoint and its new CI knob: `commands/smoke-test.sh` / `commands/smoke-test.ps1` now honour `POWBOX_SMOKE_REQUIRE_IMAGE=1` (sh) / `-RequireImage` (ps1) — fail instead of self-skipping image-gated stages — and print an end-of-run "STAGES SKIPPED" banner. Added on branch `minor-fixes`; this task depends on it.
- Build entry: `build.sh` → `scripts/build-image.sh`; two-stage bake `docker-bake.hcl` (`base` then `agent`, `agent` is `FROM base`). Base is `node:24-trixie-slim` + ~12 apt groups (incl. `mssql-tools18`, `powershell`, `gh`) — ~13 min cold; warm layer cache makes the rare rebuild minutes.
- Exec-bit guard suggested earlier (netcup brief A-01): `! git ls-files -s -- '*.sh' | grep ^100644`.

## Target files or areas

- New: `.github/workflows/native-linux-ci.yml` (name TBD by implementer).
- Possibly a tiny `scripts/check-exec-bits.sh` if the Tier-0 guard is worth factoring out (judgement call).

## Implementation notes

Recommended shape — layered:

- **Tier 0 — every PR, seconds, no Docker.** Static guards: exec-bit check (`! git ls-files -s -- '*.sh' | grep ^100644`), `shellcheck` + `shfmt -d` on `*.sh`, `Invoke-ScriptAnalyzer` (PSScriptAnalyzer, with `PSScriptAnalyzerSettings.psd1`) on `*.ps1`. Tier 0 alone would have caught PR #51.
- **Tier 1 — only on image-affecting `paths:`** (`docker/**`, `**/Dockerfile`, `compose*.yml`, `docker-bake.hcl`, `build.*`, `scripts/launch-agent.*`, `scripts/build-image.*`, `scripts/smoke-test*`, `commands/smoke-test.*`). Steps: set up buildx with the GitHub Actions layer cache (`cache-from`/`cache-to: type=gha`), `./build.sh` (or `docker buildx bake`), then `POWBOX_SMOKE_REQUIRE_IMAGE=1 ./commands/smoke-test.sh`. `REQUIRE_IMAGE` guarantees no stage self-skips into a false green. The `pg-dev-up` functional stage runs fine on a hosted runner; the Podman stage's nested-run checks self-skip if `/dev/net/tun`//`/dev/fuse` are unavailable (static engine wiring still validated) — that's acceptable, not a failure. Once task 005 lands, its dir-mount-ownership stage runs here too and would have caught PR #55.

Why path-gating matters: across recent history most PRs are skill/docs/launcher edits (skill *content* is not even in this repo — it is seeded via `docker/shared/seed-skills.sh`), so the heavy build must not run on every PR. Path filters + layer cache keep CI cheap; Tier 0 still covers every PR.

Alternative (document, don't necessarily build now): run the same workflow on a **self-hosted runner** to also cover nested rootless-Podman and (with `NET_ADMIN`) the firewall — fuller coverage, more setup and a maintained runner. Lead with the hosted-Tier-0+1 recommendation; leave the runner choice to whoever implements, noting the VPS remains the backstop either way.

## Acceptance criteria

- Opening/updating a PR runs Tier 0 on `ubuntu-latest` and it passes on a clean branch; a deliberately un-`chmod`ed `*.sh` makes it fail.
- A PR touching an image-affecting path runs Tier 1: image builds (cache-aware) and `commands/smoke-test.sh` runs under `POWBOX_SMOKE_REQUIRE_IMAGE=1` with no stage silently skipped.
- A skill/docs-only PR runs Tier 0 only (no image build).
- README/AGENTS documents what CI covers vs. what stays VPS-only.

## Validation

- Push a branch with the workflow; confirm Tier 0 green and that reverting PR #51's exec bits turns it red.
- On an image-affecting branch, confirm Tier 1 builds and smoke-tests, and that an injected smoke failure (e.g. a removed CLI) fails the job.
- Confirm a docs-only change skips Tier 1 (cost check).

## Review plan

Reviewer confirms: path filters are correct (no heavy build on docs/skill PRs), `REQUIRE_IMAGE` is set in CI, the cache keys are sound, `claude.yml` is untouched, and the VPS-only boundary is written down.

## Status

**Not started.** Depends on the `POWBOX_SMOKE_REQUIRE_IMAGE` smoke-test knob (branch `minor-fixes`). Consumes task [005](005-dir-mount-ownership-smoke-stage.md) once it lands (CI works without it too).
