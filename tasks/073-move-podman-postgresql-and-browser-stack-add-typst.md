# 073 — Move Podman, PostgreSQL and the browser stack into `full`; add Typst to the lean base

## Why this task exists

Task 071 moved the toolchains that nothing at startup depends on.
This task finishes the lean base by moving the three groups that **are** coupled to the launcher, the entrypoint or a smoke stage, and closes the one capability the lean image would otherwise lose: producing PDFs.

Together with task 071 this takes about 2.7 GB out of a 5.5 GB root filesystem.

## Scope

**In scope — move from `docker/base/Dockerfile` to `docker/layers/full/Dockerfile`:**

| Group | Approximate size | What moves with it |
|---|---|---|
| Rootless Podman stack | 104 MB | the "Rootless container engine (Podman)" apt block, the subuid/subgid lines, `/etc/containers/nodocker`, `docker/shared/containers.conf`, `docker/shared/seed-image-store.sh`, `ENV XDG_RUNTIME_DIR` |
| PostgreSQL 16 | 48 MB | the PGDG repo block, `docker/shared/pg-dev-up` |
| Chromium | 374 MB | the `chromium` apt package and the `CHROME_PATH` / `PUPPETEER_*` / `CHROME_NO_SANDBOX` env |
| Mermaid CLI | 476 MB | |
| Marp CLI | 134 MB | it needs a browser for PDF, PPTX and PNG output, so it travels with Chromium |
| Playwright CLI | 19 MB | |

**Also in scope:**

- Typst **0.13.1** added to the lean base as the PDF engine for `pandoc`.
- The launcher skips the shared image-store seeder for an image without Podman.
- Template rows and sections, probes, smoke Stage 3 label check, manifests and docs follow the moved tools.

**Out of scope:**

- Device passthrough. The launcher keeps passing `/dev/fuse` and `/dev/net/tun` exactly as `PODMAN_DEVICE_MODE` resolves them today, whether or not the image has Podman (see "Decisions" below).
- The Podman-motivated `security_opt` entries in `compose.shared.yml` (deferred task 075).
- LaTeX. It was measured and rejected: the smallest set that serves `pandoc` is 189 MB, 402 MB with XeTeX for Unicode text, against 40 MB for Typst.

## Context and references

- Depends on task 071 (the `full` set already holds real content, notes and probes).
- `docker/shared/entrypoint-core.sh` already guards its whole Podman preparation with `command -v podman`, so the entrypoint needs no change for a Podman-less image. Verify rather than assume.
- `scripts/launch-agent.sh`: the block introduced by the comment "Seed the GLOBAL shared image store from a dedicated, short-lived, DETACHED writer" runs a `docker compose … run --rm -d` with `POWBOX_IMAGE_STORE_ROLE=writer` and `seed-image-store.sh seed` whenever the resolved device set includes fuse. `scripts/launch-agent.ps1` mirrors it. Because of `--rm`, the writer container removes itself when it exits.
- The same launcher already reads an image label as a capability gate: under `--isolated` it inspects `powbox-agent:latest` for `powbox.base.selfhosted`. That `docker image inspect --format '{{ index .Config.Labels "…" }}'` read, including its handling of an empty value and `<no value>`, is the precedent for the `powbox.podman` gate in both languages.
- `commands/smoke-test.sh`: Stage 2 (pg-dev-up functional) and Stage 3 (rootless Podman), both capability-gated by task 069. The core Stage 1 list holds `psql --version`, `pg-dev-up check`, three Playwright probes and the `command -v podman` probe task 069 added; it has no probe for `chromium`, `marp` or `mmdc`.
- `docs/rootless-podman.md`, `docs/podman-shared-image-store.md`, and `docs/architecture.md` ("Bundled PostgreSQL", "Bundled Playwright").

## Decisions

- **Devices stay.** Not passing `/dev/fuse` and `/dev/net/tun` to a lean container was considered and rejected. The container already runs with `SYS_ADMIN` and unconfined seccomp, so the device nodes add no capability; traffic through a tun device is still subject to the container's firewall; and gating them would recreate stopped containers every time a user switches layer sets, because the device set is frozen at creation and recorded in the `powbox.podman-devices` label. Leaving them also keeps a session-time `apt-get install podman` workable.
- **The seeder is gated.** On a lean image the image-store writer would start a container on every launch only to find no `seed-image-store.sh`. The `full` Dockerfile declares `LABEL powbox.podman="1"` inside its Podman block; the launcher reads that label from the agent image and skips the writer when it is absent. A custom set that deletes the Podman block deletes the label with it.
- **Typst is pinned to 0.13.1, deliberately not the latest.** Debian trixie ships `pandoc` 3.1.11.1, whose default Typst template fails on Typst 0.14 and 0.15 with `error: font fallback list must not be empty`. 0.13.1 works out of the box. Re-test before bumping either tool.

## Verified Typst facts

Measured in a current container with `pandoc` 3.1.11.1 and the static `typst` 0.13.1 binary on `PATH`:

- `pandoc in.md -o out.pdf --pdf-engine=typst` produces a correct PDF with title block, headings, a table, nested lists, highlighted code, a block quote, an embedded image, inline and display math, a footnote, and Slovak diacritics. The fonts are embedded in the binary; no font package and no `HOME` are needed.
- The default page size is US Letter; `-V papersize=a4` gives A4.
- Converting a `.docx` that contains images needs `--extract-media=<dir>`, or Typst cannot find the media files.
- The binary is 40 MB unpacked. Release assets are `typst-<arch>-unknown-linux-musl.tar.xz` with the binary at `typst-<arch>-unknown-linux-musl/typst`, where `<arch>` is `x86_64` for `amd64` and `aarch64` for `arm64`.
- sha256 of the v0.13.1 assets as downloaded on 2026-09-30 (re-derive before pinning): `x86_64` `7d214bfeffc2e585dc422d1a09d2b144969421281e8c7f5d784b65fc69b5673f`, `aarch64` `4f5b7ee6e57fb639019ee0f6bffcf940edad228ede6ff5269a9f05a1544ceed4`.

## Target files or areas

- `docker/base/Dockerfile` — remove the three groups; add a Typst block in the style of the OPA block (version variable, per-arch sha256, `curl` with the same retry flags, extract only the binary to `/usr/local/bin/typst`); remove `pg-dev-up` and `seed-image-store.sh` from the shared-script `COPY` and the `containers.conf` `COPY`.
- `docker/layers/full/Dockerfile`, plus `docker/layers/full/pg-dev-up`, `containers.conf`, `seed-image-store.sh` moved from `docker/shared/`.
- `docker/layers/full/agent-notes.md`, `docker/layers/full/smoke-probes.txt`.
- `docker/shared/container-agent.md.tmpl` — move the Databases (`psql`, `pg-dev-up`; `sqlite3` stays), Headless browser, Playwright and Containers rows, the Marp and Mermaid parts of Document processing, the whole "Local PostgreSQL" section, the Podman storage row of "Filesystem layout" and the Podman paragraph of "Network"; add the PDF guidance below.
- `scripts/launch-agent.sh`, `scripts/launch-agent.ps1` — the seeder gate, and a container label on the writer's `compose run` (see "Writer label").
- A pure-shell suite for the gate decision, where it can be isolated (see "Validation").
- `commands/smoke-test.sh`, `commands/smoke-test.ps1`, and `scripts/smoke-test-podman.{sh,ps1}` if the label check lives there.
- `scripts/test-pg-dev-up-scoped.sh` and any other suite or doc that names `docker/shared/pg-dev-up`, `containers.conf` or `seed-image-store.sh` (grep; at the time of writing, besides `docker/base/Dockerfile` itself: `docs/architecture.md`, `docs/podman-shared-image-store.md`, `docs/rootless-podman.md`, `scripts/base-source-files.txt`, `scripts/test-pg-dev-up-scoped.sh`). Task files keep their wording, including those under `tasks/done/`: they are history. The two Podman docs are partly dated records of how the wiring was applied (the "What changed" table in `docs/rootless-podman.md`; the section "Wiring checklist — APPLIED (kept as the record of what changed)" with its diff blocks, and the validation notes, in `docs/podman-shared-image-store.md`). Do not rewrite those passages as if the files had always lived in the layer set. Add a note near the top of each doc saying where the three files live now, and correct any passage that describes the present layout.
- `AGENTS.md` — the "Shell formatting convention" sentence lists the extensionless `docker/shared/` helpers including `pg-dev-up`; update the path.
- `README.md` ("Nested Containers (rootless Podman)", "Layout"), the docs above, `.github/workflows/native-linux-build.yml` (cache keys, the `scripts/test-pg-dev-up-scoped.sh` path filter stays valid).

## Implementation notes

- **Core template PDF guidance.** Add to the Document processing row, in wording that stays true when a layer set adds more tools: `pandoc` converts Markdown to Word, PowerPoint, HTML and EPUB, and to PDF through the baked Typst engine (`pandoc in.md -o out.pdf --pdf-engine=typst`, `-V papersize=a4` for A4, `--extract-media=<dir>` for `.docx` input with images). State that no headless browser or LaTeX is part of this base image, that HTML or slide decks to PDF therefore need a browser, and that the agent should use one documented in the layer-set section at the end of the file when present, or otherwise install what it needs for the session.
- **Core probe.** Add a functional Stage 1 probe that builds a one-line Markdown file into a PDF with the Typst engine and checks the result with `pdfinfo`. A bare `typst --version` would not catch the template incompatibility that motivated the pin.
- **Layer probes.** Move these out of the core Stage 1 list in both drivers into `docker/layers/full/smoke-probes.txt`: `psql --version`, `pg-dev-up check`, `command -v podman` and the three Playwright probes (including the `ms-playwright` cache-directory one). Left in the core list, they would fail the lean Stage 1. Then add presence probes for `chromium`, `marp` and `mmdc`, which have none today, and for anything else the moved blocks install that is still unprobed. Those probes are what make a missing tool fail the `full` run (task 069).
- **Stage 3 label check.** Where Stage 3 decides whether Podman is present, also assert that the `powbox.podman` label and the binary agree. An image with Podman but no label would silently lose the shared image store; an image with the label but no Podman would run a useless writer.
- **Writer label.** Add `--label powbox.image-store-role=writer` to the writer's `docker compose … run` in both launchers; the final agent run already passes `--label` the same way. The name mirrors the `POWBOX_IMAGE_STORE_ROLE=writer` variable the writer is started with. It exists so the writer can be told apart from the volume-prep container, which is an anonymous compose one-off from the same image (see "Validation"). It must be a container label given on the command line, not an image label: a container inherits its image's labels, so a filter on `powbox.podman` would match every container started from a `full` image. Mention the label where `docs/podman-shared-image-store.md` describes the writer.
- **Missing-engine wording.** Task 069 reworded the sentence in `docs/smoke-tests.md` ("Partial runs, host gates, and skipping") and the headers of `scripts/smoke-test-podman.{sh,ps1}` to say that a missing engine fails Stage 1. Once the `command -v podman` probe lives in `docker/layers/full/smoke-probes.txt`, that is wrong for both images. Reword all three: on an image built from a set that installs Podman, a missing engine fails Stage 1b through the set's presence probe; on the lean image Podman is absent by design and Stage 3 is not applicable; a dropped drop-in still fails Stage 3.
- **Podman block content.** Keep the engine config drop-in directory creation (`mkdir -p -m 0755 /etc/containers/containers.conf.d`) in the same layer as before the `COPY`; the base Dockerfile comment on that `COPY` explains the BuildKit `--chmod` pitfall.
- **`pg-dev-up` is tested from source.** `scripts/test-pg-dev-up-scoped.sh` runs the repo copy against the baked server binaries in Stage 2; point it at the new path.
- **Pre-cached images.** The Containers row says common dev images are pre-cached; that remains true only for images with Podman and moves with the row.
- `gnupg` and `curl` stay in the base; the PGDG block in the layer uses them.
- The `node` user's `~/.local/share/containers` volume is still mounted by the launcher for a lean container. It is empty and harmless; do not gate it.

## Acceptance criteria

- The lean image contains none of `podman`, `docker`, `psql`, `pg-dev-up`, `chromium`, `marp`, `mmdc`, `playwright`, and contains `typst` 0.13.1.
- In a lean container, `pandoc` turns a Markdown file with a table, an image and non-ASCII text into a PDF using `--pdf-engine=typst`, with no network access and nothing installed.
- A lean container starts cleanly: no Podman warnings from the entrypoint, and no image-store writer container is created by the launcher. A `full` launch on a host with `/dev/fuse` still creates one.
- The writer's `compose run` carries the container label `powbox.image-store-role=writer` in both launchers.
- The gate is shown to work by observation, not by absence of leftovers: `docker events --filter type=container --filter event=create --filter label=powbox.image-store-role=writer` prints nothing during a lean launch that creates its container, and exactly one line during such a `full` launch on a host with `/dev/fuse` (see "Validation").
- The core Stage 1 list in both drivers contains no probe for a moved tool, and `./commands/smoke-test.sh` passes against the lean image with Stage 2 and Stage 3 reported as not applicable.
- An image built with `full` selected passes the whole smoke test, including Stage 2, Stage 3 and the label check, and its containers resolve pre-cached images as before.
- The instruction file in a lean container documents Typst PDF output and says a browser is not part of the base; in a `full` container the appended section documents Chromium, Marp, Mermaid, Playwright, Podman and PostgreSQL.
- `scripts/base-source-files.txt` matches the base `COPY` lines.
- Outside `tasks/`, `git grep` for `docker/shared/pg-dev-up`, `docker/shared/containers.conf` and `docker/shared/seed-image-store.sh` finds no file that presents an old path as the current one. Code, manifests, suites and prose about the present layout use the new paths; the only hits left are the dated records in `docs/podman-shared-image-store.md` and `docs/rootless-podman.md` named under "Target files or areas", each below a note that says where the files live now.
- Static checks and `./scripts/run-pure-shell-tests.sh` pass; Tier 1 is green for both passes.

## Validation

Static checks run in-container.
If the gate decision is a small function of the image label, unit-test it in a pure-shell suite in both languages (label present, absent, empty, `<no value>`) with a fake `docker` on `PATH` that answers `image inspect`. `scripts/test-context-mount-config.sh` shows the fake-`docker` technique, but only to prove Docker is not reached; driving the whole launcher as far as the writer block through a fake would mean answering every earlier Docker call, so do not attempt that.
Ask the maintainer to build both images on the host, run `./commands/smoke-test.sh` against each, and launch one lean and one `full` container through `cc`. Each launch must be one that **creates** its container (no container exists yet for that project, or it was removed first): a launch that resumes an existing container takes the `docker start` path and reaches neither the prep step nor the writer block.
`docker ps -a` cannot show whether the gate works: the writer runs with `--rm`, and on a lean image it would exit at once, so it is gone either way. Counting created containers does not work either. Every such launch first runs a short-lived prep container: the `docker compose … run --rm --no-deps --user root --entrypoint /bin/sh` under the comment "Pre-create and chown the per-instance volumes to node", in the `--isolated` branch and in its `else`, mirrored in `scripts/launch-agent.ps1`. So a lean launch creates two containers (prep, then agent) and a `full` launch on a `/dev/fuse` host creates three (prep, writer, agent). The prep container and the writer are both anonymous compose one-offs from the same image, and without `--filter type=container` the event stream also carries network and volume creates.
Instead, start `docker events --filter type=container --filter event=create --filter label=powbox.image-store-role=writer` in a second terminal before each launch. It must print nothing for the lean launch and exactly one line for the `full` launch.
Record both image sizes in the PR description. On Windows, run the launcher once through PowerShell to exercise the mirrored gate and the mirrored label.

## Review plan

Check the launcher gate in both languages against the label the layer Dockerfile sets, then read the lean base Dockerfile end to end for anything that still assumes a moved tool (an `ENV`, a `COPY`, a symlink, a comment). Finally compare the core template with the base Dockerfile line by line: every tool it names must be installed there.
