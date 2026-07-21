# Task 025a: Fix podman-compose exec-form health checks at the root, then raise the smoke bar to hard-fail

## Why this task exists

Task 025's smoke proved that the bundled `podman-compose` 1.3 always rewrites an exec-form health check `test: ["CMD", "/bin/true"]` into a shell-wrapped `["CMD-SHELL", "/bin/sh -c /bin/true"]`.
On images that ship a shell (e.g. alpine) the wrapped command still runs, so the defect is invisible; on distroless / shell-less images (no `/bin/sh`) the health check can never execute and the service stays at `starting` forever — the exact Kalm2 SPIRE-overlay symptom that motivated task 025.

This is a quirk of the current `podman-compose` version, not something Powbox's architecture introduces.
Task 025 therefore shipped an honest, deliberately GREEN `KNOWN-XFAIL`: its distroless reproduction (section 4c of `scripts/smoke-test-podman.sh`) demonstrates the break exists today and emits a loud self-clearing NOTE if the wrap ever disappears, but it does not fail CI over an upstream limitation.
This follow-up fixes the mistranslation at the root and then raises the passing bar so any future regression is caught hard.

## Scope

- Investigate and land a root fix so the provider selected by `podman compose` / the `docker compose` shim preserves exec-form health checks unchanged: upgrade `podman-compose`, patch it, or switch to a compose provider that translates the exec array faithfully (e.g. Podman's Go/compose-go path or Docker Compose v2), whichever is the least invasive compliant option.
- Verify compliance with task 025's exact distroless reproduction: under the supported Compose command path, the wired `.Config.Healthcheck.Test` for the shell-less service must be the PRESERVED `CMD` exec form (not `CMD-SHELL` / `/bin/sh -c …`). This preserved-exec-form inspection is the LOAD-BEARING discriminator — NOT "reaches healthy". Task 025's distroless probe deliberately uses `registry.k8s.io/pause`'s never-exiting `/pause` binary, which can never satisfy a health-check timeout even with a correctly preserved `CMD` exec form, so "reaches healthy" cannot distinguish a fixed provider from a broken one; only the translated form can. (If you additionally switch the distroless probe to a genuinely shell-less image that ships a short-lived exit-0 binary, you MAY also require it to reach `healthy` — but the preserved-exec-form inspection must remain the primary hard-fail check.)
- Once a compliant provider is bundled and verified, flip task 025's distroless `KNOWN-XFAIL` (and its self-clearing NOTE branch) to a HARD FAIL keyed on the translated form: a wired `CMD-SHELL` / `/bin/sh -c …` wrap (the exec→shell rewrite) must turn the smoke red, while the preserved `CMD` exec form passes. Update the documentation to state that exec-form health checks are now supported and the bar is hard-fail.

Out of scope: changing the smoke's fixture/cleanup/gating structure beyond flipping the XFAIL to a hard failure; reworking health-check semantics; the no-systemd manual-drive behavior (a separate sandbox limitation, not this mistranslation).

## Context and references

- `docker/base/Dockerfile` (or wherever `podman-compose` is installed/pinned) — the provider version under test.
- `scripts/smoke-test-podman.sh` section 4c — the distroless exec-form reproduction, its `KNOWN-XFAIL` classification, and the self-clearing NOTE branch that this task's fix is designed to trip.
- `scripts/test-podman-compose-healthcheck.sh` — the pure-shell invariants that must be updated when the XFAIL becomes a hard fail.
- `scripts/smoke-test-podman.ps1` — the PowerShell mirror (keep Bash/PowerShell parity).
- `docs/rootless-podman.md` "Compose health-check behavior" — documents the current limitation; update it once the provider is compliant.
- `tasks/025-podman-compose-exec-healthcheck-smoke.md` (or `tasks/done/…`) — the originating task and its acceptance criterion "fails clearly if Compose converts the exec form incorrectly", which this task finally lets the smoke honor as a hard failure.

## Target files or areas

- `docker/base/Dockerfile` (provider install/pin) and any provider-selection glue.
- `scripts/smoke-test-podman.sh` and `scripts/smoke-test-podman.ps1` (flip 4c XFAIL → hard fail; retire the self-clearing NOTE once compliant).
- `scripts/test-podman-compose-healthcheck.sh` (update invariants to expect the exec form preserved and the hard-fail behavior).
- `docs/rootless-podman.md` and `README.md` (state the compatibility contract once it changes).

## Implementation notes

- Prefer the smallest change that makes `podman compose` and the `docker compose` shim emit the exec form unchanged; if both the current `podman-compose` and any drop-in upgrade still mistranslate, evaluate switching the provider rather than carrying the workaround indefinitely.
- Re-use task 025's distroless reproduction as the acceptance probe — do not invent a new fixture; the point is that the same scenario that is an XFAIL today becomes a hard-verified pass.
- Only convert the XFAIL to a hard fail AFTER a compliant provider is actually bundled and verified end to end; do not raise the bar while the provider still mistranslates, or CI goes permanently red.
- If, after investigation, no compliant provider can be bundled without unacceptable cost, record that finding and keep the XFAIL — but say so explicitly rather than leaving this task silently open.
- Preserve the existing capability/`/dev/net/tun` gating, invocation-unique project naming, and complete on-success-and-failure cleanup.

## Acceptance criteria

- The bundled provider preserves exec-form health checks: under `docker compose` (and `podman compose`), a shell-less/distroless service with `test: ["CMD", …]` keeps its wired `.Config.Healthcheck.Test` as the `CMD` exec form (not `CMD-SHELL`). This preserved-exec-form inspection is the acceptance discriminator; "reaches healthy" is NOT required because the `/pause` probe never exits (see Scope). If the probe is switched to a short-lived exit-0 binary in a shell-less image, "reaches healthy" MAY additionally be asserted.
- Task 025's distroless scenario is a HARD FAIL on any exec→shell rewrite — i.e. a wired `CMD-SHELL` / `/bin/sh -c …` form fails the smoke (no longer a green XFAIL); a preserved `CMD` exec form passes.
- `scripts/test-podman-compose-healthcheck.sh` invariants are updated accordingly and pass; Bash/PowerShell parity retained.
- `docs/rootless-podman.md` (and `README.md` if the advertised contract changes) state that exec-form health checks are supported and the smoke now enforces it, replacing the documented limitation.
- If the root fix proves infeasible, the investigation outcome is documented and the XFAIL is retained with an explicit rationale.

## Validation

- This is base-image behavior: request a host/CI image rebuild and run `POWBOX_PODMAN=on POWBOX_SMOKE_REQUIRE_IMAGE=1 ./commands/smoke-test.sh` after rebuilding, confirming the distroless service now reaches `healthy` and that a forced rewrite fails the smoke.
- Run `shellcheck` and `shfmt -d` on changed shell files and the pure-shell invariant test in-container.

## Review plan

Confirm the provider genuinely preserves the exec array (inspect the wired health check), that the XFAIL→hard-fail flip cannot false-pass and truly reddens on a rewrite, and that the documentation no longer describes the mistranslation as a permanent accepted limitation.
