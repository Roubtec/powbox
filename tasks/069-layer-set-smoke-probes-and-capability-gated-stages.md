# 069 — Run layer-set smoke probes and gate the PostgreSQL and Podman stages by image capability

## Why this task exists

`commands/smoke-test.sh` assumes one image that contains everything: Stage 1 asserts Go, .NET, OPA and more, Stage 2 starts a PostgreSQL cluster, Stage 3 exercises rootless Podman.
With an optional layer set (task 063) there are two valid images, and the lean one will not contain those tools once tasks 071 and 073 move them.

The agreed composition is:

- the smoke test keeps a **reduced core** that every image must pass;
- a layer set **carries its own probes**, which run only against an image built from that set;
- a user who edits their own set maintains or deletes its probes;
- stages that need host orchestration stay in the repo and run only when the image has the tool they test.

This task builds that mechanism while every tool is still in the base, so it changes no outcome yet. Tasks 071 and 073 then move probes into `docker/layers/full/` alongside the tools.

## Scope

**In scope:**

1. An optional `smoke-probes.txt` in a layer set directory, read by both smoke drivers and run as its own stage.
2. Capability gating of Stage 2 (PostgreSQL) and Stage 3 (Podman): run when the image has the tool, report "not in this image" otherwise.
3. A reporting distinction between a stage that was **skipped** and one that is **not applicable** to the image.
4. Bash and PowerShell parity, unit coverage, and `docs/smoke-tests.md`.

**Out of scope:**

- Moving any probe out of the core list (tasks 071, 073).
- Layer sets adding their own host-orchestrated stages. A set contributes in-container probes only.
- CI (task 065).

## Context and references

- Depends on task 063 for the image labels `powbox.layers.set` and `powbox.layers.digest`.
- `commands/smoke-test.sh` and `commands/smoke-test.ps1`: the Stage 1 call into `scripts/smoke-test-image.{sh,ps1}`, the Stage 2 block gated by `POWBOX_SMOKE_SKIP_DB`, the Stage 3 block gated by `POWBOX_SMOKE_SKIP_PODMAN`, the `skipped` array and the end-of-run banner.
- `scripts/smoke-test-image.sh`: probes are passed to the container as positional arguments and each runs in its own `sh -ec`; the header explains why, and why every probe must be a single line.
- `scripts/test-smoke-probe-wrapper.sh` unit-tests that runner and its `.sh`/`.ps1` parity.
- `docs/smoke-tests.md`: "What each stage is for", "Partial runs, host gates, and skipping", "The banner is not complete", "The PowerShell mirror".

## Target files or areas

- `commands/smoke-test.sh`, `commands/smoke-test.ps1`.
- `scripts/smoke-test-image.sh`, `scripts/smoke-test-image.ps1` only if the probe-file reader belongs there.
- `scripts/test-smoke-probe-wrapper.sh` (or a sibling suite) for the reader and its parity.
- `docs/smoke-tests.md`, and the smoke summary in `README.md` ("Host Validation", "Continuous Integration") where it enumerates stages.

## Implementation notes

- **Which set.** Read `powbox.layers.set` from the image under test, not from `.powbox-layers`: the smoke test must describe the image it was given. The probes come from `docker/layers/<set>/smoke-probes.txt` in the working tree.
  - No label: the image is lean; there is no layer stage, and that is not a skip.
  - Label present, file absent: the set ships no probes; print one note line and continue. This is how a user opts out of layer tests.
  - Label present but the set directory is missing from the working tree: record it in `skipped` with a warning (the run is partial), and fail instead when `POWBOX_SMOKE_REQUIRE_IMAGE` is set.
  - Image digest label differs from the working tree's digest: warn that the image is stale relative to the probes, then run them anyway.
- **File format.** One probe per line. Blank lines and lines whose first non-space character is `#` are ignored. Strip a trailing CR. Nothing else is interpreted: the line is handed to the existing runner unchanged, so every guarantee in the `scripts/smoke-test-image.sh` header still holds. Order is preserved, because probes may rely on filesystem state left by an earlier one (the golangci-lint fixture probes do).
- **Stage name.** Run the file as its own stage right after Stage 1, labelled `Stage 1b — layer-set probes (<set>)` in both drivers, through the same `smoke-test-image` driver so a failure prints the index → probe manifest.
- **Capability gating.** Decide Stage 2 by whether `pg-dev-up` is on the image's `PATH`, and Stage 3 by whether `podman` is, using one short `docker run --rm --entrypoint sh` per check. Keep `POWBOX_SMOKE_SKIP_DB` and `POWBOX_SMOKE_SKIP_PODMAN` working as they do today; the capability check comes first.
- **Reporting.** Add a separate list for "not applicable to this image" and print it in the banner as information. It must not make the run "partial": a lean image without Podman has been fully tested. A skip requested by a variable or forced by the host stays in `skipped` as today.
- **No silent pass for `full`.** Capability gating alone would let a `full` image that lost Podman pass with Stage 3 reported as not applicable. The guard is the set's own probe file: tasks 071 and 073 must put a presence probe for every tool the set installs into `docker/layers/full/smoke-probes.txt`. State this rule in `docs/smoke-tests.md` so set authors know the probe file is what makes absence a failure.
- The scoped PostgreSQL suite that Stage 2 runs (`scripts/test-pg-dev-up-scoped.sh`) is gated together with the rest of Stage 2.
- PowerShell mirror: the two umbrellas must agree on stage labels, gating and banner wording, as `docs/smoke-tests.md` already requires.

## Acceptance criteria

- Against the current all-in-one image with no layer label, both drivers behave exactly as before: same stages, same banner.
- Against an image labelled with a set that has `smoke-probes.txt`, Stage 1b runs those probes in file order, and a failing probe fails the run and is named by index with the manifest printed.
- Against an image without `pg-dev-up`, Stage 2 is reported as not applicable and the run is not marked partial; likewise Stage 3 without `podman`.
- `POWBOX_SMOKE_SKIP_DB` and `POWBOX_SMOKE_SKIP_PODMAN` still record a skip and mark the run partial.
- A probe file with CRLF line endings, comments and blank lines yields the same probe list in bash and PowerShell.
- A multi-line or continuation-ending probe in the file is rejected by the existing driver check, not run truncated.
- `docs/smoke-tests.md` describes Stage 1b, the file format, the three label/file cases, the not-applicable list and the presence-probe rule.
- `shellcheck`, `shfmt -d`, PSScriptAnalyzer (`-Recurse`) and `./scripts/run-pure-shell-tests.sh` pass.

## Validation

- Unit-test the probe-file reader and its bash/PowerShell parity in the pure-shell suite, with fixtures for CRLF, comments, blank lines and an ordering-sensitive pair.
- The stage behaviour needs images. Ask the maintainer to run `./commands/smoke-test.sh` on the host against the current image (no behaviour change expected), and against a small `custom` set with a two-line probe file, one line deliberately failing. Tier 1 (task 065) covers the rest once it has landed.

## Review plan

Check that probe text from the file reaches the container exactly as written, by reading the reader next to the runner in `scripts/smoke-test-image.sh`. Then walk the banner logic for a lean image, a `full` image and a run with both skip variables set, confirming "not applicable" and "skipped" can never be confused.
