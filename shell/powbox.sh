# shellcheck shell=bash
# This file is sourced, not executed, so it has no shebang. The directive above
# tells shellcheck to analyze it as bash (its closest supported dialect); the
# file is also sourced into zsh at runtime.
#
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
    # `return` succeeds when sourced (the intended use) and fails when the file
    # is run directly, in which case `exit 1` takes over. shellcheck only models
    # the sourced path and so flags `exit 1` as unreachable; the fallback is
    # deliberate.
    # shellcheck disable=SC2317
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
            cd "$target" || echo "powbox: warning: could not cd into '$target'" >&2
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
            cd "$target" || echo "powbox: warning: could not cd into '$target'" >&2
        fi
        return $rc
    fi
}

agent-prune-volumes() {
    "$POWBOX_ROOT/commands/prune-volumes.sh" "$@"
}

# Remove all exited containers whose name matches the given prefix filter.
# Names are read line-by-line into an array so this behaves identically under
# bash and zsh. zsh does not word-split unquoted expansions, so the older
# `docker rm $names` form silently passed every name as a single argument and
# failed when more than one container matched. Process substitution (rather
# than a pipe) keeps the loop in the current shell so the array survives.
_powbox_prune_exited() {
    local name names=()
    while IFS= read -r name; do
        [ -n "$name" ] && names+=("$name")
    done < <(docker ps -a --format "{{.Names}}" --filter "status=exited" --filter "name=$1")
    [ "${#names[@]}" -gt 0 ] && docker rm "${names[@]}" 2>/dev/null
}

agent-prune-stopped() {
    _powbox_prune_exited "claude-"
    _powbox_prune_exited "codex-"
}

agent-prune() {
    agent-prune-stopped
    # Forward any flags (e.g. --dry-run/--force) on to prune-volumes.sh.
    agent-prune-volumes "$@"
}

agent-check-updates() {
    "$POWBOX_ROOT/commands/check-updates.sh" "$@"
}

agent-reset-claude-history() {
    "$POWBOX_ROOT/commands/reset-claude-history.sh" "$@"
}

# Read the machine-readable update table once (one container start reads both
# baked agent versions). Each row is: name<TAB>status<TAB>baked<TAB>latest.
_powbox_agent_porcelain() {
    "$POWBOX_ROOT/commands/check-updates.sh" --porcelain
}

# Build the unified agent image from a porcelain table, pinning each binary so
# Docker rebuilds only the layers that actually changed.
#   $1            porcelain table (multi-line)
#   $2            space-separated agents to force to their latest version
#   $3..          extra args forwarded to build.sh
# Agents not in the force list are pinned to their currently baked version so
# Docker reuses that layer. Because Codex sits below Claude in the image, a
# Claude-only update rebuilds just the Claude layer; a Codex update also
# rebuilds the Claude layer above it (the accepted, rarer cost).
_powbox_build_from_table() {
    local table="$1" force=" $2 "
    shift 2
    local name status baked latest ver
    local claude_ver="" codex_ver=""
    while IFS=$'\t' read -r name status baked latest; do
        [ -n "$name" ] || continue
        [ "$name" = base ] && continue
        case "$force" in
            *" $name "*) ver="$latest" ;;   # forced: install latest
            *)           ver="$baked"  ;;    # unchanged: pin baked to reuse layer
        esac
        # '-' is the porcelain's empty marker (unknown/missing); leave unpinned so
        # the build falls back to the `latest` tag for that binary.
        [ "$ver" = "-" ] && ver=""
        case "$name" in
            claude) claude_ver="$ver" ;;
            codex)  codex_ver="$ver" ;;
        esac
    done < <(printf '%s\n' "$table")
    local args=(agent)
    [ -n "$claude_ver" ] && args+=(--claude-version "$claude_ver")
    [ -n "$codex_ver" ]  && args+=(--codex-version "$codex_ver")
    "$POWBOX_ROOT/build.sh" "${args[@]}" "$@"
}

agent-update-claude() {
    local table
    if ! table="$(_powbox_agent_porcelain)"; then
        echo "agent-update-claude: update check failed" >&2
        return 1
    fi
    _powbox_build_from_table "$table" "claude" "$@"
}

agent-update-codex() {
    local table
    if ! table="$(_powbox_agent_porcelain)"; then
        echo "agent-update-codex: update check failed" >&2
        return 1
    fi
    _powbox_build_from_table "$table" "codex" "$@"
}

agent-update-base() {
    # A new base means the whole agent image should be rebuilt on top of it.
    "$POWBOX_ROOT/build.sh" all --pull --no-cache "$@"
}

# Show the full update report, then (if anything is stale) ask for confirmation
# before rebuilding. On confirmation we re-check rather than reusing the first
# result, so an update approved in another terminal while this prompt was waiting
# is still picked up. A stale base image is upstream of everything, so it triggers
# a full --pull --no-cache rebuild of base + the agent image; otherwise only the
# stale agents are forced to latest and the unified image is rebuilt with minimal
# layers (the unchanged binary's layer is reused). Extra args go to build.sh.
agent-update() {
    local report
    if ! report="$("$POWBOX_ROOT/commands/check-updates.sh")"; then
        [ -n "$report" ] && printf '%s\n' "$report"
        echo "agent-update: update check failed" >&2
        return 1
    fi
    printf '%s\n' "$report"

    # The report prints the literal "update available" marker for each stale
    # component, so grepping it lets us decide whether to prompt without a second
    # network round-trip. Keep this in sync with commands/check-updates.sh.
    if ! printf '%s\n' "$report" | grep -q 'update available'; then
        echo "All agent images are up to date."
        return 0
    fi

    local reply
    printf 'Proceed with the update? [y/N] '
    read -r reply
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Update cancelled."; return 0 ;;
    esac

    local table
    if ! table="$(_powbox_agent_porcelain)"; then
        echo "agent-update: update check failed" >&2
        return 1
    fi

    if printf '%s\n' "$table" | awk -F'\t' '$1=="base" && $2=="stale"{f=1} END{exit !f}'; then
        echo "Base image is stale — rebuilding base (with --pull) and the agent image on top."
        "$POWBOX_ROOT/build.sh" all --pull --no-cache "$@"
        return $?
    fi

    local name status rest stale=""
    while IFS=$'\t' read -r name status rest; do
        case "$name" in
            claude|codex) [ "$status" = stale ] && stale="$stale $name" ;;
        esac
    done < <(printf '%s\n' "$table")
    stale="${stale# }"

    if [ -z "$stale" ]; then
        echo "Nothing to update — already up to date."
        return 0
    fi

    echo "Updating: ${stale// /, } (rebuilding only the affected image layers)."
    _powbox_build_from_table "$table" "$stale" "$@"
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
