# Task 043 — Record upstream source in .powbox-seeded markers (source=<repo>#<path>)

## Why this task exists

Seeded skills and workflows carry a `.powbox-seeded` marker with `epoch=` and `commit=` lines (`docker/shared/seed-skills.sh`, `seed_marker_content`).
That answers "which image build put this here" but not "where does the canonical source live" — and the second question is the one an agent hits when it finds a defect in a baked artifact mid-run.
In a scribz session, an agent that found a real capability gap in `wf-address-tasks.js` spent several exploratory commands across four plugin-cache copies before concluding (from the marker's `commit=`) that the file was image-managed, and still could not tell that the fix belonged in `Roubtec/powbox` at `docker/claude/agent-container/workflows/wf-address-tasks.js` — the session patch died with the session, and the report had to describe the upstream location by inference.

One extra marker line turns that multi-command hunt into one `cat`.

## Scope

Included:

- Extend `seed_marker_content` (or the call sites, if the source path is only known there) so every marker also records the upstream location, e.g. `source=Roubtec/powbox#docker/claude/agent-container/skills/<name>` for powbox-owned assets, and the correct repo#path for assets staged from `Roubtec/agent-skills`.
- Ensure all marker producers agree: skill dirs (`<skill>/.powbox-seeded`), workflow sidecars (`.<workflow>.js.powbox-seeded`), and any codex-side equivalents written by `sync-codex-skills.sh` / `seed-claude-plugins.sh`.
- Ensure marker **consumers** (staleness/ownership checks in `seed-skills.sh`, `update-skills-incontainer.sh`, and the pruning logic described in `docs/skills-refresh-and-provenance.md`) tolerate the new line — parse specific keys, never assume a two-line file.
- Update `docs/skills-refresh-and-provenance.md` to document the new field and its purpose ("this is where you fix it").

Out of scope:

- Any change to seeding/pruning semantics.
- Mounting sources read-write into containers.

## Context and references

- `docker/shared/seed-skills.sh:26-43,194` — marker name, content builder, workflow sidecar naming.
- `docker/shared/update-skills-incontainer.sh`, `docker/shared/sync-codex-skills.sh`, `docker/shared/seed-claude-plugins.sh` — other producers/consumers to sweep.
- `docs/skills-refresh-and-provenance.md` — the provenance chapter to extend.
- The build stages agent-skills sources under `.agent-skills-src/` (`scripts/build-image.sh`), so the seed step knows at bake time which repo a file came from; carry that through to marker writing (a per-source-root constant is fine — no need to thread git metadata).

## Target files or areas

- `docker/shared/seed-skills.sh` (and sibling seed/sync scripts as needed)
- `docs/skills-refresh-and-provenance.md`
- Tests: `scripts/test-sync-codex-skills.sh` and any marker-shape assertions.

## Implementation notes

- Backward compatibility: containers running an older image write two-line markers; consumers of the new image may read old markers. Key-based parsing (grep `^commit=` etc.) on both sides keeps the transition safe — audit for `wc -l`/positional reads.
- Prefer `source=<owner>/<repo>#<repo-relative-path>` — greppable, unambiguous, and usable directly in a report or PR description.
- The path recorded is the **source-of-truth path in the owning repo**, not the container destination.

## Acceptance criteria

- Every marker written by a rebuilt image contains a correct `source=` line (spot-check one powbox-owned skill, one workflow sidecar, one agent-skills-owned asset).
- Existing staleness/refresh/prune behavior is unchanged (old markers still parse).
- The provenance doc explains the field.

## Validation

- In-container: `scripts/test-sync-codex-skills.sh` and shell lints pass.
- Host: rebuild + `scripts/smoke-test-image.sh`; verify markers in a fresh container.

## Review plan

Reviewer sweeps every reader of `.powbox-seeded` for positional/line-count assumptions and confirms the source path for agent-skills-staged assets names the agent-skills repo, not powbox.
