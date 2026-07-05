# 014 — Multi-folder context mounts via `.powbox.local.yml`

> **STATUS: FIRST DRAFT — open questions below must be resolved with the
> maintainer before implementation starts.** The spec sections are written
> against the current recommendations so the draft is concrete; any resolution
> that differs simply amends the affected section.
>
> Numbered 014 (even = inserted task) deliberately so it executes **before**
> the 015a–015e skills-management batch.

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
- A `ctx:` list in that file: host paths with an optional `:rw` / `:ro`
  suffix, `ro` default (docker-compose-mount-inspired, but no container-side
  path — the launcher derives it).
- Mount layout: each entry mounts at `/ctx/<basename>/` (e.g.
  `C:\Code\OtherRepo:rw` → `/ctx/OtherRepo` read-write;
  `/home/alice/code/DocumentRepo` → `/ctx/DocumentRepo` read-only).
- Warnings for duplicate target names and non-existent host paths (see OQ-4,
  OQ-5).
- Precedence rules: `.powbox.local.yml` over `.powbox.yml` (see OQ-2);
  explicit CLI `--ctx` over both (see OQ-3).
- Generalizing the existing container-reuse **mount-change detection** from
  "one `/ctx` mount source" to "the set of `/ctx` + `/ctx/*` mounts, including
  each mount's rw/ro mode".
- Documentation: README "Read-Only Context Volume" section (title no longer
  accurate), `docs/architecture.md` if it mentions `/ctx`.

**Out of scope:**

- Any container-side behavior change. The container cannot act on host paths;
  it just sees whatever is mounted under `/ctx`. (Whether `shadow:` also
  becomes overridable via the local file is OQ-6 — if resolved "yes", decide
  then whether it lands here or as a follow-up 014a.)
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
  - C:\Code\OtherRepo:rw
  - C:\Users\alice\Documents\Specs        # ro is the default
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

1. Split the optional trailing `:ro`/`:rw` mode suffix (default `ro`).
   Windows drive letters (`C:\...`) must not be misread as a mode separator —
   only a trailing `:ro`/`:rw` counts.
2. Resolve and validate the host path; warn (not abort — see OQ-5) if it does
   not exist or is not a directory, and skip the entry.
3. Target name = the folder's basename → mount `-v <host>:/ctx/<name>:<mode>`.
4. Duplicate target names: warn and de-conflict (see OQ-4).

The result flattens any odd combination of host folders into one predictable,
easy-to-reference list of directories under `/ctx`. Mixing rw/ro is entirely
the user's responsibility.

### Precedence

- `.powbox.local.yml` wins over `.powbox.yml` (merge semantics: OQ-2).
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
- (Only if OQ-6 says so) `docker/shared/detect-shadows.sh` — read
  `.powbox.local.yml` in addition to `.powbox.yml`.

## Implementation notes

- **Parity is mandatory:** every behavior (parsing, warnings, dedup, diff
  detection) must be implemented equivalently in both the `.sh` and `.ps1`
  launchers, matching each script's existing style.
- The mount-diff comparison should reuse the existing normalization helpers
  (`normalize_ctx_path`, `ConvertFrom-DockerDesktopPath`) per mount.
- Keep the config parser deliberately dumb and schema-constrained (see OQ-7):
  a top-level `ctx:` key followed by `- <value>` list items is all this task
  needs. Reject/warn on anything it cannot understand rather than guessing.
- Comments (`#`), blank lines, and quoted values should parse; anchors,
  nested maps, multi-doc YAML, etc. are out of scope for the mini-parser.
- Empty `ctx:` list or absent file ⇒ behave exactly as today.
- Beware Windows edge cases: drive-root entries (`C:\` has no basename),
  trailing slashes/backslashes, UNC paths (`\\server\share`) — define and
  document behavior (reasonable: warn-and-skip anything without a usable
  basename).
- The container does **not** need to know about this feature; `/ctx` simply
  contains subdirectories instead of (or in addition to) flattened content.

## Open questions (resolve before implementation)

- **OQ-1 — File name.** `.powbox.local.yml` (shared schema with
  `.powbox.yml`, any setting committable *or* local — maintainer leaning, and
  the draft's working assumption) vs `.powbox.context.yml` (narrow,
  self-describing, no merge semantics needed). *Recommendation:
  `.powbox.local.yml` — the local-overrides pattern (`settings.local.json`,
  `docker-compose.override.yml`) is well understood and leaves room for future
  local-only settings without another filename.*
- **OQ-2 — Merge semantics.** When both files define sections: (a) top-level
  sections combine, and a section present in both is **clobbered whole** by
  the local file (arrays don't merge); (b) full deep merge with array
  concatenation; (c) local file completely replaces the committed one when
  present. *Recommendation: (a) — predictable, trivial to implement
  identically in sh and PowerShell, and array-concat (b) makes it impossible
  for a local file to *remove* a committed entry.*
- **OQ-3 — CLI `--ctx` interplay.** (a) `--ctx <path>` fully overrides
  configured context and keeps today's flattened single-mount layout; (b)
  same override but the CLI path now also mounts at `/ctx/<basename>` for
  consistency; (c) CLI becomes repeatable with `:rw` suffix support and
  *merges* with config. *Recommendation: (a) — matches the maintainer's
  "one-off divergent behavior" intent, zero regression risk; (c) can be a
  later task if ever needed.*
- **OQ-4 — Duplicate target names.** Two entries with basename `OtherRepo`:
  (a) warn + auto-suffix (`/ctx/OtherRepo`, `/ctx/OtherRepo2`); (b) warn +
  mount only the first, skip the rest; (c) hard error. *Recommendation: (b) —
  deterministic and simple; auto-suffix (a) silently changes a path the user
  may have referenced in a prompt, and the "2" assignment depends on list
  order.*
- **OQ-5 — Non-existent configured path.** (a) warn + skip that entry,
  launch continues; (b) hard error like today's `--ctx`. *Recommendation:
  (a) for config-driven entries (a stale line in a local file shouldn't brick
  every launch), keeping (b) for the explicit CLI argument (you asked for it
  right now, so failing loudly is correct).*
- **OQ-6 — Is `shadow:` honored in `.powbox.local.yml`?** The shared-schema
  idea implies yes; the container *can* read the local file (it sits in the
  workspace bind mount), so it is feasible — `detect-shadows.sh` would read
  both files and apply OQ-2's merge. Decide: in-scope here, follow-up 014a,
  or explicitly ctx-only-for-now with a documented note. *Recommendation:
  follow-up 014a — keeps 014 host-side-only and independently shippable.*
- **OQ-7 — Host-side YAML parsing strategy.** Hosts are not guaranteed to
  have `yq`, and PowerShell has no built-in YAML cmdlet. (a) hand-rolled
  mini-parser for the constrained schema (top-level keys + string lists) in
  both scripts; (b) require/vendor a real parser (`yq` on PATH,
  `powershell-yaml` module); (c) make the file JSON instead. *Recommendation:
  (a) — the schema is deliberately tiny, and adding host prerequisites
  contradicts powbox's "everything baked in the container" philosophy; the
  host launcher must stay dependency-free.*
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

1. With a `.powbox.local.yml` declaring two folders (one `:rw`, one default),
   a plain `cc` in the workspace creates a container where `/ctx/<nameA>` is
   writable, `/ctx/<nameB>` is read-only, and both show the correct host
   content. Verified on both a bash host and a PowerShell host.
2. `--ctx <path>` on the CLI ignores the configured context entirely and
   behaves byte-for-byte like today (single flattened read-only `/ctx`).
3. Editing the local file's `ctx` list (add/remove/change mode) and re-running
   `cc` against a **stopped** container recreates it with the new mount set;
   against a **running** container it fails with the existing "stop first"
   message; `--resume` warns and resumes unchanged.
4. Duplicate basenames and missing host paths produce clear warnings and the
   resolved fallback behavior (per OQ-4/OQ-5), never a silent wrong mount.
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
