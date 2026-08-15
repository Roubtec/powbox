# Task 053b — Share Container B between the two worktree-metadata smoke drivers

## Prerequisite — task 053a (PR #152) must land first

Everything below describes the tree as it stands **after** PR #152 merges, and that PR is still open at the time of writing.
On `main` today `scripts/smoke-test-worktree-metadata-container-a.bash` does not exist, neither driver reads a shared payload, and `.github/workflows/native-linux-build.yml` runs `./commands/smoke-test.sh` only, with no PowerShell Stage 6 step.
Do not start this task against a tree where 053a's mechanism is absent: there is nothing to mirror, and the parity measurements below were taken on 053a's branch rather than on `main`.

## Why this task exists

Task 053a (PR #152) extracts **Container A**'s inner script into one file both drivers embed (`scripts/smoke-test-worktree-metadata-container-a.bash`), because a ~150-line Bash payload duplicated across `scripts/smoke-test-worktree-metadata.sh` and `scripts/smoke-test-worktree-metadata.ps1` is exactly how the coverage gap that created task 053a opened in the first place.

**Container B** — the recreate half, ~90 lines — was left duplicated. That was correct scoping for 053a, but the same drift has already started.

Measured on the branch that delivered 053a, comparing the `.sh`'s `VERIFY_SCRIPT='…'` body against the `.ps1`'s `$verifyScript = @(…)` array literal, whitespace-insensitively:

- One comment is **rewrapped and shortened** in the `.ps1`: the `.sh` has `# 1. Metadata survived: git status works in the recycled worktree, and the admin` / `#    dir is visible again through the re-established bind.` where the `.ps1` has the single line `# 1. Metadata survived: git status works, and the admin dir is visible via the bind.`
- One assertion message differs by **punctuation**: `git status failed in the recycled worktree — per-worktree metadata did not survive recreation` (em dash) versus the same line with a hyphen in the `.ps1`.
- Indentation differs throughout (tabs in the `.sh` heredoc, two spaces in the `.ps1` array), which a shared file also erases.

None of that changes behavior today.
That is the point: cosmetic drift is the observable early stage of the divergence that ended in a real coverage hole, and nothing in the repo can detect it — no static tool compares the two payloads.

## Scope

Move Container B's inner script into a single shared file both drivers read at runtime and hand to `/bin/bash -c`, exactly as 053a did for Container A.

The mechanism is already built and proven by 053a — reuse it rather than inventing a second one:

- a sibling `.bash` file beside the drivers, LF-pinned via `.gitattributes`
- picked up by Tier 0's shellcheck shebang matcher automatically
- the CRLF strip and the missing-file guard already exist on both sides for the Container A file; mirror them
- non-executable (mode 644) by design — running it on a host would aim `shadow-mounts.sh` at host paths

## Target files or areas

- `scripts/smoke-test-worktree-metadata.sh` — the `VERIFY_SCRIPT='…'` literal (the `--- Container B: recreate, re-bind, assert the worktree survived intact ----------` block)
- `scripts/smoke-test-worktree-metadata.ps1` — the `$verifyScript = @(…)` array literal (the `The in-container verify script (Container B)` block)
- wherever the shared Container B Bash lands (a new sibling file, named consistently with `scripts/smoke-test-worktree-metadata-container-a.bash`)
- `.gitattributes` — LF pin for the new file, matching the Container A entry
- `docs/smoke-tests.md` → Stage 6 and "The PowerShell mirror" — both mention that Container A's inner script is shared; extend to Container B

## Implementation notes

- **Read 053a's PR (#152) before starting.** Its round-1 defect was that the shared file was loaded into a variable and then *silently clobbered* by the stale inline literal a few lines further down, so `docker run` received the old payload. PSScriptAnalyzer cannot see it (the variable *is* used) and neither can any other gate in this repo. Delete the old literal in the same commit that adds the read, and prove reachability directly — 053a did it by executing the driver with `docker` stubbed on a scratch `PATH` and comparing the captured argv after `-c` byte-for-byte against the shared file, with a negative control against the broken commit.
- Verify parity in both directions before and after: the shared file should be byte-identical to one former copy, and the diff against the other should be only the cosmetic drift listed above (which this task deliberately resolves in one direction — pick the `.sh`'s wording, since the shared file is Bash and the `.ps1` no longer needs to be ASCII-clean for content it only reads at runtime).
- Follow `AGENTS.md` → "File Conventions": `.ps1` stays CRLF; the shared `.bash` is LF.
- Lint with `pwsh -Command "Invoke-ScriptAnalyzer -Path ."`, `shellcheck`, `shfmt -d`, and `./scripts/run-pure-shell-tests.sh`.

## Validation

Unlike 053a, the positive half is automated once 053a lands: Tier 1 then runs **both** drivers' Stage 6 (`.github/workflows/native-linux-build.yml` gains a dedicated PowerShell step in PR #152), so a payload that *breaks inside the image* turns Tier 1 red rather than needing a maintainer's desktop.
That step also fails on a runtime self-skip and counts the three `ok: mountpoint ownership` lines, so it cannot go green on a driver that started but never reached its assertions.

**Tier 1 is not evidence that the shared payload is the one that ran, and must not be treated as such.**
Under exactly the defect the implementation notes above describe — the shared file loaded into a variable that a stale inline literal then clobbers — both Stage 6 runs stay **green**, because the stale literal is still *correct*: the container does the right thing with the wrong copy, and no gate in this repo compares the two.
So the stubbed-`docker` reachability check is required rather than a nicety: it is the only check available here that distinguishes a payload that is *reached* from a payload that is merely *present and correct*.

A host run (`./build.ps1 all`, then `commands/smoke-test.ps1`) is still the only way to exercise the Windows/macOS side.

## Acceptance criteria

- Container B's inner script exists in exactly ONE place that both drivers use; a change to it cannot land in one driver only.
- The old inline literal is **deleted** from each driver — not left in place — and reachability is proven directly by the stubbed-`docker` argv comparison, not inferred from the artifact being correct and not inferred from a green Tier 1, which stays green under the loaded-then-clobbered defect.
- The cosmetic drift listed above is gone by construction.
- Tier 1 is green, including the PowerShell Stage 6 step with its three ownership assertions.
- `docs/smoke-tests.md` describes both containers' scripts as shared.
