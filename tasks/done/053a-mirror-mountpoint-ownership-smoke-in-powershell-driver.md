# Task 053a — Mirror the mountpoint-ownership smoke into the PowerShell worktree-metadata driver

## Why this task exists

Task 053 (PR #131) added privileged, end-to-end coverage for `docker/shared/shadow-mounts.sh`'s "created mountpoint directory inherits the deepest existing ancestor's ownership" `chown` to `scripts/smoke-test-worktree-metadata.sh`.
The PowerShell counterpart, `scripts/smoke-test-worktree-metadata.ps1`, did **not** get that coverage.

That matters because the two drivers are not Windows-only vs. Linux-only: `commands/smoke-test.ps1` runs anywhere `pwsh` runs, including a native-Linux host, and its `Stage 6 - durable worktree-metadata recreate lifecycle` block invokes `scripts/smoke-test-worktree-metadata.ps1` — never the Bash script.
So a full smoke driven through the PowerShell umbrella can report success without ever exercising the mountpoint-chown integration check, which is precisely the regression net task 053 exists to install.
The `.ps1` header historically claimed it was "behaviourally identical" to the `.sh` script; PR #131 corrected that claim to name this divergence and point here, but the coverage gap itself is still open.

Raised by the codex reviewer on PR #131 (https://github.com/Roubtec/powbox/pull/131#discussion_r3707692376) and deferred out of that PR: the port is not mechanical (see below) and, like everything in the smoke tier, cannot be validated from inside an agent container — shipping an unvalidatable harness edit blind is worse than queueing it.

## Scope

Bring the task 053 ownership coverage to `scripts/smoke-test-worktree-metadata.ps1`: share the Container A Bash between the two drivers and mirror the host-side assertions natively (see decision (c) below).

The Bash side added four pieces; all four need an answer.
Each is cited below by the construct that names it rather than by line number: these files shift under ordinary edits, and the line citations this task originally carried had already rotted twice before anyone re-read them. Every anchor quoted here is a unique string in its file, so `grep -n` locates it whatever the current numbering is — keep it that way when editing this task.

1. **Host fixture** (`scripts/smoke-test-worktree-metadata.sh`, the `A stand-in project directory for the mountpoint-ownership coverage` block just after the `FIXTURE="$(mktemp -d …)"` line) — the invoking host user creates `$FIXTURE/proj` (plus a marker file) before Container A runs, so that shadowing `proj/bin` creates exactly ONE component whose deepest existing ancestor is invoker-owned. This is the .NET artifact shape the chown was written for.
2. **Container A additions** (`scripts/smoke-test-worktree-metadata-container-a.bash`, the shared inner script both drivers embed: from the `Mountpoint-ownership coverage (task 053), MULTI-component case` comment through the `single-component artifact shadow created at proj/bin` ok line) — run `/usr/local/bin/shadow-mounts.sh` against `$WS/.claude/worktrees` (a MULTI-component creation: two levels, so the walk must reach the workspace root) and against `$WS/proj/bin` (a SINGLE component on the ordinary tmpfs branch), assert each became a mountpoint, and assert in-container that the intermediate `$WS/.claude` — created but never itself a mountpoint — has the same `uid:gid` as `$WS`, with `UNREADABLE` sentinels so a failed `stat` is a hard failure rather than a vacuous "both unknown, so equal".
3. **Host-side assertions** (`scripts/smoke-test-worktree-metadata.sh`, the whole `--- Host-side: created mountpoints inherited the tree's ownership (task 053) ---` section: its header comment, `owner_of()`, `assert_created_mountpoint_owner()` and the three call sites, ending just before `--- Container B (the recreate) ---`) — after Container A exits (its mount namespace is gone, so a plain `stat` sees the UNDERLYING directory), assert that `proj/bin`, `.claude/worktrees` and `.git/worktrees` each have the same `uid:gid` as their deepest pre-existing ancestor. Note that `.git/worktrees` goes through the durable-BIND branch, so it is not a duplicate of the `proj/bin` tmpfs case, and that `.worktrees` is deliberately NOT asserted (the container engine creates that mountpoint for the named volume, so it is legitimately root-owned).
4. **Cleanup + vacuity honesty** (`scripts/smoke-test-worktree-metadata.sh`: the `cleanup()` function registered with `trap cleanup EXIT`; the `Tolerance:` paragraph and the `state the vacuity conditions out loud` list that close the host-side section header; and the two `note:` announcements in that section's `else` branch, guarded by `docker info -f '{{.SecurityOptions}}' … grep -q rootless` and `[ "$(id -u)" = 0 ]`) — the equality-with-ancestor form (never `== $(id -u)`) that tolerates a squashing filesystem, the announced vacuity conditions (rootless engine, smoke run as root), and the cleanup comment explaining that `.claude/worktrees` may leak an empty dir in exactly the regression case.

## Design decisions — DECIDED, implement exactly this

These three questions are why this was not a same-PR fix. The maintainer has now settled all three; there is nothing left to choose. Each declined alternative is kept only so the reasoning is not relitigated.

### (a) Reading `uid:gid` from PowerShell — shell out to `stat`, mirroring the Bash side exactly

Try GNU `stat -c '%u:%g'` first and fall back to BSD `stat -f '%u:%g'`, which is byte-for-byte what `owner_of()` does in `scripts/smoke-test-worktree-metadata.sh`.
When neither form works, record a `Note-Skip` and skip the ownership assertions instead of failing — identical tolerance to that script's `if ! owner_of "$FIXTURE" >/dev/null 2>&1` guard, whose `note_skip` branch reports `mountpoint-ownership assertions skipped: this host's stat supports neither 'stat -c' nor 'stat -f'`, and for the same reason: silence there would be indistinguishable from a real pass.

Considered and declined:

- **`stat -c` only.** Diverges from the `.sh`'s documented BSD tolerance: `owner_of()`'s `stat -f '%u:%g'` fallback means a macOS host reads the ownership and runs the assertions, so a `stat -c`-only port would hard-fail where the Bash driver passes — the `.sh`'s skip guard fires only when *neither* form works.
- **A pure PowerShell/.NET route.** .NET exposes `UnixFileMode` but not the owner uid/gid, so this would mean P/Invoke into libc — far more code and a new portability surface for a smoke test.

### (b) Non-Linux hosts — gate the ownership assertions on `$IsLinux`, and record a counted, reported `Note-Skip` otherwise

On a Windows/FUSE bind mount `uid:gid` is squashed, so every path reports the same owner and the equality assertions compare equal trivially.
That is a vacuous **pass** — a milder strain of exactly the false-green disease this task exists to cure — so on a non-Linux host the assertions must not run at all: skip them and surface the skip through the umbrella banner via the existing `Note-Skip` / `POWBOX_SMOKE_SKIP_MARKER` mechanism, the same way the driver's other runtime self-skips are counted and reported.
Note that this **introduces** the driver's first OS gate: `scripts/smoke-test-worktree-metadata.ps1` currently has zero `$IsLinux` / `$IsWindows` / `$IsMacOS` references (verified), because the durable bind itself happens inside the Linux VM and is genuinely portable. Gate only the ownership assertions; leave the rest of the stage OS-agnostic.

Considered and declined:

- **Running them vacuously with the vacuity conditions announced**, matching the Bash script's tolerance. Closer parity with the `.sh`, but the PowerShell umbrella would then report a green that proves nothing on Windows/macOS.

### (c) Share or duplicate — share the Bash, duplicate the host-side assertions

Factor the **Container A additions** into one place both drivers embed. They were already plain Bash in the PowerShell driver too — before this change, its own inline `$setupScript` array literal in `scripts/smoke-test-worktree-metadata.ps1`, handed to `/bin/bash` by that file's Container A `docker run @runArgs … --entrypoint /bin/bash $Image -c $setupScript` call — so a single shared source of that inner script removes the largest drift surface at the lowest cost.
Write the ~40 lines of **host-side assertions** natively in each driver instead. Duplicating that much is acceptable; sharing it is what would require a bad mechanism (see below).

Considered and declined:

- **Full duplication** (inner script copied too). Recreates the ~150-line parity hazard that caused this task in the first place.
- **Full sharing, with the `.ps1` shelling out to the `.sh`.** Needs bash on the host, which defeats the whole reason the `.ps1` exists on Windows.

## Target files or areas

- `scripts/smoke-test-worktree-metadata.ps1` (the coverage gap; also remove the KNOWN DIVERGENCE block in its header once closed)
- `scripts/smoke-test-worktree-metadata.sh` (the Container A additions move to the shared source per decision (c))
- wherever the shared Container A Bash lands (a new file both drivers read/embed)
- possibly `commands/smoke-test.ps1` (Stage 6 comment)
- `docs/smoke-tests.md` → "The PowerShell mirror" (drop the Stage 6 divergence bullet once the gap is closed)

## Implementation notes

- Follow `AGENTS.md` → "File Conventions": `.ps1` files stay **CRLF**, and must be UTF-8 **with BOM** if any non-ASCII character is introduced (the current file is pure ASCII — keep it that way and no BOM is needed).
- Lint with `pwsh -Command "Invoke-ScriptAnalyzer -Path ."` (the repo-root `PSScriptAnalyzerSettings.psd1` is auto-applied).
- This **must be validated on the host** (`./build.ps1 all`, then `commands/smoke-test.ps1`), not in an agent container — see `AGENTS.md` → "Validating Changes". A native-Linux host with a rootful engine and an unprivileged invoking user is the only configuration where the assertions have real teeth.

## Acceptance criteria

- A `commands/smoke-test.ps1` run on a native-Linux host exercises the mountpoint-ownership check and fails when the `chown` is removed from `docker/shared/shadow-mounts.sh` — i.e. the PowerShell route is no longer a false green for that regression.
- Both the multi-component (`.claude/worktrees`) and single-component (`proj/bin`, tmpfs branch) cases are covered, plus `.git/worktrees` on the durable-bind branch, matching the Bash script.
- `uid:gid` is read by shelling out to `stat -c '%u:%g'` with a `stat -f '%u:%g'` fallback, and a host where neither works records a `Note-Skip` rather than failing (decision (a)).
- On a non-Linux host the ownership assertions do **not** run: they are gated on `$IsLinux` and a `Note-Skip` is recorded and surfaced in the umbrella banner, so the PowerShell umbrella never reports a vacuous green for them (decision (b)). The rest of the stage stays OS-agnostic.
- The remaining vacuity conditions on Linux (rootless engine, root invoker) are handled the same way the Bash script handles them, and announced rather than hidden.
- The Container A additions exist in exactly ONE place that both drivers use; a change to them cannot land in one driver only (decision (c)). The host-side assertions may be written natively in each driver.
- The KNOWN DIVERGENCE block in `scripts/smoke-test-worktree-metadata.ps1`'s header is removed, and its "behaviourally identical" claim is true again — with the `$IsLinux` gate on the ownership assertions documented in the header, since that is a deliberate, narrower divergence from the `.sh`.
- The Stage 6 divergence bullet in `docs/smoke-tests.md` → "The PowerShell mirror" is removed or reduced to the `$IsLinux` gate.
