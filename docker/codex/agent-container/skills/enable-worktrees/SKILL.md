---
name: enable-worktrees
description: Prepare a repository for git-worktree-based parallel development — verify and fix the repo-root .powbox.yml declarations and .gitignore so worktree scaffolding stays container-local (persistent volume for .worktrees, tmpfs for metadata roots) and is never committed. Trigger when the user wants to enable, set up, or prepare a repo for parallel worktree tasks, or to fix a repo that is not worktree-ready. Do NOT trigger to actually execute a task batch (use address-tasks-worktrees) or for unrelated .gitignore edits.
---

Prepare the current repository to support the git-worktree parallel-development workflow.

This is the **setup** counterpart to `address-tasks-worktrees`.
That skill *runs* a task batch across worktrees and assumes the repo is already prepared; this skill *prepares* the repo's committed config so the workflow works hands-free on every future container.
Run it once per repo, and re-run any time to verify or repair.

This is a small, mechanical config task — do it inline yourself.
Do **not** spawn worker or explorer subagents.

## What "worktree-ready" means

Declared workspace subdirectories are kept container-local so writes there never reach the host bind mount.
The launcher-mounted `.worktrees` volume takes precedence; declared roots that are not already mountpoints get tmpfs shadows.
For worktree-based parallelism a repo needs two committed things.

1. **`.powbox.yml`** at the repo root declaring the worktree scaffolding as **literal** shadow paths. powbox's `detect-shadows.sh` creates literal paths (no `* ? [ ]` glob metacharacters) at container startup *even when they do not exist yet* and tmpfs-shadows any that are not already mountpoints, so committed declarations apply hands-free on a fresh checkout:

   ```yaml
   shadow:
     - .worktrees          # orchestrator-created worktrees (one per task)
     - .claude/worktrees   # harness-native worktrees (cross-agent parity)
     - .git/worktrees      # per-worktree git metadata — keeps the host's own
                           #   worktree registrations out of the container, and ours off the host
   ```

   Task worktrees created by Codex's `address-tasks-worktrees` live under `.worktrees/`.
   The `.claude/worktrees/` entry is part of the current cross-agent shadow contract; it is not a requirement for Codex subagent execution, but keeping it declared preserves parity for repos used by either primary agent.

2. **`.gitignore`** ignoring the two working-tree roots so worktree files are never committed:

   ```gitignore
   .worktrees/
   .claude/worktrees/
   ```

   `.git/worktrees` needs **no** gitignore entry — it lives inside the untracked `.git/` directory.

Why this is safe and durable: the common `.git` (objects + refs) is *not* shadowed, so committed work persists on the host and survives container recycle. The powbox launcher backs `.worktrees` with a **persistent per-project volume** (which also holds the pnpm store, so worktree `pnpm install` hardlinks from it); `.claude/worktrees` and `.git/worktrees` stay ephemeral tmpfs. The `.worktrees` entry below is then a harmless **fallback** — skipped when the volume is mounted, used only if the container is launched without it.
powbox's README "Workspace Shadow Mounts → Git Worktree Parallel Development" has the full model (readable at `/ctx` if the powbox repo happens to be mounted, but this skill ships the contract so that is optional).

## Procedure

Operate on the current repository only.
Every step is idempotent and surgical — preserve unrelated content, comments, and formatting, and never remove shadow entries or gitignore lines you did not add.

1. **Locate the repo root.** `ROOT="$(git rev-parse --show-toplevel)"`. If this is not a git repository, stop and tell the user — worktrees require git.

2. **Reconcile `.powbox.yml`.** Read `$ROOT/.powbox.yml` if it exists.
   - Absent → create it with a `shadow:` list containing the three literal entries above.
   - Present → ensure the `shadow:` list contains each of the three entries and add any that are missing. **Keep every existing entry** (other shadow paths, monorepo `node_modules` globs, etc.) untouched. If the file has a `shadow:` key that is malformed or not a list, stop and report rather than rewriting it.

3. **Reconcile `.gitignore`.** Ensure `$ROOT/.gitignore` ignores `.worktrees/` and `.claude/worktrees/`.
   - Accept an existing equivalent entry (`.worktrees` without a trailing slash also matches the directory). Only add what is missing, under a short comment such as `# powbox git worktrees (container-local; never commit working trees)`.
   - Do **not** add `.git/worktrees`.

4. **Guard against leaked tracking.** Run `git -C "$ROOT" ls-files -- .worktrees .claude/worktrees`. If anything is tracked, `git -C "$ROOT" rm -r --cached` it (keeping the working copy) so worktree contents stop being committed. Report what you untracked.

5. **(Optional) Apply immediately in this session.** Committed declarations take effect automatically at the *next* container start. To shadow the directories now, in the running container, without relaunching:

   ```bash
   shadow-refresh.sh "$ROOT"
   for root in "$ROOT/.worktrees" "$ROOT/.claude/worktrees" "$ROOT/.git/worktrees"; do
     mountpoint -q "$root" || { echo "Unsafe worktree root (not a mountpoint): $root" >&2; exit 1; }
     findmnt -no TARGET,FSTYPE -T "$root"
   done
   for root in "$ROOT/.claude/worktrees" "$ROOT/.git/worktrees"; do
     [ "$(findmnt -nro FSTYPE -T "$root")" = tmpfs ] ||
       { echo "Unsafe worktree metadata root (expected tmpfs): $root" >&2; exit 1; }
   done
   case "$(findmnt -nro FSTYPE -T "$ROOT/.worktrees")" in
     9p|drvfs|virtiofs) echo "Unsafe .worktrees host filesystem" >&2; exit 1 ;;
   esac
   ```

   `.worktrees` is healthy when it is its own mount on any container-local filesystem — normally the per-project volume, or tmpfs as a fallback. The other two roots must be tmpfs. If a check fails, tell the user to rebuild the powbox image on the host (`./build.sh all`) and relaunch; the repo config you wrote is still correct.

6. **Commit the config.** These files belong in version control so every teammate and every future container inherits a worktree-ready repo. Stage `.powbox.yml` and `.gitignore` and commit them following the repo's commit conventions — or, if the user prefers to review first, leave them staged and say so.

## Report

State concisely:

- Whether the repo was already compliant, or what you changed, per file.
- Anything you untracked in step 4.
- Whether the container-local mounts are live in the current session (step 5) or pending the next container start.
- Any blocker: not a git repo, a malformed `.powbox.yml`, or a stale image.

## Notes

- This skill changes only **repo config** — it does not create worktrees or run tasks. To execute a task batch across worktrees afterward, use `address-tasks-worktrees`.
- If Codex or another harness later keeps native worktrees under a different root, declare and gitignore that root the same way, alongside the three above.
