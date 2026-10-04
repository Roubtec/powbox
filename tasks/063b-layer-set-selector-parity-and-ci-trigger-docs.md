# Task 063b — Close the PowerShell layer-set selector's invisible-character gap and list the staging script among README's Tier 1 triggers

**Relates to:** 063 (the selector and its bash/PowerShell parity requirement), 067 (the template-staging script that triggers Tier 1).

## Why this task exists

The sweep that reaped tasks 063 and 067 found the residuals below, each too small for a task of its own.

### The PowerShell selector silently skips a line that bash rejects

Task 063's selector contract says an invalid `.powbox-layers` name is a hard error, never a silent fallback to the lean image, and that `scripts/layers-select.sh` and `scripts/layers-select.ps1` agree on every input.
The PowerShell twin decides whether a trimmed line is blank or a `#` comment with culture-aware comparisons (`-eq ''` and a one-argument `StartsWith('#')`).
Under the invariant/current culture those comparisons ignore zero-width and other ignorable code points, so a line consisting only of, say, U+00AD (soft hyphen) or U+200B (zero-width space) counts as blank, and a line beginning with U+200B followed by `#` counts as a comment.
Bash treats the same bytes as an invalid name and exits non-zero.

Reproduced during the sweep: a selector holding only U+00AD makes `layers-select.sh` exit 1 with "invalid layer-set name", while `layers-select.ps1` exits 0 with no output, which means it silently picks the lean image. A U+200B line before `full` makes PowerShell print `full` and bash fail.
The practical effect is that a `build.ps1` build and the bash update check can disagree about the same checkout.
The digest twin had the same bug class and was already fixed by switching to ordinal comparison (see `scripts/layers-digest.ps1`). The selector was not.

The user writes the selector file, so the severity is low. It is still a parity break the task's acceptance criteria rule out.

### README's Tier 1 trigger sentence omits the template-staging script

Task 067 added `scripts/stage-agent-template.*` to the `paths:` filter of `.github/workflows/native-linux-build.yml`, so that a PR changing only the staging script runs Tier 1.
README "Continuous Integration" lists what triggers Tier 1, and that list does not name the staging script. It implies such a PR runs Tier 0 alone.
The sentence currently reads as a complete list, which is what lets it drift whenever the filter changes. The workflow's `paths:` filter is the source of truth, so the sentence should summarize it, say where the authoritative list lives, and stop claiming to be exhaustive.

## Scope

**In scope:**

- Make the PowerShell selector's blank-line and comment-line tests ordinal, so they classify exactly the lines the bash selector does.
- Add selector cases to the existing bash/PowerShell parity coverage in `scripts/test-layer-sets.sh` for ignorable code points: a lone ignorable line, an ignorable line before a valid name, and an ignorable character before `#`. Both languages must reject each one the same way.
- Reword README "Continuous Integration"'s Tier 1 trigger sentence as a summary that points at the workflow's `paths:` filter as the authoritative list, mentioning the staging script.

**Out of scope:**

- Changing the selector's accepted-name grammar.
- Changing the workflow's `paths:` filter itself.

## Acceptance criteria

- Every ignorable-code-point selector case makes `layers-select.sh` and `layers-select.ps1` both fail, with matching stderr, as the existing parity cases do.
- The existing selector cases still pass unchanged.
- `scripts/test-layer-sets.sh` passes with `pwsh` present.
- README's Tier 1 trigger sentence mentions the staging script, names the workflow's `paths:` filter as the authoritative list, and no longer reads as exhaustive.

## Validation

- Run `bash scripts/test-layer-sets.sh` in a `full` image so the PowerShell half runs.
- Run PSScriptAnalyzer recursively from the repo root (see AGENTS.md "PowerShell Linting").
- Read the README sentence against `.github/workflows/native-linux-build.yml` and confirm nothing it says contradicts the filter.
