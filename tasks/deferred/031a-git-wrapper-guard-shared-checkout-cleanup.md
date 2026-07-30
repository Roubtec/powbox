# 031a (deferred) — Structural guard against destructive cleanup of the shared main checkout

## Why this task exists (and why it is deferred)

Task 031 documented the shared-vs-isolated surfaces boundary: the main checkout and the `.worktrees` volume are shared by every process in a container (including a peer harness), `.worktrees` is protected only by `.gitignore` + tmpfs shadows, and one repo-root `git clean -fdx` or `git reset --hard` by any co-tenant can silently destroy another agent's uncommitted work.
That protection is convention-only.
During a July 2026 kalm2 parallel batch the failure was real: an implementer's worktree was reset/hard-cleaned mid-task several times by an unattributed co-tenant process, discarding uncommitted work (committed work always survived).

**Deferred because:** the documentation shipped (task 031, the template's "Shared vs. isolated surfaces" section) and no recurrence has been observed since; a git shim is invasive (surprising `git` behavior is its own footgun) and should be built from a fresh incident's specifics, not speculatively.
This spec exists as inspiration for the day it bites again.

## Trigger to action this

Any recurrence of uncommitted-work loss in a worktree or the main checkout that traces to a co-tenant's repo-root cleanup command.

## Scope (sketch — revalidate against the incident that actions this)

- Bake a `git` shim at `/usr/local/bin/git` (ahead of `/usr/bin/git` on `PATH`) that passes everything through via `exec /usr/bin/git "$@"` except when ALL of the following hold:
  - the effective subcommand is `clean` with `-x`/`-X` in its flag cluster, or `reset --hard` (mind `-C <path>`, `--git-dir`, and global-flag parsing before the subcommand);
  - the target working tree resolves to a repo ROOT directly under `/workspace/` (the shared main checkout — never inside `.worktrees/`, never a self-hosted private clone's scratch area);
  - live linked worktrees exist under that repo's `.worktrees/` (any container's subdir — the point is protecting siblings).
- On match: refuse with a short explanation quoting the shared-surfaces rule, name the live worktrees found, and require an explicit env override (`POWBOX_ALLOW_DESTRUCTIVE_CLEAN=1`) to proceed.
- Path-scoped invocations (`git clean -fdx -- <subpath>` not covering `.worktrees`) may pass; start strict and loosen if the shim annoys.
- Out of scope: intercepting `rm -rf .worktrees` (not practically shimmable; the volume mount already makes a plain `rm -rf` of the mountpoint fail) and any change to `wt-*` helpers (they already refuse destructive operations on dirty trees).

## Context and references

- `docker/shared/container-agent.md.tmpl` → "Shared vs. isolated surfaces" — the rule the shim enforces.
- `tasks/done/031-document-shared-checkout-worktree-boundaries.md` — the documentation-only predecessor.
- `docker/shared/wt-remove` — precedent for "refuses destructive operations, even with --force" semantics and messaging tone.

## Implementation notes (for whenever this is actioned)

- The shim must be transparent for scripting: identical exit codes/stdout for passthrough, refusal only on the narrow match, and it must not slow down hot paths (string checks only, no `git` subprocess calls before the exec on the passthrough path).
- Beware `git -c ...`/alias expansion; parse conservatively and prefer false-negative (allow) over false-positive (block a legitimate command) for anything ambiguous — the guard is a seatbelt, not a sandbox.
- Test as a pure-shell suite (fake repo + fake worktrees): blocked cases, override, passthrough fidelity (including `--version`, hooks, plumbing under stdin pressure).

## Acceptance criteria

- Repo-root `git clean -fdx` / `git reset --hard` in a shared main checkout with live sibling worktrees is refused with an actionable message; the override works; all other git usage is byte-transparent.

## Validation

- Pure-shell test suite in-container; image smoke asserts the shim resolves first on `PATH` and `git --version` still works for both agents.

## Review plan

Reviewer attacks the argv parser (aliases, `-C`, global flags, `--` separators) looking for both bypasses and false blocks, and confirms passthrough adds no measurable latency.
