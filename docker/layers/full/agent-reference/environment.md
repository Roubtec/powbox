### Filesystem layout

| Path | What it is |
|------|------------|
| `/home/node/.local/share/containers` | Per-container rootless Podman storage, keyed by agent + project (Claude and Codex get separate stores for the same repo) — images and named volumes persist here (Docker volume) |

### Network

Containers you start with Podman route their outbound traffic through this container, so they inherit the same firewall: they can pull images and reach the public internet, but not your LAN or host. Talk to a nested service from this container (or from a sibling container) via its **published port on `localhost`** rather than its in-container IP.
