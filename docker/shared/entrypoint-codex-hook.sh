#!/usr/bin/env bash
set -euo pipefail

# This script is normally executed by the unified entrypoint, but the seed
# helper functions below are also unit-tested in isolation (see
# scripts/test-codex-config-seed.sh). Everything above the "sourced?" guard near
# the end is pure function definitions with no side effects, so a test can
# `source` this file to get the helpers without running the seeding body.

ensure_top_level_array_setting() {
	local file="$1" key="$2" values="$3"

	if [ ! -f "$file" ]; then
		: >"$file"
	fi

	if awk -v key="$key" '
		/^[[:space:]]*\[/ { exit }
		$0 ~ "^[[:space:]]*" key "[[:space:]]*=" { found = 1; exit }
		END { exit (!found) }
	' "$file"; then
		return
	fi

	local block tmp
	block="${key} = [
${values}
]"
	tmp="$(mktemp)"

	awk -v block="$block" '
		BEGIN {
			inserted = 0
		}
		/^\[/ && !inserted {
			print block
			print ""
			inserted = 1
		}
		{
			print
		}
		END {
			if (!inserted) {
				if (NR > 0) {
					print ""
				}
				print block
			}
		}
	' "$file" >"$tmp"

	mv "$tmp" "$file"
}

# Return success (0) when a table setting is already present in a form the
# ensure_table_* writers must not touch: either `key` is set under a real
# [table] header (tolerating a decorated header with surrounding whitespace or a
# trailing comment), OR `table` exists only as an inline table (table = { ... }).
# The writers call this as a no-clobber early return so an already-seeded key
# leaves the file byte- and mtime-stable, and an inline table is never shadowed
# by a duplicate [table] header (a config Codex rejects). `table`/`key` are
# controlled literals (no regex metacharacters).
config_table_setting_present() {
	local file="$1" table="$2" key="$3"

	[ -f "$file" ] || return 1

	# Inline table form: cannot be extended in place, so a later [table] header
	# would define the table twice. Treat as present (skip the write). TOML treats
	# table, "table", and 'table' as the same key, so accept either quote char.
	if grep -qE "^[[:space:]]*[\"']?${table}[\"']?[[:space:]]*=[[:space:]]*\{" "$file"; then
		return 0
	fi

	# key already set under a [table] header. The header and the key both tolerate
	# the TOML-equivalent bare / "double" / 'single' quoted spellings.
	awk -v table="$table" -v key="$key" '
		BEGIN {
			header_re = "^[[:space:]]*\\[[[:space:]]*[\"'\'']?" table "[\"'\'']?[[:space:]]*\\][[:space:]]*(#.*)?$"
		}
		$0 ~ header_re {
			in_table = 1
			next
		}
		in_table && /^[[:space:]]*\[/ {
			in_table = 0
		}
		in_table && $0 ~ ("^[[:space:]]*[\"'\'']?" key "[\"'\'']?[[:space:]]*=") {
			found = 1
			exit
		}
		END {
			exit (!found)
		}
	' "$file"
}

ensure_table_array_setting() {
	local file="$1" table="$2" key="$3" values="$4"

	if [ ! -f "$file" ]; then
		: >"$file"
	fi

	# No-clobber early return: leave the file byte- and mtime-stable (no rewrite)
	# when the key is already set under [table], or when [table] exists only as an
	# inline table (table = { ... }) we cannot safely extend in place. This makes
	# every-start re-runs a true no-op. See config_v2_seed_blocked for the header
	# forms recognised; `table` is a controlled literal (no regex metacharacters).
	if config_table_setting_present "$file" "$table" "$key"; then
		return
	fi

	local block table_header tmp
	block="${key} = [
${values}
]"
	table_header="[${table}]"
	tmp="$(mktemp)"

	awk -v block="$block" -v table_header="$table_header" -v table="$table" -v key="$key" '
		BEGIN {
			header_re = "^[[:space:]]*\\[[[:space:]]*[\"'\'']?" table "[\"'\'']?[[:space:]]*\\][[:space:]]*(#.*)?$"
			in_table = 0
			inserted = 0
		}
		$0 ~ header_re {
			in_table = 1
			print
			next
		}
		in_table && /^[[:space:]]*\[/ {
			if (!inserted) {
				print block
				print ""
				inserted = 1
			}
			in_table = 0
		}
		in_table && $0 ~ ("^[[:space:]]*[\"'\'']?" key "[\"'\'']?[[:space:]]*=") {
			inserted = 1
		}
		{
			print
		}
		END {
			if (!inserted) {
				if (in_table) {
					print block
				} else {
					if (NR > 0) {
						print ""
					}
					print table_header
					print block
				}
			}
		}
	' "$file" >"$tmp"

	mv "$tmp" "$file"
}

# Insert a scalar `key = value` under [table], no-clobber. The scalar sibling of
# ensure_table_array_setting: same placement logic (into an existing [table], or
# append the table at EOF), but the value is written verbatim as a single line
# rather than a multi-line array. Skips when the key is already set under the
# table so a user/host value is never overwritten.
ensure_table_scalar_setting() {
	local file="$1" table="$2" key="$3" value="$4"

	if [ ! -f "$file" ]; then
		: >"$file"
	fi

	# No-clobber early return, mirroring ensure_table_array_setting: skip the
	# rewrite when the key is already set under [table] (byte- and mtime-stable
	# re-run) or when [table] exists only as an inline table we must not shadow.
	if config_table_setting_present "$file" "$table" "$key"; then
		return
	fi

	local block table_header tmp
	block="${key} = ${value}"
	table_header="[${table}]"
	tmp="$(mktemp)"

	awk -v block="$block" -v table_header="$table_header" -v table="$table" -v key="$key" '
		BEGIN {
			header_re = "^[[:space:]]*\\[[[:space:]]*[\"'\'']?" table "[\"'\'']?[[:space:]]*\\][[:space:]]*(#.*)?$"
			in_table = 0
			inserted = 0
		}
		$0 ~ header_re {
			in_table = 1
			print
			next
		}
		in_table && /^[[:space:]]*\[/ {
			if (!inserted) {
				print block
				print ""
				inserted = 1
			}
			in_table = 0
		}
		in_table && $0 ~ ("^[[:space:]]*[\"'\'']?" key "[\"'\'']?[[:space:]]*=") {
			inserted = 1
		}
		{
			print
		}
		END {
			if (!inserted) {
				if (in_table) {
					print block
				} else {
					if (NR > 0) {
						print ""
					}
					print table_header
					print block
				}
			}
		}
	' "$file" >"$tmp"

	mv "$tmp" "$file"
}

# Decide whether the multi_agent_v2 concurrency default must NOT be seeded.
# Returns success (0 = "blocked, skip the seed") when any of:
#   1. The config already carries a multi_agent_v2 assignment in any form —
#      the [features] table or an inline `features = { multi_agent_v2 = ... }`,
#      set to true OR false, with a bare, "double"-quoted or 'single'-quoted key
#      (TOML treats all three spellings as the same key). No-clobber: never
#      overwrite the user's choice.
#   2. The config already defines an [agents] block in ANY valid-TOML form: a
#      table header ([agents] / [agents.sub] / [[agents]] array-of-tables, with
#      optional inner whitespace or quotes such as [ agents ] / ["agents"] /
#      ['agents']), a top-level dotted assignment (agents.max_threads = ...), or
#      an inline table (agents = { ... }), with a bare, "double"- or 'single'-
#      quoted key. Codex refuses to launch when both an [agents] block
#      and features.multi_agent_v2 are set (they are mutually exclusive), so we
#      must never author that conflict. The seed is no-clobber, so it will not
#      remove the [agents] block either — a user opting into v2 must delete it
#      themselves (documented in README as the migration caveat).
#   3. The config already defines the features table at top level without a
#      [features] header — either as an INLINE table (features = { ... }) or via
#      a top-level dotted key (features.some_flag = ...) — carrying no
#      multi_agent_v2 key. In both forms `features` is CONCRETELY defined, so
#      appending a separate [features] table would define `features` twice — a
#      config Codex rejects (a "duplicate key" TOML error). (A real [features]
#      header is fine: the writer extends it in place, so it is intentionally NOT
#      matched here. A [features.<sub>] / ["features".<sub>] subtable header is
#      likewise, and deliberately, NOT matched: it only *implicitly* creates the
#      `features` super-table, and TOML 1.0.0 explicitly permits defining a plain
#      [features] table afterward — the writer appends exactly that, landing
#      multi_agent_v2 on the same `features` table as valid TOML Codex loads.
#      Verified against the Rust `toml` crate and Python tomllib; see PR #108
#      review thread r3577981715.) Fail safe: skip the seed rather than author a
#      duplicate-table conflict for the inline/dotted forms.
# Returns failure (1 = "not blocked, seed it") otherwise, including a cold
# config file that does not exist yet.
#
# The guard is deliberately conservative: when in doubt it errs toward NOT
# seeding rather than authoring a config Codex would reject. It keys off the
# literal `multi_agent_v2` name, so the (unrealistic) case of that key living
# under an unrelated table also blocks — this only ever skips the seed, never
# corrupts a config, so the conservative over-match is acceptable.
config_v2_seed_blocked() {
	local file="$1"

	[ -f "$file" ] || return 1

	# Any multi_agent_v2 assignment, whether under [features] or inline; the key
	# is not line-anchored so an inline `features = { multi_agent_v2 = ... }` is
	# caught too, and an optional closing quote (either " or ', which TOML treats
	# identically) catches a quoted `"multi_agent_v2"` / `'multi_agent_v2'`.
	if grep -qE 'multi_agent_v2["'\'']?[[:space:]]*=' "$file"; then
		return 0
	fi

	# An existing [agents] table header ([agents] / [agents.sub] / [[agents]]
	# array-of-tables, with optional inner whitespace or quotes), a top-level
	# dotted key (agents.<key> = ...), or an inline table (agents = { ... }), with
	# an optionally " or ' quoted "agents" (TOML-equivalent spellings).
	if grep -qE '^[[:space:]]*(\[\[?[[:space:]]*["'\'']?agents["'\'']?[[:space:]]*[].]|["'\'']?agents["'\'']?[[:space:]]*[.=])' "$file"; then
		return 0
	fi

	# A top-level features definition with no multi_agent_v2 key (that case is
	# caught above): an inline table (features = { ... }) OR a top-level dotted key
	# (features.some_flag = ...). In either form `features` is already defined, so
	# appending a [features] table would define it twice. The trailing [.=] accepts
	# a dotted key (features.x) or an assignment (features = ...); a real [features]
	# table header starts with `[` and is intentionally not matched, so the writer
	# can extend it in place. Accept a bare or " / ' quoted "features".
	if grep -qE '^[[:space:]]*["'\'']?features["'\'']?[[:space:]]*[.=]' "$file"; then
		return 0
	fi

	return 1
}

replace_config_string() {
	local file="$1" old="$2" new="$3"

	# An empty $old would match every position and spin the awk index() loop
	# below forever; it is never a meaningful migration, so bail out. The grep
	# `--` guards a $old that begins with `-` from being parsed as an option.
	if [ -z "$old" ] || [ ! -f "$file" ] || ! grep -qF -- "$old" "$file"; then
		return
	fi

	local tmp
	tmp="$(mktemp)"
	# Literal (non-regex) replacement: awk index/substr avoids sed treating
	# metacharacters in $old/$new (. * [ ] / & \ ...) as regex or replacement
	# syntax. Values are passed via the environment so awk does not interpret
	# backslash escapes the way it would with -v.
	old="$old" new="$new" awk '
		BEGIN { old = ENVIRON["old"]; new = ENVIRON["new"] }
		{
			line = $0
			result = ""
			while ((pos = index(line, old)) > 0) {
				result = result substr(line, 1, pos - 1) new
				line = substr(line, pos + length(old))
			}
			print result line
		}
	' "$file" >"$tmp"
	mv "$tmp" "$file"
}

# When sourced (e.g. by scripts/test-codex-config-seed.sh), stop here so only the
# helper functions above are defined — none of the seeding side effects below run.
if (return 0 2>/dev/null); then
	return 0
fi

AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:?AGENT_CONFIG_DIR must be set}"
# Directory holding this agent's image-baked seed assets (instruction template,
# skills, build epoch). Defaults to the legacy shared path so the hook still
# works standalone; the unified entrypoint points it at the per-agent
# subdirectory /home/node/.agent-container/<agent>.
AGENT_SEED_DIR="${AGENT_SEED_DIR:-/home/node/.agent-container}"

# Host config is intentionally not seeded; the container grows its own Codex ecosystem
# (config.toml, sessions, history) independent of the host. The ensure_* helpers below
# write the image-baked statusline/terminal-title defaults straight into config.toml
# when the keys are missing, which covers the only state we care to seed.
chmod 700 "$AGENT_CONFIG_DIR" 2>/dev/null || true

# Codex's user-level skill search path is $HOME/.agents/skills. Point ~/.agents at a
# subdirectory of $AGENT_CONFIG_DIR so skill customisations persist in the codex-config
# volume without requiring a separate volume. Only create the symlink when the path does
# not already exist or is already a symlink (guards against an older codex-agents volume
# mount left over from a stale container).
AGENTS_LINK="$HOME/.agents"
AGENTS_TARGET="$AGENT_CONFIG_DIR/agents"
mkdir -p "$AGENTS_TARGET"
if [ ! -e "$AGENTS_LINK" ] || [ -L "$AGENTS_LINK" ]; then
	ln -sfn "$AGENTS_TARGET" "$AGENTS_LINK"
fi

# Seed a richer native Codex status line/title, but only when the user has not
# already chosen their own values.
CONFIG_FILE="$AGENT_CONFIG_DIR/config.toml"
# Codex 0.135 removed context-remaining-percent; keep older persisted volumes
# warning-free while preserving the user's status line ordering.
replace_config_string "$CONFIG_FILE" '"context-remaining-percent"' '"context-remaining"'
STATUS_LINE_DEFAULTS=$(cat <<'EOF'
  "model-with-reasoning",
  "current-dir",
  "context-remaining",
  "five-hour-limit",
  "weekly-limit",
  "used-tokens"
EOF
)
TERMINAL_TITLE_DEFAULTS=$(cat <<'EOF'
  "current-dir",
  "git-branch",
  "model-name",
  "thread-title"
EOF
)
# Codex persists the bottom status line picker under [tui].status_line.
ensure_table_array_setting "$CONFIG_FILE" "tui" "status_line" "$STATUS_LINE_DEFAULTS"
# terminal_title is a separate top-level setting for the terminal/tab title.
ensure_top_level_array_setting "$CONFIG_FILE" "terminal_title" "$TERMINAL_TITLE_DEFAULTS"

# Raise Codex's multi-agent concurrency default by enabling multi_agent_v2, whose
# built-in concurrency (>=8 threads) roughly doubles the legacy [agents] ceiling
# (~4, one reserved for root) with no tuning keys required. This powers powbox's
# parallel fan-outs (address-tasks / address-reviews and Codex-side delegation).
# No-clobber and guarded: config_v2_seed_blocked skips the seed when the user
# already set multi_agent_v2 (true or false) or defines an [agents] block, so we
# never overwrite a choice nor author the mutually-exclusive [agents] +
# multi_agent_v2 config Codex rejects at load. The unstable-feature warning is
# left ON (suppress_unstable_features_warning is intentionally not seeded) so the
# pre-release opt-in stays visible until v2 graduates. See README "Codex config".
if ! config_v2_seed_blocked "$CONFIG_FILE"; then
	ensure_table_scalar_setting "$CONFIG_FILE" "features" "multi_agent_v2" "true"
fi
chmod 600 "$CONFIG_FILE" || true

AGENT_TMPL="$AGENT_SEED_DIR/agent.md.tmpl"
if [ -f "$AGENT_TMPL" ]; then
	IMAGE_EPOCH=$(cat "$AGENT_SEED_DIR/build-epoch" 2>/dev/null || echo 0)
	[[ "$IMAGE_EPOCH" =~ ^[0-9]+$ ]] || IMAGE_EPOCH=0
	VOLUME_EPOCH=$(cat "$AGENT_CONFIG_DIR/.instruction-epoch" 2>/dev/null || echo 0)
	[[ "$VOLUME_EPOCH" =~ ^[0-9]+$ ]] || VOLUME_EPOCH=0
	if [ "$IMAGE_EPOCH" -ge "$VOLUME_EPOCH" ]; then
		# shellcheck disable=SC2016
		# envsubst needs literal ${VAR} names.
		envsubst '${AGENT_NAME} ${AGENT_AUTONOMY_FLAG} ${AGENT_CONFIG_DIR} ${AGENT_PEERS}' \
			< "$AGENT_TMPL" > "$AGENT_CONFIG_DIR/${AGENT_INSTRUCTION_FILE:?}"

		# Seed image-baked skills (no-clobber: preserves user-modified versions;
		# delete the skill directory to pick up the latest image version on next
		# container start, or run `agent-update-skills` to force a refresh).
		# Per-repo .agents/skills/ still takes precedence at invoke time. The copy
		# logic and the .powbox-seeded ownership marker live in the shared
		# seed-skills.sh so this and the updater never drift.
		# shellcheck source=docker/shared/seed-skills.sh
		. /usr/local/bin/seed-skills.sh
		seed_skills "$AGENT_SEED_DIR/skills" "$AGENT_CONFIG_DIR/agents/skills" noclobber "$AGENT_SEED_DIR" ||
			echo "Warning: one or more Codex skills failed to seed; continuing." >&2

		echo "$IMAGE_EPOCH" > "$AGENT_CONFIG_DIR/.instruction-epoch"
	fi
fi

if [ -z "${OPENAI_API_KEY:-}" ] && [ "${PRIMARY_AGENT:-codex}" = "codex" ]; then
	echo "Warning: OPENAI_API_KEY is not set. Codex CLI will not be able to authenticate with OpenAI." >&2
	echo "Set OPENAI_API_KEY on the host before launching, or pass it with docker run/compose." >&2
fi
