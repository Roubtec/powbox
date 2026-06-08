# Rootless containers inside the sandbox (Podman)

**Status:** implemented and **validated end-to-end on the trixie/Podman-5.4.2 base**
(2026-06-07). **Update 2026-06-07 (post-rebuild validation, Claude):** ran the full
validation prompt in the first container built on the Debian 13 base. Everything
that was PARTIAL/FAIL on bookworm/4.3.1 now **PASSES**: `podman --version` → 5.4.2;
`/proc/sys` is `rw` (no longer a masked ro mount → `systempaths=unconfined` took);
`keyctl ok`; both devices present; default-network run, persistent named volumes,
**compose stacks with published ports on a bridge network**, aardvark inter-container
DNS, egress-firewall inheritance, and **`podman build` with a networked RUN** all
pass; `podman compose` (native subcommand) **and** `docker compose` (shim) both work.
One **new** blocker surfaced and was fixed: Podman 5.x's netavark defaults its
firewall driver to **nftables**, but the image ships no `nft` binary, so every bridge
network / published port died with `netavark: nftables error: unable to execute nft`.
Fixed by setting `firewall_driver = "iptables"` in the `containers.conf` drop-in
(`docker/shared/containers.conf`) — we already ship `iptables` (nf_tables-backed) for
the agent's own egress firewall, so netavark reuses it with no new package. This was
validated live via a user `containers.conf` override; the baked drop-in change was
**since confirmed working on a freshly-rebuilt second container** (which carried the
bake natively, no override). That second container also closed the last open
image-store items — cross-container sharing and read-while-write both **PASS** (see
[podman-shared-image-store.md](podman-shared-image-store.md)). Filled-in post-rebuild
results in **Results** below.

**Update 2026-06-07:** validation found that nested
containers could pull/build/store images but could not **run** — `/dev/net/tun`
was not passed in (networking) and the host's default seccomp profile blocked
`keyctl`/`pivot_root` (crun's keyring + pivot_root). Both are fixed by the run-path
changes, with the two devices split across overlays: `/dev/net/tun` rides its own
`compose.netdev.yml`, `/dev/fuse` stays in `compose.fuse.yml`, both gated by the
single `POWBOX_PODMAN` switch (`POWBOX_FUSE` is the deprecated alias);
`compose.shared.yml` adds `security_opt: seccomp=unconfined + apparmor=unconfined`.
Those take effect on the next base+agent rebuild — rebuild, relaunch with
`POWBOX_PODMAN=on`, then run
the validation procedure below (it could not have passed before this fix). The
shared read-only image store (see [podman-shared-image-store.md](podman-shared-image-store.md))
is validated on overlay.

**Update 2026-06-07 (run validation, Claude):** ran the validation procedure in
the first container rebuilt with the seccomp + tun fixes — they work (containers
**run** now). Doing so surfaced a **third sysctl blocker**: the host masks
`/proc/sys` read-only, so crun's `ping_group_range` (every run) and netavark's
`route_localnet` (published ports on a bridge → every compose stack) EPERM. Fixed
by adding `systempaths=unconfined` to `compose.shared.yml` — **pending the next
rebuild + relaunch** (couldn't be tested in-place). Validated PASS this round:
engine sanity, image pull, default-network run, persistent named volumes,
published ports on the default network, egress-firewall inheritance, and aardvark
inter-container DNS. Still open: published ports on bridge/compose networks (the
`systempaths` fix, pending relaunch) and a tooling gap — Podman 4.3.1 has no
`podman compose`/`docker compose` subcommand (only `podman-compose` works); see
**Compose command compatibility**. Filled-in results in **Results** below.

**Update 2026-06-07 (compose-tooling resolution + base upgrade, Claude):** the
Podman-4.3.1 compose gap is fixed by moving the base from bookworm to **Debian 13
(`node:24-slim` → `node:24-trixie-slim`) → Podman 5.4.2**, applied to
`docker/base/Dockerfile` on this branch (validated in a nested `debian:trixie`
container; staying on Node 24 LTS — the Node version doesn't affect Podman). This
is a base-OS bump, so it **must be rebuilt + relaunched** before anything else —
**start the next session at [How to resume after the rebuild](#how-to-resume-after-the-rebuild-next-session)**, which lists the rebuild, the post-rebuild
environment checks (`podman --version` → 5.4.2, `/proc/sys` now `rw`), and the two
validations to re-run (compose + published ports, and `podman build` RUN). See
**Compose command compatibility** for the migration details.

## Why

Some projects need Dockerized backing services (databases, Adminer, service
stacks). We want an in-sandbox agent to build, run, and orchestrate those
containers itself — hands-free — **without weakening the sandbox**.

The two "easy" routes both delete the sandbox and were rejected:

- **Host Docker socket (DooD):** anyone with the socket is root on the host in
  one `docker run -v /:/host …`. Hard no.
- **Privileged `dockerd` (classic DinD):** needs `--privileged`, which drops the
  isolation that the whole sandbox exists to provide. No.

So we use **rootless Podman**: it runs as the unprivileged `node` user through a
user namespace. No privileged daemon, no host socket — the blast radius stays
inside this container. A `docker` shim and `podman compose` mean existing
`docker` / `docker compose` muscle memory and project scripts keep working.

A neat security property falls out of this: rootless Podman NATs nested
containers' outbound traffic through *this* container's network namespace, so
nested containers **inherit the egress firewall** (`init-firewall.sh`) — they
reach the public internet but not your LAN/host, exactly like the agent itself.

The known ceiling (when to graduate to a full Ubuntu VM): GUI apps, phone
emulators, or a non-headless browser. Track that separately.

## What changed

| File | Change |
|------|--------|
| `docker/base/Dockerfile` | New apt layer installing `podman`, `podman-docker`, `podman-compose`, `uidmap`, `fuse-overlayfs`, `slirp4netns`, `passt`, `crun`, `netavark`, `aardvark-dns`, `catatonit`; writes `/etc/subuid`+`/etc/subgid` ranges for `node`; `touch /etc/containers/nodocker`. Sets `ENV XDG_RUNTIME_DIR=/home/node/.local/run`. Placed low so it doesn't bust the gh/mssql/pwsh/npm layers. |
| `docker/shared/containers.conf` | New engine drop-in → `/etc/containers/containers.conf.d/10-powbox.conf`: `cgroup_manager=cgroupfs`, `events_logger=file` (no systemd/journald in-container), `network_backend=netavark`, **`firewall_driver=iptables`** (2026-06-07 — Podman 5.x netavark defaults to nftables, which needs an `nft` binary the image lacks; we already ship `iptables`/nf_tables for the egress firewall, so netavark reuses it). |
| `compose.shared.yml` | `security_opt: seccomp=unconfined` + `apparmor=unconfined` **plus `systempaths=unconfined`** (2026-06-07). seccomp/apparmor unblock the syscalls crun needs to RUN (`keyctl`, `pivot_root` → EPERM); `systempaths=unconfined` makes the Docker-masked read-only `/proc/sys` writable so crun can set `ping_group_range` (every run) and netavark can set `route_localnet` (published ports on bridge networks) — without it both EPERM. Acceptable because this container + its egress firewall ARE the boundary. |
| `compose.fuse.yml` | Optional overlay (added to the `-f` chain by the `POWBOX_PODMAN` gate) carrying `/dev/fuse` for the overlay storage driver; absent → vfs fallback. `docker compose run` has no `--device` flag, hence a compose file. |
| `compose.netdev.yml` | Optional overlay carrying `/dev/net/tun` for nested-container networking (slirp4netns/pasta; without it every default `podman run` fails). Same `POWBOX_PODMAN` gate as `compose.fuse.yml`, but a separate file so the two devices attach independently under `auto`. |
| `docker/shared/entrypoint-core.sh` | At startup (guarded by `command -v podman`): create `XDG_RUNTIME_DIR` mode 700; pick storage driver — keep the image default (overlay + fuse-overlayfs) when `/dev/fuse` is present, else write a user `storage.conf` selecting the slower `vfs` driver. |
| `scripts/launch-agent.sh` | New per-container volume `agent-podman-<agent>-<project>` mounted at `/home/node/.local/share/containers` (images + named volumes persist across restarts), created+chowned in the existing root pre-run. Adds `compose.fuse.yml` + `compose.netdev.yml` to the `-f` chain to attach `/dev/fuse` + `/dev/net/tun` per the `POWBOX_PODMAN` gate (`on` forces both, `auto` detects each, `off` neither; `POWBOX_FUSE` is the deprecated alias). |
| `docker/shared/container-agent.md.tmpl` | Documents the capability for the in-container agent (tooling row, filesystem row, network note). |

### Design decisions / rationale

- **Rootless, not rootful.** Preserves the sandbox boundary. SYS_ADMIN is
  already granted (for the tmpfs shadow mounts), which also helps Podman mount.
- **Per-container storage volume** (`agent-podman-<agent>-<project>`). Persists
  each container's images and DB data across recreation. Keyed by the OUTER
  container (agent + project), not just the project: a project's Claude and Codex
  containers can run concurrently, and a Podman graphroot is a single locked
  layer+metadata store — two Podman instances with separate runroots/namespaces
  pointing at one graphroot cause name conflicts, cross-instance stale-state
  cleanup, and failed lifecycle ops. (Sharing the graphroot would not even let
  the two outer containers collaborate: they have separate network namespaces, so
  a nested service started by one is unreachable from the other.) Trade-off:
  images re-pull per container. The fix for that is a shared *read-only* image
  store (`additionalimagestores`) layered under each per-container writable
  graphroot — see Follow-ups.
- **fuse-overlayfs with vfs fallback.** fuse-overlayfs needs `/dev/fuse`; the
  launcher passes it when present. If it's missing (or `POWBOX_PODMAN=off`),
  entrypoint-core drops a user `storage.conf` selecting `vfs` so Podman still
  works — slower and more disk, but functional.
- **`localhost`-published ports are the access path.** Reach a nested service
  from the agent via its published port on `localhost` (loopback is ACCEPTed by
  the firewall); container-to-container uses service names over netavark/aardvark.

## Rebuilding for testing

The **base image changed**, so rebuild base then agent (not just agent):

```bash
# from the powbox repo on this branch
./build.sh base && ./build.sh agent
```

Then launch an agent into a throwaway project to validate (a fresh container so
the new base/volume wiring takes effect — use a scratch dir, not this repo):

```bash
mkdir -p /tmp/podman-probe
cc /tmp/podman-probe --build      # cc = claude; cx for codex. --build is optional after the explicit build above.
```

> If an old container for that project already exists, recreate it
> (`cc … --volatile`) so it picks up the new `/dev/fuse` device and storage
> volume — existing containers were created without them.

## Validation prompt (hand this to a fresh agent inside the rebuilt container)

Copy everything in the block below to a freshly spawned agent running **inside**
a newly built container. It runs read-mostly probes plus a couple of disposable
containers, then cleans up, and reports a filled-in results table.

```text
You are inside a powbox sandbox container that just gained rootless Podman support.
Validate it end to end and report results. Run the steps in order; for each, record
PASS/FAIL and the key output. Do NOT stop on first failure — capture it and continue,
since later independent steps still inform us. Clean up at the end.

0. Engine sanity
   - `id` → confirm uid=1000(node), not root.
   - `command -v podman docker podman-compose` → all present.
   - `cat /etc/subuid /etc/subgid` → both contain a `node:` line.
   - `echo "$XDG_RUNTIME_DIR"; ls -ld "$XDG_RUNTIME_DIR"` → exists, mode 700, owned node.
   - `ls -l /dev/fuse` → note present/absent.
   - `ls -l /dev/net/tun` → MUST be present (else every `podman run` fails at
     slirp4netns; attached via compose.netdev.yml under POWBOX_PODMAN).
   - `python3 -c "import ctypes,ctypes.util;l=ctypes.CDLL(ctypes.util.find_library('c'),use_errno=True);print('keyctl ok' if l.syscall(250,1,0)>=0 else 'keyctl EPERM — seccomp still blocking, run will fail')"`
     → expect `keyctl ok` (proves the seccomp=unconfined fix took; EPERM means the
     rebuild/relaunch didn't pick up compose.shared.yml).
   - `podman info --format '{{.Host.Security.Rootless}} | {{.Store.GraphDriverName}} | {{.Host.CgroupManager}} | {{.Host.NetworkBackend}} | {{.Store.GraphRoot}}'`
     Expect: `true | overlay | cgroupfs | netavark | /home/node/.local/share/containers/storage`
     (GraphDriverName is `vfs` instead if /dev/fuse was absent — that's an expected fallback, note it.)

1. Pull + run
   - `podman run --rm docker.io/library/hello-world` → succeeds (proves pull over the
     firewall to docker.io + run).
   - `podman run --rm docker.io/library/alpine echo ok` → prints `ok`.

2. Persistent named volume (the DB-data use case)
   - `podman volume create probe-pgdata`
   - `podman run -d --name probe-pg -e POSTGRES_PASSWORD=secret \
        -v probe-pgdata:/var/lib/postgresql/data -p 5432:5432 \
        docker.io/library/postgres:16-alpine`
   - Poll up to ~30s: `podman exec probe-pg pg_isready -U postgres` → "accepting connections".
   - Write data: `podman exec probe-pg psql -U postgres -c \
        "create table probe(x int); insert into probe values (42);"`
   - Reach it from THIS container over the published port (validates the loopback path
     through the firewall; php8.4-pgsql is preinstalled):
     `php -r '$c=@pg_connect("host=127.0.0.1 port=5432 user=postgres password=secret dbname=postgres");
        if(!$c){fwrite(STDERR,"connect failed\n");exit(1);}
        echo pg_fetch_result(pg_query($c,"select x from probe"),0,0),"\n";'`
     → prints `42`.
   - Persistence across container recreation: `podman rm -f probe-pg`, then re-run the
     same `podman run …` command above with the same `-v probe-pgdata:…`, wait for
     pg_isready, then `podman exec probe-pg psql -U postgres -c "select count(*) from probe;"`
     → count is `1` (data survived because it lives in the named volume).

3. Compose + inter-container DNS
   - Write /tmp/probe-compose/docker-compose.yml with two services on the default network:
       services:
         db:
           image: docker.io/library/postgres:16-alpine
           environment: { POSTGRES_PASSWORD: secret }
         adminer:
           image: docker.io/library/adminer
           ports: ["8080:8080"]
   - `cd /tmp/probe-compose && podman compose up -d` (also try `docker compose up -d` to
     confirm the docker shim routes to podman).
   - `curl -fsS http://localhost:8080 | head -c 200` → returns Adminer HTML (published port works).
   - Confirm adminer resolves `db` by service name (aardvark-dns):
     `podman exec "$(podman ps --filter name=adminer -q | head -n1)" \
        sh -c 'getent hosts db || nslookup db || true'` → resolves to an internal IP.
   - `podman compose down`

4. Firewall inheritance (security invariant)
   - `podman run --rm docker.io/library/alpine sh -c \
        'wget -T5 -qO- https://example.com >/dev/null 2>&1 && echo PUBLIC_OK || echo PUBLIC_FAIL;
         wget -T3 -qO- http://192.168.1.1 >/dev/null 2>&1 && echo LAN_REACHED || echo LAN_BLOCKED'`
     → expect `PUBLIC_OK` and `LAN_BLOCKED`. (LAN_REACHED would mean nested containers
       bypass the egress firewall — a real finding, report loudly.)

5. Cleanup
   - `podman rm -f probe-pg 2>/dev/null; podman volume rm probe-pgdata 2>/dev/null`
   - `podman compose -f /tmp/probe-compose/docker-compose.yml down 2>/dev/null; rm -rf /tmp/probe-compose`
   - Leave pulled images in place (they're cached in the persistent volume).

Report a table: step | PASS/FAIL | evidence (1 line). Then a short verdict:
is rootless Podman usable for hands-free dev here, and did any step need a workaround
(e.g. seccomp/apparmor, vfs fallback)? If something failed, include the exact error.
```

## Results

_Fill this in after running the validation prompt so we keep continuity across sessions._

_Run 2026-06-07 (Claude), **post-rebuild on the trixie/Podman-5.4.2 base** with
`POWBOX_PODMAN=on`. First container on the Debian 13 base; this is the run that
cleared the two previously-blocked rows (compose+published-ports and build RUN) and
surfaced the netavark-nftables finding._

| Step | PASS/FAIL | Notes |
|------|-----------|-------|
| 0. Engine sanity | **PASS** | uid=1000(node); podman/docker/podman-compose present; subuid/subgid `node:` lines OK; `XDG_RUNTIME_DIR` 700; **both `/dev/fuse` and `/dev/net/tun` present**; `keyctl ok`; **`/proc/sys` now `rw`** (no longer a masked ro mount — `systempaths=unconfined` took); `podman --version` → **5.4.2**; `podman info` → `true \| overlay \| cgroupfs \| netavark \| …/storage`. |
| 1. Pull + run | **PASS** | `hello-world` + `alpine echo ok` both run with **no** `ping_group_range` EPERM (the read-only `/proc/sys` blocker is gone). |
| 2. Persistent volume | **PASS** (prior run) | Re-confirmed from the earlier run: postgres on a named volume, reachable over published `127.0.0.1:5432`, data survives recreate. |
| 3. Compose + published ports + DNS | **PASS** | After the `firewall_driver=iptables` fix (see below): `docker compose up -d` **and** `podman compose up -d` both bring up db+adminer; `curl http://localhost:8080` returns Adminer HTML (**published port on a bridge network works** — netavark `route_localnet`/DNAT succeed on the now-writable `/proc/sys`); aardvark resolves `db` → `10.89.0.2`. Native `podman compose` subcommand exists on 5.4.2 (delegates to `podman-compose` 1.3.0). |
| 3b. `podman build` networked RUN | **PASS** | `Containerfile` with `RUN apk add curl && curl https://example.com` builds clean (`networked RUN ok`) — the read-only `/proc/sys` build-RUN failure is gone. |
| 4. Firewall inheritance | **PASS** | Nested container: `PUBLIC_OK` + `LAN_BLOCKED` — egress firewall still inherited even with netavark's iptables driver adding its own chains. |
| Image store | **PASS** | `seed-image-store.sh status` → mounted/overlay/seeded; the 4 curated images resolve `RO=true` (shared store), the two probe pulls (`alpine`,`hello-world`) are `RO=false` (per-container writable graphroot) — write isolation holds. Cross-*container* sharing + read-while-write **since confirmed PASS** from a second container (see [podman-shared-image-store.md](podman-shared-image-store.md)). |

**New finding (fixed): netavark nftables driver / no `nft` binary.** First `docker
compose up` failed with `netavark: nftables error: unable to execute nft: No such
file or directory`. Podman 5.x's netavark defaults `firewall_driver` to `nftables`,
which shells out to `nft`; the image has no `nftables` package. The image *does* ship
`iptables` v1.8.11 (nf_tables backend) for the agent's own egress firewall, so the
fix is `firewall_driver = "iptables"` in the `containers.conf` drop-in — netavark
then drives the existing `iptables`, no new package, everything on one firewall
interface. Validated live with a user `~/.config/containers/containers.conf` override
(the baked drop-in change takes effect next rebuild).

**Host:** WSL2 (Docker Desktop backend) — **/dev/fuse + /dev/net/tun present:** y —
**storage driver:** overlay — **/proc/sys:** rw — **Podman:** 5.4.2.

**Verdict (post-rebuild):** rootless Podman is now **fully usable for hands-free dev
here** — pull, run, persistent named volumes, **compose stacks with published ports**,
inter-container DNS, networked image builds, and the shared read-only image store all
work, and the egress firewall is still inherited (`LAN_BLOCKED`). The only required
workaround beyond the unconfined seccomp/apparmor/systempaths profile is the one-line
`firewall_driver=iptables` (now baked in `docker/shared/containers.conf` and confirmed
on a freshly-rebuilt second container). Cross-container image-store sharing and
read-while-write — the last open items — also **PASS** (see
[podman-shared-image-store.md](podman-shared-image-store.md)). No open items remain.

---

_Run 2026-06-07 (Claude), inside a container rebuilt with the device-passthrough
split (`POWBOX_PODMAN`) and `POWBOX_PODMAN=on`. This is the first container that could attempt a real `podman
run` — and doing so surfaced a third sysctl blocker (read-only `/proc/sys`) below._

| Step | PASS/FAIL | Notes |
|------|-----------|-------|
| 0. Engine sanity | **PASS** | uid=1000(node); podman/docker/podman-compose present; subuid/subgid `node:` lines OK; `XDG_RUNTIME_DIR` 700; **both `/dev/fuse` and `/dev/net/tun` present**; `keyctl ok` (seccomp=unconfined fix took); `podman info` → `true \| overlay \| cgroupfs \| netavark \| …/storage`. |
| 1. Pull + run | **PASS\*** | Pull over the firewall + image-store wiring fine. \*Raw `podman run` **FAILED** on `crun: open /proc/sys/net/ipv4/ping_group_range: Read-only file system`; PASS after neutralising that sysctl (see blocker below — real fix `systempaths=unconfined`, pending relaunch). |
| 2. Persistent volume | **PASS** | postgres:16-alpine on `probe-pgdata`; reached over published `127.0.0.1:5432` from this container (got `42`); data survived `rm -f` + re-run (count `1`). Default-network `-p` works (rootlessport handler). |
| 3. Compose + DNS | **PARTIAL** | Inter-container DNS via aardvark **PASS** (`db` → `10.89.1.2`); bridge networking **PASS**. **Published ports on a bridge/compose network FAIL**: `netavark: Sysctl error: … Read-only file system` (route_localnet) — same `/proc/sys` root cause. Also: **`podman compose` / `docker compose` don't exist on Podman 4.3.1** — only `podman-compose` (Python) works (see tooling gap below). |
| 4. Firewall inheritance | **PASS** | Nested container: `PUBLIC_OK` + `LAN_BLOCKED` — egress firewall inherited, LAN/host still blocked. |

**Host:** WSL2 (Docker Desktop backend; `/proc/sys` masked read-only) — **/dev/fuse present:** y — **storage driver:** overlay

**Verdict:** Rootless Podman genuinely **runs** nested containers here now (the
seccomp + `/dev/net/tun` fixes work): images pull, default-network containers run,
named volumes persist, published ports on the **default** network are reachable
over loopback, the egress firewall is inherited, and aardvark inter-container DNS
resolves. **Two gaps remain before compose stacks with published ports work
hands-free:**

1. **Read-only `/proc/sys`** (Docker masks it) blocks two sysctl writes Podman
   needs: crun's default `ping_group_range` on *every* run (including `podman build`
   RUN steps — so image builds with a networked RUN fail too), and netavark's
   `route_localnet` whenever a **bridge network publishes a port** (i.e. nearly
   every compose stack). Fixed by adding `systempaths=unconfined` to
   `compose.shared.yml` (commit on this branch) — **needs a base+agent rebuild +
   relaunch to validate** (could not be tested in-place: `node` has no caps to
   remount `/proc/sys`). A confirmed in-container *workaround* for the crun half
   only is `~/.config/containers/containers.conf` with `[containers]
   default_sysctls = []`, but that doesn't fix the netavark/published-port half and
   disables container `ping` — `systempaths=unconfined` is the real fix.
2. **Podman 4.3.1** (Debian bookworm) has **no `compose` subcommand** — so
   `podman compose …` and `docker compose …` (the shim is `exec podman "$@"`) both
   fail with "unrecognized command", and there is no `docker-compose` binary. Only
   `podman-compose` (Python, v1.0.3) works. This contradicts the base Dockerfile
   comment and the agent-facing docs, and breaks project scripts that call
   `docker compose`. **RESOLVED on this branch** by moving the base to Debian 13
   (`node:24-trixie-slim` → Podman 5.4.2, which has the native subcommand) — pending
   the rebuild. See **Compose command compatibility** below.

## Known risks & likely fixes (if validation fails)

- **`/dev/fuse` not passed on WSL2/Docker Desktop.** The launcher auto-detects on
  the host running `cc`; if that host lacks the node but the daemon has it,
  force it: `POWBOX_PODMAN=on cc <project> --volatile`. Otherwise it falls back to
  vfs (works, slower).
- **Run blocked by the host security profile — CONFIRMED + APPLIED
  (`compose.shared.yml` `security_opt`).** This was predicted here as a conditional "if needed" loosening; it
  turned out to be required. The default seccomp profile the host runtime applies
  to this container stacks onto every descendant process, including the user
  namespaces rootless Podman creates to run a nested container, and blocks the
  syscalls crun needs: `keyctl` (crun's session keyring — needs no capability, yet
  EPERMs, which is the tell that it's seccomp not caps) and `pivot_root`. Symptom:
  `podman run` fails at `create keyring … Operation not permitted`, and with
  `--network=none` it gets one step further to `pivot_root … Operation not
  permitted`. Fix applied: `security_opt: seccomp=unconfined` (+ `apparmor=unconfined`
  for hosts that enforce the docker-default apparmor profile) in `compose.shared.yml`.
  Acceptable because the container + egress firewall ARE the boundary and it already
  runs `--dangerously-*`.
- **No nested networking — `/dev/net/tun` missing (CONFIRMED + APPLIED via
  `compose.netdev.yml`).** Every `podman run` failed with `slirp4netns … open("/dev/net/tun"):
  No such file or directory` — the tun device node was never passed into the agent
  container (the kernel module is present on the host, just not exposed). slirp4netns
  AND pasta both need it. Fix: `/dev/net/tun` added in its own `compose.netdev.yml`,
  gated by the `POWBOX_PODMAN` switch (the deprecated `POWBOX_FUSE` alias still works).
  It's a separate file from `compose.fuse.yml` so the two devices attach
  independently under `auto` — a host with tun but not fuse still gets networking on
  vfs. Caveat: `POWBOX_PODMAN=off` skips both devices (no overlay, no networking).
- **Sysctl writes fail — read-only `/proc/sys` (CONFIRMED 2026-06-07; FIX APPLIED
  in compose, PENDING relaunch).** Surfaced only once a container could actually
  `podman run` (after the seccomp + tun fixes). The host runtime mounts `/proc/sys`
  **read-only** (Docker's default `ReadonlyPaths`), but Podman must *write* sysctls
  to start a container, and two writes EPERM:
  - crun sets the default `net.ipv4.ping_group_range` on **every** run →
    `crun: open /proc/sys/net/ipv4/ping_group_range: Read-only file system`. So
    every default-network `podman run` failed (`hello-world`, `alpine echo`).
  - netavark sets `net.ipv4.conf.<bridge>.route_localnet` (+ forwarding) whenever a
    **bridge network publishes a port** → `netavark: Sysctl error: … Read-only file
    system`. So `-p` on a custom network and essentially every compose stack failed.
    (The rootless **default** network + `-p` survives — it uses the rootlessport
    handler, not a netavark bridge — which is why single `podman run -p` on the
    default net works but compose does not. Bridge networking *without* a published
    port and aardvark DNS both work.)

  Fix applied: add `systempaths=unconfined` to `security_opt` in
  `compose.shared.yml`, which unmasks `/proc/sys` (and Docker's other masked `/proc`
  paths) so both writes succeed. Same boundary rationale as seccomp/apparmor.
  **Takes effect on the next base+agent rebuild + relaunch** — it could not be
  tested in-place (`node` holds no caps; remounting `/proc/sys` rw or `sudo` both
  refused). Narrow interim workaround for the `podman run` default-network half
  only: `printf '[containers]\ndefault_sysctls = []\n' > ~/.config/containers/containers.conf`
  — but it disables container `ping`, does **not** fix published ports, and (tested)
  does **not** fix `podman build` RUN steps either (buildah re-applies the sysctl,
  so `podman build` with a networked `RUN` still fails `open …/ping_group_range:
  Read-only file system`). `systempaths=unconfined` is the only fix that covers all
  three (default run, published ports, build RUN).
- **netavark can't run `nft` — `nftables error: unable to execute nft` (CONFIRMED
  2026-06-07 on Podman 5.4.2; FIX APPLIED in the drop-in).** Only surfaced once the
  base moved to trixie/Podman 5.x: netavark 1.x defaults `firewall_driver` to
  `nftables`, which shells out to the `nft` binary — not installed in the image. So
  every **bridge network** (i.e. every compose stack) and every **published port**
  failed at container start with `netavark: nftables error: unable to execute nft:
  No such file or directory`. The default rootless network + `-p` (rootlessport, no
  netavark bridge) still worked, which is why single `podman run -p` survived but
  compose did not — the same split as the old `/proc/sys` blocker, different cause.
  Fix: `firewall_driver = "iptables"` in `docker/shared/containers.conf` — the image
  already ships `iptables` v1.8.11 (nf_tables backend) for the agent's egress
  firewall, so netavark reuses it; no `nftables` package needed and the whole
  container stays on one firewall interface. Alternative (not taken): `apt-get
  install nftables` and keep netavark's nftables default — rejected to avoid image
  bloat and mixing native-nft (netavark) with iptables-nft-compat (init-firewall)
  rule styles. Takes effect on the next rebuild; validated in-place via a user
  `~/.config/containers/containers.conf` override.
- **`newuidmap: write to uid_map failed`.** Means the `/etc/subuid`/`/etc/subgid`
  ranges didn't take; verify the apt layer wrote the `node:` lines and that
  `uidmap` is installed (`which newuidmap`).
- **`podman compose` / `docker compose` say "unrecognized command" (CONFIRMED
  2026-06-07).** Podman 4.3.1 (Debian bookworm) has **no `compose` subcommand** —
  that delegating wrapper only exists in Podman ≥ 4.7. The `docker` shim is
  `exec podman "$@"`, so `docker compose …` hits the same wall, and there is no
  `docker-compose` binary. **Only `podman-compose` (Python, v1.0.3) works** today.
  This contradicts the base Dockerfile comment ("`podman-compose` backs
  `docker compose` / `podman compose`") and the agent-facing docs. See **Compose
  command compatibility** below for the fix options.
- **First run after upgrading an existing project container.** Recreate it
  (`cc … --volatile`) so the new device + storage volume attach.

## Compose command compatibility — RESOLVED by moving the base to Debian 13 (trixie)

**Decision (2026-06-07):** upgrade Podman by moving the base image to Debian 13
(`node:24-slim` → `node:24-trixie-slim`), which ships **Podman 5.4.2** — applied on
this branch, **pending the base+agent rebuild**. This replaces the
old-Podman-4.3.1 limitation below.

The problem (as measured on the bookworm Podman 4.3.1 container): the built-in
`podman compose` delegating subcommand only exists in Podman ≥ 4.7, so on 4.3.1
**only** the standalone `podman-compose` (Python) worked — `podman compose …`,
`docker compose …` (the `docker` shim is `exec podman "$@"`), and `docker-compose`
all failed. That broke `docker compose` muscle memory and project scripts.

Why the **trixie base** and not the alternatives:
- **Podman is a Debian package, not a Node one** — its version is set by the OS
  release, *not* the Node tag. Bookworm = 4.3.1; trixie = 5.4.2. So the fix is the
  OS bump; the Node major version (24 vs 26) is orthogonal and buys nothing here.
  We stay on **Node 24 (Active LTS)** → zero Node breaking changes. (Node 26 is
  "Current", not LTS until 2026-10-28; revisit independently if a newer Node is
  wanted for its own sake — it's a one-line `FROM` change.)
- **Not apt-pinning trixie's Podman onto bookworm** — trixie's podman needs the
  t64/newer-glibc (2.41 vs bookworm 2.36) library set; pinning it would be a
  broken "frankendebian". Podman is *not* in bookworm-backports either.
- **Not just compat shims on 4.3.1** — podman-compose v1 isn't fully compose-v2
  compatible; the engine upgrade is the real fix and brings newer
  crun/netavark/pasta too.

On trixie (Podman 5.4.2) all four forms work: `podman compose …` (native
subcommand) and `docker compose …` (via the shim) both delegate to
`podman-compose` (now v1.3.0), and `podman-compose`/`docker-compose` work directly.

Migration applied to `docker/base/Dockerfile` (validated in a nested `debian:trixie`
container before committing — all candidates resolve): `FROM node:24-trixie-slim`;
`php8.2-*` → `php8.4-*`; **Microsoft repo via the official
`packages-microsoft-prod.deb` for `debian/13`** (trixie's strict `sqv` verifier
rejects the legacy `microsoft.asc` — it's signed by a rotated key; the config deb
ships the correct `microsoft-prod.gpg`); PGDG `bookworm-pgdg` → `trixie-pgdg`;
dropped `postgresql-contrib-16` (its modules now ship inside `postgresql-16`);
`BASE_SOURCE_IMAGE` + script/README/`reset-claude-history.{sh,ps1}` fallbacks bumped
to `node:24-trixie-slim`. `docker/shared/container-agent.md.tmpl` and the validation
prompt's step 3 can now use `docker compose`/`podman compose` again.

## How to resume after the rebuild (next session)

> **DONE (2026-06-07).** The rebuild happened and steps 1–5 below were executed and
> **PASS** (see the post-rebuild Results table) — plus one new fix
> (`firewall_driver=iptables`). Step 6 (Results) is filled in. **Step 5
> (image-store cross-container check) is also complete:** a freshly-rebuilt *second*
> container on a different project ran the reader role of a scratch two-container
> writer/reader harness (run out-of-tree) against a live seed here — cross-container
> sharing, read-while-write (#4), and
> concurrent same-image pull (#5) all PASS. That second container carried the
> `firewall_driver=iptables` bake natively (no user override needed), so the baked
> drop-in is confirmed too. The user-facing docs (image-store wiring-checklist step 6
> — README, this doc's Follow-ups, the agent template) are done as well, so **all
> rootless-Podman + image-store work on this branch is complete.**

Everything below was **applied in the repo on this branch and needed a host-side
rebuild + relaunch to take effect** (the launcher and base image both changed). The
running container that produced the *pre-rebuild* findings was bookworm/Podman-4.3.1
and could not self-rebuild; the post-rebuild run above was done on the trixie image.

1. **Rebuild base + agent** (base changed → both): from the powbox repo on this
   branch, `./build.sh base && ./build.sh agent` (or `./build.sh all`). Confirm the
   trixie migration baked: the build must succeed through the MS + PGDG layers (the
   highest-risk steps; package availability was pre-validated but the full image
   build is the real proof).
2. **Relaunch** a throwaway probe project with both devices forced:
   `POWBOX_PODMAN=on cc /tmp/podman-probe --volatile` (recreate so the new base +
   `/dev/fuse` + `/dev/net/tun` + storage volume attach).
3. **Confirm the environment took** inside the new container:
   - `podman --version` → **5.4.2** (proves the trixie base; `podman compose version`
     should now work too).
   - `cat /proc/mounts | grep '/proc/sys '` → should be **`rw`** now (proves
     `systempaths=unconfined` took; it was `ro` before). Also
     `podman run --rm docker.io/library/alpine echo ok` must print `ok` with **no**
     `ping_group_range` error.
   - `ls -l /dev/fuse /dev/net/tun` both present; `podman info` → `overlay | cgroupfs
     | netavark`.
4. **Re-run the two validations that were blocked**, which should now PASS:
   - **Step 3 of the Validation prompt above** (compose + published ports + DNS) —
     use `podman compose up -d` *and* `docker compose up -d` to confirm both the
     native subcommand and the shim route correctly on 5.4.2; `curl
     http://localhost:8080` should return Adminer HTML (the netavark `route_localnet`
     write now succeeds on the writable `/proc/sys`).
   - **`podman build` with a networked RUN step** (the case that failed on read-only
     `/proc/sys`): a `Containerfile` whose `RUN apk add …` needs the network.
   - Re-confirm Step 4 (firewall: `PUBLIC_OK` / `LAN_BLOCKED`) still holds.
5. ✅ **Image-store cross-container check — DONE** (see
   [podman-shared-image-store.md](podman-shared-image-store.md) Validation plan
   step 3 + open questions #4/#5): a *second* container on a different project saw the
   curated images `RO=true` pre-pull (sharing), did 18 reads with 0 errors/0 deadlocks
   across a live seed (#4), and pulled all 6 actively-seeded images into its own
   graphroot without hanging (#5). Driven by a scratch two-container writer/reader
   harness, run out-of-tree.
6. ✅ **Results table filled in** for the post-rebuild run; status header updated.

## Follow-ups

- **Shared read-only image store** (`additionalimagestores`) layered under each
  per-container writable graphroot, so agents stop re-pulling the same base
  images per container without giving up the per-container store isolation.
  **Implemented and fully validated** (2026-06-07) — overlay path, plus
  cross-container sharing and read-while-write from a second container. See
  [podman-shared-image-store.md](podman-shared-image-store.md).
- If/when GUI, emulator, or non-headless-browser needs appear, that's the signal
  to move that workload to a dedicated Ubuntu VM (snapshot-based reset), per the
  original Option B → VM plan.
- **Smoke test — DONE** (`scripts/smoke-test-podman.{sh,ps1}`, wired as stage 3 of
  `commands/smoke-test.{sh,ps1}`). Future base/Podman bumps now catch engine
  regressions automatically: it runs the built image with the launch-time wiring
  the launcher supplies via the compose overlays (`/dev/net/tun`, optional
  `/dev/fuse`, and `seccomp/apparmor/systempaths=unconfined` +
  `SYS_ADMIN/NET_ADMIN/NET_RAW`) and asserts the high-signal subset of the manual
  validation prompt above: engine sanity (rootless, `cgroupfs`, `netavark`, the
  `firewall_driver=iptables` drop-in, subuid/subgid, the `podman compose`
  subcommand that the trixie bump exists for), a nested run on the default network
  (proves seccomp + `/dev/net/tun` + the `ping_group_range` sysctl), and a bridge
  network with a published port (proves the iptables firewall driver + the
  `route_localnet` sysctl `systempaths=unconfined` unblocks). It mirrors the
  launcher's `POWBOX_PODMAN` gate. The probe has two halves: the device-free
  engine-wiring checks (engine present, the drop-in, `podman info`, the `compose`
  subcommand) run on **every** host, and the nested-run/published-port checks
  **self-skip** when `/dev/net/tun` is absent — e.g. the Docker Desktop VM under the
  default `auto`, where `POWBOX_PODMAN=on` forces the full run. So an environment
  that simply cannot do nested networking is not failed, but a genuinely broken
  image (missing engine, dropped drop-in) **fails** the stage on any host — a
  missing engine is a real regression, not a skip (use `POWBOX_SMOKE_SKIP_PODMAN=1`
  / `POWBOX_PODMAN=off` to skip a legacy pre-Podman image on purpose). The full
  validation prompt above stays the deeper manual check (postgres on a named volume,
  compose + adminer, firewall-inheritance `LAN_BLOCKED`); the smoke test is the fast
  automated guard.
