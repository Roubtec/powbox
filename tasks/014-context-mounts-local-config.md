# 014 — Multi-folder context mounts via `.powbox.local.yml`

> **STATUS: SECOND DRAFT — partially resolved.** OQ-2, OQ-5, OQ-6, and OQ-7
> are settled (see "Resolved decisions"); the remaining open questions must be
> resolved with the maintainer before implementation starts. The spec sections
> are written against the resolutions plus the current recommendations.
>
> Numbered 014 (even = inserted task) deliberately so it executes **before**
> the 015a–015e skills-management batch. Follow-up: `014a` (shadow overrides
> in the local file) is already written and executes after this task.

## Why this task exists

`--ctx` / `-Ctx` mounts exactly one host folder, always read-only, flattened
directly onto `/ctx` (no parent-folder name inside the container). In practice
users sometimes need **several** external references at once (another repo for
code style/configs, a folder of documents to process) and sometimes need one of
them **read-write** (e.g. transfer files between two repos and push both).
Today the only workaround is mounting a common parent folder, which is awkward
whenever the host directory layout doesn't cooperate.

This task adds a user-local, gitignored config file that declares a *set* of
context folders with per-folder access modes, picked up automatically by a
plain `cc` / `cx` in the workspace folder, with each folder mounted under its
own name at `/ctx/<name>/`.

## Scope

**In scope:**

- A new repo-root config file (working name **`.powbox.local.yml`** — see
  OQ-1) read by the **host-side launch scripts**, both flavors:
  `scripts/launch-agent.ps1` and `scripts/launch-agent.sh`.
- A `ctx:` list in that file, docker-compose-inspired dual syntax (see OQ-4):
  **short form** — a host path string with optional `:rw` / `:ro` suffix,
  `ro` default; **long form** — an object with `path:` plus optional `name:`
  (mount alias) and `mode:` keys. No container-side path is ever specified —
  the launcher derives it.
- Mount layout: each entry mounts at `/ctx/<name>/`, where `<name>` is the
  explicit `name:` alias or defaults to the path's basename (e.g.
  `C:\Code\OtherRepo:rw` → `/ctx/OtherRepo` read-write;
  `/home/alice/code/DocumentRepo` → `/ctx/DocumentRepo` read-only).
- Warnings for duplicate target names (see OQ-4) and non-existent host paths
  (**settled:** warn + skip for config entries; the CLI argument keeps its
  hard error).
- Precedence rules: `.powbox.local.yml` over `.powbox.yml` (**settled:**
  top-level section clobber); explicit CLI `--ctx` over both (see OQ-3).
- Generalizing the existing container-reuse **mount-change detection** from
  "one `/ctx` mount source" to "the set of `/ctx` + `/ctx/*` mounts, including
  each mount's rw/ro mode".
- Documentation: README "Read-Only Context Volume" section (title no longer
  accurate), `docs/architecture.md` if it mentions `/ctx`.

**Out of scope:**

- Any container-side behavior change. The container cannot act on host paths;
  it just sees whatever is mounted under `/ctx`. (`shadow:` overrides via the
  local file are **task 014a** — already written; execute after this task.)
- Changing what the existing single `--ctx` CLI argument does (layout stays
  flattened-onto-`/ctx` for backward compatibility, unless OQ-3 resolves
  otherwise).
- Multi-value or `:rw`-suffixed **CLI** syntax (`--ctx a:rw --ctx b`) — only
  if OQ-3 resolves in favor of it.

## Context and references

- **Current `--ctx` implementation (host side):**
  - `scripts/launch-agent.sh:25` (var), `:77-79` (arg parse), `:124-129`
    (existence check — currently a **hard error**), `:207-215`
    (`normalize_ctx_path`), `:552-553` (`--resume` ignores ctx, warns),
    `:617-641` (reuse-vs-recreate detection via
    `docker inspect --format '{{range .Mounts}}...{{end}}'` comparing the
    single `/ctx` mount source), `:912-914` (`CTX_ARGS=(-v "$CTX_PATH:/ctx:ro")`).
  - `scripts/launch-agent.ps1:14`, `:89-93`, `:396-397`, `:470-510`
    (same logic, incl. `ConvertFrom-DockerDesktopPath` normalization for
    Windows/Docker-Desktop path comparison), `:812-814` (`$ctxArgs`).
- **Pass-through wrappers** (must not need changes beyond docs, since the
  config file is read by the launch scripts themselves): 
  `commands/claude-container.ps1`, `commands/codex-container.ps1`,
  `shell/powbox.ps1` (`cc`/`cx` functions), `shell/powbox.sh`.
- **`.powbox.yml` today:** parsed **only container-side** —
  `docker/shared/detect-shadows.sh:59-127` reads `shadow:` globs with `yq`.
  The host launchers only test the file's *existence* to classify the project
  (`scripts/launch-agent.sh:428`, `scripts/launch-agent.ps1:262`). **This task
  introduces the first host-side parsing of a powbox YAML file, and it must
  work in both PowerShell (Windows) and POSIX sh/bash (Unix) without assuming
  `yq` exists on the host** (see OQ-7).
- **Docs:** `README.md` "Read-Only Context Volume" (~line 375) and "Context
  Changes on Resume"; `docs/architecture.md`.
- **Task conventions:** `tasks/AGENTS.md`.

## Proposed behavior (draft spec)

### Config file

`.powbox.local.yml` at the workspace root, gitignored by the user (see OQ-8),
sharing the `.powbox.yml` schema so any setting can live in either file:

```yaml
# .powbox.local.yml — user-specific, never committed
ctx:
  # Short form: <path>[:ro|:rw] — name defaults to the basename, mode to ro.
  - C:\Code\OtherRepo:rw
  - C:\Users\alice\Documents\Specs
  # Long form: explicit object; name and mode are optional. Sidesteps the
  # Windows drive-letter-vs-suffix ambiguity and resolves basename clashes.
  - path: C:\Work\OtherRepo
    name: OtherRepoWork
    mode: rw
```

```yaml
# .powbox.yml — committed (existing file, existing section)
shadow:
  - .worktrees
  - .claude/worktrees
  - .git/worktrees
```

Host-OS path flavor applies naturally (Windows paths on Windows hosts, POSIX
paths elsewhere); a config written on one OS is not expected to be portable.

### Mount derivation

For each `ctx` entry, in listed order:

1. Normalize to `(path, name, mode)`. Short form: split the optional trailing
   `:ro`/`:rw` mode suffix (default `ro`) — Windows drive letters (`C:\...`)
   must not be misread as a mode separator; only a trailing `:ro`/`:rw`
   counts. Long form: read `path:` (required), `name:` and `mode:` (optional).
   Warn + skip an entry with an unknown `mode:` value or missing `path:`.
2. Resolve and validate the host path; warn (**settled** — not abort) if it
   does not exist or is not a directory, and skip the entry.
3. Target name = the `name:` alias if given, else the folder's basename.
   Validate it is a single, safe path segment (non-empty, no `/` or `\`, not
   `.`/`..`); warn + skip otherwise. Mount `-v <host>:/ctx/<name>:<mode>`.
4. Duplicate target names after alias resolution: warn + skip the later
   entry, with the warning suggesting a `name:` alias as the fix (final
   confirmation: OQ-4).

The result flattens any odd combination of host folders into one predictable,
easy-to-reference list of directories under `/ctx`. Mixing rw/ro is entirely
the user's responsibility.

### Precedence

- `.powbox.local.yml` wins over `.powbox.yml`. **Settled merge semantics:**
  top-level section clobber — sections combine across files, but a section
  present in both is replaced wholesale by the local one (arrays never
  concatenate, so a local file can also *remove* committed entries, e.g.
  `ctx: []`).
- An explicit CLI `--ctx <path>` wins over **all** configured context and
  keeps today's exact behavior (single folder, flattened onto `/ctx`,
  read-only) for one-off divergence (see OQ-3).
- `--resume` keeps its current semantics: resume exactly as created; if the
  configured context differs, print the existing warning-and-ignore notice.
- Container-reuse detection: if the *set* of desired `/ctx*` mounts (sources
  **and** modes **and** target names) differs from what the stopped container
  was created with, recreate; if the container is *running*, fail with the
  existing "stop the container first" guidance. Omitted config + omitted
  `--ctx` keeps today's "keep whatever is already mounted" behavior.

## Target files or areas

- `scripts/launch-agent.sh` — config discovery, `ctx` parsing (POSIX-safe),
  mount-set derivation, warnings, generalized mount-diff detection, mount args.
- `scripts/launch-agent.ps1` — the same, PowerShell-native.
- `README.md`, `docs/architecture.md` — feature docs, section retitle, config
  examples, precedence table.
- (`docker/shared/detect-shadows.sh` is **not** touched here — that is
  task 014a.)

## Implementation notes

- **Parity is mandatory:** every behavior (parsing, warnings, dedup, diff
  detection) must be implemented equivalently in both the `.sh` and `.ps1`
  launchers, matching each script's existing style.
- The mount-diff comparison should reuse the existing normalization helpers
  (`normalize_ctx_path`, `ConvertFrom-DockerDesktopPath`) per mount.
- **Settled (OQ-7):** hand-rolled, deliberately dumb, schema-constrained
  mini-parser in both scripts — no host dependency (`yq`, modules) and no
  container round-trip. The exact shape it must handle: top-level `key:`
  lines; under `ctx:`, list items that are either `- <string>` or an object
  item (`- path: <v>` followed by indented `name:`/`mode:` lines). One level,
  no recursion. Reject/warn on anything it cannot understand rather than
  guessing.
- Comments (`#`), blank lines, and quoted values should parse; anchors,
  nested maps beyond the long-form entry keys, multi-doc YAML, etc. are out
  of scope for the mini-parser.
- Empty `ctx:` list or absent file ⇒ behave exactly as today.
- Beware Windows edge cases: drive-root entries (`C:\` has no basename),
  trailing slashes/backslashes, UNC paths (`\\server\share`) — define and
  document behavior (reasonable: warn-and-skip anything without a usable
  basename).
- The container does **not** need to know about this feature; `/ctx` simply
  contains subdirectories instead of (or in addition to) flattened content.

## Resolved decisions

- **OQ-2 — Merge semantics: RESOLVED (a).** Top-level section clobber:
  sections combine across the two files; a section present in both is
  replaced wholesale by the local one. Arrays never concatenate (so a local
  file can remove committed entries).
- **OQ-5 — Non-existent configured path: RESOLVED (a).** Config entries warn
  + skip so a stale local line never bricks a launch; the explicit CLI
  `--ctx` argument keeps today's hard error.
- **OQ-6 — `shadow:` in the local file: RESOLVED → task 014a.** Written as
  `tasks/014a-shadow-overrides-in-local-config.md`; container-side, executes
  after this task. 014 stays host-side-only.
- **OQ-7 — Host-side YAML parsing: RESOLVED (a).** Hand-rolled
  schema-constrained mini-parser in both launchers. Alternatives rejected:
  requiring `yq`/`powershell-yaml` on the host adds prerequisites powbox
  deliberately avoids; delegating parsing to a throw-away container was
  considered and rejected as far too heavy for the job — it also breaks
  bootstrap ordering (the launcher needs the config *before* the image is
  guaranteed to exist locally) and adds a `docker run` to every launch.

## Open questions (resolve before implementation)

- **OQ-1 — File name.** `.powbox.local.yml` (shared schema with
  `.powbox.yml`, any setting committable *or* local — maintainer leaning, and
  the draft's working assumption) vs `.powbox.context.yml` (narrow,
  self-describing, no merge semantics needed). *Recommendation:
  `.powbox.local.yml` — the local-overrides pattern (`settings.local.json`,
  `docker-compose.override.yml`) is well understood and leaves room for future
  local-only settings without another filename.*
- **OQ-3 — CLI `--ctx` interplay.** (a) `--ctx <path>` fully overrides
  configured context and keeps today's flattened single-mount layout; (b)
  same override but the CLI path now also mounts at `/ctx/<basename>` for
  consistency; (c) CLI becomes repeatable with `:rw` suffix support and
  *merges* with config. *Recommendation: (a) — matches the maintainer's
  "one-off divergent behavior" intent, zero regression risk; (c) can be a
  later task if ever needed.*
- **OQ-4 — Entry format & duplicate names (reframed).** Maintainer proposal:
  allow explicit mount aliases via an exploded-object entry form instead of
  auto-suffixing. Draft spec adopts docker-compose-style dual syntax — short
  string form (`<path>[:ro|:rw]`) for the common case, long object form
  (`path:` + optional `name:` + optional `mode:`) when an alias is wanted or
  to avoid the Windows `:` ambiguity. Duplicates after alias resolution:
  warn + skip the later entry, warning suggests `name:`. **Confirm:** dual
  syntax as specced, and warn-+-skip-later as the duplicate rule (an explicit
  alias now being the sanctioned fix). *Recommendation: yes to both — the
  long form makes every collision user-resolvable, keeps one-liners terse,
  and stays within the mini-parser's one-level shape.*
- **OQ-8 — Gitignore responsibility.** (a) purely the user's job, documented
  (add `.powbox.local.yml` to the repo's `.gitignore`); (b) launcher warns at
  startup when the file exists, is in a git repo, and is not ignored; (c)
  extend the `enable-worktrees` skill (or a sibling) to add the ignore line.
  *Recommendation: (b) — a one-line, cheap `git check-ignore` guard prevents
  the obvious foot-gun (committing machine-specific absolute paths) without
  writing to the user's repo uninvited; document (a) regardless.*
- **OQ-9 — Path conveniences.** Should entries support `~`,
  `$HOME`/`%USERPROFILE%`, or relative paths (relative to the workspace
  root)? *Recommendation: expand `~` and environment variables using each
  shell's native mechanism, allow relative paths resolved against the
  workspace root; all cheap and each launcher's platform idiom.*
- **OQ-10 — Naming of the section.** `ctx:` (matches the flag and `/ctx`)
  vs `context:` (self-describing). *Recommendation: `ctx:` — mirrors the
  CLI flag and the in-container path; less to explain.*

## Acceptance criteria (draft — re-baseline after OQ resolution)

1. With a `.powbox.local.yml` declaring three folders — one short-form `:rw`,
   one short-form default, one long-form with a `name:` alias — a plain `cc`
   in the workspace creates a container where each mounts at its expected
   `/ctx/<name>` with the expected mode and the correct host content.
   Verified on both a bash host and a PowerShell host.
2. `--ctx <path>` on the CLI ignores the configured context entirely and
   behaves byte-for-byte like today (single flattened read-only `/ctx`).
3. Editing the local file's `ctx` list (add/remove/change mode) and re-running
   `cc` against a **stopped** container recreates it with the new mount set;
   against a **running** container it fails with the existing "stop first"
   message; `--resume` warns and resumes unchanged.
4. A missing host path warns and is skipped (launch proceeds); a duplicate
   target name warns, skips the later entry, and suggests a `name:` alias
   (pending OQ-4 confirmation) — never a silent wrong mount, never an abort.
5. No config file + no `--ctx` ⇒ behavior identical to today (including the
   "keep whatever is already mounted" reuse path).
6. The container image is unchanged; no new host dependencies are required.
7. README and architecture docs describe the file, the schema, precedence,
   and the rw warning ("mixing rw/ro is the user's responsibility").

## Validation

- `shellcheck` passes on `launch-agent.sh`; `Invoke-ScriptAnalyzer` (per
  `PSScriptAnalyzerSettings.psd1`) passes on `launch-agent.ps1`.
- Manual end-to-end on at least one host flavor: create a local config with
  two context folders (one rw), launch, verify mounts via
  `docker inspect --format '{{json .Mounts}}'` and by touching a file in the
  rw mount from inside the container; verify the ro mount rejects writes.
- Exercise the reuse/recreate matrix from acceptance criterion 3.
- Negative tests: bogus path entry, duplicate basenames, malformed YAML line
  — each warns as specified and never aborts with a stack trace.

## Review plan

Reviewer should check: (1) sh/ps1 behavioral parity line by line for parsing,
warnings, and diff detection; (2) that the mount-diff generalization cannot
regress the existing single-`--ctx` reuse flows; (3) Windows path handling
(drive letters vs `:rw` suffix, `ConvertFrom-DockerDesktopPath` usage); (4)
that the mini-parser fails safe (warn + ignore) on YAML it doesn't understand;
(5) docs accurately reflect resolved OQ decisions.
