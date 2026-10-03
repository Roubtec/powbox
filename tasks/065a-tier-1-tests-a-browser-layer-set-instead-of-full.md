# Task 065a — Make Tier 1 test the layer-set mechanism with a committed `browser` set instead of `full`

## Why this task exists

Task 065 made Tier 1 build and smoke two images: the lean one, and lean + `full`.
Once tasks 071 and 073 move the large toolchains into `full`, that second pass would build and cache the maintainer's own working set on every image-affecting PR. `full` is large, it is used by one person, and when one of its installers breaks, the fix is the maintainer's to make on their own machine. Paying CI time and Actions cache space for it buys little.

The maintainer decided (2026-10-03, after PR #162's first runs):

- **CI does not build `full`.** The maintainer builds and runs it by hand, and fixes it when it breaks.
- **CI tests the mechanism with a second committed set, `browser`.** It is mid-sized and generally useful: the browser stack that task 073 takes out of the base (Chromium, Marp CLI, Mermaid CLI, Playwright CLI). It is a separate flavor rather than a layer under `full`, since a build selects exactly one set. Task 073 therefore installs the browser stack in both sets.
- **CI checks the mechanisms end to end, not every install.** That means the set's agent notes reaching both agents' instruction templates, Stage 1b running the set's probes, and a failing probe being named. The set's own probes, which task 073 writes, decide how much of the tooling is exercised.

`full` still gets one cheap guard: Tier 0 runs the layer-set contract scan over every committed set, so a `full` that breaks the contract is caught without being built.

## Scope

**In scope:**

1. A committed `docker/layers/browser/` set: a `Dockerfile` with the same contract-compliant header shape as `docker/layers/full/Dockerfile`, a skeleton `smoke-probes.txt` (header comments, no probe lines), and **no** `agent-notes.md`. It installs nothing yet; task 073 fills it.
2. `.github/workflows/native-linux-build.yml`: the second pass selects `browser` instead of `full`, and all of its parts follow:
   - step names and messages;
   - the label assertion (`powbox.layers.set=browser`);
   - the layers cache key (`docker/layers/browser/**`, the `browser` digest, and a `powbox-layers-browser-` prefix);
   - the `paths:` filter, which gains `!docker/layers/full/**` after `docker/**`, so a PR that changes only `full` does not start Tier 1.
3. Two mechanism checks added to the second pass, after its smoke step:
   - **Seeded template.** The template baked into the agent image for each agent must equal `.powbox-staging/agent.md.tmpl` byte for byte. That is `/home/node/.agent-container/claude/agent.md.tmpl` and `/home/node/.agent-container/codex/agent.md.tmpl`. Run the same check in the lean pass against `docker/shared/container-agent.md.tmpl`. Also check the notes heading, ``## Additional tooling from the `browser` layer set``:
     - it must be present when `docker/layers/browser/agent-notes.md` has non-whitespace content;
     - it must be absent otherwise.

     The absent direction applies from the day this task lands. The present direction applies once task 073 adds the notes.
   - **Failing probe.** Run Stage 1b's code path against the built image with a probe file that holds one passing line followed by one failing line. Assert that it exits non-zero, that it names probe 2, and that it prints the index → probe manifest.
4. `.github/workflows/native-linux-ci.yml` (Tier 0): a step that runs `./scripts/layers-digest.sh docker/layers/<set>` for every directory under `docker/layers/` and fails on any non-zero exit. The step needs no Docker.
5. Docs that say what Tier 1 builds, and how `full` is covered: `README.md` ("Continuous Integration", "Layer sets"), `docs/smoke-tests.md` ("CI gating"), `AGENTS.md` ("Validating Changes").

**Out of scope:**

- Putting tools, notes or probes into `browser`. Task 073 does that (see "Effect on tasks 071 and 073").
- Any change to the smoke scripts or the staging scripts themselves.
- Building `full` anywhere in CI.
- Changing how the layers image is cached (one `docker save` tarball, no `restore-keys`). Task 073 records the `browser` tarball size and job times once the set has content. The maintainer decides from those numbers whether the set should be rebuilt each run instead of cached.

## Context and references

- **Depends on** tasks 065 (PR #162: the two-pass Tier 1 job and the layers cache), 067 (PR #164: `.powbox-staging/agent.md.tmpl` and its `COPY` into both agents' seed directories) and 069 (PR #165: Stage 1b in `scripts/smoke-test-lib.{sh,ps1}`). All three must be merged first. Land this task **before task 071**, so that CI never builds the populated `full`.
- `.github/workflows/native-linux-build.yml`, job `build-and-smoke`. The steps this task changes are:
  - "Compute image cache keys" (the `LAYERS_INPUTS` env and the `layers=` output);
  - "Select the full layer set";
  - "Restore layers image cache";
  - "Build full image (base + layers + agent, layer set full)";
  - "Smoke test - full image (image required, no image-gated self-skip)".

  The build step's currency check sources `scripts/build-image-lib.sh` and calls `layers_stale_reason`. It is set-agnostic as long as it is given the selected set and that set's digest, so only its inputs change.
- `scripts/smoke-test-lib.sh`: the Stage 1b entry point that both umbrellas call (`smoke_layer_stage`), and the probe-file reader it uses. Stage 1b reads `docker/layers/<set>/smoke-probes.txt` from the working tree, keyed by the image's `powbox.layers.set` label. A failing probe is reported by index through `scripts/smoke-test-image.sh`.
- `docker/agent/Dockerfile`, section "Per-agent seed assets": the two `COPY .powbox-staging/agent.md.tmpl …/agent.md.tmpl` lines.
- `scripts/layers-digest.sh` header: the contract. Exit status 1 means a contract violation, and every offending line or path is named on stderr.
- `docker/layers/full/Dockerfile` header: the shape a new set's Dockerfile follows. Every `COPY`/`ADD` carries `--chmod`, there is no `ONBUILD`, and no `RUN --mount` binds the build context.

## Target files or areas

- New: `docker/layers/browser/Dockerfile`, `docker/layers/browser/smoke-probes.txt`.
- `.github/workflows/native-linux-build.yml`, `.github/workflows/native-linux-ci.yml`.
- `README.md`, `docs/smoke-tests.md`, `AGENTS.md`.
- `tasks/071-move-self-contained-toolchains-into-the-full-layer-set.md` and `tasks/073-move-podman-postgresql-and-browser-stack-add-typst.md` were already amended when this task was written (see "Effect on tasks 071 and 073"). Check that they still match what lands.

## Implementation notes

- **The failing-probe check must not leak into later steps.** One way is to write a throwaway set: copy `docker/layers/browser/` to a temporary path under `docker/layers/`, append the failing line to the copy's probe file, and point Stage 1b at it. Another is to append to the committed probe file and restore it with `git checkout -- docker/layers/browser/smoke-probes.txt`. Both must be undone in an `always()`-safe way before the PowerShell Stage 6 step runs.
  - A temporary set copy needs an image whose label names it, so the restore route is usually simpler.
  - Either way the working-tree digest changes, so Stage 1b's stale-image warning is expected in that step's output and is not a failure.
  - Call the library function directly from a small bash snippet (source `scripts/smoke-test-lib.sh`, as the build step already sources `scripts/build-image-lib.sh`). Do not rerun the umbrella.
- **The seeded-template check reads files out of the image**, for example with `docker run --rm --entrypoint cat powbox-agent:latest <path>`. It does not start the entrypoint. The hooks' `envsubst` render is unchanged by the layer-set work and is pinned by `scripts/test-stage-agent-template.sh`, so this check covers what the hooks do not: that the staged file reached both agents' images.
- **The `!docker/layers/full/**` exclusion** must come after `docker/**` in the list, since GitHub applies `paths:` patterns in order. A PR that touches `full` and anything else image-affecting still runs Tier 1.
- **Tier 0 scan placement.** Put the step next to the other static guards, before the pure-shell suites. Use a `for` loop over `docker/layers/*/` that names each set as it goes, so a failure points at the set.
- Keep the file's comment style: each step explains why it exists. Replace the comments that justify building `full` rather than appending to them.
- `browser`'s Dockerfile must pass the Tier 0 scan, and its digest must be stable across checkouts. Use LF line endings and keep it to regular files only.

## Effect on tasks 071 and 073

Both were amended in the same commit that wrote this task:

- **071** no longer expects Tier 1 to build `full`. Its "both passes" are lean + `browser`. The `full` image contents are verified by the maintainer's host build, which its Validation section already asks for. Its CI cache-key note now refers only to the base key.
- **073** installs the browser stack (Chromium and its env, Marp CLI, Mermaid CLI, Playwright CLI) in **both** `docker/layers/browser/Dockerfile` and `docker/layers/full/Dockerfile`, as verbatim copies of the same blocks. It writes the browser rows into both sets' `agent-notes.md`. It adds the browser probes to both sets' `smoke-probes.txt`, including at least one functional probe for each tool: a Marp deck to PDF, a Mermaid diagram to SVG, and a headless Chromium print-to-PDF of an HTML file. That way the `browser` pass exercises real, generally useful scenarios. The Podman and PostgreSQL moves go to `full` only.

## Acceptance criteria

- A Tier 1 run on a PR that touches `docker/**` shows the lean pass and then the `browser` pass, and no step builds or selects `full`. The `browser` pass fails unless the agent image carries `powbox.layers.set=browser`.
- A PR that changes only files under `docker/layers/full/` triggers Tier 0 (including the new contract scan) but not Tier 1.
- In both passes, the two seeded `agent.md.tmpl` files equal the expected source byte for byte: the core template for lean, `.powbox-staging/agent.md.tmpl` for `browser`. With no `docker/layers/browser/agent-notes.md`, the notes heading is absent, and the check would fail if it appeared.
- The failing-probe check fails its assertion if Stage 1b exits zero or does not name probe 2. Show this once on the PR with a perturbed copy of the check, then revert it. Afterwards the working tree is clean again before the next step runs.
- Tier 0 fails, naming the set, when any committed set violates the layer-set contract. Show this once with a deliberate violation in a scratch commit on the PR (for example a `COPY` without `--chmod` in `browser`), then revert it.
- A run that hits both caches performs no layers bake in the `browser` pass, as the currency check already enforces.
- `actionlint` passes on both workflows, and `markdownlint-cli2` reports no new findings on the changed Markdown.
- `README.md`, `docs/smoke-tests.md` and `AGENTS.md` say that Tier 1 builds lean + `browser`, that `full` is the maintainer's set built by hand, and that Tier 0 contract-scans every committed set. No claim is left that CI builds `full`.

## Validation

- Locally: `actionlint` on both workflows; `./scripts/layers-digest.sh docker/layers/browser` and `… docker/layers/full` both exit 0; `bash scripts/test-layer-sets.sh` and `./scripts/run-pure-shell-tests.sh` pass.
- Extract the failing-probe and seeded-template snippets from the YAML and run them against a stub `docker` on `PATH`. Do it in a temporary directory outside the worktree, as the task 065 round-3 fixer did for the currency check. Cover the pass, fail and notes-heading cases.
- On the PR:
  - check the run log for both passes' label assertions and both template checks;
  - run the two one-off negative demonstrations from the acceptance criteria;
  - re-run once to confirm a double cache hit performs no bake;
  - record the cold and warm job times and the `browser` cache size in the PR description.

## Review plan

Read the Tier 1 job top to bottom as a runner would, and check two things. First, that nothing still names `full` except the comments that explain why CI does not build it. Second, that the failing-probe step restores the working tree on every exit path. Then confirm the Tier 0 loop covers every directory under `docker/layers/`, including ones added later, and that the amended tasks 071 and 073 agree with this one.
