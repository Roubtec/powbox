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
  `scripts/launch-agent.ps1` and `scripts/launch-agent.sh`. Because the two
  files share one schema, the launchers parse the `ctx:` section from **both**
  `.powbox.yml` (committed) and `.powbox.local.yml` (user-local) — not from the
  local file alone — with the local file taking precedence per the clobber rule
  below.
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
  - **Launch mechanism:** the container is created by `docker compose … run`
    (`launch-agent.sh:1160`, `launch-agent.ps1:1072`) with the `-f` overlay
    chain in `COMPOSE_ARGS` (`:495` / `:332`); `CTX_ARGS`/`$ctxArgs` are spread
    into that `run`. `docker compose run` accepts **only** `-v/--volume` (no
    `--mount`), which is why ctx mounts must go through a generated long-form
    `volumes:` overlay rather than mount flags (see "Mount form").
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
   and skip the entry if the resolved path does not exist or is not a
   directory.
3. Target name = the `name:` alias if given, else the folder's basename.
   Validate it is a single, safe path segment (non-empty, no `/` or `\`, not
   `.`/`..`); warn + skip otherwise. `:`, `,`, and any other character legal in
   a POSIX path segment are fine — the mount form below carries them. Emit the
   mount as a long-form `volumes:` entry into the generated ctx compose overlay
   (see "Mount form"): a `type: bind` mapping with `source: <host>`,
   `target: /ctx/<name>`, and `read_only: true` for `ro` / `false` for `rw`.
4. Duplicate target names after alias resolution: warn + skip the later
   entry, with the warning suggesting a `name:` alias as the fix.

**Mount form — generated compose overlay, long-form `volumes:`.** The launcher
never passes `-v`/`--mount` flags for ctx. The container is created with
`docker compose … run` (`scripts/launch-agent.sh:1160`,
`scripts/launch-agent.ps1:1072`), and **`docker compose run` supports only
`-v/--volume`, not `--mount`** (verified: `docker compose run --help` lists no
`--mount`). A colon-packed `-v <host>:/ctx/<name>:<mode>` is also unusable
because `:` is its field delimiter yet a valid POSIX path character, so it
breaks on a `:` in **either** the host source or the derived target. Instead,
derive the ctx mounts into a **generated compose overlay** — e.g. a temp
`compose.ctx.yml` — declaring each mount under the `agent` service in
docker-compose **long syntax**, and add that file to the `-f` chain of **only
the final agent-run** `docker compose … run` (`scripts/launch-agent.sh:1160`,
`scripts/launch-agent.ps1:1072`) — see "Scope the overlay to the final agent
run only" below — in the same long-syntax spirit as the existing
`compose.selfhosted.yml` / `compose.fuse.yml` / `compose.netdev.yml` overlays:

```yaml
services:
  agent:
    volumes:
      - type: bind
        source: <normalized-host-path>
        target: /ctx/<name>
        read_only: true   # ro; false for rw
```

Long syntax passes source and target as separate YAML scalars, so `:`, `,`, and
`|` all flow through untouched — there is no delimiter to collide with, and the
round-1 `--mount` comma limitation is gone (this is the compose-native form of
the long-syntax idea that `--mount` was reaching for). The implementer has **two
emission obligations, both mandatory**:

1. **Correctly-quoted YAML scalar** — quote or escape a path containing YAML
   metacharacters (a leading `!`/`&`/`*`/`#`, a `: ` sequence, quotes, or a
   Windows backslash) so the overlay always parses.
2. **Doubled `$` for Compose interpolation** — Compose runs variable
   interpolation on values *after* YAML parsing (`$FOO`/`${FOO}` are substituted;
   [Docker's interpolation docs](https://docs.docker.com/reference/compose-file/interpolation/)
   require `$$` for a literal dollar), so **every `$` in the `source` and
   `target` scalars must be emitted as `$$`**. This is independent of, and
   additional to, YAML quoting — a quoted `"$FOO"` is still interpolated — and it
   is what keeps the "environment variables stay literal" guarantee (OQ-9); skip
   it and a host path or derived name containing `$FOO`/`${FOO}` mounts the wrong
   directory or fails the overlay.

Compose merges `volumes:` across `-f` files by target, so the unique
`/ctx/<name>` targets append cleanly — the same merge-by-target the self-hosted
overlay already relies on when its `workspace:/workspace/${PROJECT_NAME}` entry
(`compose.selfhosted.yml`) overrides the host bind at that same target in
`compose.shared.yml`. The recreate-detection
label is still written by the same `docker compose run --label` invocation,
unchanged.

**Scope the overlay to the final agent run only — not the shared
`COMPOSE_ARGS`.** `COMPOSE_ARGS`/`$composeArgs`
(`scripts/launch-agent.sh:495`, `scripts/launch-agent.ps1:332`) is reused for
the root workspace-prep runs (`:961`/`:985` sh, `:861`/`:886` ps1) and the
detached image-store writer (`:1149` sh, `:953` ps1) as well as the final agent
run. Adding the ctx overlay to that shared list would mount every context
folder — including `rw` user folders — into those root/writer helpers before the
agent even starts. Append the overlay to a **final-run-specific** `-f` list (or
only after all helper runs have completed), never to the shared `COMPOSE_ARGS`,
so external context reaches only the agent container.

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
one-item set), serialize them into an **injective** canonical form, hash it,
and store the digest as a docker **label** (e.g. `powbox.ctx-hash`) at
container creation. On a later launch, compare the freshly derived hash
against the label: differ + stopped ⇒ recreate; differ + running ⇒ the
existing "stop the container first" error.

**Injective canonicalization — no delimiter collisions.** A naive
`name|path|mode` join is *not* injective: `|` and newlines are legal in POSIX
host paths (and in a basename-derived alias), so two different mount sets can
render to identical text and hash equal — silently reusing a container after a
real ctx change (an alias `a|b` + path `/x` vs alias `a` + path `b|/x` both
give `a|b|/x|ro`). Make it collision-free **without escaping or banning legal
path characters** by separating fields with **NUL (`\0`)** — the one byte that
cannot occur in a POSIX or Windows path, an alias, or the mode (`ro`/`rw`) — at
a fixed arity of three fields per record. Canonical order comes from sorting
the records by `name` (unique after duplicate-name dedup and a validated safe
segment, so a clean sort key) before serialization — but the sort **must be a
byte-wise ordinal comparison**, not the default line-oriented, locale/culture-
sensitive sort of either shell. A `name` may legally contain a newline (the very
reason the fields are NUL-, not newline-, delimited): a line-oriented `sort`
would split such a record and corrupt the boundary, and a locale/culture-aware
collation would order the same set differently on the two hosts — either one
breaks the byte-identical-stream requirement. Sort the **entries** (each keyed
by its single-field `name`, *before* the three fields are serialized together),
not the already-joined records. On Unix, emit one NUL-terminated `name` per
entry and order them with `LC_ALL=C sort -z` (`-z` makes NUL — not newline — the
record separator, so a `name` containing a newline stays one sort unit; the `C`
locale forces byte ordering), then materialize each entry's three fields in that
order; in PowerShell, sort the entry objects by `name` with an explicit ordinal
comparer (e.g. `[System.StringComparer]::Ordinal`), never the default
culture-aware `Sort-Object`. Serialize each record as
its three fields **each terminated by a NUL** — a trailing `\0` after every
field, including the last, so both launchers emit a byte-identical stream (use
a terminator, not a separator, to avoid an off-by-one divergence between the
two implementations). Concretely: normalize each path via the existing
`normalize_ctx_path` / `ConvertFrom-DockerDesktopPath` helpers, sort entries by
name with the ordinal comparison above, then on Unix feed
`printf '%s\0%s\0%s\0' "$name" "$path" "$mode"` per
entry to `sha256sum`; in PowerShell append `[char]0` after each of the three
fields per record and hash the UTF-8 bytes. (Percent-escaping the structural characters is an acceptable
alternative where NUL is awkward to thread through a pipeline, but NUL needs no
escaping because it is already illegal in every field.)

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
- **Legacy containers** (created before this feature, no label): a no-label
  container necessarily still carries the retired flattened-`/ctx` layout, so a
  plain source-only comparison is not enough — relaunched with the same `--ctx`
  path it would see an unchanged mount source and wrongly reuse the flattened
  mount, never migrating to `/ctx/<basename>` nor gaining the label. Instead,
  whenever the desired context set is determined at all — a CLI `--ctx`, or a
  `ctx:` key present in config (a non-empty set migrates to `/ctx/<basename>`;
  an explicit `ctx: []` drops the mount entirely) — treat the missing label as a
  mismatch and recreate once (stopped ⇒ recreate; running ⇒ the "stop the
  container first" error); the recreation writes the label. Only the genuine
  "don't care" case (no `--ctx`, no `ctx:` key) keeps the old behavior of
  leaving the existing flattened mount untouched.

## Target files or areas

- `scripts/launch-agent.sh` — config discovery, `ctx` parsing (POSIX-safe),
  mount-set derivation, warnings, generalized mount-diff detection, and the
  generated `compose.ctx.yml` overlay added to the `-f` chain of **only the
  final agent-run** `docker compose … run` (`:1160`) — **not** the shared
  `COMPOSE_ARGS` (`:495`), which is reused by the root workspace-prep runs
  (`:961`, `:985`) and the detached image-store writer (`:1149`); those helpers
  must not see user context mounts (especially `rw` folders).
- `scripts/launch-agent.ps1` — the same, PowerShell-native (final agent run
  `docker compose … run` at `:1072`; keep the overlay off the shared
  `$composeArgs` (`:332`) reused by the root prep at `:861`/`:886` and the writer
  at `:953`).
- `README.md`, `docs/architecture.md` — feature docs, section retitle, config
  examples, precedence table.
- In-container docs that describe a flattened `/ctx` and must move to the
  `/ctx/<name>` layout: `docker/shared/container-agent.md.tmpl`, root
  `AGENTS.md`, and both baked
  `docker/{claude,codex}/agent-container/skills/enable-worktrees/SKILL.md`
  (each tells agents the powbox README is "readable at `/ctx`").
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
  lines; a top-level `key: []` **inline empty list** — notably `ctx: []`, the
  load-bearing "remove all committed entries" override, which must be
  recognized as *key present, empty set* (distinct from an absent key) and
  **not** dismissed as malformed, or the empty-set drop of committed mounts
  becomes unreachable; under a block `ctx:`, list items that are either
  `- <string>` or an object item (`- path: <v>` followed by indented
  `name:`/`mode:` lines). One level, no recursion. Reject/warn on anything it
  cannot understand rather than guessing.
- Comments (`#`), blank lines, and quoted values should parse; anchors,
  nested maps beyond the long-form entry keys, multi-doc YAML, etc. are out
  of scope for the mini-parser.
- **No `ctx:` key in _either_ file** (both absent, or present with no `ctx:`
  key) ⇒ "don't care": behave exactly as today (keep whatever is already
  mounted; skip the recreate comparison). A `ctx:` key present in **either**
  file determines the set — in particular the committed `.powbox.yml`'s `ctx:`
  still applies when the local file omits the key (only a *present* local
  `ctx:` clobbers it), so a present-but-`ctx:`-less local file is **not** on its
  own a "don't care". An explicit `ctx: []` is also **not** the same — per
  Recreate detection above it is the empty set ("no context"): it hashes as
  empty and recreates a *stopped* container that still carries ctx mounts
  (running ⇒ the "stop first" error).
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
- **Mount form: generated compose overlay, long-form `volumes:`.** The launch
  path is `docker compose run`, which accepts only `-v/--volume` — **not**
  `--mount`. Ctx (and CLI `--ctx`) mounts are therefore emitted into a
  generated `compose.ctx.yml` overlay in docker-compose long syntax (`type:
  bind` + `source`/`target`/`read_only`), added to the `-f` chain of **only the
  final agent run** (never the shared `COMPOSE_ARGS`, which is reused by the
  root-prep and image-store-writer helper runs that must not see user context).
  Long syntax is colon- **and** comma-safe (separate YAML
  scalars), so no path character needs banning; the two implementer obligations
  are (a) correctly-quoted YAML and (b) doubling every `$` to `$$` so Compose
  does not interpolate `$FOO`/`${FOO}` in a path or name. Rejected: colon-packed
  `-v` (breaks on a `:` in either position — valid POSIX) and the round-1
  `--mount` flag form (unsupported by `docker compose run`, confirmed against
  `--help`). Rationale and verification in "Mount form" under Mount derivation.
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
   because a missing `powbox.ctx-hash` label counts as a mismatch whenever a
   desired context set is present (see "Recreate detection" → Legacy
   containers) — **not** via a source-only comparison, which would see the
   unchanged path and wrongly reuse the flattened, unlabeled mount.
3. Editing the local file's `ctx` list (add/remove an entry, change a mode or
   alias) changes the hash: a **stopped** container is recreated with the new
   mount set; a **running** one fails with the existing "stop first" message;
   `--resume` warns and resumes unchanged. A cosmetic-only edit (comment,
   reordering, whitespace) does **not** recreate; a warn-skipped missing path
   that now exists **does**.
4. A missing host path warns and is skipped (launch proceeds); a duplicate
   target name warns, skips the later entry, and suggests a `name:` alias —
   never a silent wrong mount, never an abort. A host path or derived name
   containing a `:`, `,`, or other POSIX-legal character mounts correctly under
   `/ctx/<name>` via the generated long-form `volumes:` overlay — `docker
   compose run` accepts it and the container is actually created (no
   `incorrect volume format` / unsupported-flag failure). A host path or name
   containing a literal `$` (`$FOO`, `${BAR}`) mounts that exact directory —
   Compose does **not** interpolate it — because the overlay emitter doubled each
   `$` to `$$`.
5. No config file + no `--ctx` ⇒ behavior identical to today (including the
   "keep whatever is already mounted" reuse path).
6. No new host dependencies are required. The **agent image does change** —
   this task edits baked in-container docs (`docker/shared/container-agent.md.tmpl`
   and both `docker/{claude,codex}/agent-container/skills/enable-worktrees/SKILL.md`,
   all copied into the image by `docker/agent/Dockerfile:44-47`) — so shipping the
   updated `/ctx/<name>` guidance requires an **agent-image rebuild** (`build.sh` /
   `build.ps1`), validated so the shipped image reflects the new layout. The host
   launch scripts (`launch-agent.*`) run on the host and are not baked.
7. README and architecture docs describe the file, the schema, precedence,
   and the rw warning ("mixing rw/ro is the user's responsibility"); **every**
   in-container doc describing a flattened `/ctx` is updated to the
   `/ctx/<name>` layout — not only `docker/shared/container-agent.md.tmpl` and
   root `AGENTS.md` but also both baked
   `docker/{claude,codex}/agent-container/skills/enable-worktrees/SKILL.md`
   (they tell agents the powbox README is "readable at `/ctx`"). A repo-wide
   `/ctx` grep finds nothing still pointing at the flattened path.
8. Entries with a leading `~` or a workspace-root-relative path resolve
   correctly; environment variables are left literal.
9. The gitignore guard warns exactly when `.powbox.local.yml` exists in a git
   repo and is not ignored, and stays silent otherwise (ignored, absent, not
   a repo, git not on PATH).

## Validation

- `shellcheck` passes on `launch-agent.sh`; `Invoke-ScriptAnalyzer` (per
  `PSScriptAnalyzerSettings.psd1`) passes on `launch-agent.ps1`.
- Manual end-to-end on at least one host flavor: create a local config with
  two context folders (one rw, and one whose directory name contains a `:` and a
  literal `$`), launch, verify mounts via
  `docker inspect --format '{{json .Mounts}}'` and by
  touching a file in the rw mount from inside the container; verify the ro
  mount rejects writes and the colon/`$`-named folder mounted at its literal path
  (the generated `compose.ctx.yml` overlay carried it, rather than failing at
  `docker compose run` or Compose interpolating the `$`). Inspect the generated
  overlay to confirm well-formed, quoted YAML with every `$` doubled to `$$`.
- Confirm the ctx overlay reaches **only** the final agent container: the root
  workspace-prep runs (`launch-agent.sh:961`/`:985`, `launch-agent.ps1:861`/`:886`)
  and the detached image-store writer (`launch-agent.sh:1149`,
  `launch-agent.ps1:953`) must **not** carry any `/ctx/*` mount
  (`docker inspect` those helper containers, or assert the overlay is absent
  from their compose arg list).
- Because the baked in-container docs change, rebuild the agent image
  (`build.sh` / `build.ps1`) and confirm the shipped image carries the
  `/ctx/<name>` layout guidance rather than the retired flattened text (e.g.
  grep the baked `container-agent.md.tmpl` / `enable-worktrees/SKILL.md` copies
  under `/home/node/.agent-container/` inside a container from the fresh image).
- Exercise the reuse/recreate matrix from acceptance criterion 3.
- Negative / edge tests: bogus path entry, duplicate basenames, malformed YAML
  line — each warns as specified and never aborts with a stack trace; an inline
  `ctx: []` parses as the empty set (not malformed) and drops committed mounts
  (stopped ⇒ recreate, running ⇒ "stop first"); a host path or alias containing
  `|` or a newline does **not** collide in the hash with a different mount set,
  and the sh and ps1 launchers produce the **byte-identical** hash for that set
  (injective NUL-separated canonicalization + byte-wise ordinal `LC_ALL=C sort
  -z` / `[StringComparer]::Ordinal` sort, so a newline-bearing name neither
  corrupts a record boundary nor diverges the two implementations).

## Review plan

Reviewer should check: (1) sh/ps1 behavioral parity line by line for parsing,
warnings, and hash derivation; (2) that the label-hash recreate detection —
including the legacy no-label fallback and the "don't care" (no `ctx:` key in
either file, no `--ctx`) path — cannot regress the existing reuse flows, **and**
that the hash canonicalization is injective (NUL-separated fields at fixed arity;
a `|` or newline in a path/alias cannot make two different sets hash equal)
**and deterministic across launchers** (a byte-wise ordinal `LC_ALL=C sort -z` /
`[StringComparer]::Ordinal` sort, so a newline in a name cannot corrupt a record
boundary and locale/culture differences cannot diverge the sh and ps1 hashes);
(3) Windows
path handling (drive letters vs `:rw` suffix, `ConvertFrom-DockerDesktopPath`
usage); (4) that the mini-parser fails safe (warn + ignore) on YAML it doesn't
understand, **including** recognizing the inline `ctx: []` empty-list override
as the empty set rather than as malformed/absent;
(5) docs accurately reflect resolved OQ decisions, **including** the full
`/ctx` doc sweep (both `enable-worktrees/SKILL.md` copies, not just the
tmpl/AGENTS.md) and the agent-image rebuild the baked-doc edits require;
(6) ctx mounts are emitted as a generated long-form `volumes:`
compose overlay added to the `-f` chain — **not** `-v`/`--mount` flags, which
`docker compose run` would reject or mis-split — with values emitted as
correctly-quoted YAML **and every `$` doubled to `$$`** (so a `:`/`,`/`$` in a
path or name mounts literally rather than failing or being interpolated),
merged by target so other mounts are not clobbered, and scoped to the **final
agent run only** — never the shared `COMPOSE_ARGS` reused by the root-prep and
image-store-writer helper runs.
