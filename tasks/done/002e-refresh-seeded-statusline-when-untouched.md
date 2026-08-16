# 002e — Refresh the seeded statusline on a newer image, but only when untouched

## Why this task exists

`docker/shared/entrypoint-claude-hook.sh:46-49` seeds the statusline **no-clobber**: it copies the baked script only when `$AGENT_CONFIG_DIR/statusline-command.sh` does not already exist, and its comment tells the reader to "delete the file to pick up the latest version on next container start".

Every other asset that hook seeds is gated on a **build epoch** instead. Lines 53-57 read `$AGENT_SEED_DIR/build-epoch` against `$AGENT_CONFIG_DIR/.instruction-epoch`, and when the image is newer they re-render the instruction file and re-merge the `statusLine` key into `settings.json`, stamping the new epoch at line 98. So the settings entry that *points at* the statusline refreshes on every rebuild while the script it points at never does.

The consequence is that a `claude-config` volume created once keeps its original statusline forever. That was tolerable while the file was pure presentation. It is not, now: PR #143 turned it into a script that resolves the authenticated account by probing `claude auth status` and caching the result, and shipped three rounds of correctness fixes to that logic (a malformed-probe name leak, an unbounded-staleness bug, a per-render subprocess storm). None of it reaches an existing container. Every future statusline fix has the same problem, and the failure is silent — nothing tells the user their copy is stale.

Straight epoch-gating is the wrong fix, because no-clobber is protecting something real. The seed is deliberately opinionated (tuned to the maintainer's taste), users are expected to edit it, and overwriting a customization on a routine `agent-update` would be a genuine data loss. The gate therefore has to distinguish "the user never touched this" from "the user made it theirs" — a question the current mechanism cannot ask, because nothing records what was originally seeded.

## Scope

**In scope:**

1. Record, at seed time, enough to answer "is the on-disk statusline still exactly what this image (or an earlier one) seeded?" — a content digest of the seeded file.
2. On a newer build epoch, refresh the statusline **only** when the on-disk copy still matches a digest powbox itself wrote. A file that differs, or that carries no marker at all, is left alone.
3. Cover the three transitions in the hermetic entrypoint tests: untouched → refreshed; customized → preserved; unmarked pre-existing file (every volume that exists today) → preserved.
4. Update the README sentence that currently tells users to delete the file by hand, and the entrypoint chapter's description of the seeding step.

**Out of scope:**

- Changing what the statusline displays. This is delivery machinery only.
- Migrating the other seeded assets. The instruction file is regenerated from a template on every epoch bump by design and has no user-customization story; do not fold it into this mechanism.
- A user-facing opt-out flag. Decide that only if the "untouched" test proves insufficient in practice — an extra environment variable to explain is a cost, and the digest check should make it unnecessary.
- Any change to `settings.json` merging.

## Design direction

Follow the marker convention the repo already has rather than inventing a second one. Task 043 (`tasks/done/043-powbox-seeded-markers-carry-source-provenance.md`) established `.powbox-seeded` markers carrying `epoch=`, `commit=` and `source=` lines for seeded skills and workflows, with `seed_marker_content` (`docker/shared/seed-skills.sh:93`) as the body builder and `seed_workflow_marker_path` (`:260`) producing exactly the `.<filename>.powbox-seeded` sidecar name proposed below and a documented rule that consumers parse specific keys and never assume a fixed line count. A statusline marker — e.g. `$AGENT_CONFIG_DIR/.statusline-command.sh.powbox-seeded` holding `epoch=`, `sha256=`, and `source=` — fits that shape and inherits its documentation in `docs/skills-refresh-and-provenance.md`.

The resulting logic in the hook:

- No statusline present → copy it and write the marker (today's behavior plus a marker).
- Statusline present, no marker → **leave it**. This is every volume in existence right now, and powbox cannot prove it was not customized. It adopts the new mechanism the first time the user deletes the file.
- Statusline present, marker present, image epoch not newer → leave it.
- Statusline present, marker present, image epoch newer, on-disk digest matches the marker's → copy the new file and rewrite the marker.
- Statusline present, marker present, image epoch newer, digest does **not** match → the user edited it. Leave it. Consider one line on stderr saying a newer version exists and how to take it, but keep it to a single non-fatal note; the entrypoint should not nag on every start.

Note the ordering constraint: the statusline seed currently runs *before* the epoch block that computes `IMAGE_EPOCH`/`VOLUME_EPOCH` (lines 53-57), so it will need the epoch values hoisted above it or recomputed. Do not move the `.instruction-epoch` stamp at line 98 — the instruction file's refresh must stay gated on its own comparison, and a statusline that is skipped for being customized must not prevent the instruction file from updating, nor vice versa.

`sha256sum` is available in the image. Prefer it over comparing against the previous image's baked copy, which is not present in a running container.

## Target files or areas

- `docker/shared/entrypoint-claude-hook.sh` (~lines 40-60, 98) — the seeding step, the epoch block, and their ordering.
- `docker/shared/seed-skills.sh` — `seed_marker_content` (~93-104) and `seed_workflow_marker_path` (~260-265), the marker body and sidecar-name builders to mirror. Note `entrypoint-claude-hook.sh` does **not** source this file today (only `update-skills-incontainer.sh` does), so reusing them means taking a new dependency on `/usr/local/bin/seed-skills.sh` — weigh that against writing the two lines inline.
- `scripts/test-claude-hook-skew.sh` — the existing hermetic suite for this hook, and the natural home for the three transition cases. Add to it rather than starting a new file.
- `docs/entrypoint-and-runtime.md` — the per-agent hook section describing what is seeded and when it refreshes.
- `docs/skills-refresh-and-provenance.md` — if the marker reuses the `.powbox-seeded` convention, document the statusline as a producer.
- `README.md` (~line 254) — currently ends the statusline paragraph with "reaches an existing container only after you delete `~/.claude/statusline-command.sh`, which is seeded no-clobber". That sentence becomes wrong for untouched files and needs to state the new rule.

## Acceptance criteria

- A container started on a volume whose statusline is byte-identical to what powbox seeded, from an image with a newer build epoch, ends up with the new statusline and an updated marker.
- A container started on a volume whose statusline was edited keeps the edited file, whatever the epoch. Verified by editing one byte.
- A container started on a volume with a statusline but **no** marker keeps that file. This is the upgrade path for every volume that exists today, so it must be explicit in the tests, not incidental.
- Deleting the statusline still restores the current baked copy, and now also writes a marker, so the next rebuild refreshes it automatically.
- The instruction file and `settings.json` refresh exactly as they do today; the statusline decision does not gate them and they do not gate it.
- The new cases run in the pure-shell suite (`./scripts/run-pure-shell-tests.sh`) with no image required.
- `shellcheck` (error severity) and `shfmt -d` pass on the changed hook.

## Validation

The hook is pure shell, so the three transitions are testable hermetically with a fake `AGENT_SEED_DIR` and `AGENT_CONFIG_DIR` under one `mktemp -d` — no image, no container. Add those to the pure-shell suite and run it.

Full confirmation needs the host: build the agent image, start a container to seed a volume, rebuild with a modified statusline, restart, and confirm the file updated; then edit the file, rebuild again, restart, and confirm it did not.

## Status

**Not started.** Queued deliberately rather than deferred: the condition is live right now — the statusline changes on PR #143 are already unreachable on every existing volume — but nothing is broken, since the current file keeps working and the manual `rm` escape hatch is documented. Sequenced after PR #143 merges so this builds on the final statusline rather than a moving one.
