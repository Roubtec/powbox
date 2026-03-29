# Container Environment

You are running inside an isolated Docker container. The host filesystem is not accessible except through the bind mount under `/workspace`. You have full autonomy (`--dangerously-bypass-approvals-and-sandbox`) — the container and its network firewall are your safety boundary.

Your identity for this session is in `$CONTAINER_NAME` (also available via the `cid` command).

## Available tooling

Everything below is on `PATH` and ready to use — no installation needed.

| Category | Tools |
|----------|-------|
| Core runtime | `node`, `npm`, `pnpm`, `python3`, `pip3` |
| Git/GitHub | `git`, `gh`, `ssh` |
| Shell | `zsh`, `jq`, `yq`, `fzf`, `less`, `tree`, `file`, `htop`, `shellcheck`, `shfmt`, `strace`, `lsof` |
| Build | `make`, `patch`, `gcc`, `g++` |
| Archives/transfer | `wget`, `curl`, `zip`, `unzip`, `rsync`, `bzip2`, `xz`, `zstd` |
| Data | `sqlcmd`, `sqlite3`, `envsubst`, `bc`, `xxd` |
| Network | `ping`, `nc` |
| File search | `fd`, `bat` |
| Editors | `nano`, `vim` |
| Sandbox | `bubblewrap` (`bwrap`) |

## Git and GitHub

- This container authenticates to GitHub via **HTTPS** using the `gh` credential helper, which is configured automatically at startup. There are no SSH keys in the container.
- Prefer `gh` for remote operations: `gh pr create`, `gh pr merge`, etc. These use the GitHub API directly and are not affected by the remote URL protocol.
- For `git push`/`git pull`, the remote URL **must** be HTTPS. Host-mounted workspaces often have SSH remote URLs (`git@github.com:...`) which will fail. Before pushing, check and fix if needed:

  ```sh
  # check current remote
  git remote get-url origin
  # if it starts with git@, switch to HTTPS
  git remote set-url origin "$(git remote get-url origin | sed 's|git@github.com:|https://github.com/|')"
  ```

- `git` is available for all local operations (status, diff, log, commit, branch, etc.).
- The global git config is seeded from the host on first run. Do not modify `/home/node/.gitconfig-host` (read-only mount).

## Filesystem layout

| Path | What it is |
|------|------------|
| `/workspace/<project>` | Project source (bind-mounted from host, read-write); the working directory |
| `/workspace/<project>/node_modules` | Per-project Docker volume (Linux packages, separate from host) |
| `/ctx` | Optional read-only context volume (reference code/data, mounted via `--ctx`) |
| `/home/node/.codex` | Codex config/state (persistent Docker volume) |
| `/home/node/.config/gh` | GitHub CLI config (persistent Docker volume) |
| `/home/node/.local/share/pnpm/store` | Shared pnpm cache (persistent Docker volume) |

## Network

Private/local networks (10.x, 172.16.x, 192.168.x, link-local) are blocked by the container firewall. Public internet is fully open for npm, GitHub, web research, and API calls.
