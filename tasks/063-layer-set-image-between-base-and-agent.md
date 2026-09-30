# 063 — Build an optional layer-set image between the base and the agent image

## Why this task exists

The base image carries every tool its maintainer's projects need (Go, .NET, PowerShell, Chromium, Podman, …), which is about 2.7 GB of the 5.5 GB root filesystem and irrelevant to most other users.
The agreed direction is a **lean base** plus an optional, user-selectable **layer set** built on top of it, so a new user gets a small useful image out of the box and anyone can add their own toolchains without editing tracked files.

This task delivers the mechanism only: the image chain, the selector, staleness detection and the update flow.
It moves **no tool** out of the base.
The tool moves are tasks 071 and 073; CI coverage is 065; agent-facing notes are 067; smoke composition is 069.

## Scope

**In scope:**

1. A three-image chain: `powbox-agent-base:latest` → `powbox-agent-layers:latest` (only when a set is selected) → `powbox-agent:latest`.
2. The layer-set layout under `docker/layers/`, a gitignored selector file `.powbox-layers`, and a committed `.powbox-layers.example`.
3. A committed **skeleton** `docker/layers/full/` set whose Dockerfile adds nothing yet, so the chain is exercised before any tool moves.
4. A directory digest for the selected set, recorded on the layers image and compared by the update check.
5. `agent-check-updates` / `agent-update` awareness: a `layers` row, and a rebuild path that rebuilds only the layers and agent images, from cache.
6. Bash and PowerShell parity for every script touched.
7. Documentation of the mechanism.

**Out of scope:**

- Moving any tool, template row or smoke probe (tasks 071, 073).
- Agent instruction notes for a layer set (task 067) and layer smoke probes (task 069).
- Stacking several sets. Exactly one set is selected, or none.
- Backward compatibility with existing images. The maintainer rebuilds; do not add migration shims.

## Context and references

- `docker/agent/Dockerfile` already starts with `ARG BASE_IMAGE=powbox-agent-base:latest` and `FROM ${BASE_IMAGE}`, and `docker-bake.hcl` passes `BASE_IMAGE` to the `agent` target. Pointing the agent at another parent needs no Dockerfile edit.
- `scripts/base-source-digest.sh` and its `.ps1` sibling define the existing recipe digest (manifest `scripts/base-source-files.txt`, label `powbox.base.recipe.digest`). The new digest follows the same algorithm and the same "build-time and check-time must call one script" rule stated in that file's header.
- `commands/check-updates.sh` documents the porcelain contract in its header and emits the literal `update available` marker that `agent-update` greps for.
- `shell/powbox.sh`: `agent-update`, `_powbox_build_from_table`, `agent-full-rebuild`, `agent-image-info`. `shell/powbox.ps1` mirrors them (`agent-update`, `_Powbox-BuildFromTable`, `agent-full-rebuild`, `agent-image-info`).
- `scripts/build-image.sh`: the `TARGET` dispatch at the end of the file, `run_bake`, `ensure_base_image`, `base_image_id`, `resolve_codex_commit`. `scripts/build-image.ps1` mirrors it.
- `docs/skills-refresh-and-provenance.md` describes the per-layer commit provenance this task must keep truthful.

## Design decisions already made

These were settled with the maintainer; implement them rather than reopening them.

- **Layout.**

  ```text
  docker/layers/full/Dockerfile     committed; the maintainer's bundle (skeleton in this task)
  docker/layers/custom/.gitkeep     committed; everything else in this directory is gitignored
  .powbox-layers                    gitignored; one line naming the selected set
  .powbox-layers.example            committed; a commented template for the selector
  ```

- **Selector.** `.powbox-layers` at the repo root. The first line that is neither blank nor a `#` comment, trimmed of whitespace and a trailing CR, is the set name. It must match `^[a-z0-9][a-z0-9._-]*$` and `docker/layers/<name>/Dockerfile` must exist. A missing or effectively empty file means **no set: the lean image**. An invalid name or a missing Dockerfile is a hard error naming the path, never a silent fallback to lean.
- **Why a file and not an environment variable.** The build, the update check and the smoke test run from different shells (bash and PowerShell) and must agree, or the update check reports permanent false staleness.
- **Build context is the set's own directory**, not the repo root. A copied set then works unchanged, and the digest covers exactly the build inputs. A set that needs a repo file keeps its own copy.
- **Layer Dockerfile contract.** It starts with `ARG BASE_IMAGE=powbox-agent-base:latest` and `FROM ${BASE_IMAGE}`, switches to `USER root` for installs, and ends with `USER node`. The base's final user is `node`, and the agent Dockerfile assumes that.
- **Image name.** `powbox-agent-layers:latest`, whichever set is selected. It is deliberately not named after the `custom` directory, so an image built from `full` is not called "custom".
- **Digest.** sha256 over every regular file under the selected set directory, recursively, excluding `.gitkeep`: paths relative to the set directory, forward slashes, byte-sorted, same `"<sha256>  <path>\n"` buffer format as `base-source-digest`. Stamp it and the set name on the layers image as labels `powbox.layers.digest` and `powbox.layers.set`, plus `powbox.commit.layers` for provenance. Set these from the bake target (its `labels` attribute), not from the user's Dockerfile, so a custom Dockerfile cannot omit them. The agent image inherits them from its parent; an agent built directly on the base has none, which reads as "no set".
- **Targets.** `build.sh` / `build.ps1` accept `base | layers | agent | all`.
  - `base`: base only, as today.
  - `layers`: the layers image only; errors clearly when no set is selected.
  - `agent`: ensure the base exists (as `ensure_base_image` does), then ensure the layers image is **current** (build it when it is absent or its `powbox.layers.set` / `powbox.layers.digest` labels differ from the working tree), then build the agent on it. With no set selected, build the agent on the base.
  - `all`: base, then layers when a set is selected, then agent.
- **Update flow.** A stale base keeps today's behaviour (`all --pull --no-cache`), which now includes the layers image. A stale layer set with a current base rebuilds through the `agent` target **from cache**, with both agent binaries pinned to their baked versions unless they are stale too. No new flags.

## Target files or areas

- `docker-bake.hcl` — a `layers` target (context = the selected set directory, `BASE_IMAGE` arg, tag `powbox-agent-layers:latest`, the three labels), and variables for the set directory, name, digest and commit. The `all`/`default` groups cannot include it unconditionally; let the build script pass explicit targets.
- `scripts/build-image.sh`, `scripts/build-image.ps1` — selector resolution, the new targets, `BASE_IMAGE` selection for the agent bake, an `ensure`-style step for the layers image.
- New `scripts/layers-select.sh` + `.ps1` (print the selected set name, or nothing) and `scripts/layers-digest.sh` + `.ps1`. One implementation per language, called by every consumer.
- `commands/check-updates.sh`, `commands/check-updates.ps1` — the `layers` porcelain row and the human report row.
- `shell/powbox.sh`, `shell/powbox.ps1` — `agent-update`, `agent-full-rebuild`, `agent-image-info`.
- `build.sh`, `build.ps1` — only if they restrict targets.
- `.gitignore` — `.powbox-layers`, and `docker/layers/custom/*` with a `!docker/layers/custom/.gitkeep` exception.
- `docker/layers/full/Dockerfile` (skeleton: the contract lines and a comment), `docker/layers/custom/.gitkeep`, `.powbox-layers.example`.
- `README.md` ("Layout", "Build Modes", "Profile Shortcuts"), `docs/architecture.md` ("Rules the file map does not state"), `docs/skills-refresh-and-provenance.md`, `AGENTS.md` if its key-path or validation text is affected.

## Implementation notes

- **Porcelain row.** Add `layers<TAB><ok|stale><TAB><baked|-><TAB><wanted|->` where each value is `<set>@<digest>` or `-` for none. Read "baked" from the labels on `powbox-agent:latest`, because that is what containers run. `stale` when they differ, including selected-but-built-lean and lean-but-built-on-a-set. Keep the three existing rows and their meaning unchanged.
- **Human report.** One `Layers` row between `Base` and `Codex`, in the existing format. It must print the literal `update available` marker when stale, because `agent-update` greps the report for it. With no set selected and none baked, print a row that says so (for example `(none — lean image)`) rather than omitting it.
- **`agent-update`.** Today a run with no stale binary and no `--refresh` prints "Nothing to update" before building. A stale `layers` row must reach the build instead: the `agent` target with `_powbox_build_from_table` pinning both binaries.
- **Codex-layer provenance.** `resolve_codex_commit` decides whether the Codex install layer will be reused by comparing `base_image_id` with the previous agent's `powbox.base.image.id` label. The Codex layer's parent is now the layers image when a set is selected, so compare against the **actual parent**, resolved after the layers image has been ensured. A label-only change to the parent (new digest or commit label, identical filesystem layers) changes its image ID without invalidating the Codex layer, so compare the parent's layer chain (`docker image inspect --format '{{json .RootFS.Layers}}'`) rather than its `.Id`, or provenance will misattribute a reused layer to `HEAD`.
- **Cache behaviour to verify.** Editing a file in the set that the layer Dockerfile does not `COPY` changes the digest label but no filesystem layer. Confirm on a real build that this does not reinstall Codex and Claude in the agent image. If it does, record the digest on the agent image's top metadata layer instead and leave the layers image unstamped.
- **`--no-cache` and `--pull`.** Keep their current meaning for `base` and `agent`. `layers --no-cache` rebuilds the set fresh; `all --no-cache` covers all three.
- **Orphaned image.** Switching from a set back to lean leaves `powbox-agent-layers:latest` unused. Say so in the docs with the `docker image rm` line; do not auto-delete it.
- **No build happens inside a powbox container.** `scripts/build-image.sh` already fails fast under the Podman shim; keep that guard first.
- Windows checkouts: read the selector tolerating CRLF and a UTF-8 BOM in both languages.
- `.powbox-layers.example` content: comment lines explaining the three choices (absent = lean, `full`, `custom`) and a single uncommented `full` line is fine, since the file is only a template.

## Acceptance criteria

- With no `.powbox-layers`, `./build.sh all` produces the base and agent images exactly as today, no `powbox-agent-layers` image is built, and `agent-check-updates` shows the layers row as none and up to date.
- With `.powbox-layers` containing `full`, `./build.sh all` builds three images, `powbox-agent:latest` is built FROM `powbox-agent-layers:latest`, and it carries `powbox.layers.set=full` and the digest of `docker/layers/full/`.
- Editing `docker/layers/full/Dockerfile` makes the `layers` row `stale` in both the porcelain and the human report; `agent-update` then rebuilds the layers and agent images without `--pull`/`--no-cache` and without touching the base; a second `agent-check-updates` reports everything up to date.
- Removing the selector after a `full` build makes the row stale, and `agent-update` rebuilds the agent on the base.
- Copying `docker/layers/full` to `docker/layers/custom` and selecting `custom` builds without any other edit, and `git status` stays clean.
- An invalid selector (bad characters, or a set without a Dockerfile) fails the build and the update check with a message naming the offending value and path.
- The bash and PowerShell digest scripts print the identical digest for the same tree, and the bash and PowerShell selector scripts agree on every case in the test suite.
- `agent-image-info` shows the layer set and the commit that built it.
- `shellcheck`, `shfmt -d`, PSScriptAnalyzer (`-Recurse`) and `./scripts/run-pure-shell-tests.sh` pass.

## Validation

- Add a pure-shell suite (auto-discovered by `scripts/run-pure-shell-tests.sh`) covering selector parsing (absent, empty, comments, CRLF, BOM, invalid name, missing Dockerfile) and digest determinism (ordering-independent, `.gitkeep` excluded, changes when any file changes). Add a bash/PowerShell parity check that runs when `pwsh` is present and reports an honest skip otherwise.
- Image builds cannot run inside a powbox container. Ask the maintainer to run the build scenarios in "Acceptance criteria" on the host (`./build.sh all`, then `agent-update`), on Linux and once through `build.ps1`, or rely on Tier 1 once task 065 lands.

## Review plan

Read the two selector and two digest scripts side by side for parity, then trace one `agent` build in `scripts/build-image.sh` from selector to bake arguments, checking that the agent's parent and the recorded provenance always describe the same image. Confirm the porcelain contract in the `commands/check-updates.sh` header matches what both languages emit, and that no tool was moved out of `docker/base/Dockerfile`.
