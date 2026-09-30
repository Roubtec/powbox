# 067 — Append the selected layer set's agent notes to the seeded instructions

## Why this task exists

Agents learn what the container offers from the instruction file rendered from `docker/shared/container-agent.md.tmpl` (seeded as `CLAUDE.md` / `AGENTS.md` in each agent's config volume).
Once tools move into an optional layer set (tasks 071 and 073), the core template must describe only the lean image, and whatever a layer set adds has to be documented by that set.
A user who builds their own set needs a plain way to tell the agents what they added.

This task adds that channel: a hand-written `agent-notes.md` in the layer set, appended to the core template at build time.

## Scope

**In scope:**

1. An optional `agent-notes.md` in a layer set directory (`docker/layers/<set>/agent-notes.md`).
2. A host-side staging step that composes the core template and the selected set's notes into one file.
3. `docker/agent/Dockerfile` copying the staged file instead of the raw template.
4. One sentence in the core template pointing at the appended section.
5. Bash and PowerShell parity, a unit suite, and documentation.

**Out of scope:**

- Writing notes for `full`. The set is still a skeleton; tasks 071 and 073 create `docker/layers/full/agent-notes.md` as they move tools.
- Deriving notes automatically from a Dockerfile. The notes are manual by decision.
- Any change to the entrypoint hooks.

## Context and references

- Depends on task 063 (`scripts/layers-select.{sh,ps1}` and the layer-set layout).
- `docker/agent/Dockerfile`, section "Per-agent seed assets": two `COPY --chown=node:node docker/shared/container-agent.md.tmpl …/agent.md.tmpl` lines, one per agent, followed by the `build-epoch` `RUN`.
- `docker/shared/entrypoint-claude-hook.sh` and `docker/shared/entrypoint-codex-hook.sh` render `agent.md.tmpl` with `envsubst`, substituting **only** `${AGENT_NAME}`, `${AGENT_AUTONOMY_FLAG}`, `${AGENT_CONFIG_DIR}` and `${AGENT_PEERS}`, and re-render when the image's `build-epoch` is at least the volume's recorded epoch.
- `scripts/build-image.sh`, function `fetch_agent_skills`: the precedent for host-side staging into a gitignored directory (`.agent-skills-src`) that the agent Dockerfile then COPYs. A standalone `docker build` without the staging step fails at the COPY by design.
- `README.md`, "Updating Agent Instructions".

## Target files or areas

- New `scripts/stage-agent-template.sh` and `scripts/stage-agent-template.ps1`.
- `scripts/build-image.sh`, `scripts/build-image.ps1` — call the staging step before every agent bake.
- `docker/agent/Dockerfile` — the two template `COPY` lines.
- `docker/shared/container-agent.md.tmpl` — one pointer sentence under "Available tooling".
- `.gitignore` — the staging directory.
- A new pure-shell suite under `scripts/`.
- `README.md` ("Updating Agent Instructions", "Layout"), `docs/entrypoint-and-runtime.md`.

## Implementation notes

- **Staging output.** Write the composed file to a gitignored staging directory at the repo root (for example `.powbox-staging/agent.md.tmpl`). The root `.dockerignore` excludes only named paths, so a new directory is already inside the agent build context; do not add it to `.dockerignore`.
- **Composition.** The output is the core template's bytes, then, only when a set is selected **and** it has a non-empty `agent-notes.md`: a blank line, a fixed heading naming the set, a blank line, and the notes. Use the heading ``## Additional tooling from the `<set>` layer set``. Normalize the notes to LF and end the file with exactly one newline. The output must be a pure function of its inputs, so an unchanged input produces an identical file and Docker's content-keyed `COPY` cache stays warm.
- **Pointer sentence.** Add one sentence to the core template's "Available tooling" section, true for every image: tools added by an optional layer set are listed at the end of the file under "Additional tooling from the … layer set", and when that section is absent the image carries only what this table lists.
- **Variables in notes.** Because the hooks pass an explicit variable list to `envsubst`, a `$` in the notes is left alone, except the four names above, which the notes may use on purpose. State this in the docs.
- **Re-seeding.** The template `COPY` lines sit below the `build-epoch` `RUN`, so a changed staged file rebuilds that layer and containers re-render on next start. No hook change is needed; verify it rather than assume it.
- **Staleness.** The notes live in the set directory, so editing them changes the digest from task 063 and `agent-update` rebuilds through the `agent` target. That rebuild should be cheap: the layers image's filesystem layers are all cache hits and only the agent's seed layers change. Confirm that, per the "Cache behaviour to verify" note in task 063.
- **No set selected.** The staged file equals the core template byte for byte.
- The staging step must run for the `agent` and `all` targets and never for `base` or `layers`.

## Acceptance criteria

- With no set selected, the staged file is byte-identical to `docker/shared/container-agent.md.tmpl`.
- With a set that has `agent-notes.md`, the staged file ends with the heading and the notes, LF-only, and a second run produces the identical file.
- A set without `agent-notes.md`, or with an empty one, adds no heading.
- The bash and PowerShell staging scripts produce byte-identical output for the same inputs, including notes saved with CRLF.
- An agent image built with a `custom` set containing notes renders those notes into both agents' instruction files on container start, and a notes-only edit followed by `agent-update` reaches a restarted container.
- `docker/agent/Dockerfile` no longer copies `docker/shared/container-agent.md.tmpl` directly.
- `shellcheck`, `shfmt -d`, PSScriptAnalyzer (`-Recurse`), `markdownlint-cli2` on changed Markdown, and `./scripts/run-pure-shell-tests.sh` pass.

## Validation

- The new pure-shell suite covers: no set, set without notes, empty notes, notes with CRLF, notes containing `$` and one of the four substituted names, determinism across two runs, and bash/PowerShell parity when `pwsh` is present (an honest skip otherwise).
- The container-side behaviour needs a built image: ask the maintainer to build with a small `custom` set on the host and confirm the rendered instruction file, or rely on Tier 1 for the build and check the rendering manually once.

## Review plan

Diff the staged output against the core template for each case in the suite, then read `docker/agent/Dockerfile` to confirm both agents receive the staged file and the `build-epoch` layer still sits above them. Check that nothing in the hooks needed to change.
