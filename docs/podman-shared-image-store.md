# Hand-off: shared read-only Podman image store (`additionalimagestores`)

**Status:** image-store wiring **APPLIED** (steps 1–5 below) and the image-store
overlay path is now **VALIDATED on overlay** (2026-06-07, from a rebuilt
`/dev/fuse` container). While validating, a separate and more fundamental blocker
surfaced — nested containers could not **RUN at all** — now **fixed in compose
(commit `17e42b1`), pending the next base+agent rebuild**. The run path itself
(`podman run`, networking, compose stacks) is owned by
[rootless-podman.md](rootless-podman.md); this doc owns the shared image store.

### Current state (2026-06-07)

**Proven working on overlay (exercised live, not via the vfs proxy):**
- `/dev/fuse` present, driver `overlay`, fuse-overlayfs 1.10; `podman info` exits 0
  with no `CONTAINERS_CONF` override — Prerequisites 1 and 2 below are both met.
- Store seeded at `/mnt/podman-imagestore`; `storage.conf` carries
  `additionalimagestores`. All four curated images resolve **`R/O: true`** in the
  consumer and nothing copies into the per-container writable `overlay-images/`
  (only `images.lock` there). That settles open question #1 **and** the read-only
  sharing model **on overlay**, not just on the vfs proxy.

**Blocker found + fixed (pending rebuild):** nested `podman run` failed for two
outer-container reasons invisible to `podman info` — (1) `/dev/net/tun` was never
passed in, so slirp4netns/pasta networking dies on every run; and (2) the host
runtime's default seccomp profile stacks onto every descendant and blocks the
syscalls crun needs (`keyctl` and `pivot_root` return EPERM), so even
`--network=none` died at "create keyring"/"pivot_root". Fixed: `security_opt:
seccomp=unconfined + apparmor=unconfined` in `compose.shared.yml` (commit `17e42b1`),
and the two host devices each in their own overlay — `/dev/fuse` in
`compose.fuse.yml`, `/dev/net/tun` in `compose.netdev.yml` — both gated by the
single `POWBOX_PODMAN` switch (`POWBOX_FUSE` is the deprecated alias). See
[rootless-podman.md](rootless-podman.md) for the full run-path validation this
unblocks.

**Next session — how to resume after the rebuild:** the base image was bumped from
Debian bookworm to **Debian 13 (`node:24-trixie-slim`, Podman 5.4.2)** on this
branch (to fix the Podman-4.3.1 compose-subcommand gap — see
[rootless-podman.md](rootless-podman.md) → "Compose command compatibility" and "How
to resume after the rebuild"). So this is a **base-OS upgrade**, not just a compose
tweak — rebuild **base + agent** and relaunch with `POWBOX_PODMAN=on` first. Then:
1. Follow the run-path resume checklist in
   [rootless-podman.md](rootless-podman.md#how-to-resume-after-the-rebuild-next-session)
   (confirm `podman --version` → 5.4.2, `/proc/sys` now `rw`, devices present).
2. Confirm the two prerequisites below still hold on the trixie image
   (`podman info` exits 0, driver `overlay`) — fuse-overlayfs is now **1.14** on
   trixie, so re-confirm overlay + `additionalimagestores` resolve `R/O: true` once
   (the path semantics are driver-independent but the version changed).
3. Run the **Validation plan** below — the still-open items need a *second*
   container (cross-container sharing, step 3) which couldn't be exercised from
   inside the single running container: open question #4 (read-while-write) and #5
   (concurrent cross-container pull during a seed).
4. Update the user-facing docs (step 6).

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
  from "planned" to "done", linking here. (That doc's "What changed" table, known
  risk #2, and its missing-`/dev/net/tun` gap were updated alongside commit
  `17e42b1` — re-check the validation-prompt results table after rebuild.)

## Open questions — VALIDATE on the rebuilt host

These are the unverified Podman mechanics. Resolve each by running, not guessing:

1. **Additional-store path.** RESOLVED on vfs **and overlay** (2026-06-07): on the
   rebuilt overlay host the four curated images resolve `R/O: true` from the bare
   graphroot mount, nothing copied into the writable store. It wants the **graphroot**
   (`/mnt/podman-imagestore`), NOT the driver subdir
   (`/mnt/podman-imagestore/overlay`). Proof: a separate consumer with
   `additionalimagestores = ["<graphroot>"]` in storage.conf resolved a seeded
   image read-only (`ReadOnly=true`); appending `/vfs` or `/vfs-images` resolved
   nothing. So the entrypoint should point at the bare mount dir.
2. **Seeder invocation.** RESOLVED on overlay (2026-06-07): the entrypoint's
   background seed pulled all four curated images with plain
   `podman --root "$STORE" --storage-driver overlay pull …` — no explicit
   `--runroot`/`--storage-opt` needed — and consumers resolve them `R/O: true`
   with nothing copied down, so the resulting layout needs nothing extra (no
   `podman image trust`, perms tweak, or lock file) before a read-only consumer
   can use it.
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
5. **Background first-run seed.** PARTIALLY RESOLVED on overlay (2026-06-07): on
   first boot the entrypoint's backgrounded `seed-image-store.sh seed` survived
   `exec "$@"` and ran to completion — `/tmp/powbox-image-store-seed.log` ends
   `Image store: 4 pulled, 0 present, 0 failed` and the `.powbox-image-store-seeded`
   marker was written ~1 min after container start. Still untested: an agent in
   another container pulling the same image concurrently into its own graphroot
   while a seed is mid-flight not deadlocking on the store. Worst acceptable case:
   the image just isn't shared yet and the agent pulls its own copy.
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

Now also validated **on overlay** (2026-06-07, rebuilt `/dev/fuse` host): the
overlay image-store happy path end-to-end (seed → consumer resolves all four
curated images `R/O: true` → nothing copied into the writable graphroot), settling
open questions #1 and the read-only sharing model on overlay (above).

Still unverified — these need the next rebuild (≥ commit `17e42b1`) because they
depend on actually **running** a nested container, which only worked after the
`/dev/net/tun` + seccomp fix: the true driver-mismatch case is now moot (overlay
everywhere), but read-while-write (#4) and the backgrounded first-run seed
surviving `exec "$@"` (#5) still want a check, plus the cross-container sharing
test (Validation plan step 3) and the whole run-path suite in
[rootless-podman.md](rootless-podman.md).

**Update 2026-06-07 (run validation, Claude):** the run path was exercised for the
first time. The shared store is now confirmed **consumed by a real `podman run`**,
not just by inspection — `podman images --all` shows all four curated images
`R/O=true`, the step-2 postgres started from the shared copy with no layer pull,
and only the non-curated probe images (`alpine`, `hello-world`) landed in the
writable per-container graphroot (`overlay-images/`), so write isolation holds.
Cross-**container** sharing (Validation plan step 3) and read-while-write (#4)
still need a second container, which can't be launched from inside. The run-path
suite itself surfaced a new sysctl blocker (read-only `/proc/sys`, fixed via
`systempaths=unconfined` in `compose.shared.yml`, pending relaunch) and a Podman
4.3.1 compose-subcommand gap — both owned by [rootless-podman.md](rootless-podman.md).

## Enabling the Podman devices (`/dev/fuse` + `/dev/net/tun`) (WSL2 / Windows 11 host)

The launcher attaches the two devices rootless Podman needs — `/dev/fuse` (overlay
storage driver, via `compose.fuse.yml`) and `/dev/net/tun` (nested networking, via
`compose.netdev.yml`) — by adding those files to the `-f` chain (`docker compose
run` has no `--device` flag, only `docker run` does). Both ride under one gate,
`POWBOX_PODMAN` (`POWBOX_FUSE` is the deprecated alias): `on` forces both, the
default `auto` attaches each device the **shell that runs the launcher** can
already see, `off` skips both. `SYS_ADMIN` and the unconfined seccomp/apparmor
profile are already in `compose.shared.yml`, so these devices are the only
remaining host-side gate. Where they must exist depends on how Docker runs:

- **Docker Desktop (WSL2 backend)** — the common Windows 11 case. Containers run in
  Docker Desktop's *own* managed VM, not your distro, and that VM ships both
  `/dev/fuse` and `/dev/net/tun`. But `auto` checks the launcher's shell (Windows
  PowerShell has no `/dev`; a WSL2 distro's `/dev` doesn't reflect the Docker VM),
  so `auto` under-detects and skips both (→ vfs **and** no nested networking).
  **Force it: `POWBOX_PODMAN=on`.**
  - PowerShell: `$env:POWBOX_PODMAN='on'; .\scripts\launch-agent.ps1 …`
  - bash/WSL: `POWBOX_PODMAN=on ./scripts/launch-agent.sh …`
  - If `POWBOX_PODMAN=on` hard-fails at `docker … run` with a device error, the
    Docker VM isn't exposing that device — update Docker Desktop and run
    `wsl --update` (Windows) for a current kernel, then retry.
- **Docker engine native inside a WSL2 distro** (docker-ce in Ubuntu, no Docker
  Desktop) — containers share the distro kernel + `/dev`, so both devices must
  exist in that distro (here `auto` actually works):
  - `ls -l /dev/fuse /dev/net/tun` — if present, `auto` passes them (`on` also works).
  - If `/dev/fuse` is missing: `sudo modprobe fuse` (Microsoft's WSL2 kernel ships
    the module); confirm with `grep fuse /proc/filesystems`. Persist with a
    `/etc/modules-load.d/fuse.conf` containing `fuse`.
  - If `/dev/net/tun` is missing: `sudo modprobe tun`; confirm with
    `grep tun /proc/misc`. Persist with `/etc/modules-load.d/tun.conf` containing
    `tun`. Keep the kernel current via `wsl --update` + `wsl --shutdown` from Windows.

**After relaunch, verify inside the new container:** `ls -l /dev/fuse /dev/net/tun`
(both present) and `podman info --format '{{.Store.GraphDriverName}}'` → `overlay`.

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

This plan covers the **shared image store** only. The container-**run** path
(pull+run, persistent volumes, compose + DNS, firewall inheritance) lives in
[rootless-podman.md](rootless-podman.md)'s validation prompt — run that too, since
steps 3–4 below now depend on a working `podman run` (unblocked by commit
`17e42b1`). Run inside a freshly rebuilt container (overlay, `/dev/fuse` +
`/dev/net/tun` present, `POWBOX_PODMAN=on`):

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
