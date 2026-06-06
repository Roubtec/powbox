#!/usr/bin/env bash
set -euo pipefail

# The agent image is unified: both claude and codex (and codex's bwrap sandbox)
# are baked into the same image alongside the shared toolchain, so one smoke
# test validates everything in a single pass.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE="${1:-powbox-agent:latest}"

# Stage 1 — tool presence: every expected CLI resolves and runs.
"${ROOT_DIR}/scripts/smoke-test-image.sh" "$IMAGE" \
	"claude --version >/dev/null" \
	"codex --version >/dev/null" \
	"bwrap --version >/dev/null" \
	"gh --version >/dev/null" \
	"node --version >/dev/null" \
	"npm --version >/dev/null" \
	"pnpm --version >/dev/null" \
	"pip3 --version >/dev/null" \
	"python3 --version >/dev/null" \
	"sqlcmd -? >/dev/null" \
	"sqlite3 --version >/dev/null" \
	"psql --version >/dev/null" \
	"pg-dev-up check >/dev/null" \
	"shellcheck --version >/dev/null" \
	"ping -V >/dev/null" \
	"nc -h >/dev/null 2>&1" \
	"bc --version >/dev/null" \
	"less --version >/dev/null" \
	"lsof -v >/dev/null 2>&1" \
	"tree --version >/dev/null" \
	"fd --version >/dev/null" \
	"fzf --version >/dev/null" \
	"bat --version >/dev/null" \
	"ssh -V >/dev/null 2>&1" \
	"rsync --version >/dev/null" \
	"strace -V >/dev/null" \
	"gpg --version >/dev/null" \
	"gcc --version >/dev/null" \
	"file --version >/dev/null" \
	"printf test | xxd >/dev/null" \
	"envsubst --version >/dev/null" \
	"yq --version >/dev/null" \
	"shfmt --version >/dev/null" \
	"unzip -v >/dev/null" \
	"zip -v >/dev/null" \
	"wget --version >/dev/null" \
	"htop --version >/dev/null"

# Stage 2 — pg-dev-up functional test: stand up a real throwaway cluster and
# connect through the emitted DATABASE_URL. Unlike `pg-dev-up check` (binary
# presence only) this exercises role/db creation, URL percent-encoding, the
# 127.0.0.1 host binding, and the eval round-trip. Deliberately nasty
# credentials prove the SQL-quoting and URL-encoding paths. Skip the daemon
# bring-up (and keep the fast presence-only sweep) with POWBOX_SMOKE_SKIP_DB=1.
if [ -n "${POWBOX_SMOKE_SKIP_DB:-}" ]; then
	echo "Skipping pg-dev-up functional test (POWBOX_SMOKE_SKIP_DB is set)."
	exit 0
fi

echo "Running pg-dev-up functional test against $IMAGE ..."
docker run --rm \
	-e POSTGRES_USER=t \
	-e POSTGRES_PASSWORD='p@s/s&w#d' \
	-e POSTGRES_DB=app \
	--entrypoint /bin/sh "$IMAGE" -lc '
set -e
pg-dev-up up >/dev/null
url=$(pg-dev-up url)
echo "DATABASE_URL=$url"
printf %s "$url" | grep -qF "p%40s%2Fs%26w%23d" || { echo "FAIL: password not percent-encoded in URL" >&2; exit 1; }
printf %s "$url" | grep -qF "@127.0.0.1:" || { echo "FAIL: URL host is not 127.0.0.1" >&2; exit 1; }
eval "$(pg-dev-up url --export)"
out=$(psql "$DATABASE_URL" -tAc "SELECT current_user, current_database()")
echo "psql SELECT -> $out"
printf %s "$out" | grep -qxF "t|app" || { echo "FAIL: unexpected psql result: $out" >&2; exit 1; }
pg-dev-up down >/dev/null
'
echo "Smoke test (tools + pg-dev-up) passed."
