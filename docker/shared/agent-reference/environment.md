# Container environment

Where things live in this container and what the firewall lets out. Read it when you need to know whether a path is a volume, a tmpfs shadow or a host mount, what survives container recreation, where a tool's cache is kept, or how an egress exception is made.

## Filesystem layout

| Path | What it is |
|------|------------|
| `/workspace/<project-slug>` | Project source, read-write; the working directory (launch modes and host visibility: see the top of the instruction file). Slug is `<name>-<hash>` dir-mounted, `<repo-slug>[-<name-slug>]-<instance-hash>` under `--isolated` (the `agent-ws-*` volume) |
| `/workspace/<project-slug>/node_modules` | Per-container Docker volume (Linux packages, separate from host); dir-mounted JS/powbox projects only |
| `/workspace/<project-slug>/<subpackage>/node_modules` | Ephemeral tmpfs shadow (auto-detected for monorepo workspaces; the `pnpm`/`pn` wrapper re-shadows before installs, so a package added mid-session is covered automatically — in dir-mounted mode, run `shadow-refresh.sh` by hand only if you populate `node_modules` another way) |
| `/workspace/<project-slug>/<dotnet-project>/{bin,obj}` | Ephemeral tmpfs shadow (auto-detected beside every `*.csproj`/`*.fsproj`/`*.vbproj`, matched case-insensitively so a Windows-authored `Legacy.CSPROJ` counts too, ensuring a container `dotnet build` never writes container-absolute paths into `obj/` on the host bind mount where a host build would trip over them). Build output does not survive container recreation; in dir-mounted mode, run `shadow-refresh.sh` after adding a project mid-session. An existing `bin`/`obj` that is a symlink, or that holds Git-tracked files (a project redirecting output via `ArtifactsPath` may keep real content there), is left un-shadowed so nothing real is masked |
| `/workspace/<project-slug>/.worktrees` | Per-container Docker volume for git worktrees (dir-mounted JS/powbox, `go.mod`, or boundedly detected .NET projects); also holds durable per-worktree git metadata at `.worktrees/.gitworktrees` (bind-mounted over `.git/worktrees`). It also reserves cache locations for tools the core tooling table in `tooling.md` does not list, which stay unused unless a layer set (see the end of that file) or your own install adds the tool: Go module/build caches (`.gomodcache`, `.gocache`, and per-worktree `.golangci-cache/…`), the NuGet packages folder `.worktrees/.nuget` (`NUGET_PACKAGES`), the ccache directory `.worktrees/.ccache` (`CCACHE_DIR`), and the shared Playwright browsers cache `.worktrees/.ms-playwright` (`PLAYWRIGHT_BROWSERS_PATH`) |
| `/ctx` | Optional context mount root; external folders are mounted under `/ctx/<name>` via `--ctx` or `ctx:` config |
| `/home/node/.claude`, `/home/node/.codex` | Claude and Codex config/state (persistent Docker volumes, both mounted whichever agent is primary). Every container of an agent shares its volume, so the instruction file there was rendered by whichever container started last, possibly from another image build |
| `/home/node/.config/gh` | GitHub CLI config (persistent Docker volume) |
| `/usr/local/share/agent-reference` | On-demand reference baked into this image, this file among it; root-owned and read-only. It is read from the image, never from a config volume, so it describes the image you are running in |
| `/workspace/<project-slug>/.worktrees/.pnpm-store` | Per-container pnpm store, dir-mounted JS/powbox gate only (inside the `.worktrees` volume; co-located so worktree installs hardlink) |

Under `--isolated` the `node_modules`, `.worktrees`, `.git/worktrees`, and store/cache paths above (and the worktree roots `wt-bootstrap` checks) are plain subdirectories of the single `agent-ws-*` volume, not separate volumes, and the tmpfs shadows are skipped entirely — running `shadow-refresh.sh` there is a harmless no-op, because the script skips itself under `POWBOX_SELF_HOSTED=1` and exits 0 without mounting.

## Network

Private/local networks (10.x, 172.16.x, 192.168.x, link-local, IPv6 unique-local) and CGNAT (100.64.0.0/10, which includes Tailscale addresses) are blocked by the container firewall. Public internet is fully open for npm, GitHub, web research, and API calls.

The user may have opened a few exceptions to that block. `$POWBOX_EGRESS_ALLOW` lists them as `proto,destination,port` entries separated by `;`, and is unset when there are none. They are fixed when the container is created: re-running `sudo init-firewall.sh` re-applies the same set and cannot add to it. That guards against an accidental widening, not a determined one, so treat the list as the user's policy: when you need another destination, ask the user to add it to `.powbox-egress` rather than working around the firewall.
