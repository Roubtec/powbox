# PowBox shell helpers (bash / zsh).
#
# Source this file from your ~/.bashrc or ~/.zshrc:
#
#     source "$HOME/code/powbox/shell/powbox.sh"
#
# POWBOX_ROOT is auto-detected from the location of this file. If that fails
# (e.g. your shell does not expose the sourced-script path), set it explicitly
# before sourcing:
#
#     export POWBOX_ROOT="$HOME/code/powbox"
#     source "$POWBOX_ROOT/shell/powbox.sh"
#
# Behavior toggles (export before sourcing, or before calling the function):
#
#   POWBOX_CD_AFTER_LAUNCH  1 (default) = cd into the project dir after `cc`/`cx`
#                           returns when an explicit path was given
#                           0           = stay in the original directory
#
# All other behavior is controlled by flags on the underlying commands.

if [ -z "${POWBOX_ROOT:-}" ]; then
    _powbox_self=""
    if [ -n "${BASH_SOURCE[0]:-}" ]; then
        _powbox_self="${BASH_SOURCE[0]}"
    elif [ -n "${ZSH_VERSION:-}" ]; then
        _powbox_self="$(eval 'printf %s "${(%):-%x}"')"
    fi
    if [ -n "$_powbox_self" ]; then
        POWBOX_ROOT="$(cd "$(dirname "$_powbox_self")/.." && pwd)"
        export POWBOX_ROOT
    fi
    unset _powbox_self
fi

if [ -z "${POWBOX_ROOT:-}" ]; then
    echo "powbox: POWBOX_ROOT is not set and could not be auto-detected." >&2
    echo "powbox: export POWBOX_ROOT to your checkout before sourcing shell/powbox.sh." >&2
    return 1 2>/dev/null || exit 1
fi

_powbox_should_cd() {
    case "${POWBOX_CD_AFTER_LAUNCH:-1}" in
        0|false|no|off) return 1 ;;
        *) return 0 ;;
    esac
}

cc() {
    if [ $# -eq 0 ] || [[ "$1" == -* ]]; then
        "$POWBOX_ROOT/commands/claude-container.sh" "$PWD" "$@"
    else
        local target="$1"; shift
        "$POWBOX_ROOT/commands/claude-container.sh" "$target" "$@"
        local rc=$?
        if [ $rc -eq 0 ] && _powbox_should_cd; then
            cd "$target" || echo "powbox: warning: could not cd into '$target'"
        fi
        return $rc
    fi
}

cx() {
    if [ $# -eq 0 ] || [[ "$1" == -* ]]; then
        "$POWBOX_ROOT/commands/codex-container.sh" "$PWD" "$@"
    else
        local target="$1"; shift
        "$POWBOX_ROOT/commands/codex-container.sh" "$target" "$@"
        local rc=$?
        if [ $rc -eq 0 ] && _powbox_should_cd; then
            cd "$target" || echo "powbox: warning: could not cd into '$target'"
        fi
        return $rc
    fi
}

agent-prune-volumes() {
    "$POWBOX_ROOT/commands/prune-volumes.sh" "$@"
}

agent-prune-stopped() {
    local claude_names codex_names
    claude_names=$(docker ps -a --format "{{.Names}}" --filter "status=exited" --filter "name=claude-")
    if [ -n "$claude_names" ]; then
        docker rm $claude_names 2>/dev/null
    fi

    codex_names=$(docker ps -a --format "{{.Names}}" --filter "status=exited" --filter "name=codex-")
    if [ -n "$codex_names" ]; then
        docker rm $codex_names 2>/dev/null
    fi
}

agent-prune() {
    agent-prune-stopped
    agent-prune-volumes
}

agent-check-updates() {
    "$POWBOX_ROOT/commands/check-updates.sh" "$@"
}

agent-reset-claude-history() {
    "$POWBOX_ROOT/commands/reset-claude-history.sh" "$@"
}

agent-update-claude() {
    "$POWBOX_ROOT/build.sh" claude --no-cache "$@"
}

agent-update-codex() {
    "$POWBOX_ROOT/build.sh" codex --no-cache "$@"
}

cc-list() {
    docker ps -a --filter "name=claude-" --format $'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}'
}

cx-list() {
    docker ps -a --filter "name=codex-" --format $'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}'
}

agent-list() {
    docker ps -a --filter "name=claude-" --filter "name=codex-" --format $'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}'
}

agent-volumes() {
    docker volume ls --filter "name=claude-config" --filter "name=codex-config" --filter "name=agent-" --format $'table {{.Name}}\t{{.Driver}}\t{{.Mountpoint}}'
}
