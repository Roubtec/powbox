# Task 002g — The smoke umbrella's PARTIAL banner claims stages "did not run" when some only ran in part

## Why this task exists

Both smoke umbrellas close a partial run with a banner that reads:

- `commands/smoke-test.sh` — `This was a PARTIAL smoke test — the stages above did not run.`
- `commands/smoke-test.ps1` — `This was a PARTIAL smoke test - the stages above did not run.` (hyphen, not em dash — see Implementation notes)

The list entries above that line are precise, but the summary line is not: the same list also collects **within-stage** partials, where the stage ran and only a portion of it self-skipped.
So the banner tells a reader that a stage they in fact have coverage from produced none — which is the mirror image of a false green, and misleads in the direction of distrusting real coverage.

This is not a new defect and it is not caused by any one stage.
It is already reachable on **every hosted-CI Tier 1 run today**: `Stage 3: rootless Podman nested-run checks (no /dev/net/tun)` is a within-stage skip — the stage's static engine wiring is validated and only its nested half is skipped — and both `docs/smoke-tests.md` and the banner's own body already say so.
Task 053a (PR #152, since merged) added a second instance — the PowerShell driver's `$IsLinux` gate on the mountpoint-ownership assertions: Stage 6 runs, minus those assertions — and that is what surfaced this, but fixing it inside 053a would have been wrong: the defect predates it, lives in both umbrellas, and is already reachable without 053a via Stage 3.

## Scope

Correct the partial-run banner in **both** umbrellas so the whole banner covers within-stage partials, and keep the two files saying the same thing.

Three parts of that banner over-claim, not one, and a fix confined to the summary line leaves the other two contradicting it:

- the **heading** — `================ SMOKE TEST: STAGES SKIPPED ================` — which announces the list as skipped stages when some entries are stages that ran in part.
- the **summary line** — `This was a PARTIAL smoke test — the stages above did not run.` — the original over-claim.
- the **remediation** — `To run the stages above, unset the POWBOX_SMOKE_SKIP_* vars` (`.sh`) / `To run the stages above, drop the -Skip* switches` (`.ps1`) — which points the reader at a control that does not govern a within-stage skip at all: no skip variable or switch turns Stage 3's nested half back on, and the runtime condition that self-skipped it (`/dev/net/tun` absent) is not something the reader can unset.

The caveat sentences that close each banner are not the defect: they already name the within-stage skip the umbrella knows about, Stage 3's nested half, in both files alike (the `.ps1`'s caveat also named its own Stage 6 ownership omission until 053a closed that gap and dropped the sentence). That is exactly what makes the heading, summary, and remediation above them read as wrong rather than merely imprecise — the banner already contradicts itself in place.

The suggested summary wording is a one-liner: `did not run, or did not run in full.`
That is a suggestion, not a decision — for the heading and the remediation as much as for the summary, any phrasing that stops asserting whole-stage non-execution, and stops prescribing a remedy that cannot apply, is acceptable.

## Target files or areas

- `commands/smoke-test.sh` — the whole skip banner near the end of the file (the `================ SMOKE TEST: STAGES SKIPPED ================` section): its heading, the `This was a PARTIAL smoke test` line (a unique string), and the `To run the stages above, unset the POWBOX_SMOKE_SKIP_* vars` remediation
- `commands/smoke-test.ps1` — the same three parts in its mirrored banner, whose remediation instead reads `To run the stages above, drop the -Skip* switches`
- `docs/smoke-tests.md` → "Partial runs, host gates, and skipping" — check whether the chapter repeats the same over-claim and correct it if so

## Implementation notes

- The two umbrellas must not drift: this is one edit applied twice, and a PR that touches only one of them is incomplete.
- Mind the punctuation split — the `.sh` uses an em dash, the `.ps1` a hyphen, deliberately. Keep it that way: `AGENTS.md` → "File Conventions" does not forbid non-ASCII in a `.ps1`, it requires that such a file be saved as UTF-8 **with BOM**, and `commands/smoke-test.ps1` holds no non-ASCII today — so an em dash there would mean adding a BOM to a file that currently needs none. Whatever new wording the scope above lands on must respect the same split.
- `AGENTS.md` → "Documentation Practices": update `docs/smoke-tests.md` if the chapter's wording is affected.
- No behavior changes, so the in-container gates (`shellcheck`, `shfmt -d`, PSScriptAnalyzer, `markdownlint-cli2`) are the full validation surface. A host smoke run is not required for a wording change, though the line is only *seen* in a partial run.

## Acceptance criteria

- Neither umbrella's partial-run banner asserts that every listed stage failed to run at all — not in its heading, not in its summary line, and not in its remediation.
- Neither remediation tells the reader to unset a skip variable or drop a switch in order to recover a within-stage skip that no such control governs.
- The Bash and PowerShell banners remain equivalent in meaning, each with its own punctuation convention.
- `docs/smoke-tests.md` does not repeat the corrected over-claim.
- Static gates clean; `commands/smoke-test.ps1` still holds no non-ASCII, so it still needs no BOM.
