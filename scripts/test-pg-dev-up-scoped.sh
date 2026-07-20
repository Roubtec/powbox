#!/usr/bin/env bash
# Unit/integration tests for docker/shared/pg-dev-up scoped mode (task 027).
#
# Focus: the opt-in worktree/profile isolation. Two different Git worktrees must
# run `pg-dev-up --worktree` CONCURRENTLY and receive distinct data directories
# and ports, create/connect to their own configured databases, resolve the same
# instance on re-invocation, and stop INDEPENDENTLY — with `down` never touching
# an unrelated cluster. Also guards: explicit env overrides stay authoritative,
# `--profile <id>` works outside Git, and `--worktree` outside Git fails loudly
# instead of guessing.
#
# Runs the real repo copy of pg-dev-up directly against the baked PostgreSQL
# server binaries — no image build. Everything is confined to a private temp
# SCOPED_ROOT via POWBOX_PG_SCOPED_ROOT and throwaway git repos, so it never
# sees or sweeps a real /tmp cluster. Skips ONLY when the server binaries are
# absent (never to hide a collision); a genuine isolation break is a FAIL.
#
# Usage: scripts/test-pg-dev-up-scoped.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PG="$SCRIPT_DIR/../docker/shared/pg-dev-up"

if [ ! -f "$PG" ]; then
	echo "FATAL: pg-dev-up not found at $PG" >&2
	exit 1
fi

# Locate the server binaries the way pg-dev-up does; skip (do not fail) if the
# PostgreSQL server is not installed on this host.
find_bindir() {
	local d best=""
	for d in /usr/lib/postgresql/*/bin; do
		[ -x "$d/initdb" ] || continue
		if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best" "$d" | sort -V | tail -1)" = "$d" ]; then
			best="$d"
		fi
	done
	[ -n "$best" ] || return 1
	printf '%s\n' "$best"
}
if ! BINDIR="$(find_bindir)"; then
	echo "pg-dev-up scoped test skipped: PostgreSQL server binaries not found (install postgresql-16 to run it)."
	exit 0
fi

WORK="$(mktemp -d)"
SCOPED_ROOT="$WORK/scoped-root"
export POWBOX_PG_SCOPED_ROOT="$SCOPED_ROOT"
export CONTAINER_NAME="pg-scoped-test-$$"

# Stop any cluster we started and remove the sandbox, whatever happens.
STARTED_DATADIRS=()
cleanup() {
	local d
	for d in "${STARTED_DATADIRS[@]:-}"; do
		[ -n "$d" ] || continue
		[ -f "$d/postmaster.pid" ] || continue
		"$BINDIR/pg_ctl" -D "$d" -m immediate -w stop >/dev/null 2>&1 || true
	done
	rm -rf "$WORK"
}
trap cleanup EXIT

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}
ko() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
}
# try <desc> <cmd...>      -> ok if cmd succeeds, ko otherwise
# try_not <desc> <cmd...>  -> ok if cmd FAILS, ko otherwise (negative assertion)
try() {
	local desc="$1"
	shift
	if "$@"; then ok "$desc"; else ko "$desc"; fi
}
try_not() {
	local desc="$1"
	shift
	if "$@"; then ko "$desc"; else ok "$desc"; fi
}

# Run pg-dev-up from inside a given directory with a clean, explicit env.
# Usage: pg <cwd> [ENV=VAL ...] -- <pg-dev-up args...>
pg() {
	local cwd="$1"
	shift
	local -a envs=()
	while [ "$1" != "--" ]; do
		envs+=("$1")
		shift
	done
	shift # drop --
	(cd "$cwd" && env "${envs[@]}" bash "$PG" "$@")
}

# Create a throwaway git repo with one commit.
make_repo() {
	local dir="$1"
	mkdir -p "$dir"
	git -C "$dir" init -q
	git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

REPO_A="$WORK/repo-a"
REPO_B="$WORK/repo-b"
make_repo "$REPO_A"
make_repo "$REPO_B"

echo "== two concurrent worktree-scoped instances =="

# Bring both up with distinct configured databases (exercise createdb per side).
url_a="$(pg "$REPO_A" POSTGRES_DB=app_a -- --worktree up | tail -1)"
url_b="$(pg "$REPO_B" POSTGRES_DB=app_b -- --worktree up | tail -1)"

# Record the data dirs for teardown even if later assertions fail.
data_a="$(pg "$REPO_A" -- --worktree status 2>&1 | sed -n 's/.*PGDATA=\([^)]*\)).*/\1/p')"
data_b="$(pg "$REPO_B" -- --worktree status 2>&1 | sed -n 's/.*PGDATA=\([^)]*\)).*/\1/p')"
STARTED_DATADIRS=("$data_a" "$data_b")

port_a="${url_a##*:}"
port_a="${port_a%%/*}"
port_b="${url_b##*:}"
port_b="${port_b%%/*}"

if [ -n "$port_a" ] && [ -n "$port_b" ]; then ok "both instances reported a URL/port"; else ko "missing URL/port (a='$url_a' b='$url_b')"; fi
try "distinct ports ($port_a vs $port_b)" test "$port_a" != "$port_b"
try "distinct data dirs" test "$data_a" != "$data_b"
case "$data_a" in "$SCOPED_ROOT"/*) ok "A data dir under scoped root" ;; *) ko "A data dir not under scoped root: $data_a" ;; esac

# Each connects to ITS OWN configured database.
db_a="$(psql "$url_a" -tAc 'select current_database()' 2>/dev/null || true)"
db_b="$(psql "$url_b" -tAc 'select current_database()' 2>/dev/null || true)"
try "A connects to app_a (got '$db_a')" test "$db_a" = "app_a"
try "B connects to app_b (got '$db_b')" test "$db_b" = "app_b"

echo "== re-invocation resolves the SAME instance =="
url_a2="$(pg "$REPO_A" POSTGRES_DB=app_a -- --worktree url)"
try "repeat url matches ($port_a)" test "$url_a2" = "$url_a"
try "status reports running" pg "$REPO_A" -- --worktree status
exp_a="$(pg "$REPO_A" POSTGRES_DB=app_a -- --worktree url --export)"
if printf %s "$exp_a" | grep -qF "export DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:${port_a}/app_a"; then
	ok "url --export emits the scoped DATABASE_URL"
else
	ko "url --export wrong: $exp_a"
fi

echo "== independent teardown (down must not touch the other) =="
pg "$REPO_A" -- --worktree down >/dev/null 2>&1 || true
try_not "A stopped by its own down" pg "$REPO_A" -- --worktree status
try "B untouched by A's down (still running)" pg "$REPO_B" -- --worktree status
# B must still be reachable.
try "B still serves queries after A's down" test "$(psql "$url_b" -tAc 'select 1' 2>/dev/null || true)" = "1"
pg "$REPO_B" -- --worktree down >/dev/null 2>&1 || true
try_not "B stopped by its own down" pg "$REPO_B" -- --worktree status

echo "== explicit env overrides stay authoritative =="
# Explicit PGPORT wins over allocation and is recorded for later resolution.
free_port=6543
url_p="$(pg "$REPO_A" PGPORT="$free_port" POSTGRES_DB=app_a -- --worktree up | tail -1)"
STARTED_DATADIRS+=("$data_a")
port_p="${url_p##*:}"
port_p="${port_p%%/*}"
try "explicit PGPORT honored ($free_port)" test "$port_p" = "$free_port"
# A later read (no PGPORT) resolves the explicit port that up recorded.
url_pr="$(pg "$REPO_A" POSTGRES_DB=app_a -- --worktree url)"
try "recorded explicit port resolved on read" test "$url_pr" = "$url_p"
pg "$REPO_A" -- --worktree down >/dev/null 2>&1 || true

# A running scoped cluster must NOT be retargeted by a later mismatched PGPORT:
# up while running on $free_port but asked for a different port stays on the real
# one (never talks to whatever sits on the requested port).
url_pm="$(pg "$REPO_A" PGPORT="$free_port" POSTGRES_DB=app_a -- --worktree up | tail -1)"
STARTED_DATADIRS+=("$data_a")
try "still on real port after up" test "${url_pm##*:}" = "${free_port}/app_a"
url_mis="$(pg "$REPO_A" PGPORT=6544 POSTGRES_DB=app_a -- --worktree up 2>/dev/null | tail -1)"
try "mismatched PGPORT does not retarget a running cluster" test "${url_mis##*:}" = "${free_port}/app_a"
pg "$REPO_A" -- --worktree down >/dev/null 2>&1 || true

# Explicit PGDATA replaces the scoped data dir but keeps scoped port allocation,
# and is RECORDED so a later `down` (without repeating PGDATA) stops that cluster.
alt_data="$WORK/alt-pgdata"
url_d="$(pg "$REPO_B" PGDATA="$alt_data" POSTGRES_DB=app_b -- --worktree up | tail -1)"
STARTED_DATADIRS+=("$alt_data")
try "explicit PGDATA used as data dir" test -s "$alt_data/PG_VERSION"
port_d="${url_d##*:}"
port_d="${port_d%%/*}"
try "scoped port still allocated with explicit PGDATA ($port_d)" test "$port_d" != "5432"
# down WITHOUT repeating PGDATA must resolve the recorded data dir and stop it.
rec_data="$(pg "$REPO_B" -- --worktree status 2>&1 | sed -n 's/.*PGDATA=\([^)]*\)).*/\1/p')"
try "read path resolves the recorded explicit data dir" test "$rec_data" = "$alt_data"
pg "$REPO_B" -- --worktree down >/dev/null 2>&1 || true
try_not "down without PGDATA stopped the recorded explicit cluster" test -f "$alt_data/postmaster.pid"

# An empty PGDATA/PGPORT in the environment must NOT count as an explicit override
# (else scoped resolution would silently fall back to /tmp/pgdata:5432).
url_e="$(pg "$REPO_A" PGDATA= PGPORT= POSTGRES_DB=app_a -- --worktree up | tail -1)"
STARTED_DATADIRS+=("$data_a")
try "empty PGDATA/PGPORT still resolves the scoped instance" test "${url_e%/*}" != "postgresql://postgres:postgres@127.0.0.1:5432"
case "$(pg "$REPO_A" PGDATA= -- --worktree status 2>&1)" in
*"PGDATA=$SCOPED_ROOT/"*) ok "empty PGDATA reads the scoped data dir, not /tmp/pgdata" ;;
*) ko "empty PGDATA leaked to a non-scoped data dir" ;;
esac
pg "$REPO_A" -- --worktree down >/dev/null 2>&1 || true

echo "== --profile works outside Git; --worktree outside Git fails =="
NONGIT="$WORK/nongit"
mkdir -p "$NONGIT"
url_prof="$(pg "$NONGIT" POSTGRES_DB=app_p -- --profile ci-lane-1 up | tail -1)"
data_prof="$(pg "$NONGIT" -- --profile ci-lane-1 status 2>&1 | sed -n 's/.*PGDATA=\([^)]*\)).*/\1/p')"
STARTED_DATADIRS+=("$data_prof")
try "--profile instance connects (outside Git)" test "$(psql "$url_prof" -tAc 'select current_database()' 2>/dev/null || true)" = "app_p"
pg "$NONGIT" -- --profile ci-lane-1 down >/dev/null 2>&1 || true

try_not "--worktree outside Git fails cleanly" pg "$NONGIT" -- --worktree up
try_not "--profile rejects an invalid identifier" pg "$NONGIT" -- --profile 'bad id!' up

echo "== genuinely parallel up: the port lock prevents a collision =="
# Launch two fresh scoped instances at the SAME time so their port allocations
# race; the flock on the shared root must still hand out two DISTINCT ports.
REPO_C="$WORK/repo-c"
REPO_D="$WORK/repo-d"
make_repo "$REPO_C"
make_repo "$REPO_D"
pg "$REPO_C" POSTGRES_DB=app_c -- --worktree up >"$WORK/c.out" 2>/dev/null &
pid_c=$!
pg "$REPO_D" POSTGRES_DB=app_d -- --worktree up >"$WORK/d.out" 2>/dev/null &
pid_d=$!
wait "$pid_c"
wait "$pid_d"
url_c="$(tail -1 "$WORK/c.out")"
url_d="$(tail -1 "$WORK/d.out")"
data_c="$(pg "$REPO_C" -- --worktree status 2>&1 | sed -n 's/.*PGDATA=\([^)]*\)).*/\1/p')"
data_d="$(pg "$REPO_D" -- --worktree status 2>&1 | sed -n 's/.*PGDATA=\([^)]*\)).*/\1/p')"
STARTED_DATADIRS+=("$data_c" "$data_d")
port_c="${url_c##*:}"
port_c="${port_c%%/*}"
port_d="${url_d##*:}"
port_d="${port_d%%/*}"
if [ -n "$port_c" ] && [ -n "$port_d" ] && [ "$port_c" != "$port_d" ]; then
	ok "parallel up produced distinct ports ($port_c vs $port_d)"
else
	ko "parallel up port collision (c='$url_c' d='$url_d')"
fi
try "C reachable after parallel up" test "$(psql "$url_c" -tAc 'select 1' 2>/dev/null || true)" = "1"
try "D reachable after parallel up" test "$(psql "$url_d" -tAc 'select 1' 2>/dev/null || true)" = "1"
pg "$REPO_C" -- --worktree down >/dev/null 2>&1 || true
pg "$REPO_D" -- --worktree down >/dev/null 2>&1 || true

echo "== unscoped invocations keep the historical defaults =="
url_plain="$(pg "$WORK" -- url)"
try "unscoped url unchanged (/5432, default creds)" test "$url_plain" = "postgresql://postgres:postgres@127.0.0.1:5432/postgres"

echo
echo "pg-dev-up scoped: $pass passed, $fail failed."
[ "$fail" -eq 0 ]
