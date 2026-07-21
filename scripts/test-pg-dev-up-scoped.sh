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
LISTENER_PIDS=()
cleanup() {
	local d p
	for p in "${LISTENER_PIDS[@]:-}"; do
		[ -n "$p" ] || continue
		kill "$p" >/dev/null 2>&1 || true
	done
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

# Run pg-dev-up from inside a given directory with a HERMETIC, explicit env.
# We strip any PGDATA/PGPORT/POSTGRES_* the caller's shell might have exported
# (e.g. from an `eval "$(pg-dev-up url --export)"`) so the test can never touch
# or stop a caller-configured cluster; each case that needs an override sets it
# explicitly AFTER the -u strips, and env's later assignment wins.
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
	(cd "$cwd" && env -u PGDATA -u PGPORT -u POSTGRES_USER -u POSTGRES_PASSWORD -u POSTGRES_DB "${envs[@]}" bash "$PG" "$@")
}

# Pick a free loopback TCP port from a high range OUTSIDE the scoped allocator's
# 5433-6432 window (so an explicit-port case can never collide with an
# auto-allocated scoped port), probing each candidate so a pre-existing listener
# on the host does not make the test flaky. Ports handed out this run are tracked
# so successive calls return distinct values.
PICKED_PORTS=()
pick_free_port() {
	local p
	for ((p = 6500; p <= 6999; p++)); do
		case " ${PICKED_PORTS[*]:-} " in *" $p "*) continue ;; esac
		(exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && continue
		PICKED_PORTS+=("$p")
		printf '%s\n' "$p"
		return 0
	done
	echo "FATAL: no free loopback port in 6500-6999 for the explicit-port test" >&2
	return 1
}

# Start a background LISTENER occupying loopback port $1 until the test exits, so
# a scoped `up` that targets it hits pg-dev-up's "port in use; refusing to start"
# path deterministically. Returns once the socket is actually accepting.
occupy_port() {
	local port="$1" i
	python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $port))
s.listen(1)
time.sleep(120)
" &
	LISTENER_PIDS+=("$!")
	for ((i = 0; i < 100; i++)); do
		(exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && return 0
		sleep 0.05
	done
	return 1
}

# Create a throwaway git repo with one commit.
make_repo() {
	local dir="$1"
	mkdir -p "$dir"
	git -C "$dir" init -q
	git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

# Add a LINKED worktree of an existing repo. This is the identity case the task
# actually requires: two checkouts that SHARE one common Git dir but have
# distinct toplevels, so the scope key must be derived from the (common git dir,
# toplevel) pair — a plain path basename would be ambiguous, and two separate
# repos would not exercise the shared-common-dir derivation at all.
add_worktree() {
	local repo="$1" path="$2" branch="$3"
	git -C "$repo" -c user.email=t@t -c user.name=t worktree add -q -b "$branch" "$path" >/dev/null
}

# ONE repository (REPO_A is its main checkout); REPO_B is a LINKED worktree of it.
# They share REPO_A/.git as their common Git dir yet have different toplevels,
# so scoped mode must still hand them distinct data dirs and ports.
MAIN_REPO="$WORK/repo-main"
REPO_A="$MAIN_REPO"
REPO_B="$WORK/wt-b"
make_repo "$MAIN_REPO"
add_worktree "$MAIN_REPO" "$REPO_B" wt-b

# Sanity: the two checkouts genuinely share one common Git dir but differ in
# toplevel — otherwise the isolation below would be testing the wrong thing.
common_a="$(git -C "$REPO_A" rev-parse --path-format=absolute --git-common-dir)"
common_b="$(git -C "$REPO_B" rev-parse --path-format=absolute --git-common-dir)"
top_a="$(git -C "$REPO_A" rev-parse --show-toplevel)"
top_b="$(git -C "$REPO_B" rev-parse --show-toplevel)"
try "linked worktrees share one common Git dir" test "$common_a" = "$common_b"
try "linked worktrees have distinct toplevels" test "$top_a" != "$top_b"

echo "== two concurrent worktree-scoped instances (linked worktrees of one repo) =="

# Bring both up with distinct configured databases (exercise createdb per side).
# Register each cluster for teardown IMMEDIATELY after it starts (before the next
# `up`), so an early failure never leaves a postmaster running while the EXIT trap
# deletes its data directory.
url_a="$(pg "$REPO_A" POSTGRES_DB=app_a -- --worktree up | tail -1)"
data_a="$(pg "$REPO_A" -- --worktree status 2>&1 | sed -n 's/.*PGDATA=\([^)]*\)).*/\1/p')"
STARTED_DATADIRS+=("$data_a")
url_b="$(pg "$REPO_B" POSTGRES_DB=app_b -- --worktree up | tail -1)"
data_b="$(pg "$REPO_B" -- --worktree status 2>&1 | sed -n 's/.*PGDATA=\([^)]*\)).*/\1/p')"
STARTED_DATADIRS+=("$data_b")

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
# Probe for a genuinely free port rather than hard-coding one an unrelated
# listener might already hold.
free_port="$(pick_free_port)"
url_p="$(pg "$REPO_A" PGPORT="$free_port" POSTGRES_DB=app_a -- --worktree up | tail -1)"
STARTED_DATADIRS+=("$data_a")
port_p="${url_p##*:}"
port_p="${port_p%%/*}"
try "explicit PGPORT honored ($free_port)" test "$port_p" = "$free_port"
# A later read (no PGPORT) resolves the explicit port that up recorded.
url_pr="$(pg "$REPO_A" POSTGRES_DB=app_a -- --worktree url)"
try "recorded explicit port resolved on read" test "$url_pr" = "$url_p"
pg "$REPO_A" -- --worktree down >/dev/null 2>&1 || true

# A running scoped cluster must NOT be silently retargeted by a mismatched explicit
# PGPORT. Since an explicit override is authoritative, `up` with an explicit PGPORT
# different from the port the cluster is ACTUALLY running on FAILS SAFELY (finding
# #2) rather than adopting the running port and ignoring the override. The cluster
# stays up on its real port, untouched.
url_pm="$(pg "$REPO_A" PGPORT="$free_port" POSTGRES_DB=app_a -- --worktree up | tail -1)"
STARTED_DATADIRS+=("$data_a")
try "still on real port after up" test "${url_pm##*:}" = "${free_port}/app_a"
mismatch_port="$(pick_free_port)"
try_not "explicit PGPORT conflicting with a running scope fails" pg "$REPO_A" PGPORT="$mismatch_port" POSTGRES_DB=app_a -- --worktree up
# The conflict must NOT have stopped, retargeted, or corrupted the running cluster:
# a later read still resolves the real port and it still serves queries.
url_pc="$(pg "$REPO_A" POSTGRES_DB=app_a -- --worktree url)"
try "running cluster still on its real port after the conflict" test "$url_pc" = "$url_pm"
try "running cluster still serves queries after the conflict" test "$(psql "$url_pm" -tAc 'select 1' 2>/dev/null || true)" = "1"
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

echo "== explicit POSTGRES_USER / POSTGRES_PASSWORD stay authoritative (scoped) =="
# The acceptance criterion requires ALL POSTGRES_* overrides to remain
# authoritative in scoped mode. Use a password full of URL metacharacters to also
# confirm the scoped URL percent-encodes it. REPO_A keeps its scoped default data
# dir here (no explicit PGDATA), so it reuses data_a and its recorded port.
up_user="appu"
up_pass='p@ss:w/rd'
url_u="$(pg "$REPO_A" POSTGRES_USER="$up_user" POSTGRES_PASSWORD="$up_pass" POSTGRES_DB=app_a -- --worktree up | tail -1)"
STARTED_DATADIRS+=("$data_a")
role_present="$(psql "$url_u" -tAc "select rolname from pg_roles where rolname = '$up_user'" 2>/dev/null || true)"
try "explicit POSTGRES_USER role created ($up_user)" test "$role_present" = "$up_user"
# The URL must carry the explicit user and the percent-encoded password.
case "$url_u" in
	postgresql://appu:p%40ss%3Aw%2Frd@127.0.0.1:*/app_a) ok "scoped URL reflects explicit user + encoded password" ;;
	*) ko "scoped URL missing explicit user/password: $url_u" ;;
esac
# The connection actually authenticates AS the configured role.
who="$(psql "$url_u" -tAc 'select current_user' 2>/dev/null || true)"
try "connects as the explicit user ($who)" test "$who" = "$up_user"
# A later read keeps the explicit user/password authoritative (unchanged URL).
url_u2="$(pg "$REPO_A" POSTGRES_USER="$up_user" POSTGRES_PASSWORD="$up_pass" POSTGRES_DB=app_a -- --worktree url)"
try "read path keeps explicit user/password authoritative" test "$url_u2" = "$url_u"
pg "$REPO_A" -- --worktree down >/dev/null 2>&1 || true

echo "== relative explicit PGDATA is canonicalized so down from another CWD resolves it =="
# up from a SUBDIR of the repo with a RELATIVE PGDATA; the recorded marker must be
# ABSOLUTE, so status/down from a DIFFERENT working directory (the repo top)
# resolve the SAME cluster rather than a relative path re-anchored to the new CWD
# (which could stop an unrelated cluster). Same worktree => same scope.
SUBDIR="$REPO_A/sub"
mkdir -p "$SUBDIR"
pg "$SUBDIR" PGDATA=rel-pgdata POSTGRES_DB=app_a -- --worktree up >/dev/null
abs_rel="$SUBDIR/rel-pgdata"
STARTED_DATADIRS+=("$abs_rel")
try "relative PGDATA initialized at its absolute location" test -s "$abs_rel/PG_VERSION"
rec_abs="$(pg "$REPO_A" -- --worktree status 2>&1 | sed -n 's/.*PGDATA=\([^)]*\)).*/\1/p')"
try "recorded explicit data dir is absolute ($rec_abs)" test "$rec_abs" = "$abs_rel"
# down from the repo top (a different CWD than the up) must stop the SAME cluster.
pg "$REPO_A" -- --worktree down >/dev/null 2>&1 || true
try_not "down from repo top stopped the relative-PGDATA cluster" test -f "$abs_rel/postmaster.pid"

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
# Use two more LINKED worktrees of the one repo so four distinct worktrees of a
# SINGLE repository each land in their own instance.
REPO_C="$WORK/wt-c"
REPO_D="$WORK/wt-d"
add_worktree "$MAIN_REPO" "$REPO_C" wt-c
add_worktree "$MAIN_REPO" "$REPO_D" wt-d
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

echo "== same-scope up rollback safety: a failed up restores the prior markers =="
# Finding #1/#2: the marker snapshot is taken UNDER the per-scope .uplock, and the
# port-marker rollback runs UNDER the .portlock. So a same-scope `up` that fails
# after taking the lock must restore the previously-recorded port — never wipe the
# marker (which would orphan later url/status/down) and never leave the transient
# port it briefly reserved. Drive it deterministically on a FRESH worktree (no
# explicit-port history): bring the scope up (auto port, 5433-6432), down it
# (markers kept), then run a same-scope `up` with an explicit PGPORT pinned to a
# foreign listener in the disjoint 6500-6999 range so it fails at "port in use;
# refusing to start" AFTER the snapshot+trap, exercising the rollback.
REPO_E="$WORK/wt-e"
add_worktree "$MAIN_REPO" "$REPO_E" wt-e
url_r="$(pg "$REPO_E" POSTGRES_DB=app_e -- --worktree up | tail -1)"
data_e="$(pg "$REPO_E" -- --worktree status 2>&1 | sed -n 's/.*PGDATA=\([^)]*\)).*/\1/p')"
STARTED_DATADIRS+=("$data_e")
prior_port="${url_r##*:}"
prior_port="${prior_port%%/*}"
pg "$REPO_E" -- --worktree down >/dev/null 2>&1 || true
busy_port="$(pick_free_port)"
try "foreign listener occupies a port ($busy_port)" occupy_port "$busy_port"
try "busy port differs from the prior recorded port" test "$busy_port" != "$prior_port"
try_not "same-scope up with a busy explicit PGPORT fails" pg "$REPO_E" PGPORT="$busy_port" POSTGRES_DB=app_e -- --worktree up
url_rr="$(pg "$REPO_E" POSTGRES_DB=app_e -- --worktree url)"
rr_port="${url_rr##*:}"
rr_port="${rr_port%%/*}"
try "rollback restored the prior recorded port ($prior_port), not wiped" test "$rr_port" = "$prior_port"
try "rollback did not leave the transient busy port ($busy_port)" test "$rr_port" != "$busy_port"
# The instance is still fully usable: bring it back up on its restored port.
url_rb="$(pg "$REPO_E" POSTGRES_DB=app_e -- --worktree up | tail -1)"
STARTED_DATADIRS+=("$data_e")
try "instance still startable on its restored port after rollback" test "${url_rb##*:}" = "${prior_port}/app_e"
try "instance reachable after rollback" test "$(psql "$url_rb" -tAc 'select 1' 2>/dev/null || true)" = "1"
pg "$REPO_E" -- --worktree down >/dev/null 2>&1 || true

echo "== scoped dirs are forced owner-only; a pre-existing wide-open root is locked down =="
# Finding #3 (positive): a pre-existing, world-accessible scoped root must be
# corrected to 0700 before PostgreSQL serves its data/socket from it, and `up`
# proceeds. REPO_A under a fresh root is a fresh instance.
WIDE_ROOT="$WORK/wide-root"
mkdir -p "$WIDE_ROOT"
chmod 0777 "$WIDE_ROOT"
url_w="$(pg "$REPO_A" POWBOX_PG_SCOPED_ROOT="$WIDE_ROOT" POSTGRES_DB=app_a -- --worktree up | tail -1)"
data_w="$(pg "$REPO_A" POWBOX_PG_SCOPED_ROOT="$WIDE_ROOT" -- --worktree status 2>&1 | sed -n 's/.*PGDATA=\([^)]*\)).*/\1/p')"
STARTED_DATADIRS+=("$data_w")
try "up under a pre-existing 0777 scoped root succeeds" test -n "$url_w"
try "scoped root locked down to owner-only (got $(stat -c '%a' "$WIDE_ROOT"))" test "$(stat -c '%a' "$WIDE_ROOT")" = 700
inst_w="$(dirname "$data_w")"
try "instance dir owner-only (got $(stat -c '%a' "$inst_w"))" test "$(stat -c '%a' "$inst_w")" = 700
pg "$REPO_A" POWBOX_PG_SCOPED_ROOT="$WIDE_ROOT" -- --worktree down >/dev/null 2>&1 || true

echo "== refuse to start when a scoped dir cannot be secured (chmod fails) =="
# Finding #3 (refusal): a root-owned scoped root cannot be chmod'ed by this
# unprivileged user, so `up` must FAIL rather than serve the cluster from a
# world-accessible directory. /var/tmp is root-owned + world-writable here, so the
# instance dir mkdir succeeds but the enforce-owner-only chmod on the root fails.
# --profile lets us predict the single leftover dir and clean it.
RO_ROOT="/var/tmp"
if [ "$(stat -c '%U' "$RO_ROOT" 2>/dev/null || true)" != "$(id -un)" ] && ! chmod 700 "$RO_ROOT" 2>/dev/null; then
	refuse_key="$(printf 'profile\0%s\0%s\0' "${CONTAINER_NAME:-}" "refuse-lane" | sha256sum | cut -c1-16)"
	try_not "up refuses on a root-owned scoped root it cannot secure" pg "$NONGIT" POWBOX_PG_SCOPED_ROOT="$RO_ROOT" -- --profile refuse-lane up
	try "refusal left no running cluster" test '!' -f "$RO_ROOT/$refuse_key/pgdata/postmaster.pid"
	rm -rf "${RO_ROOT:?}/$refuse_key" 2>/dev/null || true
else
	echo "  skip refusal case: no un-chmod-able root-owned dir available here"
fi

echo "== PGPORT is validated as a bare TCP integer (injection/malformed rejected) =="
# Finding #4: $PGPORT is interpolated into the pg_ctl -o option string, which pg_ctl
# runs through a shell, so a non-integer PGPORT must be rejected BEFORE use rather
# than splicing extra options / shell metacharacters into the postmaster command.
# `url` exercises the same validation hermetically (no cluster touched).
pwn_marker="$WORK/pgport-pwn"
try_not "scoped up rejects a shell-injection PGPORT" pg "$REPO_A" PGPORT="5432; touch $pwn_marker" POSTGRES_DB=app_a -- --worktree up
try_not "scoped up rejects an option-injection PGPORT" pg "$REPO_A" PGPORT="5432 -k /tmp" POSTGRES_DB=app_a -- --worktree up
try_not "scoped up rejects a non-numeric PGPORT" pg "$REPO_A" PGPORT="abc" POSTGRES_DB=app_a -- --worktree up
try_not "scoped up rejects an out-of-range PGPORT" pg "$REPO_A" PGPORT="99999" POSTGRES_DB=app_a -- --worktree up
try_not "scoped up rejects PGPORT 0" pg "$REPO_A" PGPORT="0" POSTGRES_DB=app_a -- --worktree up
try_not "unscoped url rejects a malformed PGPORT" pg "$WORK" PGPORT="5432; id" -- url
try "the injection PGPORT never ran its shell payload" test '!' -e "$pwn_marker"

echo "== POWBOX_PG_SCOPED_ROOT rejects whitespace / shell metacharacters =="
# Finding #4: the scoped root becomes the socket dir ($PG_SOCKDIR) interpolated
# UNQUOTED into pg_ctl -o (shell-executed), so a root with a space or a
# metacharacter must be rejected up front.
root_pwn="$WORK/root-pwn"
try_not "scoped up rejects a scoped root with a space" pg "$REPO_A" POWBOX_PG_SCOPED_ROOT="$WORK/bad root" POSTGRES_DB=app_a -- --worktree up
try_not "scoped up rejects a scoped root with shell metacharacters" pg "$REPO_A" POWBOX_PG_SCOPED_ROOT="\$(touch $root_pwn)" POSTGRES_DB=app_a -- --worktree up
try "the metacharacter scoped root never ran its shell payload" test '!' -e "$root_pwn"

echo "== orphan prevention: up with a NEW explicit PGDATA while the scope's prior server runs FAILS =="
# Finding #3: a scope already has a running recorded cluster; a new `up` with a
# DIFFERENT explicit PGDATA would start a second server and orphan the prior one
# from scoped down/status (which resolve only the recorded markers). It must refuse
# (require an explicit stop) and leave both the running prior server and the markers
# intact — never start the new cluster.
REPO_F="$WORK/wt-f"
add_worktree "$MAIN_REPO" "$REPO_F" wt-f
url_f="$(pg "$REPO_F" POSTGRES_DB=app_f -- --worktree up | tail -1)"
data_f="$(pg "$REPO_F" -- --worktree status 2>&1 | sed -n 's/.*PGDATA=\([^)]*\)).*/\1/p')"
STARTED_DATADIRS+=("$data_f")
orphan_data="$WORK/orphan-pgdata"
try_not "up with a new explicit PGDATA while the scope runs is refused" pg "$REPO_F" PGDATA="$orphan_data" POSTGRES_DB=app_f -- --worktree up
try "refusal did not initialize the new cluster" test '!' -e "$orphan_data/PG_VERSION"
rec_f="$(pg "$REPO_F" -- --worktree status 2>&1 | sed -n 's/.*PGDATA=\([^)]*\)).*/\1/p')"
try "prior server's markers untouched by the refusal" test "$rec_f" = "$data_f"
try "prior server still serves queries after the refusal" test "$(psql "$url_f" -tAc 'select 1' 2>/dev/null || true)" = "1"
pg "$REPO_F" -- --worktree down >/dev/null 2>&1 || true

echo "== unscoped invocations keep the historical defaults =="
url_plain="$(pg "$WORK" -- url)"
try "unscoped url unchanged (/5432, default creds)" test "$url_plain" = "postgresql://postgres:postgres@127.0.0.1:5432/postgres"

echo
echo "pg-dev-up scoped: $pass passed, $fail failed."
[ "$fail" -eq 0 ]
