# Claude Code Docker Container — Future Upgrades

The original implementation plan has been carried out.

Current, authoritative documentation now lives in:

- [README.md](README.md) for setup, usage, mounts, security model, and troubleshooting
- [CLAUDE.md](CLAUDE.md) for repository-specific architecture notes and implementation constraints

This file is intentionally kept small and only tracks possible future enhancements.

## Future Upgrades

- **Stale container cleanup**: Add a helper for stale stopped containers, for example `claude-container-prune-containers.ps1`, so cleanup of both containers and orphaned `node_modules` volumes is symmetrical.
- **devcontainer.json**: Add VS Code Dev Container integration so the IDE runs fully inside the container (IntelliSense, debugger, extensions all use container packages). Would eliminate the dual node_modules setup but changes the development workflow.
- **Domain-allowlist firewall**: Switch from "block local" to "allow specific domains only" for stricter security (e.g., when working with sensitive code). The Anthropic reference implementation does this.
- **Port forwarding**: Expose container ports for web app development (`docker compose run --service-ports`). Useful if you want to run dev servers inside the container and access them from the host browser.
- **SSH keys mount**: Mount `~/.ssh` as read-only for git-over-SSH operations. Note: Docker Desktop on Windows may present permissive file modes that OpenSSH rejects — may need HTTPS auth or an SSH agent as fallback.
- **Additional host mounts**: `~/.npmrc`, `~/.config`, local CA certificates, or other config directories as needs arise.
- **Windows batch wrapper** (`claude-container.bat`): Thin wrapper around the PowerShell launcher for `cmd.exe` users.
- **Automated image rebuilds**: A scheduled task (Windows Task Scheduler or cron in WSL) to run `build.sh` daily/weekly.
- **ANTHROPIC_API_KEY fallback**: Add to `.env` if OAuth sessions prove unreliable in the container.
- **Custom Oh My Zsh plugins**: zsh-autosuggestions, zsh-syntax-highlighting, etc.
- **Read-only workspace mode**: Mount the workspace bind mount as `:ro` for pure analysis tasks where Claude shouldn't modify files.
- **Validation automation**: Convert the manual smoke checks into an automated validation script that exercises startup, networking, auth, and volume behavior.
