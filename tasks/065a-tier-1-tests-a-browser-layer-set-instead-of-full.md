# Task 065a — Make Tier 1 test the layer-set mechanism with a committed `browser` set instead of `full`

## Why this task exists

Task 065 made Tier 1 build and smoke two images: the lean one, and lean + `full`.
Once tasks 071 and 073 move the large toolchains into `full`, that second pass would build and cache the maintainer's own working set on every image-affecting PR. `full` is large, it is used by one person, and when one of its installers breaks, the fix is the maintainer's to make on their own machine. Paying CI time and Actions cache space for it buys little.

The maintainer decided (2026-10-03, after PR #162's first runs):

- **CI does not build `full`.** The maintainer builds and runs it by hand, and fixes it when it breaks.
- **CI uses a third, generally useful layer flavor instead.** It is a separate set, not a layer under `full`: a build selects exactly one set. It delivers roughly half of what `full` does, and it carries scenarios that a less technical user might run.
- **CI tests the mechanisms, not every tooling install.** If an upstream installer breaks, that is not this repository's to fix, and CI should not pay for testing infrastructure only the maintainer uses.

How this task implements that decision is the task writer's choice, recorded here so the implementer does not have to re-derive it:

- The third flavor is a committed set named `browser`, holding the browser stack that task 073 takes out of the base: Chromium, Marp CLI, Mermaid CLI and Playwright CLI. Pandoc's PDF output needs no browser after task 073, because that task adds Typst to the lean base. So the set's useful scenarios are a Marp deck to PDF, a Mermaid diagram to SVG, and headless Chromium printing HTML to PDF. Task 073 installs the stack in both `browser` and `full`.
- "Testing the mechanisms" means three end-to-end checks in Tier 1:
  - the set's agent notes reach both agents' seeded instruction templates;
  - Stage 1b runs the set's probes;
  - a failing probe is named by index.
- `full` keeps one cheap guard that needs no build. Tier 0 runs the layer-set contract scan over every committed set, so a `full` that breaks the contract is still caught.

This supersedes task 065's acceptance criterion that a change under `docker/layers/full/` alone triggers Tier 1.

## Scope

**In scope:**

1. A committed `docker/layers/browser/` set. Its `Dockerfile` has the same contract-compliant header shape as `docker/layers/full/Dockerfile`, including any contract bullet task 063a has added to that header by then. Its `smoke-probes.txt` is a skeleton: header comments, no probe lines. The header carries the same "keep this file even with no probe line" sentence as `docker/layers/full/smoke-probes.txt`. It has **no** `agent-notes.md`. It installs nothing yet; task 073 fills it.
2. `browser` becomes a documented, user-selectable committed set alongside `full`. That touches the set list and comment in `.powbox-layers.example`, the layer-set bullet in `docs/architecture.md` ("Rules the file map does not state"), and README "Layer sets". Each says that `browser` ships no tools yet. Where README "Layer sets" and `.powbox-layers.example` tell users to start their own set from a copy of `full`, mention `browser` as the smaller starting point. Also reword the `docker/layers/full/Dockerfile` header sentence that says the set exists so the chain is built and exercised, since CI now exercises the chain through `browser`.
3. `scripts/smoke-test-lib.sh` and `scripts/smoke-test-lib.ps1` (`smoke_layer_stage` / `Invoke-SmokeLayerStage`). The rule that makes a missing probe file or a missing set directory a hard failure currently covers only `full`. It must cover `browser` too. Otherwise, after this task, deleting `docker/layers/browser/smoke-probes.txt` would quietly turn Tier 1's Stage 1b into a note. Keep the set names in one list per driver rather than repeating string comparisons, and keep the two drivers' output identical. Extend `scripts/test-smoke-probe-wrapper.sh` with the `browser` cases. Its fixture builder (`new_fixture`) copies only `docker/layers/full` today, so it must copy `browser` too. Also reword every text that limits the keep-the-probe-file rule to `full`:
   - the comments in `smoke_layer_stage` / `Invoke-SmokeLayerStage`;
   - the comment above that call in `commands/smoke-test.sh` and `commands/smoke-test.ps1`;
   - README "Host Validation";
   - `docs/smoke-tests.md` "Layer-set probes (Stage 1b)": its label/file cases and the paragraph on why the `full` guard cannot be lost.
4. `.github/workflows/native-linux-build.yml`. The second pass selects `browser` instead of `full`, and every part of it follows:
   - step names and messages;
   - the label assertion (`powbox.layers.set=browser`);
   - the layers cache key: `docker/layers/browser/**`, the `browser` digest, and a `powbox-layers-browser-` prefix;
   - the `paths:` filter, which gains `!docker/layers/full/**` as its **last** entry, with a comment telling later editors to keep it last. That way a PR that changes only `full` does not start Tier 1.
5. Two mechanism checks:
   - **Seeded template.** In each pass, after its smoke step, the template baked into the agent image must equal the expected source byte for byte, for both agents. Write each extracted file to disk and compare it with `cmp`. A `$(...)` capture drops trailing newlines and would hide a difference at the end of the file. The template paths are `/home/node/.agent-container/claude/agent.md.tmpl` and `/home/node/.agent-container/codex/agent.md.tmpl`. The expected source is `docker/shared/container-agent.md.tmpl` in the lean pass and `.powbox-staging/agent.md.tmpl` in the `browser` pass. In the `browser` pass, also check the notes heading, ``## Additional tooling from the `browser` layer set``:
     - it must be present when the staged `.powbox-staging/agent.md.tmpl` differs from the core template, which is the staging script's own decision about whether the notes count;
     - it must be absent otherwise.

     The absent direction has teeth from the day this task lands, and the present direction once task 073 adds the notes.
   - **Failing probe.** In the `browser` pass, after its smoke step, run Stage 1b against the built image with a probe file of exactly two lines: one passing probe, then one failing probe. The passing probe prints nothing. Assert three things: the stage exits non-zero, and its combined output (`2>&1`) contains both the exact line `SMOKE PROBE 2 FAILED` and the manifest header that `scripts/smoke-test-image.sh` prints.
6. `.github/workflows/native-linux-ci.yml` (Tier 0): a step that runs `./scripts/layers-digest.sh docker/layers/<set>` for every committed set. That is every directory under `docker/layers/` except `custom`. The step fails on any non-zero exit. It needs no Docker.
7. Docs that say what Tier 1 builds and how `full` is covered: `README.md` ("Continuous Integration", including its list of Tier 1 trigger paths, which gains the `docker/layers/full/**` exclusion), `docs/smoke-tests.md` ("CI gating", and the Stage 1b section where it names `full` as the set whose probe file is required), and `AGENTS.md` ("Validating Changes").

**Out of scope:**

- Putting tools, notes or probes into `browser`. Task 073 does that (see "Effect on tasks 071 and 073").
- Changes to the smoke scripts or the staging scripts beyond the probe-file rule in item 3.
- Building `full` anywhere in CI.
- Changing how the layers image is cached: one `docker save` tarball, no `restore-keys`. Task 073 records the `browser` tarball size and job times once the set has content. The maintainer decides from those numbers whether the set should be rebuilt on each run instead of cached.

## Context and references

- **Depends on** tasks 065 (PR #162: the two-pass Tier 1 job and the layers cache), 067 (PR #164: `.powbox-staging/agent.md.tmpl` and its `COPY` into both agents' seed directories) and 069 (PR #165: Stage 1b in `scripts/smoke-test-lib.{sh,ps1}`). All three must be merged first. Land this task **before task 071**, so CI never builds the populated `full`.
- `.github/workflows/native-linux-build.yml`, job `build-and-smoke`. This task changes these steps:
  - "Compute image cache keys" (the `LAYERS_INPUTS` env and the `layers=` output);
  - "Select the full layer set";
  - "Restore layers image cache";
  - "Build full image (base + layers + agent, layer set full)";
  - "Smoke test - full image (image required, no image-gated self-skip)".

  The build step's currency check sources `scripts/build-image-lib.sh` and calls `layers_stale_reason`. That check works for any set, given the selected set and its digest, so only its inputs change.
- `paths:` semantics: GitHub evaluates the patterns in order, and a later positive pattern can include a path again after an earlier `!` pattern excluded it. The list already has `**/Dockerfile` after `docker/**`, and it matches `docker/layers/full/Dockerfile`. That is why the exclusion must come last.
- `scripts/smoke-test-lib.sh`, function `smoke_layer_stage`. It is the Stage 1b entry point both umbrellas call. It reads `docker/layers/<set>/smoke-probes.txt` from the working tree, keyed by the image's `powbox.layers.set` label. It takes the image and the repository root (`smoke_layer_stage <image> <repo-root>`), and it appends to the caller's `skipped` array. Declare that array first; it keeps the step's dependencies explicit. A failing probe is reported as `SMOKE PROBE <n> FAILED` with the index → probe manifest, by `scripts/smoke-test-image.sh`.
- `docker/agent/Dockerfile`, section "Per-agent seed assets": the two `COPY .powbox-staging/agent.md.tmpl …/agent.md.tmpl` lines.
- `scripts/layers-digest.sh` header: the contract. Exit status 1 means a contract violation, and every offending line or path is named on stderr.
- `docker/layers/custom/` is user-owned. `.gitignore` keeps only its `.gitkeep`, so in a CI checkout it has no Dockerfile and the scan would reject it.
- `docker/layers/full/Dockerfile` header: the shape a new set's Dockerfile follows. Every `COPY`/`ADD` carries `--chmod`, and there is no `ONBUILD`. Once task 063a (PR #163) lands, no `RUN` may bind-mount the build context either. The skeleton has no `RUN`, so it complies either way.

## Target files or areas

- New: `docker/layers/browser/Dockerfile`, `docker/layers/browser/smoke-probes.txt`.
- `scripts/smoke-test-lib.sh`, `scripts/smoke-test-lib.ps1` (CRLF, ASCII only), `scripts/test-smoke-probe-wrapper.sh`, and the comments in `commands/smoke-test.sh` and `commands/smoke-test.ps1`.
- `.github/workflows/native-linux-build.yml`, `.github/workflows/native-linux-ci.yml`.
- `.powbox-layers.example`, `README.md`, `docs/architecture.md`, `docs/smoke-tests.md`, `AGENTS.md`.
- `tasks/071-move-self-contained-toolchains-into-the-full-layer-set.md` and `tasks/073-move-podman-postgresql-and-browser-stack-add-typst.md` were amended when this task was written (see "Effect on tasks 071 and 073"). Check that they still match what lands.

## Implementation notes

- **Failing-probe check, decided route.** In one `bash` step:
  1. Set a `trap` that restores the committed file with `git checkout -- docker/layers/browser/smoke-probes.txt` on `EXIT`.
  2. Overwrite that file with exactly the two probe lines.
  3. Declare `skipped=()`, source `scripts/smoke-test-lib.sh`, and call `smoke_layer_stage powbox-agent:latest "$GITHUB_WORKSPACE"`, capturing its status and output.
  4. Assert on those.

  Do not rerun the umbrella. Do not use a temporary set copy: Stage 1b keys the set off the image's label, so a copy under another name is never read. The overwrite changes the working tree's digest, so Stage 1b's stale-image warning is expected in this step's output and is not a failure. The trap keeps the working tree clean for every later step. The step runs under `set -e`, so capture the status with `out="$(… 2>&1)" || rc=$?` rather than a bare capture.
- **The seeded-template check reads files out of the image**, for example with `docker run --rm --entrypoint cat powbox-agent:latest <path>`. It does not start the entrypoint. The hooks' `envsubst` render is unchanged by the layer-set work and is pinned by `scripts/test-stage-agent-template.sh`. So this check covers what the hook tests cannot: that the staged file reached both agents' images.
- **Tier 0 scan.** Put the step next to the other static guards, before the pure-shell suites. Loop over `docker/layers/*/`, skip `custom` by name, and print each set's name as it is scanned, so a failure points at the set. Do not skip a directory just because it has no Dockerfile: a committed set that loses its Dockerfile must fail.
- Keep the workflow's comment style, where each step explains why it exists. Replace the comments that justify building `full` rather than appending to them. That includes the workflow header, the cache-key comments, and the PowerShell Stage 6 step's comment ("Runs once, against the full image"), which now runs against the `browser` image.
- `browser`'s Dockerfile must pass the Tier 0 scan, and its digest must be stable across checkouts. Use LF line endings and keep the set to regular files only.

## Effect on tasks 071 and 073

Both were amended alongside this task:

- **071** no longer expects Tier 1 to build `full`. Its "both passes" are lean + `browser`. The `full` image is verified by the maintainer's host build, which its Validation section already asks for. Its CI cache-key note now refers only to the base key.
- **073** installs the browser stack (Chromium and its env, Marp CLI, Mermaid CLI, Playwright CLI) in **both** `docker/layers/browser/Dockerfile` and `docker/layers/full/Dockerfile`, as verbatim copies of the same blocks. It writes the browser rows into both sets' `agent-notes.md`. It adds the browser probes to both sets' `smoke-probes.txt`, with at least one functional probe per tool: a Marp deck to PDF, a Mermaid diagram to SVG, and a headless Chromium print-to-PDF of an HTML file. The Podman and PostgreSQL moves go to `full` only.
- **073** also records the maintainer's decision that Stages 2 and 3 leave CI. The Stage 2 and Stage 3 code and `scripts/test-pg-dev-up-scoped.sh` stay, and only that suite's Tier 1 `paths:` entry is removed.
- **073** also replaces the "`browser` ships no tools yet" wording this task writes into `.powbox-layers.example`, README "Layer sets", `docs/architecture.md` and the `browser` Dockerfile header.

## Acceptance criteria

- A Tier 1 run on an image-affecting PR shows the lean pass and then the `browser` pass, and no step builds or selects `full`. The `browser` pass fails unless the agent image carries `powbox.layers.set=browser`.
- A PR that changes only files under `docker/layers/full/` triggers Tier 0, including the new contract scan, but not Tier 1. This includes a PR that changes only `docker/layers/full/Dockerfile`. This criterion rests on GitHub's documented `paths:` semantics and the entry's position, which a reviewer checks by reading. It needs no throwaway PR.
- In both passes, the two seeded `agent.md.tmpl` files equal the expected source byte for byte: the core template for lean, `.powbox-staging/agent.md.tmpl` for `browser`. With no `docker/layers/browser/agent-notes.md`, the notes heading is absent, and the check would fail if it appeared.
- The failing-probe check fails its own assertion if Stage 1b exits zero or does not name probe 2. Show this once on the PR with a perturbed copy of the check, then revert. After the step, `docker/layers/browser/smoke-probes.txt` matches the committed file, whether the step passed or failed.
- A `browser` image whose working tree lacks `docker/layers/browser/smoke-probes.txt`, or the whole `docker/layers/browser/` directory, fails Stage 1b in both drivers, exactly as `full` does. The unit suite covers both cases. No doc or comment still limits the keep-the-probe-file rule to `full`.
- Tier 0 fails, naming the set, when any committed set other than `custom` violates the layer-set contract or has no Dockerfile. Show this once with a deliberate violation in a scratch commit on the PR, for example a `COPY` without `--chmod` in `browser`, then revert it. Tier 0 passes on a checkout whose `custom/` holds only `.gitkeep`.
- A run that hits both caches performs no layers bake in the `browser` pass, as the currency check already enforces.
- `.powbox-layers.example`, README "Layer sets" and `docs/architecture.md` list `browser` as a selectable committed set.
- `README.md`, `docs/smoke-tests.md` and `AGENTS.md` say that Tier 1 builds lean + `browser`, that `full` is the maintainer's set built by hand, and that Tier 0 contract-scans every committed set. No claim is left that CI builds `full`.
- `actionlint` passes on both workflows. `shellcheck`, `shfmt -d`, PSScriptAnalyzer (`-Recurse`) and `./scripts/run-pure-shell-tests.sh` pass. `markdownlint-cli2` reports no new findings on the changed Markdown.

## Validation

- Locally:
  - `actionlint` on both workflows;
  - `./scripts/layers-digest.sh docker/layers/browser` and `… docker/layers/full` both exit 0;
  - `bash scripts/test-smoke-probe-wrapper.sh`, `bash scripts/test-layer-sets.sh` and `./scripts/run-pure-shell-tests.sh` pass.
- Extract the failing-probe and seeded-template snippets from the YAML and run them against a stub `docker` on `PATH`. Do this in a disposable clone (`dc-enter`), not the worktree: the trap's `git checkout --` needs a repository. Cover the pass, fail, notes-present and notes-absent cases, and confirm the trap restores the probe file when the assertion fails.
- On the PR:
  - check the run log for both passes' label assertions and template checks;
  - run the two one-off negative demonstrations from the acceptance criteria;
  - re-run once to confirm a double cache hit performs no bake;
  - record the cold and warm job times and the `browser` cache size in the PR description.

## Review plan

Read the Tier 1 job top to bottom as a runner would. Check that nothing still names `full` except the comments that explain why CI does not build it, and that the failing-probe step restores the working tree on every exit path. Then confirm three things:

- the `paths:` exclusion is the last entry;
- the Tier 0 loop skips only `custom`;
- the probe-file rule names `browser` in both drivers.

Finally check that the amended tasks 071 and 073 agree with this one.
