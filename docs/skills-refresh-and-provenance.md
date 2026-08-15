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
   `epoch=… commit=…`, later also `source=…` — see D8) when seeding, so the updater
   can tell its own copies from user-authored/forked skills.
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
baked skill over the volume copy (`docker/shared/update-skills-incontainer.sh`).

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
(low)** → shared-linter installs → **claude install (high)** → asset COPY +
`RUN date +%s%N` epoch → entrypoint COPY. Codex stays directly on the base because
the provenance resolver models that parent exactly. The epoch `RUN` is
non-deterministic, so the asset/epoch/entrypoint layers rebuild on **every** agent
build; codex and the stable linter layers are reused on a claude-only update.

---

## Decisions (locked)

### D0 — The `mv` is an atomic swap, not a move of the seed *(clarification only)*

In `docker/shared/update-skills-incontainer.sh` the real data copy is `cp -a` straight from the
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
skill. Content (chosen: **epoch + commit**, later extended with **source** — see
[D8](#d8--the-marker-records-its-upstream-source-sourceownerrepopath)):

```
epoch=<image build-epoch>
commit=<powbox commit that built the agent image>
source=<owner>/<repo>#<repo-relative path of this item>
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

### D8 — The marker records its upstream source (`source=<owner>/<repo>#<path>`)

`epoch=`/`commit=` answer *"which image build put this here"*. They do not answer the question an agent actually hits when it finds a **defect** in a seeded skill mid-run: *"where do I fix it?"*.
That gap cost a real session several exploratory commands across four plugin-cache copies, ending in a report that could only describe the upstream location by inference — and the session's patch died with the session.

So every marker also records the **source-of-truth path in the owning repo**:

```
source=Roubtec/agent-skills#codex/dev-skills/skills/address-review
```

Format: `<owner>/<repo>#<repo-relative-path>` — greppable, unambiguous, and pasteable straight into a report or PR description.
The path is the **upstream** one, never the container destination, and it names the **item itself** (the trailing component is the skill folder / workflow file name), so `cat ~/.codex/agents/skills/<name>/.powbox-seeded` is the whole hunt.

Where the value comes from: everything powbox seeds today originates in `Roubtec/agent-skills`, so a **per-source-root constant** is enough — no git metadata is threaded through the seed path.
`seed-skills.sh` defines the roots (`POWBOX_SEED_SOURCE_{CODEX_SKILLS,CLAUDE_SKILLS,CLAUDE_WORKFLOWS}`, all derived from `POWBOX_SEED_SOURCE_REPO`), `seed_source_ref <root> <name>` appends the item name, and `seed_marker_content <meta> [<source_ref>]` emits the line.
Each producer passes the root for the kind it is writing: the Codex entrypoint hook and the plugin-clone sync pass the Codex-skills root; `update-skills-incontainer.sh` carries one per row of its driver table.
Because the value is per **item**, the marker body is built inside each producer's per-item loop rather than hoisted out of it — a hoisted body would stamp every skill with one name.
Only the updater worker needs a build-skew guard: it is bind-mounted from the checkout while `seed-skills.sh` comes from the image, so a newer worker can meet a pre-`source=` library — it then stubs `seed_source_ref`, defaults the roots to `-` (so `set -u` cannot abort the refresh), writes the same two-line markers that image wrote anyway, and says so once on stderr, since a silently source-less marker is the very gap D8 closes.
The other producers are baked in the same image layer as the library, so skew is structurally impossible for them.

Should powbox ever bake an asset it owns itself again, that call site gets its own `<owner>/<repo>#<path>` root; a call site with no upstream to name passes nothing (or `-`) and the line is **omitted** rather than written empty — an unknown source must be absent, never a misleading guess.

**Marker parsing contract (both directions of the transition).** The marker is a set of `key=value` lines and **must be parsed by key** (`grep '^commit='`), never by line number or line count.
An older image writes two-line markers that a newer image reads (ownership hinges on the marker's *presence*, so they classify, refresh, and prune exactly as before); a newer image writes three-plus-line markers that an older container may read.
Every current consumer already satisfies this — `seed_is_marked`/`seed_workflow_is_marked` test existence only, and `codex_recorded_sha` greps `^agent_skills_commit=` — and `scripts/test-seed-marker-source.sh` pins it with legacy-marker refresh/prune cases.

**Channel rename.** The plugin-clone sync previously recorded *which channel wrote the copy* as `source=plugin-clone`.
That key now means the upstream path, so the channel moved to its own key, `channel=plugin-clone` (see the task-021 section below).
Nothing in the codebase branches on either key — they are introspection only — so the transition needs no migration: a marker written by an older image keeps the old spelling until the next sync or refresh rewrites it.

### D9 — The Claude statusline is a `.powbox-seeded` producer too (task 002e)

Skills and workflows are not the only thing powbox seeds onto a config volume.
`entrypoint-claude-hook.sh` seeds `~/.claude/statusline-command.sh`, and it now stamps the same kind of marker: the sidecar `~/.claude/.statusline-command.sh.powbox-seeded`, whose name follows exactly the shape `seed_workflow_marker_path` produces for a lone file (`<dir>/.<filename>.powbox-seeded`).

Its body adds one key the skill/workflow markers do not carry:

```text
epoch=<image build-epoch that wrote this copy>
commit=<powbox commit that built the agent image>
sha256=<digest of exactly the bytes written>
source=Roubtec/powbox#docker/claude/agent-container/statusline-command.sh
```

`sha256=` exists because the statusline's ownership question is *stricter* than a skill's.
For a skill, marker-present means "powbox owns this, refresh it" — a user who wants to keep their fork deletes the marker.
The statusline is a single file the maintainer deliberately ships opinionated and expects users to tweak in place, so presence alone would license overwriting an edit nobody asked to lose; the refresh therefore requires the on-disk digest to still equal the recorded one.
A running container holds no copy of the previous image's file, so a digest recorded at seed time is the only proof available — comparing against the previous bake is not an option.
An **unmarked** statusline is treated exactly as an unmarked skill is: untouchable.
That is the upgrade path for every `claude-config` volume that predates this marker, and it self-heals the first time the user deletes the file.

"Unmarked" extends to every way the proof can come up missing, because a digest powbox cannot read is worth no more than one it never wrote: a marker with no `sha256=` key, a marker that cannot be read at all, and a file that cannot be digested (an image without `sha256sum`) all keep the file and say nothing.
The producing side matches — `seed_statusline` writes a copy whose digest it could not compute with **no marker at all**, rather than a marker it could not fill in, so the unprovable case can only ever err toward keeping what is on disk.
It also *removes* any marker already sitting there in that case, and whenever a marker cannot be published: once the file has been replaced, an old `sha256=` names bytes that are gone, and a stale proof is worse than none — it reads as "the user edited this" and nags about a file powbox itself just wrote.

`source=` names **this** repo rather than one of the `Roubtec/agent-skills` roots — the statusline is a powbox-owned asset, which is the "should powbox ever bake an asset it owns itself" case [D8](#d8--the-marker-records-its-upstream-source-sourceownerrepopath) reserved.

A start that notes something about the statusline without publishing anything also writes `notified_epoch=<image epoch>`, so the note appears once per new image instead of on every container start.
The throttle is best-effort, because it is the marker that records it: with no marker to read, or one that cannot be read or rewritten, there is nowhere to record the note and it repeats on every start.
It covers both such notes — "a newer statusline is available, yours differs" and "the destination could not be written" — because each of their branches stays true on every later start, the marker's `epoch=` never advancing while nothing is published.
`notified_epoch=` therefore reads as "the newest image this statusline has already spoken about", and a successful refresh rewrites the marker without the key, so the next image is announced again.
It is a **separate key** on purpose: reusing `epoch=` would have bought the same suppression at the cost of that key's meaning ("the build that placed this file"), which the digest comparison depends on staying true.

**Written inline, not by sourcing `seed-skills.sh`.** The two calls the library could have supplied are the epoch/commit printf and the sidecar-name join; it cannot supply `sha256=` at all, and `seed_source_ref` cannot supply this `source=` either, since every root it defines points at `Roubtec/agent-skills`.
Against that, sourcing would give the Claude hook its first library dependency — and the hook runs under `set -euo pipefail` on the startup critical path, where a missing or damaged library would take the instruction file and `settings.json` down with a cosmetic asset.
So the hook reuses the *format* (which is what consumers depend on) and not the code, and the parse-by-key rule above binds it identically: it reads keys with `sed -n 's/^<key>=//p'`, never by position.
**Published atomically, like the file it describes.** Every write of this marker goes to a `mktemp` sibling and is renamed over the real name, never written in place, because the `claude-config` volume is shared by every powbox container: a truncating write is visible to a peer mid-flight, and the peer reading a marker stripped back to `notified_epoch=` alone would treat the statusline as unmarked from then on — never refreshed, never mentioned again.
Any consumer that learns to *write* a `.powbox-seeded` marker on a shared volume should do the same, and should rename with `mv -T`: a plain `mv` onto a marker path that happens to be a *directory* moves the temp inside it and still exits 0, reporting a marker published nowhere.
Per-write atomicity is not atomicity across the **pair**, though — where there is a pair at all. Where the marker can live *inside* the asset it describes, there is none to lose: `seed_skill` stamps `<skill>/.powbox-seeded` into the staged directory and publishes the marker and the skill with the **same** `mv -T`, so no interleaving can separate them. That is the strongest form available, and the first one to reach for.
A *sidecar* marker is two independent renames, and a digest-carrying sidecar is where that bites: two containers publishing concurrently can interleave them and leave one's asset under the other's `sha256=`, after which the digest never matches again and the asset reads as customized until it is deleted. A sidecar carrying no digest survives the same interleaving, because a refresh turns on the marker's *presence* and never on what it says: `seed_workflows … refresh` and the updater's `item_is_refreshable` both ask only whether the destination is a marked plain file, and neither reads `epoch=` — so a workflow left under a peer's marker is still refreshable, which is exactly the property a digest destroys and the reason the statusline is the only consumer here for which the pair has to be serialized at all. Refreshability is the claim, not that anything on this tree currently exercises it: no Claude workflows are baked any more, so a marked on-volume copy's only disposition today is `orphan`/`--prune` ([Forfeit update](#forfeit-update-2026-07-30-no-baked-claude-items-prune-covers-whole-kind-removal)).
The statusline cannot take the in-asset form, being a single file, and accepts the race for the reason [entrypoint-and-runtime.md](entrypoint-and-runtime.md) gives (an flock there would sit on the synchronous startup path); serializing the transaction is task 002h, and a consumer that needs a digest-carrying sidecar and is not on that path should reach for the cross-container lock `seed-claude-plugins.sh` already uses.
A digest gate carries one limit that no lock repairs, and every future `sha256=` producer inherits it: the proof is established at one moment and acted on at another, so it binds only writers that are absent from the gap between them. A lock closes that gap against the *other* powbox containers, which is what task 002h is for; it does nothing about the arbitrary writer the gate was actually built to protect against — the user, editing the asset the marker calls theirs to edit. Worse, the publish that wins such a race then stamps the source digest, so the marker certifies the overwrite as powbox's own and the loss is silent as well as unrecoverable. A conditional replace is not available to close it — `rename(2)` has no such form — so a producer choosing a digest-carrying sidecar is choosing this residual too, and should state it where the statusline's is stated rather than let the `sha256=` imply a guarantee it does not carry. Task 002i settles what the statusline itself does about it.
`scripts/test-claude-hook-skew.sh` pins the marker's contents and all three transitions, plus the two concurrency shapes — a peer truncating the marker under the rewrite, and a marker that cannot be written in place while the file it describes is re-seeded — and that directory case.

---

## Three-anchor image provenance — IMPLEMENTED on the stacked branch

Status: built on branch `agent-image-provenance` (stacked on `agent-update-skills`).
The codex read-back resolver was unit-tested against a `docker` stub across the
rebuild/reuse matrix, and `agent-image-info` was exercised via a label stub; a real
image build is still to be validated on the host.

Reality: a piecemeal-updated stack can carry up to **three** distinct powbox commits.

| Anchor | Changes when | Recorded where |
|---|---|---|
| **base** | base rebuild only (separate image, own parent) | label + file on the base image |
| **codex** | codex layer rebuilt — a codex version bump, or a base rebuild that re-parents it (reused on a claude-only update over the same base) | label + file on agent image, via **read-back** |
| **claude / top** | every agent build | label + file on agent image (current HEAD) |

**Cache-safety crux:** codex's commit **cannot** be stamped inside the codex install
layer. We pass the current HEAD on every build, so any `RUN` referencing a commit
`ARG` in that layer would bust the codex layer on every commit — destroying the
layer-reuse the "codex below claude" ordering exists to preserve. Therefore codex's
commit is computed in `build-image.sh`:
- codex rebuilt this run (codex forced to latest, or `base`/`all`/`--no-cache`, no
  existing image, **or the base image changed** since the previous agent was built)
  → `powbox.commit.codex = HEAD`;
- codex pinned/reused on the *same* base → read the prior `powbox.commit.codex` off
  the existing `powbox-agent:latest` and **carry it forward unchanged**.

`build-image.{sh,ps1}` distinguishes the cases by mirroring Docker's cache key for the
codex layer — its **parent** (the base image) and its **install instruction**
(`CODEX_VERSION`). It records `powbox.base.image.id` and `powbox.codex.version` on the
agent and carries the codex commit forward only when *both* the current base image ID
and the requested `CODEX_VERSION` match what the previous `powbox-agent:latest` recorded;
otherwise the layer rebuilds at HEAD. The version half aligns with the `agent-update`
orchestration (claude-only update passes the same baked codex version → carry forward;
codex update passes a new one → HEAD); the base half catches a separately rebuilt base
(`build.sh base` then `build.sh agent`) that re-parents and thus rebuilds the codex
layer. Degrades gracefully to HEAD for ad-hoc builds; acceptable because **no logic
flows off these hashes** (introspection only).

**Known limitation (accepted):** the codex commit is resolved *before* the build, so it
predicts Docker's cache decision rather than observing it. Two residual cases can still
attribute the codex layer to a carried-forward commit when it was actually rebuilt:
(a) the BuildKit build cache is evicted between runs (e.g. `docker builder prune`), which
the host cannot detect without running the build; and (b) a Dockerfile instruction *at or
above* the codex layer is edited without bumping `CODEX_VERSION`. Both require either
external cache surgery or a source edit (which carries its own commit), and in the worst
case `powbox-provenance` shows a codex commit slightly behind HEAD — never wrong in a way
any runtime logic depends on. Fully closing them would require observing per-layer cache
hits from the build output (or relabelling after the build), which is disproportionate for
an introspection-only surface.

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
- `.powbox-seeded` marker, content `epoch=…\ncommit=…` (D2; later extended with `source=…`, D8).
- Bake the agent `build-commit` next to `build-epoch` + `build-image.{sh,ps1}`
  `git rev-parse` plumbing → bake var → Dockerfile `ARG` (D6).
- Three-way refresh with adopt/skip/rename + `--adopt-all`/`-AdoptAll` (D3).
- `--prune`/`-Prune`, report-by-default, orphan reporting from the worker (D4).
- `agent-update` re-seed/prune prompt, bash + PowerShell (D5).
- Docs: update README "Refreshing Skills", AGENTS.md, this file.

**Stacked branch (`agent-image-provenance`) — done:** three-anchor labels + files,
`build-image.{sh,ps1}` codex read-back/carry-forward, `agent-update` commit display,
the `agent-image-info` shell function, and the baked in-container `powbox-provenance`
command. Kept off the skills branch to keep that diff reviewable.

---

## Files to touch (this branch)

- **new** `docker/shared/seed-skills.sh` — shared `seed_skills` + marker write.
- `docker/shared/entrypoint-claude-hook.sh`, `docker/shared/entrypoint-codex-hook.sh`
  — replace the inline skill loop with `source seed-skills.sh; seed_skills … noclobber`.
- `docker/agent/Dockerfile` — COPY `seed-skills.sh` into `/usr/local/bin/`; `ARG`
  for the build-commit; write `build-commit` in the epoch `RUN`.
- `docker-bake.hcl` + `scripts/build-image.sh` + `scripts/build-image.ps1` — compute
  `git rev-parse HEAD`, pass as bake var → agent `ARG`.
- `docker/shared/update-skills-incontainer.sh` — source the baked helper; refresh mode;
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

## Codex plugin-clone sync (task 021) — channel precedence

Task 021 gives Codex a **start-time** refresh of the 8 *shared* skills so both agents
converge on `Roubtec/agent-skills` main at the same (container-recycle) cadence,
instead of Codex tracking the slower image-rebuild cadence.

The Claude plugin bootstrap (`seed-claude-plugins.sh`, task 015c) keeps a full clone
of the marketplace on the shared `claude-config` volume
(`~/.claude/plugins/marketplaces/roubtec/`) and refreshes it every start; that clone
carries `codex/dev-skills/skills/`. So `sync-codex-skills.sh`
(`docker/shared/sync-codex-skills.sh`, baked to `/usr/local/bin/`) is a **local** sync
from that clone into the codex-config volume's skill dir — no network op of its own.
`entrypoint-core.sh` chains it directly after the detached plugin run, as a separate
process ordered after the clone refresh; see
[entrypoint-and-runtime.md](entrypoint-and-runtime.md) for the detach / done-marker /
flock details.

It reuses this document's ownership model: it iterates the *clone's* skill names, so it
only ever touches skills the clone carries. (Historical note: while `enable-worktrees` and
`session-learnings` were powbox-specific bake-only skills absent from the clone, the sync
carried an explicit bake-owned denylist of those two names as defense in depth against an
upstream name collision. The forfeit moved both skills into `agent-skills`, so they now
arrive via the clone and are refreshed like any other shared skill — the denylist was
removed with it.) It overwrites only a `.powbox-seeded`-marked (powbox-owned)
copy via an atomic stage+rename, and never touches a marker-less user-adopted copy. It is **SHA-gated** to a byte-for-byte no-op when unchanged, and
stamps each refreshed marker with two extra provenance lines beyond the D2/D8 baseline:

```
epoch=<image build-epoch>
commit=<powbox commit that built the image>
source=Roubtec/agent-skills#codex/dev-skills/skills/<name>
agent_skills_commit=<synced agent-skills HEAD SHA>
channel=plugin-clone
```

The `epoch`/`commit`/`source` lines are still written (via `seed_marker_content`) so the
marker stays coherent with what the bake+seed refresher writes — note `source=` is
**identical** across the two channels, because both ship the same upstream file; the two
added lines record *which channel last wrote the copy* and *which agent-skills commit it
carries*.
(Before D8 the channel was spelled `source=plugin-clone`; that key was repurposed for the
upstream path and the channel moved to `channel=`. Nothing parses either, so markers on an
existing volume simply keep the old spelling until the next write.)

### Precedence decision (D7): last-writer-wins, re-sync-forward

After task 021 a Codex skill on the volume may be **newer** than the image bake (the
plugin-clone sync wrote it from a fresher `agent-skills` HEAD). The bake+seed refresher
(`update-skills-incontainer.sh`, run by `agent-update-skills`) force-refreshes every
*marked* skill from the image, and a marked skill is exactly what the sync produces — so
running the updater rewrites those copies back to the image bake (and back to the plain
bake marker — `epoch`/`commit`/`source`, without the sync's `agent_skills_commit` and
`channel` lines).

**Decision: accept last-writer-wins.** We deliberately do **not** teach the updater to
inspect `channel=plugin-clone` / `agent_skills_commit` and skip a marker whose recorded
channel is newer. Rationale:

- The rollback is self-healing and cheap. The very next container start re-runs
  `sync-codex-skills.sh`, which sees the updater's plain marker (no
  `agent_skills_commit`, so recorded ≠ clone HEAD) and re-syncs the copy forward to the
  clone HEAD — a single write, then a stable no-op thereafter. So an `agent-update-skills`
  run causes at most a one-start staleness window for the Codex shared skills, closed
  automatically without any user action.
- Special-casing the updater would couple it to the plugin channel's marker schema and
  add a precedence branch to a path that today has one simple rule ("powbox owns marked
  copies → refresh"). The convergence guarantee above makes that complexity unnecessary.

The alternative (updater skips a plugin-clone marker with a newer SHA) was considered and
rejected as disproportionate: no runtime logic flows off these markers, and the
re-sync-forward already gives the desired end state (Codex shared skills on `agent-skills`
main) at the next start.

### Accepted best-effort limitations

Two transient, self-healing divergences are accepted rather than engineered away, on the
same last-writer-wins / re-sync-forward reasoning as D7 above — each converges on the next
container start, and closing it would risk the startup critical path for a self-healing
edge case.

**1. Codex-primary cold-start interleave with the bake-seed.** `entrypoint-core.sh` spawns
the detached Codex sync *before* it runs the primary setup hook, so on a Codex-**primary**
cold start the sync and the codex hook's baked-skill seeding
(`entrypoint-codex-hook.sh` → `seed_skills … noclobber`) can run concurrently against the
same codex-config skill dir. This is bounded because the bake-seed is **no-clobber**: it
only ever fills an **absent** skill and never overwrites one already present from a prior
sync. So the only contention is the *initial placement* of an absent shared skill on a cold
volume — whichever process writes last wins that start, and the SHA-gate re-syncs the fresh
copy forward on the next start (recorded ≠ clone HEAD → one write, then a stable no-op). We
deliberately do **not** add a flock to the hook's seeding path to force the sync to win:
that path is not otherwise serialized, and adding cross-process locking to a bake-seed on
the entrypoint's critical path is disproportionate to a one-start, cold-only, self-healing
window. (Warm starts do not hit this at all — the skill is already present, so the
no-clobber seed is a no-op and only the SHA-gated sync can write.)

**2. Partial plugin-bootstrap divergence.** The Codex sync reads the same marketplace clone
that `seed-claude-plugins.sh` maintains. If a bootstrap **partially** fails — the
`marketplace update` (git pull) advances the clone HEAD but the follow-up
`plugin update dev-skills@roubtec` (which pulls the new SHA into Claude's installed plugin
cache) fails — then Codex, syncing off the advanced clone HEAD, can briefly track a commit
**ahead** of the Claude plugin until the next start re-runs both and re-converges them. This
is the plugin channel's own best-effort behavior surfacing through the piggybacked sync, not
a new failure mode; it self-heals on the next online start.

## Forfeit update (2026-07-30): no baked Claude items; prune covers whole-kind removal

Powbox forfeited its remaining in-tree skills (`enable-worktrees`, `session-learnings`, both
harnesses) and the Claude `wf-*` dynamic workflows to `Roubtec/agent-skills`. Consequences
for the machinery this document specifies:

- The bake+seed channel now carries the **Codex palette only**, copied in full from the
  agent-skills staging clone at build time. The Claude seed dirs
  (`/home/node/.agent-container/claude/{skills,workflows}`) no longer exist in the image and
  the Claude hook seeds nothing; Claude's skills and workflows all arrive via the
  `dev-skills@roubtec` plugin (workflows invoked `/dev-skills:wf-<name>`).
- **The D4 prune flow covers the whole-kind case.** `update-skills-incontainer.sh` keeps its
  claude skill and claude workflow targets, and `process_items` deliberately does NOT
  early-return when the baked source dir is absent: the baked set is then empty, so every
  marked on-volume item of that kind — the previously-seeded `enable-worktrees` /
  `session-learnings` folders, the `wf-*.js` workflows, and any stranded workflow sidecar
  marker — is classified as an `orphan` and retired by `agent-update-skills --prune`. No
  manual cleanup step is needed; unmarked (user-adopted) copies are, as always, untouched.
- The plugin-clone sync's bake-owned denylist is gone (see the historical note in the
  task 021 section above): the two forfeited skills now sync from the clone like every
  other shared skill.

## Open / deferred

- Commit-provenance display + `zsh` helper → stacked branch (above).
- Optional: make the marker the *only* way the entrypoint records ownership (it
  already only stamps what it newly seeds — no change needed).
- Optional: a `--report`/dry classification mode beyond the existing `--dry-run`
  (probably unnecessary; `--dry-run` already previews).
