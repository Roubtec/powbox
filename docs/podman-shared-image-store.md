# Hand-off: shared read-only Podman image store (`additionalimagestores`)

**Status:** designed + scaffolded; **not wired in, not validated.** Pick this up
from a session running on a **rebuilt, podman-capable** image. This document is
the spec; apply the wiring below, then run the validation plan and only then
update the user-facing docs.

## Why

PR #40 gives every outer container its **own writable Podman graphroot**
(`agent-podman-<agent>-<project>`, keyed per container so concurrent Claude +
Codex don't corrupt a shared store). The cost of that isolation is that each
container re-pulls the same base images — now **2× per project** (Claude and
Codex each pull `postgres`, `adminer`, …). This feature removes that waste by
sharing only the **read path**: one global, read-only image store that every
per-container graphroot layers on top of via Podman's `additionalimagestores`.
Writable stays per-container; only cached base layers are shared.

## Decisions already made (don't relitigate)

- **Seeded shared volume**, not baked-into-base and not a dynamic shared-writable
  store. Rationale: forward-compatible with the broader "move heavier installed
  deps into shared volumes" direction; avoids base-image bloat; a dynamic
  writable store would reintroduce the concurrent-writer corruption PR #40 just
  fixed.
- **Single GLOBAL store**, one `agent-podman-imagestore` volume shared by every
  container across all projects (the curated base images are identical
  everywhere → max dedup). Writable graphroots remain per-container.
- **In-container re-seed only** — a single bash worker
  (`docker/shared/seed-image-store.sh`), no host `.sh`/`.ps1` wrappers until
  there's a real host-trigger use case. Seeding is a podman/Linux operation that
  only makes sense inside the container. An optional zsh alias is fine.
- **Overlay-only.** An additional image store must match the consumer's storage
  driver, and consumers only use overlay when `/dev/fuse` is present; on the vfs
  fallback the store is simply not referenced.

## Already committed

- Per-container graphroot keying + prune support — PR #40, commits `b8bb07f`
  (PowerShell parity, driver stability, XDG export) and `8f31d87` (per-container
  `agent-podman-<agent>-<project>` + `agent-podman-*` pruning).
- **`docker/shared/seed-image-store.sh`** — the in-container seeder worker
  (`seed` / `update` / `list` / `status`). Inert until baked + invoked. Its
  non-podman paths are tested; the `podman --root` calls are marked `VALIDATE`.

## Wiring checklist (do these, then validate)

### 1. Bake the seeder into the image
`docker/base/Dockerfile`, in the shared-scripts `COPY --chmod=755` block (~line
220):

```diff
 COPY --chmod=755 \
     docker/shared/cid \
     docker/shared/init-firewall.sh \
     docker/shared/shadow-mounts.sh \
     docker/shared/detect-shadows.sh \
     docker/shared/shadow-refresh.sh \
     docker/shared/pg-dev-up \
     docker/shared/entrypoint-core.sh \
+    docker/shared/seed-image-store.sh \
     /usr/local/bin/
```

### 2. Launcher: create + mount the global store (both flavors)
The store is a **shared** volume (like `agent-gh-config`), not per-project.

`scripts/launch-agent.sh`:
- Add `agent-podman-imagestore` to the `SHARED_VOLUMES` array (~line 190) so it
  is auto-created.
- In the root pre-run (`docker compose … run --user root …`, ~line 379), add a
  mount + chown so `node` owns it:
  ```diff
       -v "${PODMAN_VOLUME}:/mnt/containers" \
  +    -v "agent-podman-imagestore:/mnt/podman-imagestore" \
       agent \
  -    -lc 'mkdir -p /mnt/node_modules /mnt/worktrees /mnt/containers && chown node:node /mnt/node_modules /mnt/worktrees /mnt/containers'
  +    -lc 'mkdir -p /mnt/node_modules /mnt/worktrees /mnt/containers /mnt/podman-imagestore && chown node:node /mnt/node_modules /mnt/worktrees /mnt/containers /mnt/podman-imagestore'
  ```
- In the final agent `run` (~line 429), add the mount **read-write** (Podman
  treats it read-only via `additionalimagestores` regardless; the seeder needs
  write):
  ```diff
       -v "${PODMAN_VOLUME}:/home/node/.local/share/containers" \
  +    -v "agent-podman-imagestore:/mnt/podman-imagestore" \
  ```

`scripts/launch-agent.ps1`: mirror all three (the `$sharedVolumes` array, the
root pre-run `-v`/`mkdir`/`chown`, and the final `run` `-v`).

### 3. Entrypoint: consume the store + first-run seed
`docker/shared/entrypoint-core.sh`, inside the `command -v podman` block, in the
`overlay` branch (where it currently just `rm -f storage.conf` to use the image
default). When the store mount exists, write a `storage.conf` that keeps overlay
**and** points at the additional store, then kick a one-shot background seed if
unmarked:

```sh
# (overlay branch) — replace the bare `rm -f storage.conf`
_imgstore="/mnt/podman-imagestore"
if [ -d "$_imgstore" ]; then
    # VALIDATE: exact TOML + whether the path is $_imgstore or $_imgstore/<driver>.
    printf '[storage]\ndriver = "overlay"\n\n[storage.options]\nadditionalimagestores = ["%s"]\n' \
        "$_imgstore" >"$HOME/.config/containers/storage.conf"
    # First-run seed in the background so container start isn't blocked on pulls.
    if [ ! -f "$_imgstore/.powbox-image-store-seeded" ] && command -v seed-image-store.sh >/dev/null 2>&1; then
        seed-image-store.sh seed >/tmp/powbox-image-store-seed.log 2>&1 &
    fi
else
    rm -f "$HOME/.config/containers/storage.conf"
fi
```

> Interaction with the driver-stability logic already in this block: the
> `additionalimagestores` line must be written **only on the overlay path**.
> The vfs branch leaves it out (consumers on vfs ignore the store). Keep the
> per-volume driver marker behaviour intact.

### 4. prune-volumes: never prune the global store
The global store matches the `agent-podman-*` candidate family added in
`8f31d87`, but no container is named `imagestore`, so it would be flagged as
orphan. Whitelist it as always-expected (shared infra).

`commands/prune-volumes.sh` — before the candidate loop:
```diff
+# The global shared image store is infra shared by every container (like the
+# config volumes), never a per-container orphan.
+expected+=("agent-podman-imagestore")
 candidates=()
```
`commands/prune-volumes.ps1` — after the container loop:
```diff
+# Global shared image store: infra, never an orphan.
+[void]$expectedVolumes.Add("agent-podman-imagestore")
```

### 5. Optional zsh alias
`docker/shared/.zshrc` (baked, sourced per shell). Add only once the seeder is
baked so it never points at a missing command:
```sh
alias reseed-images='seed-image-store.sh update'
```

### 6. Docs (after validation passes)
- `README.md` "Nested Containers": note the shared read-only image cache and that
  `agent-podman-imagestore` is a shared volume; add `POWBOX_IMAGE_STORE_IMAGES`
  to the env-var table if exposed at the launcher level.
- `docs/rootless-podman.md` Follow-ups: move the `additionalimagestores` bullet
  from "planned" to "done", linking here.

## Open questions — VALIDATE on the rebuilt host

These are the unverified Podman mechanics. Resolve each by running, not guessing:

1. **Additional-store path.** Does `additionalimagestores` want the graphroot dir
   (`/mnt/podman-imagestore`) or the driver subdir (`/mnt/podman-imagestore/overlay`)?
   Confirm a consumer actually resolves a seeded image from it.
2. **Seeder invocation.** Is `podman --root "$STORE" --storage-driver overlay pull …`
   sufficient, or does it need an explicit `--runroot`/`--storage-opt`? Does the
   resulting layout need anything (e.g. `podman image trust`, perms, a read-only
   lock file) before a consumer can read it?
3. **vfs consumer + overlay store.** Confirm a vfs-driver consumer cleanly
   **ignores** an overlay `additionalimagestores` entry rather than erroring.
   (If it errors, gate the storage.conf line strictly on the chosen driver.)
4. **Read-while-write.** Seed (writer) running while another container reads the
   store: does the read-only consumer tolerate it? Seeding is rare (first run +
   explicit update); the flock serializes writers, but a consumer mid-read during
   a seed is the edge to check.
5. **Background first-run seed.** Confirm the backgrounded seed survives the
   entrypoint's `exec "$@"` (reparented, keeps pulling) and that an agent pulling
   the same image concurrently into its own graphroot doesn't deadlock on the
   store. Worst acceptable case: the image just isn't shared yet and the agent
   pulls its own copy.
6. **build-epoch/commit path.** The seeder writes a marker reading
   `/usr/local/share/powbox/build-epoch|build-commit`. Confirm that's where the
   build metadata lands (seed-skills.sh reads epoch/commit from a seed meta dir —
   reuse the real path).

## Validation plan

Run inside a freshly rebuilt container (overlay path, `/dev/fuse` present):

1. `seed-image-store.sh status` → store mounted, overlay yes, seeded no.
2. `seed-image-store.sh seed` → pulls the curated set; re-run → all `present`,
   nothing re-pulled. `seed-image-store.sh list` → all `present`.
3. **Sharing works:** in a *second* container for a different project,
   `podman pull docker.io/library/postgres:16-alpine` should resolve from the
   shared store (near-instant, no network layer pulls) — compare against a
   curated image vs. a non-curated one to see the difference.
4. **Writable still isolated:** `podman run` a curated image, write data to a
   `podman volume`; confirm it lands in the per-container graphroot, not the
   shared store (shared store stays read-only/unchanged).
5. **Firewall/isolation unaffected:** re-run the egress check from
   `docs/rootless-podman.md` step 4 (PUBLIC_OK / LAN_BLOCKED).
6. **Prune safety:** `commands/prune-volumes.sh` must **not** list
   `agent-podman-imagestore`. Orphaned per-container `agent-podman-<agent>-<proj>`
   stores still prune.
7. **Update:** `seed-image-store.sh update` re-pulls; confirm consumers see
   refreshed images.

## Curated image set

Default (in `seed-image-store.sh#default_images`): `postgres:16-alpine`,
`redis:7-alpine`, `mariadb:11`, `adminer:latest`. Keep it small — every image
costs shared store space. Override per environment with
`POWBOX_IMAGE_STORE_IMAGES` (whitespace-separated) without editing the script;
decide later whether to surface that as a launcher-level env var.
