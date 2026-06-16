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
    # Self-hosted: the positional (if any) is a repo spec, not a host path, so the
    # launcher resolves the repo from --isolated's positional or --repo. Never inject
    # $PWD here — for the documented "cc --isolated owner/repo --name foo" form that
    # would pass TWO positionals ($PWD and owner/repo) and fail. Never cd afterward.
    if _powbox_arg_present --isolated "$@"; then
        "$POWBOX_ROOT/commands/claude-container.sh" "$@"
    elif [ $# -eq 0 ] || [[ "$1" == -* ]]; then
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
    # Self-hosted: the positional (if any) is a repo spec, not a host path, so the
    # launcher resolves the repo from --isolated's positional or --repo. Never inject
    # $PWD here — for the documented "cx --isolated owner/repo --name foo" form that
    # would pass TWO positionals ($PWD and owner/repo) and fail. Never cd afterward.
    if _powbox_arg_present --isolated "$@"; then
        "$POWBOX_ROOT/commands/codex-container.sh" "$@"
    elif [ $# -eq 0 ] || [[ "$1" == -* ]]; then
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

_powbox_isolated_by_name() {
    local agent_prefix="$1" lookup_name="$2"
    local name cand=()
    while IFS= read -r name; do
        [ -n "$name" ] && cand+=("$name")
    done < <(docker ps -a --filter "name=$agent_prefix" --filter "label=powbox.self-hosted=true" --format '{{.Names}}')
    [ "${#cand[@]}" -gt 0 ] || return 0

    local iname irepo iref status
    while IFS=$'\x1f' read -r name iname irepo iref status; do
        name="${name#/}"
        [ "$iname" = "<no value>" ] && iname=""
        [ "$irepo" = "<no value>" ] && irepo=""
        [ "$iref" = "<no value>" ] && iref=""
        [ "$iname" = "$lookup_name" ] || continue
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$name" "$iname" "$irepo" "$iref" "$status"
    done < <(docker inspect \
        --format $'{{.Name}}\x1f{{index .Config.Labels "powbox.instance-name"}}\x1f{{index .Config.Labels "powbox.repo"}}\x1f{{index .Config.Labels "powbox.ref"}}\x1f{{.State.Status}}' \
        "${cand[@]}" 2>/dev/null)
}

_powbox_resume_isolated_by_name() {
    local agent_label="$1" agent_prefix="$2" shortcut="$3" lookup_name="$4"
    local matches=() match
    while IFS= read -r match; do
        [ -n "$match" ] && matches+=("$match")
    done < <(_powbox_isolated_by_name "$agent_prefix" "$lookup_name")

    if [ "${#matches[@]}" -eq 0 ]; then
        echo "powbox: no self-hosted $agent_label container found with --name $(_powbox_marker_field "$lookup_name"). Use $shortcut-list to see known instances." >&2
        return 1
    fi

    if [ "${#matches[@]}" -gt 1 ]; then
        echo "powbox: --name $(_powbox_marker_field "$lookup_name") matches multiple self-hosted $agent_label containers. Relaunch one explicitly with --repo, or prune the stale instance." >&2
        for match in "${matches[@]}"; do
            local name iname irepo iref status ref_text=""
            IFS=$'\x1f' read -r name iname irepo iref status <<< "$match"
            [ -n "$iref" ] && ref_text=" --ref $(_powbox_marker_field "$iref")"
            echo "  $name [$status] repo=$(_powbox_marker_field "$irepo")$ref_text" >&2
        done
        return 1
    fi

    local first
    for first in "${matches[@]}"; do break; done
    local name iname irepo iref status
    IFS=$'\x1f' read -r name iname irepo iref status <<< "$first"
    if [ -z "$irepo" ]; then
        echo "powbox: container $name has --name $(_powbox_marker_field "$lookup_name") but no powbox.repo label, so $shortcut cannot reconstruct the isolated resume command. Use: docker start -ai $name" >&2
        return 1
    fi

    "$shortcut" --isolated --repo "$irepo" --name "$iname" --resume
}

cci() {
    if [ $# -ne 1 ]; then
        echo "usage: cci <name>" >&2
        return 2
    fi
    _powbox_resume_isolated_by_name "Claude" "claude-" cc "$1"
}

cxi() {
    if [ $# -ne 1 ]; then
        echo "usage: cxi <name>" >&2
        return 2
    fi
    _powbox_resume_isolated_by_name "Codex" "codex-" cx "$1"
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

# Print the standard `docker ps` table for the given filters, appending a marker to
# each self-hosted (--isolated) row so you can tell WHICH instance it is and resume it
# without an inspect:  [self-hosted name=<--name as entered> repo=<spec> ref=<ref>]
# (fields are omitted when empty, so an unnamed instance shows just repo/ref and an
# old container with none of the labels shows a bare [self-hosted]). The self-hosted
# set is resolved with a label FILTER (docker ps --filter label=powbox.self-hosted=true)
# and the per-row name/repo/ref are read from the powbox.instance-name/repo/ref labels
# via `docker inspect --format {{index ...}}` — both portable, unlike the `{{.Label
# "key"}}` template column podman's docker shim rejects. The name shown is the RAW
# --name (the powbox.instance-name label), which is what disambiguates two names that
# slugify to the same container-name shape. A field value containing whitespace or shell
# metacharacters is single-quoted (e.g. name='Feature A') so the marker stays unambiguous
# and pastes straight back into --name; the raw value is preserved, so its identity hash
# still recomputes. The header and dir-mounted rows pass through unchanged, so the output
# is byte-identical to before when no self-hosted container exists. Names/entries are read
# into arrays (not word-split) so this behaves identically under bash and zsh.

# Render one marker field value: verbatim when "simple" (only characters that survive a
# copy-paste back into the shell unquoted — so repo specs/refs with slashes, colons, @,
# dots stay readable), else POSIX single-quoted so a value with spaces/metacharacters is
# unambiguous and pasteable into a resume command. Embedded single quotes use the '\''
# splice. The raw value is never altered, only how it is displayed.
_powbox_marker_field() {
    case $1 in
    *[!A-Za-z0-9._/@:+-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
    esac
}

_powbox_agent_list() {
    local name cand=()
    while IFS= read -r name; do
        [ -n "$name" ] && cand+=("$name")
    done < <(docker ps -a "$@" --filter "label=powbox.self-hosted=true" --format '{{.Names}}')

    # entries[]: one "NAME<TAB>MARKER" per self-hosted container, built from its labels in
    # a single inspect (output is in input order, but we match by name, not index, so a
    # container that vanishes between the two calls is simply skipped).
    # Field separator is \x1f (US), NOT a tab: tab is IFS-whitespace, so `read` would
    # collapse an EMPTY field (an unnamed instance's blank instance-name) and shift the
    # remaining columns left. \x1f is non-whitespace, so empty fields are preserved.
    local entries=() iname irepo iref marker
    if [ "${#cand[@]}" -gt 0 ]; then
        while IFS=$'\x1f' read -r name iname irepo iref; do
            name="${name#/}" # docker inspect's .Name is /-prefixed
            [ -n "$name" ] || continue
            # A missing label can surface as the literal "<no value>" (Docker renders a
            # nil labels map that way for `index`), so an old/pre-label container would
            # otherwise show "name=<no value> repo=<no value> ...". Treat it as empty so
            # such a container shows a bare [self-hosted], matching how the repo
            # normalizes label reads elsewhere (commands/check-updates.sh, build-image.sh).
            [ "$iname" = "<no value>" ] && iname=""
            [ "$irepo" = "<no value>" ] && irepo=""
            [ "$iref" = "<no value>" ] && iref=""
            marker=" [self-hosted"
            [ -n "$iname" ] && marker="$marker name=$(_powbox_marker_field "$iname")"
            [ -n "$irepo" ] && marker="$marker repo=$(_powbox_marker_field "$irepo")"
            [ -n "$iref" ] && marker="$marker ref=$(_powbox_marker_field "$iref")"
            marker="$marker]"
            entries+=("$name"$'\t'"$marker")
        done < <(docker inspect \
            --format $'{{.Name}}\x1f{{index .Config.Labels "powbox.instance-name"}}\x1f{{index .Config.Labels "powbox.repo"}}\x1f{{index .Config.Labels "powbox.ref"}}' \
            "${cand[@]}" 2>/dev/null)
    fi

    local line row_name marked entry
    while IFS= read -r line; do
        # The Names column is field 2 of the table (ID NAMES STATUS IMAGE), and a
        # container name never contains whitespace, so the 2nd whitespace-delimited
        # token is the row's exact name. Compare it for EQUALITY: matching the whole
        # formatted line by substring would mislabel a row when one container name is
        # a substring of another (claude-foo vs claude-foo-bar) or when a name shows
        # up in another column. The header row's field 2 ("ID") matches no container,
        # so it passes through unmarked.
        row_name="$(printf '%s\n' "$line" | awk '{print $2}')"
        marked=""
        for entry in "${entries[@]}"; do
            if [ "$row_name" = "${entry%%$'\t'*}" ]; then
                marked="${entry#*$'\t'}"
                break
            fi
        done
        printf '%s%s\n' "$line" "$marked"
    done < <(docker ps -a "$@" --format $'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}')
}

cc-list() {
    _powbox_agent_list --filter "name=claude-"
}

cx-list() {
    _powbox_agent_list --filter "name=codex-"
}

agent-list() {
    _powbox_agent_list --filter "name=claude-" --filter "name=codex-"
}

agent-volumes() {
    docker volume ls --filter "name=claude-config" --filter "name=codex-config" --filter "name=agent-" --format $'table {{.Name}}\t{{.Driver}}\t{{.Mountpoint}}'
}
