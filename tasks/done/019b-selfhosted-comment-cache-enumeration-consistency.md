# Make the Self-Hosted Volume-Content Comments Enumerate the Go Caches and ccache

## Why this task exists

Task `019a` added the opt-in ccache cache under `.worktrees/.ccache` and updated every documentation table that **enumerates** the `.worktrees` / self-hosted volume contents (`AGENTS.md` Key Paths, README volume descriptions, `docs/architecture.md` "Volumes and Stores", the container template) to list it beside the pnpm store and Go caches.

During the 019a review the peer flagged (Low) that three **code comments** describing the self-hosted (`--isolated`) `agent-ws-*` workspace volume still enumerate its persistent contents as "node_modules, .worktrees, and the pnpm store" — omitting both the Go caches **and** ccache.
These comments predate the Go caches (task `011`) and use "the pnpm store" as a representative shorthand; they were never brought in line when the Go caches landed, so they are a pre-existing half-updated enumeration rather than something 019a introduced.

The orchestrator **gated** this for the 019a PR because 019a's scope was explicitly "update the volume-content docs everywhere the Go caches are currently enumerated" (the `.gomodcache`-bearing tables) — and these comments do not enumerate the Go caches at all.
This task closes the consistency gap so the self-hosted comments name the same cache set as the updated docs.

## Scope

- Update the self-hosted `agent-ws-*` volume-content **comments** so their store/cache enumeration matches the documentation tables: list the Go caches and the ccache cache alongside the pnpm store (or switch to the generic "stores/caches" shorthand used elsewhere), rather than naming only the pnpm store.
- Keep the change to comments/wording only — no behavioral change to volume wiring, gates, or mounts.

Out of scope: the actual cache wiring (already correct as of tasks `011` and `019a`), and the documentation tables (already consistent).

## Context and references

- The dir-mounted `.worktrees` enumerations and the self-hosted volume tables were already made consistent in tasks `011` and `019a`; this task only reconciles the prose code comments with them.
- README line ~243 already uses the generic "stores/caches as subdirs" phrasing for the self-hosted volume — a good precedent to mirror.

## Target files or areas

- `scripts/launch-agent.sh` — the `WS_VOLUME="agent-ws-..."` block comment (~line 1167) describing what the one per-instance workspace volume holds ("the clone, node_modules, .worktrees, and the pnpm store all live inside it as ordinary subdirs").
- `scripts/launch-agent.ps1` — the parity comment on the `$workspaceVolume = "agent-ws-..."` block (~line 786).
- `compose.selfhosted.yml` — the header comment (~line 14) "The single workspace volume also holds node_modules, .worktrees, and the pnpm store as ordinary subdirs".

## Implementation notes

- Prefer whichever phrasing keeps the three comments consistent with each other and with the doc tables: either name "the pnpm store, Go caches, and ccache" or use the generic "stores/caches" shorthand. Do not name only the pnpm store.
- Grep for `agent-ws` and `.gomodcache` to confirm no other self-hosted content enumeration is left naming only the pnpm store.
- Keep `.sh`/`.ps1` wording aligned (comment parity), and preserve one-line-per-paragraph where the surrounding style uses it.

## Acceptance criteria

- The three self-hosted `agent-ws-*` volume-content comments enumerate the Go caches and ccache consistently with each other and with the documentation tables (or use the generic stores/caches shorthand).
- No behavioral change; only comments/wording differ.
- No other self-hosted content enumeration remains that names only the pnpm store.

## Validation

- In-container: `shellcheck` and `shfmt -d` on `scripts/launch-agent.sh` (comment-only, but confirm clean); `pwsh -Command "Invoke-ScriptAnalyzer -Settings ./PSScriptAnalyzerSettings.psd1 -Path scripts/launch-agent.ps1"`.
- No image build or smoke run needed (comment-only change).

## Review plan

Reviewer confirms the three comments now match the documentation's cache enumeration and each other, that the change is comment-only with no wiring/gate edits, and that a repo grep finds no remaining self-hosted enumeration naming only the pnpm store.
