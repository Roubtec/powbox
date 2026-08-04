# Task 059 — Wire the pure-shell unit suites into CI so their evidence is enforced, not anecdotal

## Why this task exists

`AGENTS.md` → "Validating Changes" tells every agent that the pure-shell unit tests are the in-container gate to run before handing off, and the task files in this repo lean on them as their acceptance evidence.
When this task was written **no CI workflow ran any of them**; task 053 has since wired exactly one. Tier 0 (`.github/workflows/native-linux-ci.yml`) runs `shellcheck`, `shfmt` (advisory), `scripts/check-exec-bits.sh` and — since PR #131 — `scripts/test-detect-shadows.sh`; Tier 1 (`native-linux-build.yml`) builds the image and runs the smokes. `commands/smoke-test.sh` Stage 0 invokes a hand-picked subset — `test-sensitive-host-path.sh`, `test-gh-review-threads.sh`, `test-wt-orphan-safety.sh`, `test-podman-compose-healthcheck.sh`, `test-peer-review-run.sh`, and (also since PR #131) `test-detect-shadows.sh` and `test-shadow-mounts-chown.sh` — and it needs a built image, so it is not a per-PR gate for a `non-code`-labelled PR.

So `test-pnpm-shadow-wrapper.sh`, `test-pg-dev-up-scoped.sh`, `test-context-mount-config.sh`, `test-smoke-probe-wrapper.sh`, `test-sync-codex-skills.sh`, `test-claude-hook-skew.sh`, `test-seed-marker-source.sh` and `test-shadow-refresh-guard.sh` still run **only when a human or agent invokes them by hand** — eight of the fifteen `scripts/test-*.sh` files, and between them several hundred assertions. Deliberate assertion counts are left out here because they drift with every added case; re-derive them at implementation time.
Across the 035/039/043/045 batch that was roughly 340 assertions of acceptance evidence with no automated backstop — every one of them green, but nothing would have caught a later regression.

Multiple reviewers flagged this independently during that batch. It is a systemic gap, not a per-task one, which is why it is its own task.

## Scope

Included:

- Decide and implement **where** these suites run. The two credible homes:
  - **Tier 0** (`native-linux-ci.yml`) — they need no image and no Docker daemon, so they fit the static-guard tier and give the fastest signal on every PR.
  - **`commands/smoke-test.sh` Stage 0** — already the "hermetic" stage, and already runs seven of them; extending it keeps one list rather than two. Note that "hermetic" there does not mean container-free: seven of its nine entries run the suite inside the image — six of them (Stages 0a, 0b, 0d, 0f, 0g, 0h) pointed at the **baked** artifact, while Stage 0e runs in-image purely for the `yq`/`jq` toolchain, since what it validates is a `/repo` script with no baked counterpart. Either way this home needs a built image where Tier 0 does not.
  Pick one as the primary home and say why; do not silently run the same suite in both.
- Enumerate every `scripts/test-*.sh` that is genuinely hermetic (no image, no daemon, no network, no sudo/mount) and wire the full set, rather than hand-picking — the current selection looks arbitrary and that is how the gap arose.
- Make the wiring **self-maintaining**: a newly added `scripts/test-*.sh` should be picked up automatically (glob + run), or a guard should fail when a suite exists that no runner references. A hand-maintained list will drift again — this task exists because it already did.
- Explicitly classify any suite that is *not* hermetic (needs an image, a daemon, root, or the network) and route it to Tier 1 or document why it stays manual.
- **The overlap with task 053 is already resolved — read its delivered wiring before starting.** That task (`tasks/done/053-wire-detect-shadows-suite-and-cover-mountpoint-ownership.md`) merged first, in PR #131, which is the ordering its reconciliation bullet preferred, so this task's job is to **generalize** what landed there rather than to re-decide it: `scripts/test-detect-shadows.sh` now runs in Tier 0 (`.github/workflows/native-linux-ci.yml`, behind a hash-pinned python-yq install) **and** as smoke Stage 0g, and `scripts/test-shadow-mounts-chown.sh` runs as Stage 0h. Two consequences for the scope above. The "do not run the same suite in both homes" rule now has a shipped counter-example to reconcile explicitly rather than silently: Tier 0 runs the `/repo` source while Stage 0g runs the **baked** copy via `POWBOX_DETECT_SHADOWS`, which is a deliberate two-target split, not an accidental double-run — decide whether the generalized wiring keeps that shape for every suite that has a baked counterpart, and say so in the PR. And the self-maintaining requirement has to accommodate the per-suite gating 053 introduced (`--check-deps`, the `uname -s = Linux` gate on Stage 0h), so a naive glob-and-run would turn honest skips into failures.
- Update `AGENTS.md` → "Validating Changes" and the README CI description to say what is enforced where, so the docs stop implying more coverage than exists (or less).

Out of scope:

- Writing new tests or changing any existing suite's assertions.
- Task 053's item 2 (automated coverage for the `shadow-mounts.sh` mountpoint-ownership `chown`) — that stays with 053 regardless of how the overlap above is resolved.
- Changing the Tier 0 / Tier 1 split itself, or the `non-code` label behavior.
- Making `shfmt` blocking (task 049 owns the extensionless-helper house style; that work is in flight and any gap it covers is non-blocking here).

## Context and references

- `.github/workflows/native-linux-ci.yml` — Tier 0 static guards (`shellcheck --severity=error`, advisory `shfmt` scoped to changed `*.sh`, `check-exec-bits.sh`).
- `.github/workflows/native-linux-build.yml` — Tier 1 build + smoke, skipped on `non-code`-labelled PRs.
- `commands/smoke-test.sh` — Stage 0 is the hermetic stage; `commands/smoke-test.ps1` is its PowerShell sibling and must stay in step (CRLF, ASCII).
- `AGENTS.md` → "Validating Changes" — currently names three suites as examples; it should describe the enforced set.
- `tasks/done/053-wire-detect-shadows-suite-and-cover-mountpoint-ownership.md` — merged (PR #131); its items 1 and 3 wired the first suites into the same files this task touches, so read it and the resulting stages before starting; see the reconciliation bullet in Scope.
- Suites present at time of writing: `test-sensitive-host-path.sh`, `test-detect-shadows.sh`, `test-pnpm-shadow-wrapper.sh`, `test-wt-orphan-safety.sh`, `test-pg-dev-up-scoped.sh`, `test-sync-codex-skills.sh`, `test-claude-hook-skew.sh`, `test-context-mount-config.sh`, `test-seed-marker-source.sh`, `test-shadow-refresh-guard.sh`, `test-gh-review-threads.sh`, `test-podman-compose-healthcheck.sh`, `test-peer-review-run.sh`, `test-shadow-mounts-chown.sh`, `test-smoke-probe-wrapper.sh`. Re-enumerate from `scripts/test-*.sh` at implementation time rather than trusting this list — the set grows, which is the whole point of the self-maintaining requirement above.

## Target files or areas

- `.github/workflows/native-linux-ci.yml` (and/or `commands/smoke-test.sh` + `commands/smoke-test.ps1`)
- `AGENTS.md`, `README.md`
- Possibly a small runner script under `scripts/` if a glob-driven entry point is the cleanest shape.

## Implementation notes

- Check each suite's actual requirements before classifying it as hermetic — some shell out to `yq`/`jq` (present in the image, but confirm they are present on the CI runner too, which may not be the agent image).
- Runtime matters for Tier 0: measure the total. If the full set is slow enough to hurt PR feedback, prefer running it as one parallel job rather than dropping suites.
- `test-pg-dev-up-scoped.sh` stands up real PostgreSQL clusters on loopback ports — verify it is hermetic *enough* for the chosen runner (it needs the bundled server binaries, so it may be image-dependent and belong in Tier 1's smoke rather than Tier 0).
- If a glob-driven runner is used, make sure a suite that exits non-zero fails the job loudly and that the failing suite's name is obvious in the log.

## Acceptance criteria

- Every hermetic `scripts/test-*.sh` runs automatically on a PR, and a deliberately broken assertion in any of them fails CI — spot-check at least two suites by temporarily breaking them.
- A newly added `scripts/test-*.sh` is either picked up automatically or causes a guard failure until it is wired.
- Non-hermetic suites are classified, routed, or documented as manual with the reason.
- `AGENTS.md` and README describe the enforced set accurately.

## Validation

- The suites pass in-container as before (`bash scripts/test-*.sh`).
- CI is green on the PR, and the new job visibly runs the expected suite list.
- Temporarily breaking one assertion turns CI red (revert before merge).
- `shellcheck` / `shfmt -d` clean on anything added; `actionlint` if available for workflow edits.

## Review plan

Reviewer confirms the chosen home is justified rather than arbitrary, that the wiring cannot silently drop a suite as the set grows (the failure mode this task exists to fix), that no suite is double-run across tiers, and that the docs now match what CI actually enforces.
