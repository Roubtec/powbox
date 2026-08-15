# Task 053b — Share Container B between the two worktree-metadata smoke drivers

## Prerequisite — task 053a (PR #152), already satisfied

Everything below describes the tree as it stands **after** PR #152, which has merged to `main`.
Confirm the three things this task mirrors are present before starting, because without them there is nothing to mirror: on `main` today `scripts/smoke-test-worktree-metadata-container-a.bash` exists, both drivers read that shared payload (`scripts/smoke-test-worktree-metadata.sh` via `cat`, `scripts/smoke-test-worktree-metadata.ps1` via `Get-Content -Raw`), and `.github/workflows/native-linux-build.yml` runs a dedicated PowerShell Stage 6 step beside `./commands/smoke-test.sh`.

## Why this task exists

Task 053a (PR #152) extracted **Container A**'s inner script into one file both drivers embed (`scripts/smoke-test-worktree-metadata-container-a.bash`), because a ~150-line Bash payload duplicated across `scripts/smoke-test-worktree-metadata.sh` and `scripts/smoke-test-worktree-metadata.ps1` is exactly how the coverage gap that created task 053a opened in the first place.

**Container B** — the recreate half, ~90 lines — was left duplicated. That was correct scoping for 053a, but the same drift has already started.

Measured on `main` after 053a merged, the `.sh`'s `VERIFY_SCRIPT='…'` body and the `.ps1`'s `$verifyScript = @(…)` array literal are not the same bytes.

Two of the byte differences are framing rather than drift — each embedding construct imposes one, and neither is part of the script.
The `.sh` literal opens `VERIFY_SCRIPT='` immediately followed by a newline, so its extracted body begins on an empty line the other forms do not have.
And `-join` inserts separators only, so the `.ps1`'s body ends `exit 0` with **no** final LF, where the `.sh`'s ends `exit 0` and a newline.
Set those two aside and the payloads differ in exactly these four ways and no others:

- One comment is **rewrapped and shortened** in the `.ps1`: the `.sh` has `# 1. Metadata survived: git status works in the recycled worktree, and the admin` / `#    dir is visible again through the re-established bind.` where the `.ps1` has the single line `# 1. Metadata survived: git status works, and the admin dir is visible via the bind.`
- One assertion message differs by **punctuation**: `git status failed in the recycled worktree — per-worktree metadata did not survive recreation` (em dash) versus the same line with a hyphen in the `.ps1`.
- Indentation differs throughout (tabs in the `.sh`'s single-quoted `VERIFY_SCRIPT` literal, two spaces in the `.ps1` array), which a shared file also erases.
- The `.ps1` **drops every blank line**: the `.sh`'s payload has 8 empty lines separating its sections, where the `.ps1`'s 87-element array holds no empty element at all — so the text it hands `bash -c` has no blank line anywhere. A shared file settles that one way for both drivers too.

None of that changes behavior today.
That is the point: cosmetic drift is the observable early stage of the divergence that ended in a real coverage hole, and nothing in the repo can detect it — no static tool compares the two payloads.

## Scope

Move Container B's inner script into a single shared file both drivers read at runtime and hand to `/bin/bash -c`, exactly as 053a did for Container A.

The mechanism is already built and proven by 053a — reuse it rather than inventing a second one:

- a sibling `.bash` file beside the drivers, LF-pinned via `.gitattributes`
- picked up by Tier 0's shellcheck shebang matcher automatically — which is also why the shared file is byte-equal to nothing it replaces: the matcher reads only each tracked non-`.sh` file's first line (`.github/workflows/native-linux-ci.yml`), so the file has to open with a shebang, and 053a's Container A file puts the drivers' contract in a header comment under it (34 lines before its first statement). Every comparison this task prescribes is therefore stated on payload bodies, or on what a loader captured, and names what it excludes — none of them is a raw identity against the file.
- the missing-file guard already exists on both sides for the Container A file, and the `.ps1` adds a CRLF strip after `Get-Content -Raw` that the `.sh`'s bare `cat` does not need; mirror both constructs — the guard on both drivers, the strip in the `.ps1` only
- non-executable (mode 644) by design — running it on a host would aim `shadow-mounts.sh` at host paths

## Target files or areas

- `scripts/smoke-test-worktree-metadata.sh` — the `VERIFY_SCRIPT='…'` literal (the `--- Container B: recreate, re-bind, assert the worktree survived intact ----------` block)
- `scripts/smoke-test-worktree-metadata.ps1` — the `$verifyScript = @(…)` array literal (the `The in-container verify script (Container B)` block)
- wherever the shared Container B Bash lands (a new sibling file, named consistently with `scripts/smoke-test-worktree-metadata-container-a.bash`)
- `.gitattributes` — no change needed: the catch-all `* text=auto eol=lf` already pins the new `.bash`, as it does the Container A file (053a added no per-file entry)
- `docs/smoke-tests.md` → Stage 6 and "The PowerShell mirror" — both mention that Container A's inner script is shared; extend to Container B

## Implementation notes

- **Read 053a's PR (#152) before starting.** Its round-1 defect was that the shared file was loaded into a variable and then *silently clobbered* by the stale inline literal a few lines further down, so `docker run` received the old payload. PSScriptAnalyzer cannot see it (the variable *is* used) and neither can any other gate in this repo. Delete the old literal in the same commit that adds the read, and prove reachability directly — 053a did it by executing the driver with `docker` stubbed on a scratch `PATH` and comparing the captured argv after `-c` against the shared file, with a negative control against the broken commit.
  Compare after each loader's own normalization rather than demanding raw byte identity with the file, which the Bash side cannot deliver: `SETUP_SCRIPT="$(cat "$file")"` is a command substitution, and that strips **every** trailing newline, while the `.ps1`'s `Get-Content -Raw` keeps the file's final LF (its `-replace` only folds CRLF). For a normally newline-terminated `.bash` file the two captures therefore differ from the file, and from each other, in exactly that byte. Strip trailing newlines from the file and from each capture before comparing: that keeps the check exact on everything a clobbered payload would change, and true for both drivers.
- Verify parity in both directions before and after on the three payload **bodies**, since each of the three forms frames its body differently: strip the shared file's preamble, take the `.sh`'s text between the `VERIFY_SCRIPT='` quotes (that literal holds no `'`, so the text between them is the payload verbatim), and `-join` the `.ps1`'s array elements with LF. Normalize away the two framing bytes named under "Why this task exists" before asserting anything exact, and both comparisons are then exact: drop the `.sh` body's leading empty line and its diff against the shared file's body must be **empty**; strip leading indentation and drop every blank line from both the `.ps1`'s body and the shared file's — which also settles the `-join`'s missing final LF, since a line-oriented filter re-terminates its last line — and that diff must be exactly the rewrapped comment and the em dash, the two content drifts listed above, and nothing else. Resolve that drift in the `.sh`'s direction, since the shared file is Bash: its em dash moves into the `.bash` rather than into the `.ps1`, which holds no non-ASCII today and so still needs none of the UTF-8-with-BOM save `AGENTS.md` → "File Conventions" requires of a `.ps1` that does.
- Follow `AGENTS.md` → "File Conventions": `.ps1` stays CRLF; the shared `.bash` is LF.
- Lint with `pwsh -Command "Invoke-ScriptAnalyzer -Path ."`, `shellcheck`, `shfmt -d`, and `./scripts/run-pure-shell-tests.sh`.

## Validation

Unlike 053a, the positive half is already automated: Tier 1 runs **both** drivers' Stage 6 (`.github/workflows/native-linux-build.yml` gained a dedicated PowerShell step in PR #152), so a payload that *breaks inside the image* turns Tier 1 red rather than needing a maintainer's desktop.
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
