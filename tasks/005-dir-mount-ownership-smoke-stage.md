# 005 — Smoke stage: dir-mounted root-owned repo must be writable by the node agent

## Why this task exists

PR #55 fixed a total native-Linux blocker: a dir-mounted repo owned by `root` (e.g. a repo under `/root`) is `root:root` inside the container, and the `node` (uid 1000) agent could not write it — `touch` and `git pull` failed with EACCES (`cannot open '.git/FETCH_HEAD': Permission denied`). The pre-fix entrypoint only registered `safe.directory` (which silences the *ownership warning*, not write perms). The fix made the entrypoint probe writability and `chown` root-owned mounts via a new sudo helper (`docker/shared/fix-workspace-perms.sh`).

There is **no automated guard** for this. Like PR #54's Stage B, it is exactly the kind of native-Linux-only behavior that Windows/WSL never shows and that only a real Linux host exercises. A regression (entrypoint reordering, a dropped sudoers entry, a helper rename) would silently re-break every native-Linux host whose mounted repo is not uid-1000-owned.

## Scope

Included:
- A smoke stage that dir-mounts a **root-owned** throwaway git repo into the agent image and asserts the `node` agent can write it (create a file, and perform a git operation) after the entrypoint runs.
- A short README/AGENTS note documenting the native-Linux bind-mount uid expectation, next to the existing exec-bit note.
- **Once task [006](006-selfheal-mixed-ownership-dir-mount.md) lands:** a second fixture variant for the **mixed-ownership** case — a node-owned repo root with nested `root`-owned files (e.g. a tracked file plus a `.git/objects/<xx>` dir chowned to root, simulating a host `sudo git pull`) — asserting the entrypoint re-owns them and a `node` git write succeeds. This guards the 006 self-heal, which the root-level write probe alone would miss. (Until 006 lands, this variant is expected to fail, so add it together with 006, not before.)

Out of scope: changing the fix itself (PR #55 shipped it); Windows/macOS uid behavior (the bug is native-Linux-specific).

## Context and references

- The fix: PR #55; entrypoint probe + `docker/shared/fix-workspace-perms.sh` (baked to `/usr/local/bin/fix-workspace-perms.sh`; sudoers entry in `docker/base/Dockerfile` ~line 192). The chown helper is one of three NOPASSWD sudo commands for `node`.
- Origin: an agent-session retrospective (2026-06-14) flagging that the PR #55 fix has no regression guard.
- Pattern to follow: `scripts/smoke-test-selfhosted.sh` (Stage A always-runs / Stage B image-gated), wired into `commands/smoke-test.{sh,ps1}` as a stage with its own `POWBOX_SMOKE_SKIP_*` flag.
- The umbrella now exports `POWBOX_SMOKE_REQUIRE_IMAGE`; the new stage must honour it (fail instead of self-skip when the image is absent), matching the self-hosted stage's pattern.

## Target files or areas

- New: `scripts/smoke-test-dirmount.sh` + `scripts/smoke-test-dirmount.ps1` (or an added stage inside the self-hosted scripts — implementer's call; a separate script keeps the concern isolated).
- Wire into `commands/smoke-test.sh` and `commands/smoke-test.ps1` as a new stage with a `POWBOX_SMOKE_SKIP_DIRMOUNT` flag and skip-banner tracking (mirror the existing four stages).
- README / AGENTS.md: native-Linux bind-mount uid note.

## Implementation notes

- Build a fixture: a temp dir, `git init` a trivial repo inside it, then make it **root-owned** (`chown -R root:root`). Creating a root-owned path needs root — trivial on a CI runner; locally it needs `sudo`, so the stage should detect when it cannot create a root-owned fixture and **skip with a clear message** rather than fail (and say so in the banner). In CI (task 003) it runs for real.
- Launch the agent image in dir-mount mode against the fixture (the real launcher path, or a `docker run` that reproduces the mount + entrypoint), let the entrypoint run, then assert as `node`: a `touch <mount>/smoke-write` succeeds and a git write (e.g. `git -C <mount> commit --allow-empty`) succeeds. Assert the host-side file is owned appropriately afterward.
- Image-gated: if the image is absent, self-skip — unless `POWBOX_SMOKE_REQUIRE_IMAGE` is set, then fail (copy the guard added to `smoke-test-selfhosted.sh`).
- Clean up the fixture (including the root-owned files — may need `sudo rm -rf` or a container-side chown back) in a trap/finally.

## Acceptance criteria

- New stage runs from `commands/smoke-test.sh`/`.ps1`, is listed in the skipped-stages banner when skipped, and honours `POWBOX_SMOKE_REQUIRE_IMAGE`.
- Against the current (post-#55) image the stage passes; temporarily reverting the entrypoint chown makes it fail with a clear EACCES-style message.
- (With task [006](006-selfheal-mixed-ownership-dir-mount.md)) the mixed-ownership fixture variant also passes against the post-006 image, and fails if 006's nested-uid-0 detection/chown is reverted.
- `shellcheck`/`shfmt` clean (sh) and `Invoke-ScriptAnalyzer` clean (ps1).
- README/AGENTS documents the native-Linux bind-mount uid expectation.

## Validation

On a Linux host (or CI runner): run the stage against a freshly built image — passes. Revert `fix-workspace-perms.sh`'s chown (or strip the sudoers entry) and rebuild — the stage fails on the `node` write. Confirm fixture cleanup leaves no root-owned temp dirs behind.

## Review plan

Reviewer confirms the fixture is genuinely root-owned (not just `safe.directory`-flagged), the write assertions run as `node` (not root), the local no-sudo path skips cleanly, `REQUIRE_IMAGE` is honoured, and cleanup is robust.

## Status

**Not started.** Feeds task [003](003-native-linux-ci.md) (this stage runs in Tier 1 CI once both land). The mixed-ownership fixture variant pairs with task [006](006-selfheal-mixed-ownership-dir-mount.md) and should be added alongside it.
