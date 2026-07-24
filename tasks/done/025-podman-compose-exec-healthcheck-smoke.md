# Task 025: Smoke-test Podman Compose exec-form health checks

## Why this task exists

Powbox promises that the rootless `podman compose` command and the Docker-compatible `docker compose` shim are usable from an agent container.

A Kalm2 SPIRE-overlay session reported that Podman Compose 1.3 left a distroless exec-form health check permanently at `starting`, despite the service running.

The current Podman smoke verifies the command exists but does not create a Compose service with an exec-form health check, so this compatibility gap can regress unnoticed.

## Scope

- Extend the nested-container portion of the Podman smoke with a minimal, hermetic Compose fixture that uses an exec-form health check (`test: ["CMD", "/bin/true"]` or equivalent).
- Verify the service becomes `healthy` within a bounded interval through the supported Compose command path, and clean up all fixture resources even on failure.
- Record the precise supported behavior and any deliberately accepted limitation in the rootless-Podman documentation.

Out of scope: changing Kalm2's SPIRE Compose files, adding a general Compose conformance suite, or treating an absent `/dev/net/tun` as a product failure.

## Context and references

- `scripts/smoke-test-podman.sh` currently verifies Podman, nested runs, bridge networking, and only the presence of the Compose subcommand.
- Powbox currently installs Podman 5.x with `podman-compose` 1.3; the task must test the actual provider selected by `podman compose`/the Docker shim, not assume Docker Compose v2 semantics.
- Kalm2's `deploy/local/docker-compose.spire.yml` is the motivating real-world shape: distroless images need `CMD` exec-form checks rather than `CMD-SHELL`.
- The outer smoke command must keep its existing capability/device gating, so this new check belongs with the already-gated nested-run portion.

## Target files or areas

- `scripts/smoke-test-podman.sh`
- `docs/rootless-podman.md`
- `README.md` only if the advertised Compose compatibility contract needs clarification
- A focused pure-shell test script, if fixture construction/parsing can be tested without an image

## Implementation notes

- Materialize the fixture in a fresh `mktemp -d` directory inside the throwaway agent container, with restrictive ownership and an `EXIT` trap that tears down the exact Compose project and removes only that directory.
- Give the Compose project an invocation-unique name so it cannot collide with a simultaneous smoke run.
- Prefer a small image already used by the Podman smoke and a binary that the image definitely contains; the test is about Compose translation of the exec array and health-state propagation, not application behavior.
- Use a bounded poll or the provider's reliable wait primitive, then inspect the service health state explicitly. A merely running service is not a pass.
- Exercise the command spelling agents are expected to use (`docker compose` through the shim) and, if behavior differs from `podman compose`, report that as a failure or document a single canonical spelling. Do not silently test only one while advertising both.
- Preserve the existing no-`/dev/net/tun` skip behavior for nested engine checks and make the skip reason visible in the umbrella smoke summary.

## Acceptance criteria

- On a host where the nested Podman checks run, the smoke starts a Compose service with an exec-form health check and proves it reaches `healthy` within a bounded timeout.
- The test fails clearly if Compose leaves the check at `starting`, converts the exec form incorrectly, or cannot cleanly start the service.
- All containers, networks, and temporary fixture files created by the test are removed on success and failure.
- A host without `/dev/net/tun` retains the current static-engine pass plus explicit nested-check skip; it does not claim the health-check scenario ran.
- Documentation states the validated command/provider behavior and the scope of the smoke.

## Validation

- Run `shellcheck scripts/smoke-test-podman.sh` and `shfmt -d scripts/smoke-test-podman.sh`.
- Run the relevant static smoke/unit gates in-container where possible.
- This is image-affecting behavior: ask for a host or CI build and run `POWBOX_PODMAN=on POWBOX_SMOKE_REQUIRE_IMAGE=1 ./commands/smoke-test.sh` after rebuilding the agent image.

## Review plan

Review the fixture's health-check form, timeout, cleanup trap, unique project naming, and capability gating; confirm the test would fail on a running-but-never-healthy service.
