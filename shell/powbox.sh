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

# True if the given args contain a flag (used to suppress the cd-after-launch when
# the positional is a self-hosted repo spec, not a host path).
_powbox_arg_present() {
    local needle="$1"; shift
    local a
    for a in "$@"; do
        [ "$a" = "$needle" ] && return 0
    done
    return 1
}

cc() {
    if [ $# -eq 0 ] || [[ "$1" == -* ]]; then
        "$POWBOX_ROOT/commands/claude-container.sh" "$PWD" "$@"
    else
        local target="$1"; shift
        "$POWBOX_ROOT/commands/claude-container.sh" "$target" "$@"
        local rc=$?
        # In self-hosted (--isolated) mode the positional is a repo spec, not a
        # path, so never cd into it.
        if [ $rc -eq 0 ] && _powbox_should_cd && ! _powbox_arg_present --isolated "$@"; then
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
        # In self-hosted (--isolated) mode the positional is a repo spec, not a
        # path, so never cd into it.
        if [ $rc -eq 0 ] && _powbox_should_cd && ! _powbox_arg_present --isolated "$@"; then
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

# Re-seed the image-baked skills onto the claude-config/codex-config volumes,
# overriding the startup no-clobber so updated skill text in a rebuilt image
# replaces the stale copies left on the volumes. Forwards flags:
# --dry-run (preview), --prune (drop obsolete seeds), --adopt-all (take baked
# versions of unmarked name-collisions).
agent-update-skills() {
    "$POWBOX_ROOT/commands/update-skills.sh" "$@"
}

# After a successful image rebuild, offer to re-seed skills from the fresh image
# in the same flow. update-skills.sh itself prompts about conflicts/obsolete
# skills, so this only needs the top-level yes/no. Skipped when non-interactive.
_powbox_offer_reseed() {
    [ -t 0 ] || return 0
    local reply
    printf 'Re-seed skills from the freshly built image onto the config volumes now? [y/N] '
    read -r reply
    case "$reply" in
        [yY]|[yY][eE][sS]) "$POWBOX_ROOT/commands/update-skills.sh" ;;
        *) echo "Skipped skill re-seed. Run 'agent-update-skills' later to refresh." ;;
    esac
}

_powbox_norm_label() {
    case "$1" in "" | "<no value>") echo unknown ;; *) echo "$1" ;; esac
}

# Show the powbox commit that built each layer of powbox-agent:latest, plus the
# powbox working-tree HEAD so a stale image (built from an older repo state) is
# obvious even when the agent binaries themselves are current. A piecemeal build
# can carry up to three distinct commits: the base image has its own parent, and
# the Claude layer can rebuild without touching the Codex layer below it. The
# base commit is read from the label the agent image inherits from its base.
agent-image-info() {
    local img="powbox-agent:latest"
    if ! docker image inspect "$img" >/dev/null 2>&1; then
        echo "Image $img not found — build it with agent-update." >&2
        return 1
    fi
    local base codex claude codexver claudever
    IFS=$'\t' read -r base codex claude codexver claudever < <(
        docker image inspect "$img" --format \
            '{{index .Config.Labels "powbox.commit.base"}}{{"\t"}}{{index .Config.Labels "powbox.commit.codex"}}{{"\t"}}{{index .Config.Labels "powbox.commit.claude"}}{{"\t"}}{{index .Config.Labels "powbox.codex.version"}}{{"\t"}}{{index .Config.Labels "powbox.claude.version"}}'
    )
    echo "$img — powbox commit that built each layer:"
    printf '  base:         %s\n' "$(_powbox_norm_label "$base")"
    printf '  codex:        %s  (codex %s)\n' "$(_powbox_norm_label "$codex")" "$(_powbox_norm_label "$codexver")"
    printf '  claude/top:   %s  (claude %s)\n' "$(_powbox_norm_label "$claude")" "$(_powbox_norm_label "$claudever")"
    local head
    if head="$(git -C "$POWBOX_ROOT" rev-parse --short HEAD 2>/dev/null)"; then
        [ -n "$(git -C "$POWBOX_ROOT" status --porcelain 2>/dev/null)" ] && head="${head}-dirty"
        printf '  working tree: %s\n' "$head"
    fi
}

# Print image provenance, then offer the skill re-seed, after a successful build.
_powbox_post_build() {
    agent-image-info 2>/dev/null || true
    _powbox_offer_reseed
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
#   $3            build target (agent|all)
#   $4..          extra args forwarded to build.sh
# Agents not in the force list are pinned to their currently baked version so
# Docker reuses that layer. Because Codex sits below Claude in the image, a
# Claude-only update rebuilds just the Claude layer; a Codex update also
# rebuilds the Claude layer above it (the accepted, rarer cost).
_powbox_build_from_table() {
    local table="$1" force=" $2 " target="$3"
    shift 3
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
    local args=("$target")
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
    _powbox_build_from_table "$table" "claude" agent "$@"
}

agent-update-codex() {
    local table
    if ! table="$(_powbox_agent_porcelain)"; then
        echo "agent-update-codex: update check failed" >&2
        return 1
    fi
    _powbox_build_from_table "$table" "codex" agent "$@"
}

agent-update-base() {
    # A new base means the whole agent image should be rebuilt on top of it.
    local table
    if table="$(_powbox_agent_porcelain)"; then
        _powbox_build_from_table "$table" "claude codex" all --pull --no-cache "$@"
    else
        "$POWBOX_ROOT/build.sh" all --pull --no-cache "$@"
    fi
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

    # Provenance: which powbox commit built the current image vs. the working
    # tree. A current binary set can still sit on an image built from an older
    # repo — this surfaces that so the user can rebuild for repo changes alone.
    agent-image-info 2>/dev/null || true

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
        _powbox_build_from_table "$table" "claude codex" all --pull --no-cache "$@"
        local rc=$?
        [ "$rc" -eq 0 ] && _powbox_post_build
        return "$rc"
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
    _powbox_build_from_table "$table" "$stale" agent "$@"
    local rc=$?
    [ "$rc" -eq 0 ] && _powbox_post_build
    return "$rc"
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
