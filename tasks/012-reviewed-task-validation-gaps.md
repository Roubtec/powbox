# 012 — Close validation gaps from the 009/011 task review

## Why this task exists

The review of `tasks/009-privileged-perms-backstop-true-host-source.md` and `tasks/011-go-cache-persistence-and-worktree-scoping.md` found that the core behavior appears implemented, and direct Podman builds of the base and agent images succeeded from the current checkout.

The tasks cannot be closed cleanly yet because their required validation is not green through the repo's standard paths: `./build.sh all` fails immediately in the powbox container's Podman-backed `docker` shim, and the task-relevant shell files are not `shellcheck`/`shfmt` clean.

## Scope

- Restore a successful full-build path that works in the documented agent container environment, where `docker` is a Podman shim.
- Make the shell validation expected by tasks 009 and 011 pass for the files those tasks touched.
- Re-run the relevant smoke coverage and document any environment-only skips clearly.

Out of scope: changing the true-source marker design from task 009, changing the Go cache layout from task 011, or fixing unrelated self-hosted clone fixture behavior unless it is required by the validation path selected here.

## Context and references

- Reviewed originals: `tasks/done/009-privileged-perms-backstop-true-host-source.md` and `tasks/done/011-go-cache-persistence-and-worktree-scoping.md`.
- Full build failure observed during review:
  - command: `./build.sh all`
  - result: `docker buildx bake --file ...` failed with `Error: unknown flag: --file`
  - environment: `docker --version` and `podman --version` both reported Podman 5.4.2.
- Equivalent direct builds did pass:
  - `docker build --layers -f docker/base/Dockerfile -t powbox-agent-base:latest ... .`
  - `docker build --layers -f docker/agent/Dockerfile -t powbox-agent:latest ... .`
- Task-relevant shell validation failures observed:
  - `shellcheck scripts/launch-agent.sh` reports SC2016 at the intentional inner-shell command strings around lines 858 and 924.
  - `shfmt -d docker/shared/entrypoint-core.sh scripts/launch-agent.sh` reports formatting diffs in touched sections.
- PowerShell analyzer was clean with `pwsh -NoProfile -NonInteractive -Command "Invoke-ScriptAnalyzer -Path ."`.

## Target files or areas

- `scripts/build-image.sh`
- `scripts/build-image.ps1`, if PowerShell parity is needed for any build-path behavior change.
- `scripts/launch-agent.sh`
- `docker/shared/entrypoint-core.sh`
- Any documentation that states the supported build command or validation workflow.

## Implementation notes

- Decide whether the intended fix is to make `scripts/build-image.sh` detect Podman-backed `docker buildx` and use equivalent `docker build`/`podman build` commands, or to provide a separate documented full-build path for the agent container environment.
- If SC2016 is intentional, add targeted `# shellcheck disable=SC2016` comments immediately above the affected assignments rather than weakening shellcheck globally.
- Prefer applying `shfmt` to the touched shell files or documenting the exact project shfmt settings if the default formatter is not the intended standard.
- Keep PowerShell parity in mind if the build-path behavior changes; do not let shell-only validation diverge from `build.ps1` / `scripts/build-image.ps1` expectations.

## Acceptance criteria

- `./build.sh all` either succeeds in the documented powbox agent container environment or fails fast with a clear, documented reason and an equally documented full-build command that succeeds there.
- The base and agent image build path used for validation builds current sources and stamps the current commit consistently with the existing provenance intent.
- `shellcheck` passes on the task-relevant shell files, including `scripts/launch-agent.sh`, `docker/shared/entrypoint-core.sh`, `docker/shared/fix-workspace-perms.sh`, `docker/shared/heal-workspace-perms.sh`, `docker/shared/sensitive-host-path.sh`, `docker/shared/golangci-lint-wrapper.sh`, `docker/shared/wt-bootstrap`, and `docker/shared/wt-remove`.
- `shfmt -d` is clean for the touched shell files, or the repository documents and automates a different formatter invocation and that invocation is clean.
- PowerShell analyzer remains clean.
- The image smoke still verifies the Go toolchain/cache probes and the golangci-lint wrapper cache paths.
- The dir-mount smoke for task 009 is run in a root-capable/native-Linux environment, or the skip is explicitly captured as environment-only and CI is confirmed to run it for real.

## Validation

Run:

```bash
./build.sh all
scripts/test-sensitive-host-path.sh
shellcheck docker/shared/fix-workspace-perms.sh docker/shared/heal-workspace-perms.sh docker/shared/sensitive-host-path.sh docker/shared/entrypoint-core.sh docker/shared/golangci-lint-wrapper.sh docker/shared/wt-bootstrap docker/shared/wt-remove scripts/launch-agent.sh scripts/smoke-test-dirmount.sh scripts/smoke-test-selfhosted.sh scripts/test-sensitive-host-path.sh
shfmt -d docker/shared/fix-workspace-perms.sh docker/shared/heal-workspace-perms.sh docker/shared/sensitive-host-path.sh docker/shared/entrypoint-core.sh docker/shared/golangci-lint-wrapper.sh docker/shared/wt-bootstrap docker/shared/wt-remove scripts/launch-agent.sh scripts/smoke-test-dirmount.sh scripts/smoke-test-selfhosted.sh scripts/test-sensitive-host-path.sh
pwsh -NoProfile -NonInteractive -Command "Invoke-ScriptAnalyzer -Path ."
POWBOX_SMOKE_SKIP_DB=1 POWBOX_SMOKE_SKIP_PODMAN=1 POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE=1 commands/smoke-test.sh powbox-agent:latest
POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE=1 pwsh -NoProfile -NonInteractive -File scripts/smoke-test-selfhosted.ps1 -Image powbox-agent:latest
```

On a root-capable/native-Linux validation host, also run `scripts/smoke-test-dirmount.sh powbox-agent:latest` without an environment-induced skip.

## Review plan

Reviewer confirms the standard build path and task-relevant lint/format commands are green, then spot-checks that the follow-up did not alter the accepted task 009 true-source behavior or task 011 Go cache layout except as required for validation.
