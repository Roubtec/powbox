# Task 023: Seed a higher Codex multi-agent concurrency default in the image

## Problem

Codex's out-of-the-box multi-agent concurrency is low: in the shipped build it caps at ~4 concurrent agents with one reserved for the root, i.e. ~3 usable subagents.
That throttles powbox's parallel workflows (the `address-tasks` / `address-reviews` fan-outs and any Codex-side delegation), which are the whole point of the worktree isolation machinery.
We want a higher concurrency ceiling to be a **powbox image default**, seeded no-clobber into `~/.codex/config.toml` so host/user overrides always win — the same contract the existing `entrypoint-codex-hook.sh` status-line/terminal-title seeding already honours.

## Findings (Codex 0.144.1, verified against the shipped binary)

The build ships **two** mutually exclusive multi-agent subsystems:

| | v1 — `[agents]` | v2 — `features.multi_agent_v2` |
|---|---|---|
| Config keys | `max_threads`, `max_depth` (scalars) | `max_concurrent_threads_per_session`, `*_wait_timeout_ms`, hint texts, token weights (table) |
| Feature flag (`codex features list`) | `multi_agent` = **stable / on** | `multi_agent_v2` = **under development / off** |
| Validated at config load | yes (`agents.max_threads must be at least 1`, proven by setting `0`) | yes (`…max_concurrent_threads_per_session must be at least 1`) |
| Default concurrency | small (~4, the observed "one reserved for root") | **≥8** (binary warns against "setting … below 8") |

Decisive constraints:

- **Mutual exclusion is a hard config-load error:** the binary contains
  `agents.max_threads cannot be set when features.multi_agent_v2 is enabled`.
  So a config may set the v1 `[agents]` block **or** enable v2 — never both, or Codex refuses to launch.
- **Enabling v2 is a single additive line:** `codex features enable multi_agent_v2` writes exactly
  ```toml
  [features]
  multi_agent_v2 = true
  ```
  which validates clean and preserves the rest of the config (verified by diffing against a copy of a real `config.toml`). v2 then rides its built-in defaults (≥8 threads) with no tuning keys required.
- **Forward-compat risk for the v1 seed:** if a future Codex flips `multi_agent_v2` on-by-default, any baked `[agents]` block becomes a hard startup error via the exclusion above. The v1 option is only safe while v2 stays opt-in.
- **v2 is still "under development":** enabling it bakes a pre-release feature; Codex prints an unstable-feature warning at start unless `suppress_unstable_features_warning = true` is also set.

Not yet pinned down (deliberately — `codex debug models` does not exercise the multi-agent tuning path, so all shapes returned exit 0): the exact TOML nesting for the v2 tuning keys (`max_concurrent_threads_per_session` et al.). The **enable flag is confirmed**; anyone choosing to also seed tuning values must confirm the nesting against a live session first, rather than trust `debug models`.

## Goal

Seed one of the two options below as a powbox image default via `docker/shared/entrypoint-codex-hook.sh`, no-clobber, so fresh Codex containers parallelize more aggressively while any pre-existing user/host config is left untouched.

## The choice (exclusive — pick exactly one)

### Option A — raise the v1 ceiling (`9` / `1`)

Seed, no-clobber:

```toml
[agents]
max_threads = 9
max_depth = 1
```

- `max_depth = 1`: root fans out to many subagents, but subagents do **not** recursively spawn their own — matches how the powbox skills work today and keeps token cost predictable. (`max_depth = 2` would enable recursive fan-out; out of scope unless explicitly wanted.)
- Needs a new **scalar-under-table** seed helper. The existing `ensure_table_array_setting` / `ensure_top_level_array_setting` only handle array values; add an `ensure_table_scalar_setting "$CONFIG_FILE" "agents" "max_threads" "9"` sibling that inserts `key = value` under `[agents]` only when absent.
- Pro: stable feature, no unstable-feature warning. Con: carries the forward-compat risk above (breaks if v2 ever becomes default) and stays on the older subsystem.

### Option B — enable v2 (recommended)

Seed, no-clobber:

```toml
[features]
multi_agent_v2 = true
```

- Reuse the official shape (`codex features enable multi_agent_v2` output). v2's default concurrency (≥8) already doubles v1's ceiling with no tuning, and it is the subsystem Codex is steering toward — aligning powbox with the direction of travel and side-stepping the exclusion trap.
- Decide whether to also seed `suppress_unstable_features_warning = true` (quiet startup vs. an honest reminder that v2 is pre-release). Recommendation: leave the warning **on** so the opt-in stays visible; revisit when v2 graduates.
- **Migration caveat to document:** a user/host `config.toml` that already carries a `[agents]` block (e.g. from Option A on an earlier image, or hand-added) will make Codex **refuse to launch** once v2 is enabled. Because the seed is no-clobber it will not remove that block — users must delete any `[agents]` settings themselves. Call this out in the release note / docs.
- Requires no new helper if seeded via the same `ensure_*` approach adapted for a bool, or a tiny `ensure_top_level_table_bool` equivalent; keep it no-clobber (skip if `[features] multi_agent_v2` is already present in either sense).

**Recommendation:** Option B. It gives more parallelism than the 9/1 v1 tuning, avoids the forward-compat landmine, and follows the feature Codex is converging on. The only cost is the pre-release status and the one-time `[agents]`-removal caveat for existing configs.

## Design requirements (whichever option)

1. **No-clobber, idempotent, runs every start** — mirror the existing `entrypoint-codex-hook.sh` seeding: only write when the key/table is absent; never overwrite a user/host value; a re-run on an already-seeded volume is a byte-for-byte no-op.
2. **Never author a config Codex will reject** — for Option B, guard so the seed is skipped if an `[agents]` block already exists (do not create the exclusion conflict); for Option A, guard against seeding when `features.multi_agent_v2` is present.
3. **Static gates clean in-container** — `shellcheck -x` and `shfmt -d` on the hook; add/extend the pure-shell seed-helper unit test if one exists for the `ensure_*` family.
4. **Validation surface** — this is an image change: it needs a host rebuild + the Codex smoke to verify end-to-end (per AGENTS.md, cannot build in-container). The helper logic itself is unit-testable in-container against a scratch `config.toml`.
5. **Docs** — note the new default in README (the Codex config-seeding paragraph) and, for Option B, document the `[agents]`-removal migration caveat prominently.

## Acceptance criteria

- A fresh Codex container (cold codex-config volume) starts with the chosen option present in `~/.codex/config.toml` and Codex launches without error.
- A volume whose `config.toml` already sets the opposing/overlapping key is left untouched and Codex still launches (no exclusion conflict authored).
- Re-running the hook produces no diff on an already-seeded config (stable mtime across two starts).
- `shellcheck -x` and `shfmt -d` clean.
- Docs updated per requirement 5.

## Notes / context

- A live one-off of Option B has already been applied to this container's persistent codex-config volume (`[features] multi_agent_v2 = true`) to unblock immediate parallelism; that is **not** the image default — this task is what makes it (or Option A) a baked default for all future containers.
- References: `docker/shared/entrypoint-codex-hook.sh` (the `ensure_table_array_setting` / `ensure_top_level_array_setting` no-clobber helpers to extend), README "Codex config" seeding paragraph, and `codex features enable multi_agent_v2` for the canonical Option-B shape.
