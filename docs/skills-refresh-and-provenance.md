# Skills refresh: unified seeding, ownership markers, pruning, and image provenance

Status: **implemented** on branch `agent-update-skills` (this-branch scope below);
the three-anchor provenance display remains deferred to a stacked branch. Logic was
unit-tested out-of-container against a sandbox skill tree (seed/refresh/conflict/
adopt/orphan/prune) and both launchers were exercised with a `docker` stub; a real
image build + in-container refresh is still to be validated.
This document is the agreed plan and resume point; it captures every decision and
its rationale so the work can be resumed if the working session is lost.
Date: 2026-06-06 (design + implementation).

## TL;DR

The `agent-update-skills` branch already added a command to force-refresh the
image-baked skills onto the `claude-config` / `codex-config` volumes (commits
`6d0ee54`, `ac0cdba`). This follow-on work hardens and extends it:

1. **Unify the copy mechanism.** The identical per-skill "copy into temp, atomic
   `mv`" loop lives in **three** places today — `entrypoint-claude-hook.sh`,
   `entrypoint-codex-hook.sh`, and the updater worker. Extract it into one baked
   helper used by all three, with a `noclobber|refresh` mode flag.
2. **Mark powbox-owned skills.** Drop a per-skill `.powbox-seeded` marker (content
   `epoch=… commit=…`) when seeding, so the updater can tell its own copies from
   user-authored/forked skills.
3. **Resolve conflicts explicitly.** On refresh, an *unmarked* folder whose name
   collides with a baked skill is ambiguous (legacy seed vs. user fork) — never
   silently overwrite it; surface it and let the user adopt / skip / rename.
4. **Prune obsolete seeds.** A marked skill no longer baked into the image is a
   prune candidate (report by default, delete with `--prune`).
5. **Re-seed from `agent-update`.** After a successful rebuild, offer to re-seed
   (and prune) in the same flow.

A separate **stacked branch** adds full three-anchor image-commit provenance
(base / codex / claude) surfaced in `agent-update` and a `zsh` helper; this
branch only bakes the single agent build-commit that the marker needs.

---

## Background: what exists today

Seeding is **no-clobber**. At container start each agent's entrypoint hook copies
every image-baked skill onto its config volume **only when that skill folder is
absent** (`docker/shared/entrypoint-claude-hook.sh:74-96`,
`docker/shared/entrypoint-codex-hook.sh:208-230`). The copy is staged in a sibling
temp dir and swapped in with `mv` (atomic rename on the same volume) so a running
agent never sees a half-written skill.

Consequence: a rebuilt image with **updated** skill text does not replace the
stale copy already on the volume. The existing `commands/update-skills.{sh,ps1}`
(function `agent-update-skills`) closes that gap by running a throwaway
`powbox-agent` container with both config volumes mounted and force-copying each
baked skill over the volume copy (`commands/update-skills-incontainer.sh`).

### Path map (mirror points)

| Agent | Baked seed dir (`AGENT_SEED_DIR`) | Skills source | Skills dest on volume |
|---|---|---|---|
| claude | `/home/node/.agent-container/claude` | `…/claude/skills` | `/home/node/.claude/skills` |
| codex | `/home/node/.agent-container/codex` | `…/codex/skills` | `/home/node/.codex/agents/skills` |

(Codex's dest is under `agents/skills` because `~/.agents` is symlinked into the
codex-config volume — see `entrypoint-codex-hook.sh:155-160`.)

### Build pipeline (provenance seam)

`build.sh` → `scripts/build-image.{sh,ps1}` (computes provenance, passes env vars)
→ `docker buildx bake -f docker-bake.hcl` → bake variables → Dockerfile `ARG`s →
`LABEL`s / baked files. The existing `powbox.base.source.digest` label is computed
this way and is the precedent to follow for commit provenance.

Agent image layer order (`docker/agent/Dockerfile`): `FROM base` → **codex install
(low)** → **claude install (high)** → asset COPY + `RUN date +%s%N` epoch → entrypoint
COPY. The epoch `RUN` is non-deterministic, so the asset/epoch/entrypoint layers
rebuild on **every** agent build; codex's install layer is the only one that is
reused on a claude-only update.

---

## Decisions (locked)

### D0 — The `mv` is an atomic swap, not a move of the seed *(clarification only)*

In `update-skills-incontainer.sh` the real data copy is `cp -a` straight from the
baked seed into a temp dir created **under the destination** (same filesystem);
the `mv` only renames that fully-staged temp dir into place. The seed is never
moved (only read). `mv` is used instead of a direct `cp` over the live target to
avoid a concurrently-invoking agent observing a half-written skill. No change
required — this was a review question, and the pattern is correct.

### D1 — Unify the per-skill copy into one baked helper

Create `docker/shared/seed-skills.sh`, baked to `/usr/local/bin/seed-skills.sh`
(alongside the entrypoint hooks). It exposes one function:

```sh
# seed_skills <src_skills_dir> <dest_skills_dir> <noclobber|refresh>
```

- Both entrypoint hooks `source` it and call `noclobber`.
- The updater worker (runs **inside** the image, so the baked lib is on its path)
  sources the same file and calls `refresh`.

The copy logic (cp-to-temp + atomic mv + marker stamp, below) lives only here, so
the three sites can no longer drift. Tradeoff: changing the copy logic now needs an
image rebuild — but that is already true of the entrypoint hooks, and the updater
seeds *from* the image, so this is the correct coupling. The updater worker stays
bind-mounted as a thin wrapper (its agent→src/dest mapping table), so the part that
is actually iterated on still needs no rebuild.

### D2 — Per-skill ownership marker `.powbox-seeded`

`seed_skills` writes `<dest>/<skill>/.powbox-seeded` whenever it places/refreshes a
skill. Content (chosen: **epoch + commit**):

```
epoch=<image build-epoch>
commit=<powbox commit that built the agent image>
```

Discrimination rule — **the marker means "powbox owns this copy."**

- marker **present** → powbox placed it → safe to refresh, and a prune candidate
  if no longer baked.
- marker **absent** → user-authored or hand-forked → **never touched**.

To adopt a seeded skill as your own (fork-and-keep), delete its `.powbox-seeded`
(or rename the folder); powbox then leaves it alone permanently. The marker is a
hidden file inside the skill dir; agents read `SKILL.md` and ignore it. Placing it
*inside* the dir (vs. a central manifest) makes provenance self-describing and
travels with the folder — no separate list to keep consistent.

### D3 — Three-way classification + explicit conflict resolution (refresh)

The updater (refresh mode) classifies each **baked** skill against the volume:

| Volume state | Action |
|---|---|
| absent | seed + stamp marker |
| present + **marked** | refresh (overwrite) + re-stamp — documented force-refresh, powbox already owns it |
| present + **unmarked** | **CONFLICT** — never auto-touch; surface + resolve |

**Why conflicts must be explicit:** an unmarked name-collision is ambiguous — it
could be a legacy seed (ours, pre-marker) *or* a user fork / coincidental same-name
skill (theirs). Presence/absence can't tell them apart, so silently re-stamping +
overwriting would clobber a user's skill and mislabel it. (This corrects an earlier
hand-wave that claimed refresh would "just re-stamp every baked skill" — it must
not.)

The entrypoint stays **pure no-clobber**: it only stamps skills it *newly* seeds and
never overwrites, so the safety-critical startup path is behaviorally unchanged.
Conflicts are exclusively an `update-skills` concern.

**Conflict UX** (default = **skip**):
- Interactive (TTY), per conflict: **Adopt** (powbox takes over → overwrite with
  baked version + stamp) / **Skip** (keep your copy untouched & unmarked; powbox's
  version stays shadowed) / resolve manually by **rename**.
- Non-interactive: never adopt; report + instruct, with `--adopt-all` / `-AdoptAll`
  as the explicit "quiet, pre-approved" escape hatch.

Bonus: this makes `update-skills` the place where a *new* baked skill colliding with
an existing user skill becomes visible (the entrypoint would otherwise let the
user's win silently).

### D4 — Prune obsolete seeded skills

Orphan = marker **present** AND name **∉** current baked set. User-authored skills
(no marker) are structurally never orphans, so they are safe.

- Default: refresh + **report** orphans (e.g. `obsolete (seeded, now gone): X, Y`).
- `--prune` / `-Prune`: delete them.
- Interactive prompting lives in the **shell launchers** (`update-skills.{sh,ps1}`,
  and `agent-update`), not the containerized worker (TTY-through-`docker run` is
  fussy). The worker emits a machine-readable orphan list; the launcher decides.

### D5 — `agent-update` re-seed/prune prompt *(point 3)*

After a **successful** rebuild in `agent-update` (both the base-stale `all` branch
and the agent-stale `agent` branch rebuild the agent image, so both qualify), prompt
`Re-seed skills from the freshly built image now? [y/N]`. On yes, run the same
`update-skills` the `agent-update-skills` function uses; if orphans exist, a
follow-up `Remove N obsolete seeded skills too? [y/N]` forwards `--prune`. The
"nothing to update" and "cancelled" paths do not prompt. Mirror in bash + PowerShell.

### D6 — Marker content needs the agent build-commit (bake it)

The marker records `commit=<agent build-commit>`. Skills live in the asset COPY
layer (part of the always-rebuilt top group), so the **agent's own top build
commit** is the correct provenance for seeded skills — no read-back needed here.

Bake it like `build-epoch`: `build-image.{sh,ps1}` computes `git rev-parse HEAD`,
passes it as a bake var → Dockerfile `ARG` → write to
`/home/node/.agent-container/{claude,codex}/build-commit` in the **same `RUN`** as
the epoch (that layer already rebuilds every build, so it is free). The entrypoint
hook and the updater worker read it next to `build-epoch`.

---

## Three-anchor image provenance — design, deferred to a STACKED branch

Reality: a piecemeal-updated stack can carry up to **three** distinct powbox commits.

| Anchor | Changes when | Recorded where |
|---|---|---|
| **base** | base rebuild only (separate image, own parent) | label + file on the base image |
| **codex** | codex layer rebuilt (reused on claude-only update) | label + file on agent image, via **read-back** |
| **claude / top** | every agent build | label + file on agent image (current HEAD) |

**Cache-safety crux:** codex's commit **cannot** be stamped inside the codex install
layer. We pass the current HEAD on every build, so any `RUN` referencing a commit
`ARG` in that layer would bust the codex layer on every commit — destroying the
layer-reuse the "codex below claude" ordering exists to preserve. Therefore codex's
commit is computed in `build-image.sh`:
- codex rebuilt this run (codex forced to latest, or `base`/`all`/`--no-cache`, or
  no existing image) → `powbox.commit.codex = HEAD`;
- codex pinned/reused → read the prior `powbox.commit.codex` off the existing
  `powbox-agent:latest` and **carry it forward unchanged**.

`build-image.sh` distinguishes the cases by also recording a `powbox.codex.version`
label and comparing it to the requested `CODEX_VERSION` — which aligns with the
`agent-update` orchestration (claude-only update passes the same baked codex version
→ carry forward; codex update passes a new one → HEAD). Degrades gracefully to HEAD
for ad-hoc builds; acceptable because **no logic flows off these hashes** (introspection only).

**Surface via both:**
- **Labels** `powbox.commit.{base,codex,claude}` → host-side `docker inspect` /
  `docker image inspect`, no container needed (what `agent-update` output and the
  `zsh` helper read).
- **Baked files** under a stable path (e.g. `/home/node/.powbox/{base,codex,agent}.commit`;
  base's is inherited via `FROM`) → in-container `cat`, enabling "an agent in this
  environment diffs the building branch against the working branch"
  (`git diff <commit>..HEAD` against the powbox repo).

The single agent `build-commit` baked in THIS branch (D6) is the same value as the
`claude/top` anchor, so the stacked branch builds on it without rework.

---

## Scope split

**This branch (`agent-update-skills`):**
- `docker/shared/seed-skills.sh` shared helper; both hooks + updater worker call it (D1).
- `.powbox-seeded` marker, content `epoch=…\ncommit=…` (D2).
- Bake the agent `build-commit` next to `build-epoch` + `build-image.{sh,ps1}`
  `git rev-parse` plumbing → bake var → Dockerfile `ARG` (D6).
- Three-way refresh with adopt/skip/rename + `--adopt-all`/`-AdoptAll` (D3).
- `--prune`/`-Prune`, report-by-default, orphan reporting from the worker (D4).
- `agent-update` re-seed/prune prompt, bash + PowerShell (D5).
- Docs: update README "Refreshing Skills", AGENTS.md, this file.

**Stacked branch (image-provenance):** three-anchor labels + files, `build-image.sh`
read-back/carry-forward, `agent-update` commit display, `zsh` helper. Per the user's
offer, kept off this branch to keep the skills diff reviewable.

---

## Files to touch (this branch)

- **new** `docker/shared/seed-skills.sh` — shared `seed_skills` + marker write.
- `docker/shared/entrypoint-claude-hook.sh`, `docker/shared/entrypoint-codex-hook.sh`
  — replace the inline skill loop with `source seed-skills.sh; seed_skills … noclobber`.
- `docker/agent/Dockerfile` — COPY `seed-skills.sh` into `/usr/local/bin/`; `ARG`
  for the build-commit; write `build-commit` in the epoch `RUN`.
- `docker-bake.hcl` + `scripts/build-image.sh` + `scripts/build-image.ps1` — compute
  `git rev-parse HEAD`, pass as bake var → agent `ARG`.
- `commands/update-skills-incontainer.sh` — source the baked helper; refresh mode;
  three-way classify; emit machine-readable conflict/orphan lists; honor
  `POWBOX_PRUNE` / `POWBOX_ADOPT_ALL` env from the launcher.
- `commands/update-skills.sh`, `commands/update-skills.ps1` — `--prune`/`-Prune`,
  `--adopt-all`/`-AdoptAll`; interactive conflict/orphan prompts; pass env into the
  worker; mount the baked helper path is unnecessary (it is in the image).
- `shell/powbox.sh`, `shell/powbox.ps1` — `agent-update` re-seed/prune prompt;
  forward new flags through `agent-update-skills`.
- `README.md`, `AGENTS.md` — document markers, conflicts, prune, the re-seed prompt.

---

## Edge cases & migration

- **Legacy seeds (pre-marker), still baked:** appear unmarked → treated as a
  **conflict** on first refresh; user resolves once via Adopt (or rename). Not
  silently overwritten.
- **Legacy seeds, no longer baked:** unmarked and not baked → neither refreshed nor
  pruned (we can't prove they're ours) → left for one-time manual cleanup. Safe.
- **User fork named like a baked skill:** unmarked conflict → Skip/rename preserves
  it; Adopt would (intentionally) replace it. Default Skip protects the user.
- **New baked skill shadowed by an existing user skill of the same name:** entrypoint
  silently lets the user's win (status quo); `update-skills` surfaces it as a conflict.
- **`--adopt-all` / `--prune` in CI/non-interactive:** explicit opt-in only; defaults
  never destroy user data.

## Open / deferred

- Commit-provenance display + `zsh` helper → stacked branch (above).
- Optional: make the marker the *only* way the entrypoint records ownership (it
  already only stamps what it newly seeds — no change needed).
- Optional: a `--report`/dry classification mode beyond the existing `--dry-run`
  (probably unnecessary; `--dry-run` already previews).
