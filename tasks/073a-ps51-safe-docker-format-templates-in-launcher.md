# Task 073a — Make the launcher's `docker --format` templates survive Windows PowerShell 5.1

## Why this task exists

Task 073 added `Test-PowboxImageStoreWriterWanted` to `scripts/launch-agent.ps1`.
It reads the `powbox.podman` label with a Go raw string, `` --format '{{ index .Config.Labels `powbox.podman` }}' ``, because Windows PowerShell 5.1 strips double quotes embedded in a native-command argument.
The task 073 review (round 2, 2026-10-04) noticed that the older guards in the same file still embed double quotes, so they hit exactly that bug.
The fix was out of scope for 073, which is about moving tools into layer sets, so it is recorded here.

The bug was confirmed, not just inferred. It was checked on pwsh 7.6 with `$PSNativeCommandArgumentPassing = 'Legacy'`, which is the argument passing Windows PowerShell 5.1 uses, and a fake `docker` that prints its argv:

- `--format '{{ index .Config.Labels "powbox.base.selfhosted" }}'` arrives as `{{ index .Config.Labels powbox.base.selfhosted }}`, because PowerShell wraps the argument in quotes without escaping the inner ones, and the callee's command-line parser then drops them.
- Go's `text/template` rejects that stripped form with `function "powbox" not defined`, so `docker inspect` exits non-zero and prints nothing.
- With backticks, the template reaches `docker` intact under both `Legacy` and `Standard` passing, and it parses and resolves the label.

Pwsh 7.3 and later on Windows default to `Windows` passing, which escapes the quotes for `docker.exe`, so only Windows PowerShell 5.1 and pwsh 7.2 or older are affected.

## The affected sites and what each one does under 5.1 today

All four are in `scripts/launch-agent.ps1`. Line numbers are as of task 073's branch.

- **Line 1403, the `-Isolated` capability guard** (`powbox.base.selfhosted`, added by task 001a). The failed inspect reads as "label absent", so **every** `-Isolated` launch fails with the false message "This agent image's base predates self-hosted mode" and exits 1.
- **Line 1079, the ctx mount-set check** (`powbox.ctx-hash`). The existing hash reads as empty, so whenever a desired ctx set is present it never matches. A stopped container is recreated on every launch, and a running one fails with "running with a different ctx mount set".
- **Line 1141, the `-Continue` intent check** (`powbox.continue`). The value falls back to `"true"`, so a container created without `-Continue` is recycled or warned about on every launch.
- **Line 1343, the Podman device-set check** (`powbox.podman-devices`). The recorded label reads as empty, so the check is silently skipped and a stopped container with a stale device set is never recreated.

`scripts/launch-agent.sh` is not affected: bash passes single-quoted arguments unchanged.

## Scope

- Replace the embedded `"…"` label name with a Go raw string `` `…` `` in all four templates, the idiom `Test-PowboxImageStoreWriterWanted` already uses. Inside a PowerShell single-quoted string a backtick is literal, so no other escaping is needed.
- Add a regression guard that fails when any tracked `*.ps1` passes a `--format` (or `-f`) template that contains a double quote to a native command. A static scan in an existing pure-shell suite is enough. Optionally, also run the templates through pwsh with `$PSNativeCommandArgumentPassing = 'Legacy'` and a fake `docker`, as `scripts/test-image-store-writer-gate.sh` does for the writer gate.
- Note the behavior change in the PR: on 5.1, the ctx, continue and device checks start working where they were dead or misfiring, and `-Isolated` starts working.

Out of scope: rewriting the guards' logic, and any `.sh` change.

## Context and references

- `scripts/launch-agent.ps1`: `Test-PowboxImageStoreWriterWanted` and the comment above it (the idiom), plus the four sites above.
- `scripts/test-image-store-writer-gate.sh`: a fake-`docker` harness that already drives `launch-agent.ps1` functions under pwsh.
- Commit `11be9eb` (task 001a) introduced the `-Isolated` guard.

## Acceptance criteria

- No tracked `*.ps1` passes a `docker … --format` template containing `"`, and the new guard fails when one is reintroduced. Show this with a perturbation that puts one back.
- Under `Legacy` argument passing, each of the four templates reaches a fake `docker` byte-identical to its source text.
- PSScriptAnalyzer `-Recurse` reports no error-severity findings, and `./scripts/run-pure-shell-tests.sh` passes.
