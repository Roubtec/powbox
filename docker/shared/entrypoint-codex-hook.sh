#!/usr/bin/env bash
set -euo pipefail

AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:?AGENT_CONFIG_DIR must be set}"

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

ensure_table_array_setting() {
	local file="$1" table="$2" key="$3" values="$4"

	if [ ! -f "$file" ]; then
		: >"$file"
	fi

	local block table_header tmp
	block="${key} = [
${values}
]"
	table_header="[${table}]"
	tmp="$(mktemp)"

	awk -v block="$block" -v table_header="$table_header" -v key="$key" '
		BEGIN {
			in_table = 0
			inserted = 0
		}
		$0 == table_header {
			in_table = 1
			print
			next
		}
		in_table && /^\[/ {
			if (!inserted) {
				print block
				print ""
				inserted = 1
			}
			in_table = 0
		}
		in_table && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
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
chmod 600 "$CONFIG_FILE" || true

AGENT_TMPL="/home/node/.agent-container/agent.md.tmpl"
if [ -f "$AGENT_TMPL" ]; then
	IMAGE_EPOCH=$(cat /home/node/.agent-container/build-epoch 2>/dev/null || echo 0)
	[[ "$IMAGE_EPOCH" =~ ^[0-9]+$ ]] || IMAGE_EPOCH=0
	VOLUME_EPOCH=$(cat "$AGENT_CONFIG_DIR/.instruction-epoch" 2>/dev/null || echo 0)
	[[ "$VOLUME_EPOCH" =~ ^[0-9]+$ ]] || VOLUME_EPOCH=0
	if [ "$IMAGE_EPOCH" -ge "$VOLUME_EPOCH" ]; then
		# shellcheck disable=SC2016
		# envsubst needs literal ${VAR} names.
		envsubst '${AGENT_NAME} ${AGENT_AUTONOMY_FLAG} ${AGENT_CONFIG_DIR}' \
			< "$AGENT_TMPL" > "$AGENT_CONFIG_DIR/${AGENT_INSTRUCTION_FILE:?}"

		# Seed image-baked skills (no-clobber: preserves user-modified versions;
		# delete the skill directory to pick up the latest image version on next
		# container start). Per-repo .agents/skills/ still takes precedence at
		# invoke time.
		SKILLS_SRC="/home/node/.agent-container/skills"
		SKILLS_DEST="$AGENT_CONFIG_DIR/agents/skills"
		if [ -d "$SKILLS_SRC" ]; then
			mkdir -p "$SKILLS_DEST"
			for skill_dir in "$SKILLS_SRC"/*/; do
				[ -d "$skill_dir" ] || continue
				skill_name="$(basename "$skill_dir")"
				dest_dir="$SKILLS_DEST/$skill_name"
				[ -d "$dest_dir" ] && continue
				tmp_dir="$(mktemp -d "$SKILLS_DEST/.${skill_name}.tmp.XXXXXX")"
				if cp -a "$skill_dir"/. "$tmp_dir"/; then
					if [ -d "$dest_dir" ]; then
						rm -rf "$tmp_dir"
						continue
					fi
					if mv "$tmp_dir" "$dest_dir"; then
						continue
					fi
				fi
				rm -rf "$tmp_dir"
				if [ ! -d "$dest_dir" ]; then
					echo "Warning: failed to seed skill $skill_name" >&2
				fi
			done
		fi

		echo "$IMAGE_EPOCH" > "$AGENT_CONFIG_DIR/.instruction-epoch"
	fi
fi

if [ -z "${OPENAI_API_KEY:-}" ]; then
	echo "Warning: OPENAI_API_KEY is not set. Codex CLI will not be able to authenticate with OpenAI." >&2
	echo "Pass it via: -e OPENAI_API_KEY=\$OPENAI_API_KEY when launching the container." >&2
fi
