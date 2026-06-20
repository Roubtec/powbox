# 007 — Self-heal mixed-ownership dir-mounted workspaces (nested root-owned files)

## Why this task exists

PR #55 (and its smoke guard, task [005](005-dir-mount-ownership-smoke-stage.md)) handle a workspace that is **entirely** root-owned — root dir and everything under it: the entrypoint's write probe fails at the workspace root and `fix-workspace-perms.sh` chowns the tree to `node`.

This task handles the **mixed-ownership** case the current logic misses: a workspace whose **root dir is node-owned (uid 1000)** but which **contains nested `root`-owned files**. It arises in normal use when a host operation runs as **root** against the bind-mounted repo while the container exists — most often `sudo git pull` (or a host whose login user is root / a repo under `/root`) on a native-Linux host. A `git pull` as root re-owns to uid 0 exactly the paths it writes — new/updated `.git/objects/*`, refs/reflogs/`HEAD`/`config`, and the working-tree files changed in the pulled commits — while leaving the top-level directory node-owned.

Observed 2026-06-19 in the powbox repo itself during the PR #59 review session: ~130 uid-0 entries (including ~39 `.git/objects/<xx>/` shard dirs) left the `node` agent unable to write loose git objects — `git commit`/`git add` failed with `insufficient permission for adding an object to repository database .git/objects` — and unable to edit the root-owned tracked files. The only remedy was a manual host-side `chown -R 1000:1000 <repo>`. powbox should self-heal this on container start instead.

## The gap — two reasons a restart does NOT self-heal today

1. **The entrypoint probe is root-level only.** `entrypoint-core.sh` probes writability by `mktemp`-ing a file in each `/workspace/<slug>` **top dir** (`entrypoint-core.sh` ~line 73). A node-owned root passes, so the workspace is never added to `_unwritable` and `fix-workspace-perms.sh` is never invoked — even though nested files are root-owned.
2. **The helper refuses a node-owned root.** `fix-workspace-perms.sh` only acts when the **workspace root dir** is uid 0; for any other owner (including node) it refuses by design (to avoid stripping a non-root host user of ownership). So even if it were called here, it would no-op.

## Goal

Make a dir-mounted workspace self-heal nested root-owned files on container start — **without** ever re-owning a genuine non-root host user's files, and **without** descending into the node-owned mounted volumes.

## Scope / suggested approach

Two coordinated changes in `docker/shared/`:

1. **Entrypoint detection (`entrypoint-core.sh`).** In addition to the root-level write probe, trigger the helper when a workspace **contains** any uid-0 entry. Keep it cheap and short-circuiting — e.g. `find "$_dir" -uid 0 -print -quit` — and prune the mounted volume paths the same way the helper does so the scan does not walk `node_modules`/`.worktrees`. Add such workspaces to the existing `_unwritable` handoff list. Preserve the self-hosted / writer-role / no-sudo exemptions.
2. **Helper (`fix-workspace-perms.sh`).** Allow it to act on a workspace whose root dir is node-owned but which contains uid-0 entries, while **keeping every existing safety property**: realpath containment to a `/workspace/<slug>` child; chown **only** `find -uid 0` entries (never another host uid — that scoping is exactly what makes this safe, since root keeps host-side access via DAC bypass); prune the separately-mounted node-owned `node_modules`/`.worktrees` mountpoints (mountinfo + `-xdev` backstop); `-h` for symlinks; idempotent. Consider whether the existing "root-owned root → chown whole tree" path and the new "node-owned root → chown uid-0 entries" path collapse into a single `find -uid 0` re-own (they likely do); simplify if so.
3. **Smoke-test coverage (REQUIRED — do not skip).** Task 005 ships first and builds the reusable dir-mount smoke harness; this task **must** extend that harness with the mixed-ownership fixture variant (a node-owned repo root plus a nested `root`-owned tracked file and a `.git/objects/<xx>` dir chowned to root) and assert the entrypoint re-owns them and a `node` git write succeeds. **007 is not complete until this smoke stage exists and is green**, and until reverting 007's logic makes it fail. Wire it into the same `commands/smoke-test.{sh,ps1}` stage / `POWBOX_SMOKE_SKIP_*` flag 005 established (see task 005).

## Acceptance criteria

- A dir-mounted workspace with a node-owned root but nested root-owned files (e.g. a `.git/objects/<xx>` dir plus a tracked file made uid 0) is fully node-owned after the entrypoint runs; a `node` `git commit` and a tracked-file edit both succeed with no manual chown.
- The all-root-owned case (task 005 / PR #55) still self-heals — no regression.
- A workspace containing files owned by a **non-root, non-node** host uid leaves those files untouched (only uid-0 entries re-owned), with the existing warning preserved.
- The mounted `node_modules`/`.worktrees` volumes are never descended into or re-owned.
- Negligible startup cost for an already-clean (node-owned) workspace beyond a short-circuiting `find -uid 0 -print -quit`.
- **The mixed-ownership smoke stage (scope item 3) is added to task 005's harness and passes against the post-007 image.** Reverting 007's **helper re-own** (`fix-workspace-perms.sh`'s node-owned-root chown path) makes the stage fail with a clear EACCES-style message, so the substantive new logic is guarded — **this PR is not mergeable without that half.** The **entrypoint detection-scan** half is, like task 005's all-root case, exercised through the helper-in-isolation harness rather than a full entrypoint run, so reverting *only* that scan does not yet fail the smoke. This is a deliberate **relaxation** of the original "reverting 007's detection/chown makes it fail" wording, recorded here after the PR #63 review: closing that remaining gap is tracked as follow-up [007a](007a-smoke-exercise-entrypoint-nested-uid0-scan.md), and **the PR is mergeable with that half deferred.**
- `shellcheck` / `shfmt` clean (including the new smoke stage).

## Context / references

- Helper + sudoers: `docker/shared/fix-workspace-perms.sh` (baked to `/usr/local/bin/`; NOPASSWD sudoers entry in `docker/base/Dockerfile`). Probe: `docker/shared/entrypoint-core.sh` (~lines 59–85).
- Prior art: PR #55 (all-root-owned fix); task [005](005-dir-mount-ownership-smoke-stage.md) (its smoke guard — extend it with a mixed-ownership fixture once this lands).
- Origin: PR #59 address-review session (2026-06-19); the repo itself hit the mixed-ownership trap from a host `sudo git pull`.

## Validation

On a native-Linux host: from the host, `sudo chown root:root` a tracked file and a `.git/objects/<xx>` dir of a node-owned dir-mounted repo; restart the container; confirm the entrypoint re-owns them to node and a `node` git write succeeds. Confirm a file owned by a non-root, non-node uid is left alone. `shellcheck`/`shfmt` clean.

## Review plan

Reviewer confirms: the detection genuinely catches nested uid-0 entries (not just the root probe); the helper still refuses to touch non-root, non-node files; the mounted-volume prune still holds; the change is idempotent and cheap on a clean workspace.

## Status

**Not started.** Sequenced **after** task [005](005-dir-mount-ownership-smoke-stage.md), which builds the reusable smoke harness this task extends (maintainer decision, PR #59 session). 007 carries the obligation to add its own mixed-ownership smoke stage to that harness (scope item 3 / acceptance) — it is not done until that guard is green. Follows PR #59, which rewrites `entrypoint-core.sh`, so branch off the post-#59 `main` to avoid conflicts.
