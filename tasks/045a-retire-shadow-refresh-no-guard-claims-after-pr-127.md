# Task 045a — Retire the "`shadow-refresh.sh` has no self-hosted guard" claims once PR #127 merges

## Why this task exists

Task 045 (PR #126) made the container-facing docs describe the code as it actually is.
Three of the statements it wrote or kept are true **only** as long as `docker/shared/shadow-refresh.sh` carries no launch-mode guard — which is the state of `main` and of the `task/045-container-docs-truthfulness` branch today (`grep -n 'SELF_HOSTED\|IMAGE_STORE_ROLE' docker/shared/shadow-refresh.sh` matches nothing).

PR #127 (`fix/shadow-refresh-self-hosted-guard`, open against `main`) adds exactly those guards.
Verified against `origin/fix/shadow-refresh-self-hosted-guard`: `shadow-refresh.sh` gains an early `POWBOX_SELF_HOSTED=1` skip (line 23) and a `POWBOX_IMAGE_STORE_ROLE=writer` skip (line 31), plus `scripts/test-shadow-refresh-guard.sh` covering both.
The moment that merges, "the script itself has no self-hosted guard … so it would succeed and tmpfs-mask real workspace content" flips from an accurate warning into a false statement, and the reader is told to fear an outcome the code now prevents.

PR #127 updates `docs/entrypoint-and-runtime.md` — it appends a sentence to the shadow-mounts bullet stating that the hand-run carries the same two skips — and it also edits `README.md` and `docs/architecture.md`, but only in unrelated paragraphs (the worktree-contract paragraph around README line 171, and the pnpm-store gating paragraph in the architecture chapter's "Volumes and Stores").
What it does **not** do is fix the stale `shadow-refresh.sh` sentence at `README.md` line 496, and it does not touch `docker/shared/container-agent.md.tmpl` at all — verified against `origin/fix/shadow-refresh-self-hosted-guard`, whose complete file list is `README.md`, `docker/shared/shadow-refresh.sh`, `docs/architecture.md`, `docs/entrypoint-and-runtime.md`, `scripts/test-shadow-refresh-guard.sh`, and two unrelated new task files.
Those two sentences — README's and the template's — are the ones that go stale, and the template is the file every container's instruction copy is generated from, so a stale sentence there reaches every agent session, not just a reader of the repo.

This is a docs-only follow-up: it changes no behavior and must not be started before PR #127 merges, because doing it earlier would make the docs describe a guard that does not exist yet.

## Scope

Included — once PR #127 is merged to `main`, re-verify the guards are present in `docker/shared/shadow-refresh.sh` on `main`, then update:

1. **`README.md`** — the "Mid-Session Packages" paragraph, currently the last sentence of the block that begins "In dir-mounted mode you can still run `shadow-refresh.sh` by hand at any time" (around line 496 as of PR #126).
   Current wording: "*but never under `--isolated`: the script itself has no self-hosted guard, and the container holds `CAP_SYS_ADMIN` in both modes, so it would succeed and tmpfs-mask real workspace content.*"
   Replace with a statement that the script now **skips itself** under `POWBOX_SELF_HOSTED=1` and `POWBOX_IMAGE_STORE_ROLE=writer`, mirroring the entrypoint. Keep the `CAP_SYS_ADMIN` fact — it is what makes the guard load-bearing rather than decorative (nothing downstream re-checks: `shadow-mounts.sh` validates only "under `/workspace/` and not depth-1", never emptiness) — but reframe it as the *reason for* the guard, not as a hazard the reader must avoid by hand.
2. **`docker/shared/container-agent.md.tmpl`** — line 87 as of PR #126, the `--isolated` paragraph, currently ending: "*never run `shadow-refresh.sh` there (it has no self-hosted guard and would mask real content)*".
   Replace with the post-merge truth: running it there is a no-op because the script skips itself under `POWBOX_SELF_HOSTED`. Keep it short; this file is loaded into every session.
   Note this is a **template** — check whether anything else in the repo (or the seeding path) reproduces the sentence before editing only the one copy.
3. **Chapter docs** — re-read `docs/entrypoint-and-runtime.md` after the merge. PR #127 adds its own bullet immediately after the `shadow-mounts.sh` bullet (the one beginning "Workspace shadow mounts run after git setup"), so the chapter may already be correct; the job here is to confirm it and to reconcile it with the neighbouring pnpm-wrapper bullet.
   That pnpm bullet (line 27 as of PR #126) says the wrapper's self-hosted no-op mirrors "the entrypoint's own self-hosted skip of the shadow step — the guard lives in `entrypoint-core.sh` around the `shadow-mounts.sh` call, not inside `shadow-mounts.sh` (or `shadow-refresh.sh`), neither of which carries one".
   The parenthetical "(or `shadow-refresh.sh`), neither of which carries one" becomes **false** after PR #127 and must be narrowed back to `shadow-mounts.sh` alone, which keeps having no guard of its own (`entrypoint-core.sh` around line 345 is where its skip lives, and the comment above that call says so deliberately).
   The same wording is mirrored in `docker/shared/pnpm-shadow-wrapper.sh`'s `refresh_shadows` comment ("`shadow-mounts.sh` is skipped there entirely; mirror that here") — that one stays accurate, but re-read it so the doc and the code comment do not drift apart.

Out of scope:

- Any change to `shadow-refresh.sh`, `shadow-mounts.sh`, `entrypoint-core.sh`, or `pnpm-shadow-wrapper.sh` behavior — PR #127 owns the guards and their tests.
- Re-litigating PR #127's design (the choice of the two skip conditions, or where they live).
- A broader sweep of the shadow documentation beyond the sentences named above.

## Context and references

- PR #126 — `task/045-container-docs-truthfulness`, the docs-truthfulness pass that wrote/kept the three claims.
- PR #127 — https://github.com/Roubtec/powbox/pull/127, branch `fix/shadow-refresh-self-hosted-guard`; adds the two skips to `docker/shared/shadow-refresh.sh` and `scripts/test-shadow-refresh-guard.sh`.
  Read the merged `main` rather than trusting this description: `git show origin/main:docker/shared/shadow-refresh.sh`.
- `docker/shared/entrypoint-core.sh` — the self-hosted / image-store-writer guard around the `shadow-mounts.sh` loop (about line 345), and the comment at about line 221 explaining that this family of guards deliberately lives in the caller.
- `tasks/AGENTS.md` — numbering convention; this file is the `a` follow-up to task 045.

## Target files or areas

- `README.md` (the "Mid-Session Packages" `shadow-refresh.sh` sentence)
- `docker/shared/container-agent.md.tmpl` (the `--isolated` paragraph)
- `docs/entrypoint-and-runtime.md` (the pnpm-wrapper bullet's parenthetical; confirm PR #127's own bullet)

## Implementation notes

- **Gate on the merge.** If PR #127 is closed without merging, close this task instead of implementing it — the current wording is then still correct.
- Line numbers here are as of PR #126 and will drift; anchor on the quoted sentences, not the numbers.
- Docs-only, so the in-container gates suffice: no image rebuild or smoke run is needed. `docker/shared/container-agent.md.tmpl` is image-baked, though, so the corrected text only reaches live containers after the next `./build.sh all` on the host — say so in the PR rather than implying the fix is live on merge.
- One line per paragraph, LF endings, per `AGENTS.md`.

## Acceptance criteria

- No file in the repo claims `shadow-refresh.sh` lacks a self-hosted guard, or that running it under `--isolated` would mask real content, once those guards are on `main`.
- `grep -rn "no self-hosted guard\|would mask real content\|neither of which carries one" README.md docker/shared docs` returns nothing — the first two alternatives catch the `README.md` and `container-agent.md.tmpl` sentences, the third catches the `docs/entrypoint-and-runtime.md` parenthetical named in scope item 3; all three match today, so the grep is a live canary rather than a vacuous one.
- The statement that `shadow-mounts.sh` itself carries no guard (its skip living in `entrypoint-core.sh`) is preserved — it stays true, and it is what the pnpm wrapper's no-op mirrors.
