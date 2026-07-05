# 014 — Multi-folder context mounts via `.powbox.local.yml`

> **STATUS: RESOLVED — ready for implementation.** All open questions are
> settled with the maintainer (see "Resolved decisions" for the ledger).
>
> Numbered 014 (even = inserted task) deliberately so it executes **before**
> the 015a–015e skills-management batch. Follow-ups, both written: `014a`
> (shadow overrides in the local file, container-side) and `014b` (CLI/config
> feature parity for `--ctx`) execute after this task.

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

- A new repo-root config file, **`.powbox.local.yml`** (final), read by the
  **host-side launch scripts**, both flavors:
  `scripts/launch-agent.ps1` and `scripts/launch-agent.sh`.
- A `ctx:` list in that file (section name final), docker-compose-inspired
  dual syntax:
  **short form** — a host path string with optional `:rw` / `:ro` suffix,
  `ro` default; **long form** — an object with `path:` plus optional `name:`
  (mount alias) and `mode:` keys. No container-side path is ever specified —
  the launcher derives it.
- Mount layout: each entry mounts at `/ctx/<name>/`, where `<name>` is the
  explicit `name:` alias or defaults to the path's basename (e.g.
  `C:\Code\OtherRepo:rw` → `/ctx/OtherRepo` read-write;
  `/home/alice/code/DocumentRepo` → `/ctx/DocumentRepo` read-only).
- Warnings for duplicate target names (warn + skip the later entry, suggest a
  `name:` alias) and non-existent host paths (warn + skip for config entries;
  the CLI argument keeps its hard error).
- Precedence rules: `.powbox.local.yml` over `.powbox.yml` (top-level section
  clobber); explicit CLI `--ctx` over both.
- **Uniform mount layout, CLI included:** the single CLI `--ctx <path>` now
  also mounts at `/ctx/<basename>` (read-only; hard error on a missing path
  or unusable basename) — the legacy flattened-onto-`/ctx` layout is retired.
- **Recreate detection via config hash:** replace the single-`/ctx`
  mount-source comparison with a hash of the canonical derived mount set,
  stored as a docker label (see "Recreate detection" under Precedence).
- A startup **gitignore guard**: warn when `.powbox.local.yml` exists in a
  git repo and is not ignored (`git check-ignore -q`); never edit the
  user's `.gitignore`.
- Documentation: README "Read-Only Context Volume" section (title no longer
  accurate), `docs/architecture.md` if it mentions `/ctx`.

**Out of scope:**

- Any container-side behavior change. The container cannot act on host paths;
  it just sees whatever is mounted under `/ctx`. (`shadow:` overrides via the
  local file are **task 014a** — already written; execute after this task.)
- Full CLI/config feature parity — repeatable `--ctx`, per-occurrence modes
  and aliases — is **task 014b** (already written; executes after this task).

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

`.powbox.local.yml` at the workspace root, gitignored by the user (the
launcher warns when it isn't — see Implementation notes), sharing the
`.powbox.yml` schema so any setting can live in either file:

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
2. Expand a leading `~` to the user's home directory; resolve a relative
   path against the workspace root. Environment variables are **not**
   expanded — entries are otherwise literal. Then validate: warn (not abort)
   if the result does not exist or is not a directory, and skip the entry.
3. Target name = the `name:` alias if given, else the folder's basename.
   Validate it is a single, safe path segment (non-empty, no `/` or `\`, not
   `.`/`..`); warn + skip otherwise. Mount `-v <host>:/ctx/<name>:<mode>`.
4. Duplicate target names after alias resolution: warn + skip the later
   entry, with the warning suggesting a `name:` alias as the fix.

The result flattens any odd combination of host folders into one predictable,
easy-to-reference list of directories under `/ctx`. Mixing rw/ro is entirely
the user's responsibility.

### Precedence

- `.powbox.local.yml` wins over `.powbox.yml`. **Settled merge semantics:**
  top-level section clobber — sections combine across files, but a section
  present in both is replaced wholesale by the local one (arrays never
  concatenate, so a local file can also *remove* committed entries, e.g.
  `ctx: []`).
- An explicit CLI `--ctx <path>` wins over **all** configured context for
  one-off divergence. It mounts read-only at `/ctx/<basename>` — the same
  uniform layout as config entries; the legacy flattened-onto-`/ctx` layout
  is retired. (Full parity — repeatable, modes, aliases — is task 014b.)
- `--resume` keeps its current semantics: resume exactly as created; if the
  configured context differs, print the existing warning-and-ignore notice.

### Recreate detection (config-hash label)

After deriving the desired mounts (from CLI or config — the CLI is just a
one-item set), canonicalize them as sorted `name|normalized-path|mode` lines
(normalization via the existing `normalize_ctx_path` /
`ConvertFrom-DockerDesktopPath` helpers), hash the result, and store it as a
docker **label** (e.g. `powbox.ctx-hash`) at container creation. On a later
launch, compare the freshly derived hash against the label: differ + stopped
⇒ recreate; differ + running ⇒ the existing "stop the container first" error.

Hashing the **derived set** — not the raw section text — is deliberate:
cosmetic edits (comments, reordering, whitespace) never trigger recreation,
while a previously warn-skipped missing host path that now exists *does*
(the resolved set changed). Mode flips (`ro`→`rw`) are detected too — the
old `.Mounts`-source comparison could not see them.

- **"Don't care" is preserved:** no `--ctx` and no `ctx:` key anywhere ⇒
  skip the comparison entirely and keep whatever is mounted, exactly like
  today's omitted `--ctx`. An explicit `ctx: []` (key present, empty list)
  means "no context": it hashes as the empty set and recreates a stopped
  container that still has ctx mounts.
- **Legacy containers** (created before this feature, no label): fall back
  to the old single-`/ctx` mount-source comparison for that launch; any
  recreation from then on writes the label.

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
- The existing normalization helpers (`normalize_ctx_path`,
  `ConvertFrom-DockerDesktopPath`) move into the canonicalization step that
  feeds the hash. Hash with what each host has natively (`sha256sum` /
  `shasum` on Unix, `Get-FileHash` or the .NET crypto classes in PowerShell)
  — no new host dependencies.
- Gitignore guard: one `git check-ignore -q .powbox.local.yml` call, gated on
  the file existing, git being on PATH, and the workspace being a git repo;
  silent otherwise. Warn-only — never write to the user's `.gitignore`.
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

## Resolved decisions (complete ledger)

- **OQ-1 — File name: `.powbox.local.yml`.** Shared schema with
  `.powbox.yml`; the local-overrides pattern (`settings.local.json`,
  `docker-compose.override.yml`) leaves room for future local-only settings.
- **OQ-2 — Merge semantics: top-level section clobber.** Sections combine
  across the two files; a section present in both is replaced wholesale by
  the local one. Arrays never concatenate (so a local file can remove
  committed entries, e.g. `ctx: []`).
- **OQ-3 — CLI `--ctx` layout: uniform `/ctx/<basename>`.** The CLI argument
  also mounts under its basename; the flattened layout is retired so the
  project name is always visible in context paths and the recreate logic
  handles exactly one layout shape. Full CLI/config parity (repeatable
  `--ctx`, modes, aliases) is deferred to **task 014b**.
- **OQ-4 — Entry format: docker-compose-style dual syntax.** Short string
  form `<path>[:ro|:rw]`; long object form `path:` + optional `name:`/`mode:`
  for aliases and Windows-colon safety. Duplicate target names after alias
  resolution: warn + skip the later entry, warning suggests `name:` as the
  fix. Auto-suffixing rejected (order-dependent, silently changes paths).
- **OQ-5 — Non-existent configured path: warn + skip.** A stale local line
  never bricks a launch; the explicit CLI `--ctx` keeps today's hard error.
- **OQ-6 — `shadow:` in the local file: task 014a.** Written as
  `tasks/014a-shadow-overrides-in-local-config.md`; container-side, executes
  after this task. 014 stays host-side-only.
- **OQ-7 — Host-side YAML parsing: hand-rolled mini-parser.** In both
  launchers, schema-constrained (see Implementation notes). Rejected:
  requiring `yq`/`powershell-yaml` on the host (prerequisites powbox
  deliberately avoids) and parsing inside a throw-away container (far too
  heavy, breaks bootstrap ordering — the launcher needs the config *before*
  the image is guaranteed to exist locally — and adds a `docker run` to
  every launch).
- **Recreate detection: hash of the canonical derived mount set, stored as a
  docker label.** See "Recreate detection" under Precedence. Raw-text
  hashing rejected (cosmetic edits would recreate; a missing-then-created
  host path would go undetected); mount-set inspection rejected (fiddly
  N-mount cross-platform normalization, blind to `ro`/`rw`).
- **OQ-8 — Gitignore: docs + launcher warning.** README documents the
  requirement; the launcher warns via `git check-ignore -q` when the file
  exists in a git repo and is not ignored. Never edits `.gitignore`
  (automation rejected as too invasive).
- **OQ-9 — Path conveniences: `~` + workspace-root-relative.** Both trivial
  and eval-free in sh and PowerShell. Environment variables stay literal
  (bash would need a hand-rolled no-eval expansion loop; platform-divergent
  syntax for little gain in a machine-local file).
- **OQ-10 — Section name: `ctx:`.** Mirrors the CLI flag and the `/ctx`
  mount root.

## Acceptance criteria

1. With a `.powbox.local.yml` declaring three folders — one short-form `:rw`,
   one short-form default, one long-form with a `name:` alias — a plain `cc`
   in the workspace creates a container where each mounts at its expected
   `/ctx/<name>` with the expected mode and the correct host content.
   Verified on both a bash host and a PowerShell host.
2. `--ctx <path>` on the CLI ignores the configured context entirely and
   mounts read-only at `/ctx/<basename>` (uniform layout). Relaunching over a
   stopped legacy container (flattened `/ctx`, no label) recreates it once
   via the legacy-fallback comparison.
3. Editing the local file's `ctx` list (add/remove an entry, change a mode or
   alias) changes the hash: a **stopped** container is recreated with the new
   mount set; a **running** one fails with the existing "stop first" message;
   `--resume` warns and resumes unchanged. A cosmetic-only edit (comment,
   reordering, whitespace) does **not** recreate; a warn-skipped missing path
   that now exists **does**.
4. A missing host path warns and is skipped (launch proceeds); a duplicate
   target name warns, skips the later entry, and suggests a `name:` alias —
   never a silent wrong mount, never an abort.
5. No config file + no `--ctx` ⇒ behavior identical to today (including the
   "keep whatever is already mounted" reuse path).
6. The container image is unchanged; no new host dependencies are required.
7. README and architecture docs describe the file, the schema, precedence,
   and the rw warning ("mixing rw/ro is the user's responsibility");
   in-container docs describing a flattened `/ctx`
   (`docker/shared/container-agent.md.tmpl`, `AGENTS.md`) are updated to the
   `/ctx/<name>` layout.
8. Entries with a leading `~` or a workspace-root-relative path resolve
   correctly; environment variables are left literal.
9. The gitignore guard warns exactly when `.powbox.local.yml` exists in a git
   repo and is not ignored, and stays silent otherwise (ignored, absent, not
   a repo, git not on PATH).

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
warnings, and hash derivation; (2) that the label-hash recreate detection —
including the legacy no-label fallback and the "don't care" (no config, no
`--ctx`) path — cannot regress the existing reuse flows; (3) Windows path handling
(drive letters vs `:rw` suffix, `ConvertFrom-DockerDesktopPath` usage); (4)
that the mini-parser fails safe (warn + ignore) on YAML it doesn't understand;
(5) docs accurately reflect resolved OQ decisions.
