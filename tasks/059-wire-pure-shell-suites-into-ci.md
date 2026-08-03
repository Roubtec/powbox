# Task 059 — Wire the pure-shell unit suites into CI so their evidence is enforced, not anecdotal

## Why this task exists

`AGENTS.md` → "Validating Changes" tells every agent that the pure-shell unit tests are the in-container gate to run before handing off, and the task files in this repo lean on them as their acceptance evidence.
But **no CI workflow runs any of them.** Tier 0 (`.github/workflows/native-linux-ci.yml`) runs `shellcheck`, `shfmt` (advisory) and `scripts/check-exec-bits.sh`; Tier 1 (`native-linux-build.yml`) builds the image and runs the smokes. `commands/smoke-test.sh` Stage 0 invokes only a subset — `test-sensitive-host-path.sh`, `test-gh-review-threads.sh`, `test-wt-orphan-safety.sh`, `test-podman-compose-healthcheck.sh`, `test-peer-review-run.sh`.

So suites like `test-detect-shadows.sh` (170 assertions), `test-pnpm-shadow-wrapper.sh` (61), `test-pg-dev-up-scoped.sh` (89), `test-sync-codex-skills.sh`, `test-claude-hook-skew.sh`, `test-seed-marker-source.sh` and `test-shadow-refresh-guard.sh` run **only when a human or agent invokes them by hand**.
Across the 035/039/043/045 batch that was roughly 340 assertions of acceptance evidence with no automated backstop — every one of them green, but nothing would have caught a later regression.

Multiple reviewers flagged this independently during that batch. It is a systemic gap, not a per-task one, which is why it is its own task.

## Scope

Included:

- Decide and implement **where** these suites run. The two credible homes:
  - **Tier 0** (`native-linux-ci.yml`) — they need no image and no Docker daemon, so they fit the static-guard tier and give the fastest signal on every PR.
  - **`commands/smoke-test.sh` Stage 0** — already the "hermetic, no image needed" stage, and already runs five of them; extending it keeps one list rather than two.
  Pick one as the primary home and say why; do not silently run the same suite in both.
- Enumerate every `scripts/test-*.sh` that is genuinely hermetic (no image, no daemon, no network, no sudo/mount) and wire the full set, rather than hand-picking — the current five look arbitrary and that is how the gap arose.
- Make the wiring **self-maintaining**: a newly added `scripts/test-*.sh` should be picked up automatically (glob + run), or a guard should fail when a suite exists that no runner references. A hand-maintained list will drift again — this task exists because it already did.
- Explicitly classify any suite that is *not* hermetic (needs an image, a daemon, root, or the network) and route it to Tier 1 or document why it stays manual.
- Update `AGENTS.md` → "Validating Changes" and the README CI description to say what is enforced where, so the docs stop implying more coverage than exists (or less).

Out of scope:

- Writing new tests or changing any existing suite's assertions.
- Changing the Tier 0 / Tier 1 split itself, or the `non-code` label behavior.
- Making `shfmt` blocking (task 049 owns the extensionless-helper house style; that work is in flight and any gap it covers is non-blocking here).

## Context and references

- `.github/workflows/native-linux-ci.yml` — Tier 0 static guards (`shellcheck --severity=error`, advisory `shfmt` scoped to changed `*.sh`, `check-exec-bits.sh`).
- `.github/workflows/native-linux-build.yml` — Tier 1 build + smoke, skipped on `non-code`-labelled PRs.
- `commands/smoke-test.sh` — Stage 0 is the hermetic stage; `commands/smoke-test.ps1` is its PowerShell sibling and must stay in step (CRLF, ASCII).
- `AGENTS.md` → "Validating Changes" — currently names three suites as examples; it should describe the enforced set.
- Suites present at time of writing: `test-sensitive-host-path.sh`, `test-detect-shadows.sh`, `test-pnpm-shadow-wrapper.sh`, `test-wt-orphan-safety.sh`, `test-pg-dev-up-scoped.sh`, `test-sync-codex-skills.sh`, `test-claude-hook-skew.sh`, `test-seed-marker-source.sh`, `test-shadow-refresh-guard.sh`, `test-gh-review-threads.sh`, `test-podman-compose-healthcheck.sh`, `test-peer-review-run.sh`.

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
