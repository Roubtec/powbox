# Task 073a — Make the PowerShell scripts' `docker --format` templates survive Windows PowerShell 5.1

## Why this task exists

Task 073 added `Test-PowboxImageStoreWriterWanted` to `scripts/launch-agent.ps1`. It reads the `powbox.podman` label through a Go raw string (`` `powbox.podman` `` inside the template), because Windows PowerShell 5.1 strips double quotes embedded in a native-command argument. The task 073 review (rounds 2 and 3, 2026-10-04) found that older templates in the launcher and in three other scripts still embed double quotes, so they hit exactly that bug. The fix was out of scope for 073, which is about moving tools into layer sets, so it is recorded here.

The bug was confirmed, not just inferred. It was checked on pwsh 7.6 with `$PSNativeCommandArgumentPassing = 'Legacy'`, which is the argument passing Windows PowerShell 5.1 uses, and a fake `docker` that prints its argv:

- `--format '{{ index .Config.Labels "powbox.base.selfhosted" }}'` arrives as `{{ index .Config.Labels powbox.base.selfhosted }}`, because PowerShell wraps the argument in quotes without escaping the inner ones, and the callee's command-line parser then drops them. A template built in a variable and passed as `--format $fmt`, and one written in a double-quoted string with `` `" ``, lose their quotes the same way.
- Go's `text/template` rejects the stripped forms: an unquoted label name fails with `function "powbox" not defined`, and an unquoted mount path fails with `unexpected "/" in operand`. So `docker inspect` exits non-zero and prints nothing, and every caller below treats that as an empty value.
- With a Go raw string (backticks) in place of the double quotes, the template reaches `docker` intact under both `Legacy` and `Standard` passing, and it parses and resolves the same value.

Pwsh 7.3 and later on Windows default to `Windows` passing, which escapes the quotes for `docker.exe`, so only Windows PowerShell 5.1 and pwsh 7.2 or older are affected.

## The affected sites and what each one does under 5.1 today

There are twelve sites in four scripts. Line numbers are as of task 073's branch. The guard rule under [Scope](#scope) matches exactly these twelve lines today.

`scripts/launch-agent.ps1`, single-quoted templates:

- **Line 1079, the ctx mount-set check** (`powbox.ctx-hash`). The existing hash reads as empty, so whenever a desired ctx set is present it never matches. A stopped container is recreated on every launch, and a running one fails with "running with a different ctx mount set".
- **Line 1141, the `-Continue` intent check** (`powbox.continue`). The value falls back to `"true"`, so every launch without `-Continue` recreates a stopped container or prints the "-Continue=false is ignored" note for a running one.
- **Line 1343, the Podman device-set check** (`powbox.podman-devices`). The recorded label reads as empty, so the check is silently skipped and a stopped container with a stale device set is never recreated.
- **Line 1403, the `-Isolated` capability guard** (`powbox.base.selfhosted`, added by task 001a). The failed inspect reads as "label absent", so **every** `-Isolated` launch fails with the false message "This agent image's base predates self-hosted mode" and exits 1.

`scripts/launch-agent.ps1`, double-quoted templates (`` `" `` inside a PowerShell `"…"` string):

- **Lines 1203 and 1206, the `.worktrees` and `node_modules` mount-name checks** (`.Destination` compared with `$workspaceMount/.worktrees` and `$workspaceMount/node_modules`). Both names read as empty, so whenever the launch expects a workspace volume, a stopped container is recreated on every launch and a running one gets a warning. The message is "outdated workspace volumes" when the launch expects both volumes (a JS project); a worktrees-only project (Go or .NET) gets the "does not match … expected mounts" message instead, with the same effect.
- **Line 1311, the Podman storage-mount check** (`.Destination` compared with `/home/node/.local/share/containers`). `$hasPodmanMount` reads as empty, so every stopped container is recreated on every launch as "predates the per-container Podman storage volume", and a running one gets a warning. This is the widest-reaching site: it fires for every non-`-Volatile` launch of an existing container, whatever the project type or flags.

Two `Get-ImageLabel` helpers, double-quoted templates with the label name interpolated from `$Label`:

- **`scripts/build-image-lib.ps1:13`.** Every label reads as empty. `Get-LayersStaleReason` then reports the layer-set image as "built from layer set 'none'", so a build with a selected set re-bakes the layer-set image every time. `Resolve-CodexCommit` always falls back to the HEAD commit, so the Codex layer is stamped with HEAD even when it was reused from cache. `scripts/build-image.ps1:340` stamps the base commit as `unknown`.
- **`commands/check-updates.ps1:96`.** Every label reads as absent. The baked base recipe digest is empty, so it compares unequal and the base is always reported stale. The base source falls back to the Dockerfile default. The baked layer-set name reads as empty, so whenever `.powbox-layers` selects a set, the layers are always reported stale.

`shell/powbox.ps1`, templates built in a `$fmt` variable from single-quoted pieces and passed as `--format $fmt`:

- **Line 151, `_Powbox-GetIsolatedByName`** (behind `cci` and `cxi`). The inspect fails, so no instance is ever found and every `cci <name>` or `cxi <name>` fails with "No self-hosted … container found with -Name".
- **Line 345, `agent-image-info`.** The inspect fails with Docker's template error on the console, every provenance field prints `unknown`, and the image always shows as "layers: none (lean image)".
- **Line 645, `_Powbox-AgentList`** (behind the `*-list` shortcuts). The inspect fails, so self-hosted containers lose their `[self-hosted name=… repo=… ref=…]` markers.

`scripts/launch-agent.sh` and the other Bash scripts are not affected: bash passes single-quoted arguments unchanged.

## Scope

**In scope:**

1. Replace every embedded `"…"` in the twelve templates with a Go raw string `` `…` ``, the idiom `Test-PowboxImageStoreWriterWanted` and `Get-SmokeImageLabel` already use. The recipe depends on the PowerShell string the template sits in:

   - In a **single-quoted** string a backtick is literal, so write it as is. This covers launcher lines 1079, 1141, 1343 and 1403, and the `$fmt` pieces in `shell/powbox.ps1`:

     ```powershell
     docker inspect --format '{{with .Config.Labels}}{{with (index . `powbox.ctx-hash`)}}{{.}}{{end}}{{end}}' $containerName
     ```

   - In a **double-quoted** string a lone backtick is PowerShell's escape character, so either double it (` `` ` renders one literal backtick, and `$var` still expands), or switch to concatenated single-quoted pieces as `scripts/smoke-test-lib.ps1:43` does. This covers launcher lines 1203, 1206 and 1311 and both `Get-ImageLabel` helpers:

     ```powershell
     docker image inspect $Image --format "{{ index .Config.Labels ``$Label`` }}"
     docker image inspect $Image --format ('{{ index .Config.Labels `' + $Label + '` }}')
     ```

   A Go raw string cannot contain a backtick. The interpolated values here (label names and `/workspace/<slug>` mount paths) never do, but a helper that takes a label name from its caller may validate it, as `Get-SmokeImageLabel` does with `^[A-Za-z0-9._-]+\z`.

2. A regression guard in a pure-shell `scripts/test-*.sh` suite (a new suite is auto-discovered by `scripts/run-pure-shell-tests.sh`, or an existing one can host it). It fails when any tracked `*.ps1` has a double quote, bare or backtick-escaped, inside a `{{ … }}` template action, for example by matching each line against the extended regex `\{\{[^}]*"` with `grep -E` or `git grep -E` (in basic regex syntax `\{` starts an interval, so the pattern fails there). That rule is deliberately about the template text, not about the `--format` argument:

   - It catches templates built in variables, because the `$fmt` literals in `shell/powbox.ps1` hold the quoted label names themselves.
   - It does not flag `--format "{{.Names}}"`, where the double quotes are PowerShell's own and are removed before the call.
   - It does not flag the `podman inspect --format "{{…}}"` lines in `scripts/smoke-test-podman.ps1` (lines 110, 199, 200, 216, 238 and 239). Those quotes are Bash quotes inside the probe script's text, outside the braces, and the template bodies contain none.
   - Its blind spots are a template whose `"` is assembled at run time (from a variable or `[char]34`), one that spans lines, and one whose action holds a `}` before the offending quote, which ends the `[^}]*` run early (such as ``{{if eq .Y `}` "a"}}``, where the `}` sits in a raw string). None exists today. The suite's comment should say so rather than try to cover them.

   Optionally, also run representative templates through pwsh with `$PSNativeCommandArgumentPassing = 'Legacy'` and a fake `docker`. `scripts/test-image-store-writer-gate.sh` is a fake-`docker` harness to build on, but it runs under pwsh's default passing; setting `Legacy` passing would be new.

3. Make the PowerShell capability-label reads treat a value as present exactly when their Bash twins do. Two reads trim the whole value with `.Trim()`, so a label whose value is only whitespace reads as absent in PowerShell, while the Bash twin, whose `$(…)` strips only trailing newlines, sees a non-empty value and treats it as present:

   - **`Test-PowboxImageStoreWriterWanted`** (`scripts/launch-agent.ps1:1598`, `powbox.podman`). Twin: `powbox_image_store_writer_wanted` in `scripts/launch-agent.sh`. A custom image with such a label passes smoke Stage 3's label check (`Get-SmokeImageLabel` and its Bash twin treat it as present) but launches without the image-store writer, and only when launched through PowerShell.
   - **The `-Isolated` capability guard** (`scripts/launch-agent.ps1:1404`, `powbox.base.selfhosted`, one of the twelve sites above). Twin: the `selfhosted_cap` check in `scripts/launch-agent.sh`.

   Strip only line endings, as `Get-SmokeImageLabel` does with `` .TrimEnd("`r", "`n") ``, then compare with `''` and `<no value>` exactly as now. Leave the `.Trim()` calls on the launcher's own labels (`powbox.ctx-hash`, `powbox.continue`, `powbox.podman-devices`) and on the mount names alone. The launcher writes those values itself, so trimming them never changes an answer. Only a capability label comes from whoever built the image.

   This came from an unresolved Copilot thread on PR #168 (`scripts/launch-agent.ps1:1598`), merged before it was addressed. It sits here because this task already rewrites both reads.

4. Note the behavior change in the PR. On 5.1, the ctx, continue, device and mount checks stop misfiring or start working, `-Isolated`, `cci`/`cxi` and the list markers start working, and the build and update check read their labels again.

**Out of scope:**

- Rewriting the guards' or helpers' logic, apart from the line-ending-only trim in item 3.
- Behavior changes to any Bash script. The guard suite is a new or changed `scripts/test-*.sh` file, and that is in scope.
- The probe script in `scripts/smoke-test-podman.ps1`. It is passed to `docker` as one native argument (`-lc $script`), so under `Legacy` passing every double quote in the whole script is stripped, and the argument is split at the spaces those quotes protected. That is a different problem from template quoting: it needs another way to hand the script over, such as stdin. It is worth its own follow-up if the PowerShell smoke drivers are meant to run on 5.1.

## Context and references

- `scripts/launch-agent.ps1`: `Test-PowboxImageStoreWriterWanted` and the comment above it (the idiom), plus the seven launcher sites above.
- `scripts/smoke-test-lib.ps1`: `Get-SmokeImageLabel` and its comment, the concatenation form of the idiom with label validation.
- `scripts/test-image-store-writer-gate.sh`: a fake-`docker` harness that already drives `launch-agent.ps1` functions under pwsh.
- Commit `11be9eb` (task 001a) introduced the `-Isolated` guard.

## Acceptance criteria

- No tracked `*.ps1` has a double quote inside a `{{ … }}` template action, and the new guard fails when one is reintroduced. Show this with two perturbations: one that puts a quoted label back into a literal `--format` template, and one that puts it back into a `$fmt` variable.
- Under `Legacy` argument passing, each of the twelve rewritten templates reaches a fake `docker` byte-identical to what the same call delivers under `Standard` passing.
- A `powbox.podman` label whose value is only whitespace is reported as present by both `Test-PowboxImageStoreWriterWanted` and `powbox_image_store_writer_wanted`. Show it with a new case in `scripts/test-image-store-writer-gate.sh`, which already checks that the two twins agree, and show that the case fails against the old `.Trim()`. The `-Isolated` guard gets the same trim. It has no fake-`docker` harness, so a test for it is optional.
- PSScriptAnalyzer `-Recurse` reports no error-severity findings, and `./scripts/run-pure-shell-tests.sh` passes.
