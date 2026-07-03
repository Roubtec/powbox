# 012 — Fail fast on in-container image builds and document host-assisted validation

## Why this task exists

This retargets the original 012 follow-up from the 009/011 review (the broader "validation gaps"
scope; see this file's git history). Most of that scope dissolved on inspection: the SC2016
findings were intentional quoting and now carry targeted disable directives, the touched scripts
are shfmt-normalized (both fixed on `minor-improvements`), the repo's actual lint gates live in
`.github/workflows/native-linux-ci.yml` (`shellcheck --severity=error` blocking, `shfmt` advisory
on changed files), and the dir-mount smoke already runs for real in Tier 1 CI
(`commands/smoke-test.sh` stage 5 via `.github/workflows/native-linux-build.yml`).

What remains is the build-path gap, and its resolution is a policy, not a Podman port: full image
builds are a host/CI concern. Inside the agent container, `docker` is a Podman shim and
`podman buildx` has no `bake` subcommand, so `./build.sh all` dies with the unhelpful
`Error: unknown flag: --file`. Even a build that succeeded in-container could not be validated
meaningfully — the running container cannot be relaunched from the image it just built, and a
nested-Podman smoke run is not the documented environment. The 009/011 reviewer burned a cycle
discovering this the hard way (falling back to direct `docker build --layers`, a Podman-only
flag, just to prove buildability). An agent hitting this path should get a clear, immediate stop
that tells it to ask the user for host assistance.

## Scope

- Make `scripts/build-image.sh` detect a Podman-backed `docker` and exit non-zero early — before
  any bake attempt or image inspection side effects — with a short, actionable message: full
  image builds are not supported inside the agent container; ask the user to run `./build.sh all`
  (or `build.ps1`) on the host and restart the container from the rebuilt image; Tier 1 CI
  builds and smokes PRs automatically.
- Document the validation split in the root `AGENTS.md` for agents developing powbox from inside
  a powbox container: what runs in-container (shellcheck, shfmt, PSScriptAnalyzer, pure-shell
  unit tests such as `scripts/test-sensitive-host-path.sh`) versus what needs the host or CI
  (image builds, `commands/smoke-test.sh` and the per-stage smokes, including dir-mount). State
  explicitly that when validation requires a rebuilt image or a smoke run, the agent should stop
  and request host assistance rather than attempt an in-container build.

Out of scope: any Podman build fallback or `buildx bake` emulation (deliberately rejected — the
build path is buildx-specific and in-container builds are unnecessary); an escape-hatch
environment variable (if a supported in-container build path ever materializes, it is its own
task); changes to CI; changes to `build.ps1` / `scripts/build-image.ps1` (see notes).

## Context and references

- Failure observed during the 009/011 review, reproduced from this checkout:
  `./build.sh all` → `docker buildx bake --file docker-bake.hcl ...` →
  `Error: unknown flag: --file`; `docker --version` reports `podman version 5.4.2` in-container.
- `scripts/build-image.sh` is the only bake entry point (`build.sh` is a thin exec wrapper);
  `run_bake` and `ensure_base_image` are the call sites. The guard belongs near the top, after
  argument parsing, so bad flags still produce their normal errors.
- Repo lint gates: `.github/workflows/native-linux-ci.yml`. Build+smoke CI:
  `.github/workflows/native-linux-build.yml` (runs `./build.sh all` / `./build.sh agent` on a
  real-Docker runner, then `commands/smoke-test.sh`, and fails on partial smoke passes).

## Target files or areas

- `scripts/build-image.sh`
- `AGENTS.md` (root), plus any doc that states the supported build command if it contradicts
  the new policy.

## Implementation notes

- Detection: `docker --version 2>/dev/null | grep -qi podman` is sufficient — the shim reports
  Podman. Do not probe `docker buildx bake` support by invoking it; its confusing failure output
  is the very thing being guarded against.
- Keep the message to a few lines: why (Podman-backed `docker` has no `buildx bake`), and what to
  do (build on the host, restart the container from the new image; CI covers PRs).
- PowerShell parity is deliberately not needed: `scripts/build-image.ps1` runs on the host by
  convention (the in-container agent path is `./build.sh`), and the AGENTS.md statement covers
  the rule either way. Note this in the guard's comment so the asymmetry reads as intended.

## Acceptance criteria

- Inside the agent container, `./build.sh all` (and `base` / `agent`) exits non-zero immediately
  with the guidance message and attempts no build or pull.
- On a host with real Docker the guard does not trigger and behavior is unchanged; Tier 1 CI
  (`native-linux-build.yml`) stays green.
- Root `AGENTS.md` documents the in-container vs host/CI validation split, including the
  stop-and-ask-for-host-assistance rule for image builds and smoke runs.
- `shellcheck` (default severity) and `shfmt -d` are clean on `scripts/build-image.sh`;
  PSScriptAnalyzer remains clean.

## Validation

In the agent container:

```bash
./build.sh all            # expect the fail-fast message and a non-zero exit
shellcheck scripts/build-image.sh
shfmt -d scripts/build-image.sh
pwsh -NoProfile -NonInteractive -Command "Invoke-ScriptAnalyzer -Path ."
```

On the host (or via Tier 1 CI on the PR): `./build.sh all` still builds both images and
`commands/smoke-test.sh powbox-agent:latest` passes.

## Review plan

Reviewer confirms the guard triggers only under a Podman-backed `docker` and sits before any
build side effects, the message tells the agent/user exactly what to run on the host, no bake or
provenance logic changed, and the AGENTS.md validation split matches what CI actually gates.
