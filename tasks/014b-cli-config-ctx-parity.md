# 014b — CLI/config context parity: repeatable `--ctx` with modes and aliases

> Follow-up to task 014 (its OQ-3 resolution deferred full parity here).
> Execute **after** 014 — this task reuses 014's entry normalization and
> hash-label recreate detection. Independent of 014a. Fully resolved —
> ready for implementation once 014 lands.

## Why this task exists

After task 014, the config file can express multiple context folders with
per-folder `rw`/`ro` modes and `name:` aliases, while the CLI `--ctx`
argument remains a single read-only mount at `/ctx/<basename>`. The CLI's
entire purpose in the precedence chain is **one-off divergence** — and a
one-off sometimes needs exactly what the config can do (two repos, one of
them writable) without editing `.powbox.local.yml` and editing it back.
This task brings the argument to feature parity for a single invocation.

## Scope

**In scope:**

- `--ctx` / `-Ctx` accepts **multiple values** — repeated flags in bash
  (`--ctx A --ctx B`), a native `[string[]]` array in PowerShell
  (`-Ctx A,B`).
- Per-value **mode** and **alias** using the settled grammar (below):
  `--ctx <path>[:ro|:rw]` and `--ctx <name>=<path>[:ro|:rw]`.
- Precedence unchanged from 014: the presence of *any* CLI context value
  overrides the configured `ctx:` section wholesale — never a merge.
- CLI strictness kept and extended: missing path, unusable basename,
  malformed value, or **duplicate target name** across CLI values is a
  **hard error** (unlike config entries, which warn + skip — an explicit
  argument deserves loud failure).
- Reuse of 014's machinery: values normalize to the same `(path, name,
  mode)` tuples, feed the same canonical hash, and the same `powbox.ctx-hash`
  label drives reuse/recreation — a CLI set and a config set producing the
  same mounts produce the same hash.
- **Wrapper chain updates** so repeated/array values pass through:
  `commands/claude-container.ps1`, `commands/codex-container.ps1`
  (`[string]$Ctx` → `[string[]]`), `shell/powbox.ps1`, `shell/powbox.sh`,
  and the arg loops in `scripts/launch-agent.sh` / `scripts/launch-agent.ps1`.
- Docs: README context section gains the multi-value CLI examples.

**Out of scope:**

- Any change to the config file schema or parsing (task 014).
- Merging CLI values with configured context.
- `shadow:` concerns (task 014a).

## Context and references

- Task 014 (`tasks/014-context-mounts-local-config.md`): entry normalization
  rules (`~`/relative expansion, basename/alias validation), duplicate
  semantics, the "Recreate detection (config-hash label)" section, and the
  uniform `/ctx/<name>` layout — all reused verbatim here.
- Current single-value plumbing: `scripts/launch-agent.sh:25,77-79,124-129`
  and `scripts/launch-agent.ps1:14,89-93` (as of 014's baseline; 014 will
  have reshaped these).
- `--resume` semantics: unchanged — any CLI context alongside `--resume` is
  ignored with the existing warning.

## CLI syntax for mode and alias (settled)

**Mirror the config short form, alias via `=`:**
`--ctx <path>[:ro|:rw]` plus `--ctx <name>=<path>[:ro|:rw]` for an alias,
e.g. `--ctx C:\Code\OtherRepo:rw --ctx Docs=C:\Users\a\Documents\Specs`.
One grammar shared with the config file (same trailing-token mode split,
same Windows drive-letter care); `=` is not a legal filename character on
Windows and rare on Unix, and the form is unambiguous because the value is a
single shell token. The alias, when present, is everything before the
**first** `=`, validated by 014's alias rules (single safe path segment).

*Considered & declined:* companion flags (`--ctx-rw <path>` +
`--ctx-name <name>`) — no suffix parsing, but the positional coupling
between flags (which `--ctx-name` binds to which `--ctx`?) is error-prone
and triples the flag surface.

## Implementation notes

- PowerShell idiom differs from bash by design: `-Ctx` binds a `[string[]]`
  (`-Ctx a,b:rw`), bash repeats the flag. Document both; do not force
  repeated `-Ctx` in PowerShell.
- The single-value invocation (`--ctx <path>`) must behave exactly as it
  does after 014 — same mount, same hash — so parity is a pure superset.
- Keep 014's hard-error character for everything CLI: fail before any
  container mutation (validate the full set first, then act).
- Match each script's existing arg-parsing style; keep sh/ps1 behavioral
  parity for every error message and validation rule.

## Acceptance criteria

1. `cc --ctx <A> --ctx <B>:rw` (bash) / `cc -Ctx <A>,<B>:rw` (PowerShell)
   mounts `/ctx/<basenameA>` read-only and `/ctx/<basenameB>` read-write;
   any configured `ctx:` section is ignored.
2. An alias value (`--ctx Docs=<path>[:rw]`) mounts at `/ctx/Docs` with the
   given mode.
3. Missing path, malformed value, or duplicate target name across CLI values
   aborts the launch with a clear message before any container is created or
   removed.
4. The hash-label reuse/recreate behavior of 014 holds for CLI sets: same
   set ⇒ reuse; changed set ⇒ recreate (stopped) or "stop first" (running);
   `--resume` warns and ignores.
5. A single `--ctx <path>` invocation is behaviorally identical to post-014
   (no regression), and the whole wrapper chain (`cc`/`cx` →
   `commands/*` → `launch-agent.*`) forwards multi-values intact.
6. README documents both platforms' multi-value forms with examples.

## Validation

- `shellcheck` on `launch-agent.sh` and `shell/powbox.sh`;
  `Invoke-ScriptAnalyzer` on the three touched `.ps1` files.
- Manual: multi-mount launch on at least one host flavor, verifying mounts
  and modes via `docker inspect --format '{{json .Mounts}}'`; rerun with the
  same values (reuses) and with one mode flipped (recreates stopped).
- Negative: duplicate aliases, missing path, malformed suffix — each aborts
  cleanly with no container churn.

## Review plan

Reviewer should check: (1) the CLI grammar matches the settled
`[name=]path[:mode]` form and shares 014's normalization code rather than
duplicating it; (2) sh/ps1
parity, including the `[string[]]` binding vs repeated-flag difference;
(3) validation happens before any destructive step; (4) single-value
behavior is a strict superset of post-014 behavior.
