# Task 053a — Mirror the mountpoint-ownership smoke into the PowerShell worktree-metadata driver

## Why this task exists

Task 053 (PR #131) added privileged, end-to-end coverage for `docker/shared/shadow-mounts.sh`'s "created mountpoint directory inherits the deepest existing ancestor's ownership" `chown` to `scripts/smoke-test-worktree-metadata.sh`.
The PowerShell counterpart, `scripts/smoke-test-worktree-metadata.ps1`, did **not** get that coverage.

That matters because the two drivers are not Windows-only vs. Linux-only: `commands/smoke-test.ps1` runs anywhere `pwsh` runs, including a native-Linux host, and its Stage 6 (`commands/smoke-test.ps1:562`) invokes `scripts/smoke-test-worktree-metadata.ps1` — never the Bash script.
So a full smoke driven through the PowerShell umbrella can report success without ever exercising the mountpoint-chown integration check, which is precisely the regression net task 053 exists to install.
The `.ps1` header historically claimed it was "behaviourally identical" to the `.sh` script; PR #131 corrected that claim to name this divergence and point here, but the coverage gap itself is still open.

Raised by the codex reviewer on PR #131 (https://github.com/Roubtec/powbox/pull/131#discussion_r3707692376) and deferred out of that PR: the port is not mechanical (see below) and, like everything in the smoke tier, cannot be validated from inside an agent container — shipping an unvalidatable harness edit blind is worse than queueing it.

## Scope

Mirror the task 053 ownership coverage from `scripts/smoke-test-worktree-metadata.sh` into `scripts/smoke-test-worktree-metadata.ps1`, or share it between the two drivers.

The Bash side added four pieces; all four need an answer:

1. **Host fixture** (`scripts/smoke-test-worktree-metadata.sh:399-405`) — the invoking host user creates `$FIXTURE/proj` (plus a marker file) before Container A runs, so that shadowing `proj/bin` creates exactly ONE component whose deepest existing ancestor is invoker-owned. This is the .NET artifact shape the chown was written for.
2. **Container A additions** (`scripts/smoke-test-worktree-metadata.sh:208-256`, inside `$setupScript`) — run `/usr/local/bin/shadow-mounts.sh` against `$WS/.claude/worktrees` (a MULTI-component creation: two levels, so the walk must reach the workspace root) and against `$WS/proj/bin` (a SINGLE component on the ordinary tmpfs branch), assert each became a mountpoint, and assert in-container that the intermediate `$WS/.claude` — created but never itself a mountpoint — has the same `uid:gid` as `$WS`, with `UNREADABLE` sentinels so a failed `stat` is a hard failure rather than a vacuous "both unknown, so equal".
3. **Host-side assertions** (`scripts/smoke-test-worktree-metadata.sh:429-509`) — after Container A exits (its mount namespace is gone, so a plain `stat` sees the UNDERLYING directory), assert that `proj/bin`, `.claude/worktrees` and `.git/worktrees` each have the same `uid:gid` as their deepest pre-existing ancestor. Note that `.git/worktrees` goes through the durable-BIND branch, so it is not a duplicate of the `proj/bin` tmpfs case, and that `.worktrees` is deliberately NOT asserted (the container engine creates that mountpoint for the named volume, so it is legitimately root-owned).
4. **Cleanup + vacuity honesty** (`scripts/smoke-test-worktree-metadata.sh:377-393`, `:454-472`, `:496-506`) — the equality-with-ancestor form (never `== $(id -u)`) that tolerates a squashing filesystem, the announced vacuity conditions (rootless engine, smoke run as root), and the cleanup comment explaining that `.claude/worktrees` may leak an empty dir in exactly the regression case.

## Design decisions the implementer must make

These are why this was not a same-PR fix:

- **How to read `uid:gid` from PowerShell.** There is no native accessor; the Bash script uses GNU `stat -c '%u:%g'` with a BSD `stat -f` fallback. The PowerShell driver would have to shell out to the same `stat` (available on Linux/macOS, absent on Windows) or find another route. Decide and record which.
- **What the assertions mean on a non-Linux host.** This driver deliberately has no host-OS gate — the durable bind happens inside the Linux VM, so it is portable to Docker Desktop on Windows/macOS. But `uid:gid` ownership on a Windows/FUSE bind mount is squashed, so the assertions there are vacuous. Decide whether to run them vacuously (matching the Bash script's tolerance, which is already documented as vacuous on such filesystems), or to gate them on `$IsLinux` and record a `Note-Skip` otherwise. Either is defensible; say which in the PR.
- **Share or duplicate.** ~150 lines of assertion logic duplicated across two drivers is a parity hazard of exactly the kind this task is fixing. Consider whether the inner Container A additions (already plain Bash strings in `$setupScript`) and/or the host-side assertions can be factored so the two drivers cannot drift again — for example by having the `.ps1` invoke a shared helper, the way both umbrellas already share the `POWBOX_SMOKE_SKIP_MARKER` mechanism.

## Target files or areas

- `scripts/smoke-test-worktree-metadata.ps1` (the coverage gap; also remove the KNOWN DIVERGENCE block in its header once closed)
- `scripts/smoke-test-worktree-metadata.sh` (only if the logic is factored for sharing)
- possibly `commands/smoke-test.ps1` (Stage 6 comment)

## Implementation notes

- Follow `AGENTS.md` → "File Conventions": `.ps1` files stay **CRLF**, and must be UTF-8 **with BOM** if any non-ASCII character is introduced (the current file is pure ASCII — keep it that way and no BOM is needed).
- Lint with `pwsh -Command "Invoke-ScriptAnalyzer -Path ."` (the repo-root `PSScriptAnalyzerSettings.psd1` is auto-applied).
- This **must be validated on the host** (`./build.ps1 all`, then `commands/smoke-test.ps1`), not in an agent container — see `AGENTS.md` → "Validating Changes". A native-Linux host with a rootful engine and an unprivileged invoking user is the only configuration where the assertions have real teeth.

## Acceptance criteria

- A `commands/smoke-test.ps1` run on a native-Linux host exercises the mountpoint-ownership check and fails when the `chown` is removed from `docker/shared/shadow-mounts.sh` — i.e. the PowerShell route is no longer a false green for that regression.
- Both the multi-component (`.claude/worktrees`) and single-component (`proj/bin`, tmpfs branch) cases are covered, matching the Bash script.
- The vacuity conditions (squashing filesystem, rootless engine, root invoker) are handled the same way the Bash script handles them, and announced rather than hidden.
- The KNOWN DIVERGENCE block in `scripts/smoke-test-worktree-metadata.ps1`'s header is removed, and its "behaviourally identical" claim is true again.
