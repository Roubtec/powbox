# 065 — Build and smoke both the lean image and lean + `full` in Tier 1

## Why this task exists

Task 063 adds an optional layer-set image between the base and the agent image.
Once tools start moving out of the base (tasks 071 and 073), there are two supported images: the lean one a new user gets, and lean + `full`, which the maintainer runs.
If CI builds only one of them, the other rots: the lean image can silently depend on a tool that moved, and the committed `full` set can stop building.

This task makes Tier 1 build and smoke both, **before** any tool moves, so tasks 071 and 073 land under coverage.

## Scope

**In scope:**

1. `.github/workflows/native-linux-build.yml`: a second build + smoke pass with the `full` set selected, after the existing lean pass.
2. Caching for the layers image, alongside the existing base-image cache.
3. The workflow's `paths:` filter, so task 063's new build-input scripts trigger Tier 1.
4. The documentation that describes what Tier 1 covers.

**Out of scope:**

- Any change to the smoke scripts themselves (task 069).
- Moving tools (tasks 071, 073). At the time this lands `full` is still the skeleton from task 063, so the second pass exercises the chain, not extra tools.
- Tier 0 (`.github/workflows/native-linux-ci.yml`).

## Context and references

- Depends on task 063 (selector, `layers` target, `powbox.layers.*` labels, and the `agent` target's currency test for the layers image).
- `.github/workflows/native-linux-build.yml`, job `build-and-smoke`: the steps "Restore base image cache", "Build image (base + agent)", "Smoke test (image required, no image-gated self-skip)", and the PowerShell Stage 6 step that follows. Read the long comments on each; they explain why the cache is a `docker save` tarball and why only Stage 6 runs under PowerShell.
- `docs/smoke-tests.md` ("CI gating") and `README.md` ("Continuous Integration") describe Tier 1 and must stay accurate.
- The workflow's `paths:` filter already contains `docker/**`, which covers `docker/layers/**`. It has `scripts/build-image.*` but nothing that matches task 063's `scripts/layers-select.*` and `scripts/layers-digest.*`, so a PR touching only those would change what the images are stamped with and how the set is chosen, with no Tier 1 run.

## Target files or areas

- `.github/workflows/native-linux-build.yml`.
- `docs/smoke-tests.md`, `README.md`, and `AGENTS.md` ("Validating Changes") where they state what Tier 1 builds.

## Implementation notes

- **One job, two sequential passes.** `powbox-agent:latest` is a single tag built on one parent at a time, so the passes cannot share an agent image:
  1. Lean pass: no `.powbox-layers`; build as today; run `./commands/smoke-test.sh`.
  2. Full pass: write `full` into `.powbox-layers` (it is gitignored, so the tree stays clean and the stamped commit does not gain `-dirty`), run `./build.sh agent`, assert the agent image carries `powbox.layers.set=full`, run `./commands/smoke-test.sh` again.
- The agent install layers (Codex, Claude) are built twice because their parent differs. That is the accepted cost; do not introduce a second agent tag to avoid it.
- **Assert what was built.** After each build, check the agent image's `powbox.layers.set` label (empty for lean, `full` for the second pass). A pass that silently built the wrong parent must fail the job rather than smoke the same image twice.
- **Paths filter.** Add `scripts/layers-*` to the `paths:` list, next to `scripts/build-image.*`.
- **Layers cache.** Cache the layers image as a tarball like the base: key it on the base cache key plus `hashFiles('docker/layers/full/**', 'scripts/layers-select.sh', 'scripts/layers-digest.sh')`, with no `restore-keys` for the same reason the base cache has none. The two scripts belong in the key because they decide the labels the tarball was stamped with: a changed digest algorithm against an old tarball would make every run rebuild the set while the cache entry, which is immutable, stays stale. This is nearly free while `full` is a skeleton and matters once tasks 071 and 073 move the large toolchains in.
- **A cache hit must be recognised.** On a hit, `docker load` the layers tarball before `./build.sh agent`; on a miss, let `./build.sh agent` bake it and save the tarball afterwards. Task 063's `agent` target skips the layers bake only when the loaded image's `powbox.layers.set`, `powbox.layers.digest` and `powbox.layers.base.id` labels match the working tree and the loaded base image. Confirm in the run log that a hit on both tarballs performs no layers bake. A bake there means the currency test does not survive `docker save` / `docker load` on the runner; that is a defect to fix in the build script, not something to work around in the workflow.
- **Base cache key.** Review the `hashFiles(...)` list of the base cache against `scripts/base-source-files.txt` and add `scripts/layers-select.sh` / `scripts/layers-digest.sh` only if the base build reads them (it should not).
- **PowerShell Stage 6 step.** Run it once, after the full pass. It is a launcher-level check and gains nothing from running twice.
- **Disk and time.** Hosted runners have limited disk. Prune dangling images between the passes if the second pass runs short, and measure the job time on the PR; raise `timeout-minutes` only with the measured number in the comment.
- **Cache quota.** `docker save` of the layers image writes every layer it contains, the base's included, so the two tarballs store the base layers twice. They count against the repository's Actions cache quota (10 GB by default, least recently used entries evicted) as well as runner disk, and each PR holds its own pair. Record both compressed cache sizes in the PR description. If they crowd the quota once tasks 071 and 073 have landed, raise it with the maintainer: saving both images into one tarball under one key would store the shared layers once, but a change under `docker/layers/full/` alone would then miss the base cache too, which the acceptance criteria below rule out.
- Keep `POWBOX_SMOKE_REQUIRE_IMAGE: '1'` on both smoke steps.
- Follow the file's existing comment style: each step explains why it exists.

## Acceptance criteria

- A Tier 1 run on a PR that touches `docker/**` shows two clearly named build steps and two smoke steps, lean first.
- The lean pass fails if the built agent image carries a `powbox.layers.set` label; the full pass fails if it does not carry `full`.
- A change under `docker/layers/full/` alone triggers Tier 1 and misses only the layers cache, not the base cache.
- A change to `scripts/layers-select.*` or `scripts/layers-digest.*` alone triggers Tier 1.
- A run that hits both caches performs no layers bake in the full pass.
- Both smoke steps run with the image required.
- `actionlint` passes on the workflow.
- `docs/smoke-tests.md` and `README.md` state that Tier 1 covers both images, with no leftover claim that it builds a single image.

## Validation

Run `actionlint .github/workflows/native-linux-build.yml` locally.
The workflow itself can only be validated by its own run on the PR: confirm from the run log that the two passes built different parents (the label assertions) and record the total job time in the PR description.

## Review plan

Read the workflow top to bottom as a runner would execute it, checking that nothing from the lean pass (the selector file, a loaded tarball, an image tag) leaks into the full pass in a way that would hide a failure, and that a cache hit on either tarball can never load an image that is stale relative to its inputs.
