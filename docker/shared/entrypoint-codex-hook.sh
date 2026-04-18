#!/usr/bin/env bash
set -euo pipefail

AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:?AGENT_CONFIG_DIR must be set}"
AGENT_HOST_SEED_DIR="${AGENT_HOST_SEED_DIR:-/home/node/.codex-host}"

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

# Seed the persistent Codex config volume from a host config directory on the
# first run only. Subsequent runs keep the Docker-managed state untouched.
if [ -d "$AGENT_HOST_SEED_DIR" ] &&
	[ -n "$(find "$AGENT_HOST_SEED_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] &&
	[ ! -f "$AGENT_CONFIG_DIR/config.toml" ]; then
	rsync -a --no-owner --no-group --ignore-existing \
		--exclude '/tmp/' \
		--exclude '/.tmp/' \
		--exclude '/cache/' \
		--exclude '/log/' \
		--exclude '/sessions/' \
		--exclude '*.sqlite' \
		--exclude '*.sqlite-shm' \
		--exclude '*.sqlite-wal' \
		--exclude 'history.jsonl' \
		--exclude 'sandbox.log' \
		"$AGENT_HOST_SEED_DIR"/ "$AGENT_CONFIG_DIR"/
	chmod 700 "$AGENT_CONFIG_DIR" || true
	if [ -f "$AGENT_CONFIG_DIR/config.toml" ]; then
		chmod 600 "$AGENT_CONFIG_DIR/config.toml" || true
	fi
fi

# Seed a richer native Codex status line/title, but only when the user has not
# already chosen their own values.
CONFIG_FILE="$AGENT_CONFIG_DIR/config.toml"
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
		echo "$IMAGE_EPOCH" > "$AGENT_CONFIG_DIR/.instruction-epoch"
	fi
fi

if [ -z "${OPENAI_API_KEY:-}" ]; then
	echo "Warning: OPENAI_API_KEY is not set. Codex CLI will not be able to authenticate with OpenAI." >&2
	echo "Pass it via: -e OPENAI_API_KEY=\$OPENAI_API_KEY when launching the container." >&2
fi
