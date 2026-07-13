# Bake a General-Purpose Native-Build Package Bundle into the Base Image

## Why this task exists

A kalm2 implementation session (task 107, OPC-UA adapter with a pinned open62541/OpenSSL CGO build) verified that GCC, Make, CGO, the ASan/UBSan runtimes, and the OpenSSL 3.5 *runtime* are already baked, but every native/CMake/TLS build still has to `sudo apt-get update && apt-get install` the same small set of build-orchestration packages first: `cmake`, `pkg-config`, `libssl-dev`, `ninja-build`.

These four (plus `zlib1g-dev`, the other near-universal C dev header) are general-purpose across projects — any CGo module wrapping a C library, any CMake-based vendored dependency, any TLS-linking native build — require no privileged runtime setup, and are cheap in image size. Baking them removes a repeated multi-minute apt round-trip (and its network dependency) from every native-build session, on the same footing as the existing `build-essential` layer.

## Scope

Add the following Debian packages to the base image (`docker/base/Dockerfile`):

- `cmake`
- `pkg-config`
- `libssl-dev`
- `ninja-build`
- `zlib1g-dev`

Update the container docs and smoke coverage to match (see Target files).

**Out of scope — considered and declined** (record stays here so the next assessment doesn't re-litigate):

- `ccache` — conditionally valuable, but doing it right needs a persistent cache dir wired through the launcher/entrypoint like the Go caches; split out to follow-up task `019a`.
- `gdb` — contradicts the documented house philosophy that agent harnesses debug via tests/prints (the same rationale that keeps `gopls`/`dlv` unbaked, see the Go layer comment in `docker/base/Dockerfile`); it is one `apt-get install` away for the rare interactive-debug session.
- `autoconf`/`automake`/`libtool`, `meson` — autotools release tarballs ship pregenerated `configure` scripts, and meson is a `pip3 install` away; neither clears the "frequently used" bar yet.
- `clang` — GCC 14 already provides the required ASan/UBSan coverage.
- `gcc-aarch64-linux-gnu`, `qemu-user-static`/`binfmt-support` — cross/emulation lanes need sysroots and kernel binfmt registration; they belong in dedicated per-project build images or CI, not the general sandbox.
- `syft`/Trivy/Grype — SBOM/scanner choice should stay project-pinned until a repo-wide gate standardizes on one.
- `open62541` and other project libraries — must remain project-pinned with exact version/checksum and license provenance.

## Context and references

- Source assessment: kalm2 task `107-adapter-wave-b-modbus-opcua.md` ("Container-image recommendations" from the implementing session). Verified against the current image: `cmake`, `pkg-config`, `ninja`, `libssl-dev`, and `zlib1g-dev` are all absent; `build-essential`, `libasan8`/`libubsan1`, and `libssl3t64` (runtime) are present.
- `docker/base/Dockerfile` — note the layer-ordering convention stated repeatedly in its comments: new installs go **low in the file** so they never bust the expensive gh/mssql/pwsh/npm layers above (the Podman, Go, and OPA layers are the precedent).
- `scripts/base-source-files.txt` — the base recipe digest hashes `docker/base/Dockerfile` itself, so a pure apt-line change is picked up automatically; the manifest only needs editing when base `COPY`s change (they don't here).
- `AGENTS.md` "Validating Changes" — image builds and smoke runs cannot happen in-container; only static lint runs here.

## Target files or areas

- `docker/base/Dockerfile` — a new small `apt-get install` `RUN` layer placed low (between the OPA layer and the shared-script `COPY` is the natural slot: it re-parents only the cheap COPY/symlink/env/oh-my-zsh layers below it). Give it a brief comment stating the bundle's purpose (general-purpose native/CGo/CMake build deps) per house style; the declined list above does **not** need to be restated there.
- `docker/shared/container-agent.md.tmpl` — extend the "Build" row of the tooling table (currently `make`, `patch`, `gcc`, `g++`) with `cmake`, `ninja`, `pkg-config`, and a note that the OpenSSL and zlib dev headers are baked so `-lssl -lcrypto -lz` / `pkg-config openssl` work without installs.
- `commands/smoke-test.sh` **and** `commands/smoke-test.ps1` (keep parity) — Stage 1 probes: `cmake --version`, `ninja --version`, `pkg-config --version`, plus `pkg-config --exists openssl zlib` (this proves the dev packages' `.pc` files landed, not just the binaries).

No `README.md` change is expected: it does not enumerate baked tooling (the template is the canonical tool list). No `scripts/base-source-files.txt` change is needed (no new `COPY`s).

## Implementation notes

- Use `--no-install-recommends` and `rm -rf /var/lib/apt/lists/*` exactly like every other apt layer in the file.
- Do **not** add the packages to the first apt layer: correct alphabetical grouping is not worth re-parenting every expensive layer in the base image (Podman-layer precedent).
- The Debian binary for `ninja-build` is `ninja`; document/probe it as `ninja`.
- No entrypoint, launcher, sudoers, or firewall interaction — these are pure build-time packages.

## Acceptance criteria

- A container from the rebuilt base has `cmake`, `ninja`, `pkg-config` on `PATH` and `pkg-config --exists openssl zlib` exits 0, with no runtime apt installs.
- The template's tooling table advertises the new packages so agents stop reflex-installing them.
- Stage 1 smoke probes cover the new packages in both the Bash and PowerShell smoke drivers.
- Layer placement leaves the expensive base layers (first apt, gh, mssql/pwsh, npm, Podman, Go, OPA) cache-stable for an unrelated rebuild.

## Validation

- In-container: `shellcheck` and `shfmt -d` on the changed shell files; `pwsh -Command "Invoke-ScriptAnalyzer -Path ."` for the `.ps1` change.
- Image build + smoke must run on the host or in Tier 1 CI (`./build.sh all`, then `commands/smoke-test.sh`) — stop and hand off to the maintainer for the rebuild rather than attempting an in-container build; an image-affecting PR to main is normally covered by Tier 1 CI automatically.
- After a host rebuild, a quick end-to-end sanity check inside a fresh container: `printf 'cmake_minimum_required(VERSION 3.25)\nproject(t C)\nfind_package(OpenSSL REQUIRED)\n' > CMakeLists.txt && cmake -G Ninja -B build` succeeds without any apt install.

## Review plan

Reviewer confirms: the five packages land in one new low-placed apt layer with house-style flags and comment; no expensive layer above it changed; template Build row, both smoke drivers, and nothing else were updated; `base-source-files.txt` untouched; and the declined-package rationale in this task file was not silently expanded into the image.
