# Task 002g — The smoke umbrella's PARTIAL banner claims stages "did not run" when some only ran in part

## Why this task exists

Both smoke umbrellas close a partial run with a banner that reads:

- `commands/smoke-test.sh` — `This was a PARTIAL smoke test — the stages above did not run.`
- `commands/smoke-test.ps1` — `This was a PARTIAL smoke test - the stages above did not run.` (hyphen, not em dash: that file is kept pure ASCII, see `AGENTS.md` → "File Conventions")

The list entries above that line are precise, but the summary line is not: the same list also collects **within-stage** partials, where the stage ran and only a portion of it self-skipped.
So the banner tells a reader that a stage they in fact have coverage from produced none — which is the mirror image of a false green, and misleads in the direction of distrusting real coverage.

This is not a new defect and it is not caused by any one stage.
It is already reachable on **every hosted-CI Tier 1 run today**: `Stage 3: rootless Podman nested-run checks (no /dev/net/tun)` is a within-stage skip — the stage's static engine wiring is validated and only its nested half is skipped — and both `docs/smoke-tests.md` and the banner's own body already say so.
Task 053a added a second instance (the PowerShell driver's `$IsLinux` gate on the mountpoint-ownership assertions: Stage 6 runs, minus those assertions), which is what surfaced this, but fixing it inside 053a would have been wrong — the defect predates it and lives in both umbrellas.

## Scope

Correct the summary line in **both** umbrellas so it covers within-stage partials, and keep the two files saying the same thing.

The suggested wording is a one-liner: `did not run, or did not run in full.`
That is a suggestion, not a decision — any phrasing that stops asserting whole-stage non-execution is acceptable.

## Target files or areas

- `commands/smoke-test.sh` — the `This was a PARTIAL smoke test` line in the skip banner (unique string; the banner block is the `================ SMOKE TEST: STAGES SKIPPED ================` section near the end of the file)
- `commands/smoke-test.ps1` — the same line in its mirrored banner
- `docs/smoke-tests.md` → "Partial runs, host gates, and skipping" — check whether the chapter repeats the same over-claim and correct it if so

## Implementation notes

- The two umbrellas must not drift: this is one edit applied twice, and a PR that touches only one of them is incomplete.
- Mind the punctuation split — the `.sh` uses an em dash, the `.ps1` a hyphen, deliberately. Keep it that way; the `.ps1` must stay pure ASCII so it needs no BOM.
- `AGENTS.md` → "Documentation Practices": update `docs/smoke-tests.md` if the chapter's wording is affected.
- No behavior changes, so the in-container gates (`shellcheck`, `shfmt -d`, PSScriptAnalyzer, `markdownlint-cli2`) are the full validation surface. A host smoke run is not required for a wording change, though the line is only *seen* in a partial run.

## Acceptance criteria

- Neither umbrella's partial-run banner asserts that every listed stage failed to run at all.
- The Bash and PowerShell banners remain equivalent in meaning, each with its own punctuation convention.
- `docs/smoke-tests.md` does not repeat the corrected over-claim.
- Static gates clean; the `.ps1` stays pure ASCII with no BOM.
