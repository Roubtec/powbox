# Task 063a — Close the file-mode input a `RUN` bind mount gives a layer set

## Why this task exists

Task 063 (PR #161) introduced the optional layer-set image `powbox-agent-layers:latest`, built from `docker/layers/<set>/`.
Whether that image is current is decided by a **content-only** digest of the set directory (`scripts/layers-digest.{sh,ps1}`), so the layer-set contract removes every build input such a digest cannot see rather than hashing it:
symlinks, empty directories and other non-regular entries are rejected, every `COPY`/`ADD` must carry `--chmod=<mode>` so no mode comes from the checkout, and `ONBUILD` is rejected so nothing runs later against the agent build's repo-root context.
README "Layer sets" says these rules "keep every build input inside what the digest sees".

The cross-harness peer review of PR #161 (review round for the `ONBUILD` threads, 2026-10-01) found one input the contract still admits: a **`RUN` bind mount of the build context**.

```dockerfile
USER root
RUN --mount=type=bind,target=/ctx cp -p /ctx/tool /usr/local/bin/tool
```

A bind mount exposes the set directory as it is in the checkout, **including file modes**.
`cp -p` (or `install` without `-m`, `tar`, `rsync -p`, …) carries the executable bit into the image.
Flipping only that bit on `tool` changes the built image, yet the digest is unchanged, so `layers_stale_reason` (`scripts/build-image-lib.{sh,ps1}`) keeps reporting the layer image current and it is never rebuilt — and a Windows checkout, which has no Unix modes, builds a different image from the same commit.

This was out of scope for the `ONBUILD` threads that round, and the fix is a contract decision, so it is recorded here rather than made there.

## Scope

Decide and implement one of these, in **both** scans, keeping the `.sh` and `.ps1` byte-identical in stdout, stderr and exit status:

- **(A) Reject context bind mounts (recommended).**
  A `RUN` whose leading flags include a `--mount=` that is a bind mount **without** `from=` is a contract violation, reported like the `--chmod` one (the offending line named).
  The bind type is the default: a `--mount=` with no `type=` is a bind mount too, so `--mount=target=/ctx` must be caught as well as `--mount=type=bind,target=/ctx`.
  A bind with `from=<stage-or-image>` reads another stage or image, not the context, and stays allowed, as do `type=cache`, `type=tmpfs`, `type=secret` and `type=ssh`.
  A set that needs a file at build time copies it in with `COPY --chmod=…` instead, which the digest already covers.
- **(B) Keep bind mounts and narrow the claim.**
  Document in README "Layer sets", the `docker/layers/full/Dockerfile` header and `docs/architecture.md` that a context bind mount exposes modes the digest does not cover, so a set must not depend on them, and drop the "every build input" wording.

Out of scope: hashing modes into the digest (the digest format deliberately matches `scripts/base-source-digest.sh`, and Git tracks only the executable bit), and any change to how `ONBUILD`, heredocs or continuations are scanned.

## Context and references

- `scripts/layers-digest.sh` header comment — the algorithm, the contract, and the BuildKit parsing rules the scan follows. The `.ps1` twin defers to it.
- `scripts/layers-digest.sh` `check_instruction()` and `scripts/layers-digest.ps1` `Test-Instruction` — where `ONBUILD` is rejected and `COPY`/`ADD` flags are read. Docker accepts instruction flags only as the leading `--name=value` words after the keyword; the mount spec is a comma-separated `key=value` list, and BuildKit also accepts the key `source`/`src` and the type names case-insensitively — check `github.com/moby/buildkit/frontend/dockerfile/instructions` (`runmount.go`, `parseMount`) at the version the scans were last checked against (v0.33.1) before deciding what to match.
- `scripts/test-layer-sets.sh` — `dockerfile_case` (single-scan reject/accept cases) and the `dig_parity` loop over Dockerfile bodies (`.sh` vs `.ps1` byte parity).
- README "Layer sets" contract bullets; `docker/layers/full/Dockerfile` header; `docs/architecture.md` "Rules the file map does not state", the layer-set bullet.
- PR #161, the follow-up created while addressing review threads `PRRT_kwDORzOZTc6n7h6O` / `PRRT_kwDORzOZTc6n7h60` (the `ONBUILD` concern): https://github.com/Roubtec/powbox/pull/161

## Target files or areas

- `scripts/layers-digest.sh`, `scripts/layers-digest.ps1` (option A only; keep the `.ps1` CRLF)
- `scripts/test-layer-sets.sh`
- `README.md`, `docker/layers/full/Dockerfile`, `docs/architecture.md`

## Implementation notes

- Prerequisite: PR #161 (task 063) merged, or this task stacked on its branch.
- Option A: parse the `--mount=` value as BuildKit does. A JSON-form `RUN ["…"]` takes no flags, so only the shell form matters. Match keys case-insensitively only where BuildKit does; when unsure, err toward rejecting, as the scans already do for `# escape=` and non-ASCII spellings.
- Option A interacts with `ONBUILD RUN --mount`, which is already rejected as an `ONBUILD` — no special case needed.
- Whichever option is chosen, the `full` set must still build: it has no `RUN --mount` today.

## Acceptance criteria

- Option A: both scans reject `RUN --mount=type=bind,target=/x …`, `RUN --mount=target=/x …` and a bind spelled with other key orders or `source=`, naming the line; both accept `--mount=type=bind,from=build,…`, `--mount=type=cache,…`, `--mount=type=secret,…`; stdout, stderr and exit match byte for byte for every new body.
- Option B: the three docs no longer claim the contract removes every build input, and say plainly that a context bind mount exposes modes outside the digest.
- `bash scripts/test-layer-sets.sh` passes with no skips on a host with `pwsh`; `shellcheck`, `shfmt -d` and PSScriptAnalyzer are clean on the touched files.

## Validation

- `bash scripts/test-layer-sets.sh` (needs `pwsh` for the parity half), then `./scripts/run-pure-shell-tests.sh`.
- Option A: check each new mount shape against BuildKit's own parser (a small Go program importing `frontend/dockerfile/parser` and `instructions` at v0.33.1) so the scan matches Docker rather than a reading of its docs.
- Tier 1 CI builds the image with the `full` set selected; it must stay green.

## Review plan

A reviewer confirms the chosen option was the maintainer's, checks the mount parsing against BuildKit's `parseMount` (default type, key aliases, case), runs the parity loop, and reads the three docs for the same contract wording.
