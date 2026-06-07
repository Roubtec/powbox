# Rootless containers inside the sandbox (Podman)

**Status:** implemented. Rebuild the base + agent images and run the validation procedure below before relying on it in a new environment.

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
| `docker/shared/containers.conf` | New engine drop-in → `/etc/containers/containers.conf.d/10-powbox.conf`: `cgroup_manager=cgroupfs`, `events_logger=file` (no systemd/journald in-container), `network_backend=netavark`. |
| `docker/shared/entrypoint-core.sh` | At startup (guarded by `command -v podman`): create `XDG_RUNTIME_DIR` mode 700; pick storage driver — keep the image default (overlay + fuse-overlayfs) when `/dev/fuse` is present, else write a user `storage.conf` selecting the slower `vfs` driver. |
| `scripts/launch-agent.sh` | New per-container volume `agent-podman-<agent>-<project>` mounted at `/home/node/.local/share/containers` (images + named volumes persist across restarts), created+chowned in the existing root pre-run. Passes `--device /dev/fuse` when the host exposes it (override with `POWBOX_FUSE=on\|off`). |
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
  launcher passes it when present. If it's missing (or `POWBOX_FUSE=off`),
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
     through the firewall; php8.2-pgsql is preinstalled):
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

| Step | PASS/FAIL | Notes |
|------|-----------|-------|
| 0. Engine sanity | | |
| 1. Pull + run | | |
| 2. Persistent volume | | |
| 3. Compose + DNS | | |
| 4. Firewall inheritance | | |

**Host:** (WSL2 / native Linux / Docker Desktop) — **/dev/fuse present:** (y/n) — **storage driver:** (overlay/vfs)

**Verdict:**

## Known risks & likely fixes (if validation fails)

- **`/dev/fuse` not passed on WSL2/Docker Desktop.** The launcher auto-detects on
  the host running `cc`; if that host lacks the node but the daemon has it,
  force it: `POWBOX_FUSE=on cc <project> --volatile`. Otherwise it falls back to
  vfs (works, slower).
- **`mount`/overlay denied by the security profile.** tmpfs shadow mounts already
  work under our profile, so fuse mounts should too. If Podman complains about
  mounts or namespaces, the usual escape hatch is adding
  `--security-opt seccomp=unconfined` (and/or `apparmor=unconfined`) to the run
  in `launch-agent.sh`. The container is already the boundary and runs
  `--dangerously-*`, so this is an acceptable loosening *if needed* — but only
  add it if a test actually requires it.
- **`newuidmap: write to uid_map failed`.** Means the `/etc/subuid`/`/etc/subgid`
  ranges didn't take; verify the apt layer wrote the `node:` lines and that
  `uidmap` is installed (`which newuidmap`).
- **`podman compose` can't find a provider.** Confirm `podman-compose` is on PATH;
  `podman compose version` should print the podman-compose banner.
- **First run after upgrading an existing project container.** Recreate it
  (`cc … --volatile`) so the new device + storage volume attach.

## Follow-ups

- **Shared read-only image store** (`additionalimagestores`) layered under each
  per-container writable graphroot, so agents stop re-pulling the same base
  images per container without giving up the per-container store isolation.
  Planned for this branch as separate work.
- If/when GUI, emulator, or non-headless-browser needs appear, that's the signal
  to move that workload to a dedicated Ubuntu VM (snapshot-based reset), per the
  original Option B → VM plan.
- Consider a smoke-test addition (`scripts/smoke-test-image.sh`) once the manual
  validation passes, so future base bumps catch Podman regressions automatically.
