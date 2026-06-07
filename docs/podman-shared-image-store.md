# Hand-off: shared read-only Podman image store (`additionalimagestores`)

**Status:** wiring **APPLIED** (steps 1–5 below, in the repo now); **not yet
validated** — the overlay end-to-end needs a freshly **rebuilt** image **with
`/dev/fuse`**. Pick this up from such a session: confirm the two prerequisites
below, then run the validation plan, then update the user-facing docs.

> **Prerequisite 1 — rebuild BOTH the base AND the agent image.** The
> `docker/base/Dockerfile` fix that pre-creates `/etc/containers/containers.conf.d`
> at mode `0755` is correct and verified (without it, `COPY --chmod=644`
> auto-creates that dir at `0644` — no search bit — and **every** `podman` command
> fails with `open .../10-powbox.conf: permission denied`; confirmed by
> `dpkg -S /etc/containers/containers.conf.d` returning nothing, so the COPY itself
> created the dir). It just needs to be **baked**: a prior session rebuilt only the
> base and forgot the agent layer, so the running image still came from a pre-fix
> commit (`build-commit` baked at `/home/node/.agent-container/<agent>/build-commit`
> lagged the fix commit) and `podman info` kept failing. After rebuilding **both**
> layers and relaunching, confirm it took: **`podman info` must exit 0** with no
> `CONTAINERS_CONF` override. If you still get the permission-denied error, the
> rebuild didn't pick up the fix — stop and rebuild before doing anything below.
>
> _Interim unblock (no rebuild):_ `export CONTAINERS_CONF=<repo>/docker/shared/containers.conf`
> makes `podman` skip the broken system drop-in and run normally — enough to
> exercise the **driver-independent** parts (seeder logic, prune whitelist, the vfs
> proxy checks). It cannot exercise the overlay path.

> **Prerequisite 2 — the container must have `/dev/fuse` (overlay), or none of the
> sharing validation can run.** The shared store is overlay-only by design, and
> overlay needs `/dev/fuse` + fuse-overlayfs. Without it Podman falls back to vfs,
> the entrypoint deliberately omits the `additionalimagestores` line, and the store
> is simply unused — there is nothing overlay-specific to test. `SYS_ADMIN` is
> already granted in `compose.shared.yml`, so once the device is attached the mounts
> work; the device is the only host-side gate. See **Enabling `/dev/fuse` (WSL2)** below.
> Verify after relaunch: `podman info --format '{{.Store.GraphDriverName}}'` → `overlay`.

## Why

The rootless-Podman work gives every outer container its **own writable Podman
graphroot** (`agent-podman-<container>`, keyed per container so concurrent Claude
+ Codex don't corrupt a shared store). The cost of that isolation is that each
container re-pulls the same base images — now **2× per project** (Claude and
Codex each pull `postgres`, `adminer`, …). This feature removes that waste by
sharing only the **read path**: one global, read-only image store that every
per-container graphroot layers on top of via Podman's `additionalimagestores`.
Writable stays per-container; only cached base layers are shared.

## Decisions already made (don't relitigate)

- **Seeded shared volume**, not baked-into-base and not a dynamic shared-writable
  store. Rationale: forward-compatible with the broader "move heavier installed
  deps into shared volumes" direction; avoids base-image bloat; a dynamic
  writable store would reintroduce the concurrent-writer corruption the
  per-container graphroot keying just fixed.
- **Single GLOBAL store**, one `agent-podman-imagestore` volume shared by every
  container across all projects (the curated base images are identical
  everywhere → max dedup). Writable graphroots remain per-container.
- **In-container re-seed only** — a single bash worker
  (`docker/shared/seed-image-store.sh`), no host `.sh`/`.ps1` wrappers until
  there's a real host-trigger use case. Seeding is a podman/Linux operation that
  only makes sense inside the container. An optional zsh alias is fine.
- **Overlay-only (a scoping choice, not a vfs limitation).** An additional image
  store must match the consumer's storage driver. vfs *can* consume one too — a
  vfs store + vfs consumer resolves images fine via storage.conf (verified, see
  "Validation already done" below) — but a single GLOBAL store can only hold one
  driver, so we share on the common overlay path (`/dev/fuse` present) and simply
  don't reference the store on the vfs fallback. A future vfs-variant store for
  fuse-less hosts is possible but out of scope.

## Already in the repo

- Per-container graphroot keying + prune support: `scripts/launch-agent.{sh,ps1}`
  key the writable store `agent-podman-<container>` (agent + project) and the
  PowerShell launcher mirrors the bash one; `docker/shared/entrypoint-core.sh`
  records the chosen storage driver per volume (no silent overlay↔vfs flips); and
  `commands/prune-volumes.{sh,ps1}` discover and prune the `agent-podman-*` family.
- **`docker/shared/seed-image-store.sh`** — the in-container seeder worker
  (`seed` / `update` / `list` / `status`). Inert until baked + invoked. Its
  non-podman paths are tested; the `podman --root` calls are marked `VALIDATE`.

## Wiring checklist — APPLIED (kept as the record of what changed)

Steps 1–5 are **done and in the repo** (syntax-checked, shellcheck/PSScriptAnalyzer
clean; the prune whitelist was behaviorally verified). They take effect on the next
**base + agent** rebuild. Step 6 (user-facing docs) is still pending validation. The
diffs below are retained so the next session can see exactly what was wired and where.

- ✅ **1. Seeder baked** — `docker/shared/seed-image-store.sh` added to the
  `COPY --chmod=755` block in `docker/base/Dockerfile`.
- ✅ **2. Launcher** — `agent-podman-imagestore` added to the shared-volume array and
  mounted at `/mnt/podman-imagestore` in both the root pre-run (with mkdir+chown) and
  the final `run`, in **both** `scripts/launch-agent.sh` and `scripts/launch-agent.ps1`.
- ✅ **3. Entrypoint** — `docker/shared/entrypoint-core.sh` overlay branch now writes a
  `storage.conf` with `additionalimagestores` when the store is mounted and kicks the
  background first-run seed; vfs branch unchanged (store never referenced on vfs).
- ✅ **4. prune-volumes** — `agent-podman-imagestore` whitelisted as always-expected in
  both `commands/prune-volumes.sh` and `commands/prune-volumes.ps1`.
- ✅ **5. zsh alias** — `reseed-images` added to `docker/shared/.zshrc` (safe now that
  the seeder is baked).

### 1. Bake the seeder into the image
`docker/base/Dockerfile`, in the shared-scripts `COPY --chmod=755` block (~line
226):

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
- Add `agent-podman-imagestore` to the `SHARED_VOLUMES` array (~line 194) so it
  is auto-created.
- In the root pre-run (`docker compose … run --user root …`, ~line 408), add a
  mount + chown so `node` owns it:
  ```diff
       -v "${PODMAN_VOLUME}:/mnt/containers" \
  +    -v "agent-podman-imagestore:/mnt/podman-imagestore" \
       agent \
  -    -lc 'mkdir -p /mnt/node_modules /mnt/worktrees /mnt/containers && chown node:node /mnt/node_modules /mnt/worktrees /mnt/containers'
  +    -lc 'mkdir -p /mnt/node_modules /mnt/worktrees /mnt/containers /mnt/podman-imagestore && chown node:node /mnt/node_modules /mnt/worktrees /mnt/containers /mnt/podman-imagestore'
  ```
- In the final agent `run` (~line 469), add the mount **read-write** (Podman
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
    # Path is the graphroot ($_imgstore), NOT $_imgstore/<driver> — verified on vfs
    # (graph-layer path semantics are driver-independent). Re-confirm once on overlay.
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
The global store matches the `agent-podman-*` candidate family that
`commands/prune-volumes.{sh,ps1}` already discover, but no container is named
`imagestore`, so it would be flagged as an orphan. Whitelist it as
always-expected (shared infra).

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

1. **Additional-store path.** RESOLVED on vfs (the graph-layer path semantics are
   driver-independent; re-confirm once on overlay). It wants the **graphroot**
   (`/mnt/podman-imagestore`), NOT the driver subdir
   (`/mnt/podman-imagestore/overlay`). Proof: a separate consumer with
   `additionalimagestores = ["<graphroot>"]` in storage.conf resolved a seeded
   image read-only (`ReadOnly=true`); appending `/vfs` or `/vfs-images` resolved
   nothing. So the entrypoint should point at the bare mount dir.
2. **Seeder invocation.** Is `podman --root "$STORE" --storage-driver overlay pull …`
   sufficient, or does it need an explicit `--runroot`/`--storage-opt`? Does the
   resulting layout need anything (e.g. `podman image trust`, perms, a read-only
   lock file) before a consumer can read it?
3. **vfs consumer + overlay store (driver mismatch).** PARTIALLY RESOLVED. A
   consumer reading `additionalimagestores` from **storage.conf** does not error
   and cleanly uses it *when the store's driver matches* (vfs store + vfs consumer
   verified). Passing it instead as a `--storage-opt` driver option DOES hard-error
   (`vfs driver does not support additionalimagestores options`) — so never wire it
   that way; storage.conf only. Still unverified: a true driver MISMATCH (overlay
   store + vfs consumer), which needs `/dev/fuse` to set up. Mitigation already in
   the design: the entrypoint writes the `additionalimagestores` line ONLY on the
   overlay branch, so a vfs consumer never sees the overlay store in the first place.
4. **Read-while-write.** Seed (writer) running while another container reads the
   store: does the read-only consumer tolerate it? Seeding is rare (first run +
   explicit update); the flock serializes writers, but a consumer mid-read during
   a seed is the edge to check.
5. **Background first-run seed.** Confirm the backgrounded seed survives the
   entrypoint's `exec "$@"` (reparented, keeps pulling) and that an agent pulling
   the same image concurrently into its own graphroot doesn't deadlock on the
   store. Worst acceptable case: the image just isn't shared yet and the agent
   pulls its own copy.
6. **build-epoch/commit path.** RESOLVED by inspection. Build metadata lands at
   `/home/node/.agent-container/<agent>/build-{epoch,commit}` (written identically
   for every agent by `docker/agent/Dockerfile`), **not** `/usr/local/share/powbox/`
   — that path doesn't exist, so the old marker always degraded to `0`/`unknown`.
   The seeder now resolves it via `$AGENT_SEED_DIR` (exported by
   `entrypoint-agent.sh`), falling back to any agent's dir.

## Validation already done (vfs proxy, no `/dev/fuse`)

Done from a vfs-only container by pointing `CONTAINERS_CONF` at the repo's
`docker/shared/containers.conf` to step past the broken drop-in (see prerequisite
above), then pulling `alpine:3.19` into a throwaway "shared" graphroot and
consuming it from a second graphroot:

- **`additionalimagestores` path = the graphroot** (open question #1) — confirmed.
  The driver subdir and `vfs-images` variants resolve nothing.
- **Read-only sharing model** — the consumer sees the image with `ReadOnly=true`
  and nothing is copied into its own (empty) graphroot.
- **storage.conf vs `--storage-opt`** (open question #3) — a consumer honours
  `[storage.options] additionalimagestores` from storage.conf without error;
  passing the same as a `--storage-opt` driver option hard-errors on vfs. Wire it
  via storage.conf only.
- **Seeder build-meta** (open question #6) — `build_meta_dir` resolves the real
  epoch/commit both via `$AGENT_SEED_DIR` and via the fallback glob.

Still needs the rebuilt overlay host: the overlay happy-path end-to-end, the true
driver-mismatch case (overlay store + vfs consumer), read-while-write, and the
backgrounded first-run seed surviving `exec "$@"` (open questions #2, #3-mismatch,
#4, #5).

## Enabling `/dev/fuse` (WSL2 / Windows 11 host)

The launcher attaches `/dev/fuse` (by adding `compose.fuse.yml` to the `-f` chain
— `docker compose run` has no `--device` flag, only `docker run` does) when
`POWBOX_FUSE=on`, or under the default `auto` when the **shell that runs the
launcher** already has `/dev/fuse`.
`SYS_ADMIN` is already in `compose.shared.yml`, so the device is the only host-side
gate. Where the device must exist depends on how Docker runs:

- **Docker Desktop (WSL2 backend)** — the common Windows 11 case. Containers run in
  Docker Desktop's *own* managed VM, not your distro, and that VM ships `/dev/fuse`.
  But `auto` checks the launcher's shell (Windows PowerShell has no `/dev`; a WSL2
  distro's `/dev/fuse` doesn't reflect the Docker VM), so `auto` under-detects and
  falls back to vfs. **Force it: `POWBOX_FUSE=on`.**
  - PowerShell: `$env:POWBOX_FUSE='on'; .\scripts\launch-agent.ps1 …`
  - bash/WSL: `POWBOX_FUSE=on ./scripts/launch-agent.sh …`
  - If `POWBOX_FUSE=on` hard-fails at `docker … run` with a device error, the Docker
    VM isn't exposing `/dev/fuse` — update Docker Desktop and run `wsl --update`
    (Windows) for a current kernel, then retry.
- **Docker engine native inside a WSL2 distro** (docker-ce in Ubuntu, no Docker
  Desktop) — containers share the distro kernel + `/dev`, so `/dev/fuse` must exist
  in that distro:
  - `ls -l /dev/fuse` — if present, `auto` already passes it (`POWBOX_FUSE=on` also works).
  - If missing: `sudo modprobe fuse` (Microsoft's WSL2 kernel ships the module);
    confirm with `grep fuse /proc/filesystems`. Persist with a
    `/etc/modules-load.d/fuse.conf` containing `fuse`. Keep the kernel current via
    `wsl --update` + `wsl --shutdown` from Windows.

**After relaunch, verify inside the new container:** `ls -l /dev/fuse` (present) and
`podman info --format '{{.Store.GraphDriverName}}'` → `overlay`.

> **Gotcha — the per-container driver is pinned on first init.** The persistent
> `agent-podman-<container>` graphroot records its storage driver
> (`.powbox-storage-driver`) the first time it's created and the entrypoint **won't
> silently flip** it (changing drivers needs a clean store). If this project's
> graphroot was first initialised on vfs, adding `/dev/fuse` later keeps vfs and the
> entrypoint prints a note. To actually switch to overlay, drop that volume
> (`docker volume rm agent-podman-<container>`) or run `podman system reset` inside,
> then relaunch. The new `agent-podman-imagestore` is unaffected (the seeder pulls
> into it with an explicit `--storage-driver overlay`).

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
