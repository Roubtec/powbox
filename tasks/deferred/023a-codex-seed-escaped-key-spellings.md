# Task 023a — Codex config seeding is blind to escaped/encoded TOML key spellings

Follow-up to **Task 023** (seed `features.multi_agent_v2 = true`, PR #108). Parked in `tasks/deferred/` because the branch is defendable as-is (it builds, `scripts/test-codex-config-seed.sh` is 85/85 green, and it covers every realistic config shape), the triggering input essentially never occurs in a hand-written `config.toml`, and the proper fix is a costly design change — TOML-aware parsing — that touches the whole grep/awk seeding path, not a review-fix commit.

## The gap

Every helper in `docker/shared/entrypoint-codex-hook.sh` — the `config_v2_seed_blocked` guard (`grep -qE '(^|[^A-Za-z0-9_-])multi_agent_v2["'\'']?[[:space:]]*='`, line ~303) and the `config_table_setting_present` writer no-clobber check (`awk ... "^[[:space:]]*[\"']?" key "[\"']?..."`, line ~72 onward) — keys off the **literal ASCII text** of the key/table name. TOML, however, permits a *basic-string* (double-quoted) key to carry escape sequences, so `"multi_agent_v2"` (`2` = `2`) decodes to the real key `multi_agent_v2`.

Failure mode (false negative → **corruption**, not the guard's usual safe skip):

```toml
[features]
"multi_agent_v2" = false
```

- The guard greps for the literal substring `multi_agent_v2`; `multi_agent_v2` does not contain it, so the guard does **not** block.
- The writer's presence check likewise misses it, so `ensure_table_scalar_setting` inserts a second `multi_agent_v2 = true` under `[features]`.
- The config now defines `features.multi_agent_v2` twice (once escaped, once plain) → a TOML "duplicate key" error → **Codex refuses to load the config**.

The same blindness applies to every seeded name (`terminal_title`, `status_line`, `[tui]`, `[agents]`, `features`), so an escaped table/key spelling can equally evade the `[agents]` mutual-exclusion guard or the statusline/title no-clobber writers.

## Why deferral is safe

- **Unrealistic input.** Nobody hand-authors `"multi_agent_v2" = false` (or `\U000000XX`, or a literal-string vs basic-string mismatch) in a Codex config; the container grows its own `config.toml` from the image-baked ASCII defaults, which never use escapes.
- **Loud, self-inflicted failure.** If a user *did* write such a key and hit the duplicate, Codex prints a clear TOML load error naming the duplicate key; the user deletes one spelling.
- **No cheap grep fix.** Correctly recognizing an escaped key requires decoding TOML string escapes — i.e. a real TOML parser (or an embedded `tomllib`/`toml` shell-out), a materially larger dependency and design change than the literal-match heuristic the whole hook is built on. It is out of scope for the two Copilot review threads Task 023 addressed (substring/comment over-matching, PR #108 threads r3578205348 and r3578205382).

## Origin

Raised by the codex peer reviewer during the address-review pass on PR #108 (not a standing GitHub review thread). The guard's own comment block now names escaped/encoded key spellings as a known non-goal of the literal-match approach.

## Goal

Make the Codex config seeder recognize a key/table that is **semantically** already present regardless of its TOML spelling (bare, basic-string with `\uXXXX`/`\U…`/`\n`… escapes, literal-string), so it never authors a duplicate-key config.

## Suggested approach

- Prefer parsing over pattern-matching: shell out to a bundled TOML reader (Python `tomllib` is available in the image) to answer "is `features.multi_agent_v2` set?" and "does an `[agents]` block exist?" definitively, falling back to the current grep/awk heuristic only when no parser is reachable. Keep the no-clobber/skip-on-doubt philosophy.
- Alternatively, if a parser dependency is unwanted in the entrypoint hot path, normalize obvious escape forms (`\u00NN`) before matching — a partial mitigation that closes the most likely encodings without full parsing.
- Whichever path: extend `scripts/test-codex-config-seed.sh` with escaped-key fixtures (`"multi_agent_v2"`, an escaped `[agents]`/`features` spelling) asserting the guard blocks and the writer inserts no duplicate.

## Acceptance

- A `config.toml` whose `features.multi_agent_v2` (or `[agents]`, or a seeded statusline key) is written with a TOML escape sequence is recognized as already-present: the seed is skipped and no duplicate key is authored.
- The realistic ASCII fixtures continue to pass unchanged; the seed remains a byte-/mtime-stable no-op on an already-seeded config.
- Lint clean (`shellcheck`, `shfmt` advisory) and the test suite green.
