#!/usr/bin/env bash
set -euo pipefail

# Smoke-test the self-hosted ("--isolated") launch mode. Two stages:
#
#   Stage A — launcher identity. Drives scripts/launch-agent.sh with the
#   POWBOX_PRINT_IDENTITY hook (which resolves names and exits before any Docker
#   call), so it runs ANYWHERE — no image, no daemon, no network. It asserts the
#   naming contract: dir-mounted is byte-for-byte unchanged; a --name is
#   deterministic (so a relaunch re-attaches the same workspace path → same Claude
#   session slug); an unnamed launch is fresh each time; the repo-slug strips .git
#   and lowercases; and the per-mode volume set is correct.
#
#   Stage B — entrypoint clone behavior, exercised against the agent IMAGE
#   (default powbox-agent:latest). It runs the baked seed-workspace.sh directly
#   (--entrypoint, bypassing the firewall/podman setup) to check clone-on-first-run,
#   reuse-skips-clone, --reclone, and the loud unauthenticated-clone announcement,
#   plus the single-mount hardlink invariant the one-volume layout relies on. It
#   needs the image and network, so it SELF-SKIPS when the image is absent (e.g. a
#   launcher-only checkout) rather than failing. Skip it explicitly with
#   POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE=1.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="${ROOT_DIR}/scripts/launch-agent.sh"
IMAGE="${1:-powbox-agent:latest}"
# A tiny, stable public repo — no gh auth needed to clone it.
DEFAULT_PUBLIC_REPO="https://github.com/octocat/Hello-World.git"
PUBLIC_REPO="${POWBOX_SMOKE_PUBLIC_REPO:-$DEFAULT_PUBLIC_REPO}"
# Two of the Stage-B ref cases assert against contents specific to the default repo:
# a tracked top-level path that is NOT a ref (octocat/Hello-World ships "README"),
# and a valid non-default branch ("test"). They are configurable so a custom
# POWBOX_SMOKE_PUBLIC_REPO fixture can still exercise them, but the Hello-World
# defaults apply ONLY to the default repo — so against any other repo with neither
# override set, each case self-skips rather than failing on a fixture mismatch. (The
# bogus-ref fallback case is repo-agnostic: every repo lacks "no-such-ref-zzz-9999".)
if [ "$PUBLIC_REPO" = "$DEFAULT_PUBLIC_REPO" ]; then
	REF_PATH="${POWBOX_SMOKE_REF_PATH:-README}"
	REF_BRANCH="${POWBOX_SMOKE_REF_BRANCH:-test}"
else
	REF_PATH="${POWBOX_SMOKE_REF_PATH:-}"
	REF_BRANCH="${POWBOX_SMOKE_REF_BRANCH:-}"
fi

pass=0
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
ok() {
	pass=$((pass + 1))
	echo "  ok: $*"
}

# Read one key=value field out of a POWBOX_PRINT_IDENTITY block.
id_field() {
	# $1 = full identity output, $2 = key
	printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}

# SHA256(input)[:12] using the SAME command-fallback chain as launch-agent.sh's
# project_hash, so the expected hash is computed identically to the launcher's on
# every supported host — including macOS (shasum, no sha256sum) and any host that
# only ships openssl. Mirrors the launcher rather than hard-requiring sha256sum,
# which made Stage A die under `set -euo pipefail` before it could run.
project_hash() {
	local input="${1:-}"
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum | cut -c1-12
	elif command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 | cut -c1-12
	elif command -v openssl >/dev/null 2>&1; then
		printf '%s' "$input" | openssl dgst -sha256 | sed 's/^.* //' | cut -c1-12
	else
		fail "no hashing command found (need sha256sum, shasum, or openssl)"
	fi
}

echo "Self-hosted smoke test (launcher: $LAUNCHER)"
echo "Stage A — launcher identity (no image/daemon needed)"

# --- dir-mounted is unchanged: hash == SHA256(canonical path)[:12] -------------
DM="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude "$ROOT_DIR" 2>/dev/null)"
[ "$(id_field "$DM" mode)" = "dir-mounted" ] || fail "default mode is not dir-mounted"
# Mirror the launcher's dir-mounted hash input exactly: it lowercases the path
# before hashing on Windows (MSYS/Cygwin), where the FS is case-insensitive, and
# preserves it as-is elsewhere. Without this the expected hash would diverge from
# the launcher's on Git Bash/MSYS and the contract check would falsely fail.
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) hash_input="$(printf '%s' "$ROOT_DIR" | tr '[:upper:]' '[:lower:]')" ;;
*) hash_input="$ROOT_DIR" ;;
esac
want_hash="$(project_hash "$hash_input")"
case "$(id_field "$DM" CONTAINER_NAME)" in
*"-$want_hash") ok "dir-mounted hash matches SHA256(path)[:12]" ;;
*) fail "dir-mounted hash changed (want suffix -$want_hash): $(id_field "$DM" CONTAINER_NAME)" ;;
esac
[ -n "$(id_field "$DM" NM_VOLUME)" ] || fail "dir-mounted is missing NM_VOLUME"
[ -n "$(id_field "$DM" WT_VOLUME)" ] || fail "dir-mounted is missing WT_VOLUME"
[ -z "$(id_field "$DM" WS_VOLUME)" ] || fail "dir-mounted must not have a WS_VOLUME"
ok "dir-mounted has nm/wt volumes and no ws volume"

# --- named → deterministic (same identity twice) ------------------------------
N1="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/Repo.git --name foo 2>/dev/null)"
N2="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/Repo.git --name foo 2>/dev/null)"
[ "$(id_field "$N1" mode)" = "isolated" ] || fail "--isolated did not select isolated mode"
[ "$(id_field "$N1" CONTAINER_NAME)" = "$(id_field "$N2" CONTAINER_NAME)" ] ||
	fail "named instance is not deterministic across launches"
[ "$(id_field "$N1" WORKSPACE_MOUNT)" = "$(id_field "$N2" WORKSPACE_MOUNT)" ] ||
	fail "named instance workspace path (→ Claude session slug) is not stable"
ok "named instance is deterministic (same workspace path / session slug on relaunch)"

# --- the --name slug is visible in the container name (so cc-list / docker ps show
# WHICH instance), sitting between the repo slug and the trailing hash.
case "$(id_field "$N1" CONTAINER_NAME)" in
*-foo-*) ok "named instance surfaces the --name slug in the container name" ;;
*) fail "named instance does not surface the --name slug: $(id_field "$N1" CONTAINER_NAME)" ;;
esac

# --- two --names that SLUGIFY ALIKE stay DISTINCT (the hash folds in the RAW name), so
# a slug collision never merges two instances — yet both show the SAME visible slug, so
# the raw powbox.instance-name label (not asserted here; no Docker) is the tiebreaker.
C1="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/app --name 'Feature A' 2>/dev/null)"
C2="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/app --name 'feature/a' 2>/dev/null)"
[ "$(id_field "$C1" CONTAINER_NAME)" != "$(id_field "$C2" CONTAINER_NAME)" ] ||
	fail "two --names that slugify alike collided (the hash must fold in the raw name)"
case "$(id_field "$C1" CONTAINER_NAME)" in *-feature-a-*) : ;; *) fail "slug 'feature-a' not derived from 'Feature A'" ;; esac
case "$(id_field "$C2" CONTAINER_NAME)" in *-feature-a-*) : ;; *) fail "slug 'feature-a' not derived from 'feature/a'" ;; esac
ok "slug collisions stay distinct (raw name in the hash) while sharing the visible slug"

# --- --ref is VOLATILE and must NOT enter the identity hash: a re-run with a different
# --ref has to reuse the SAME container (not fork a new clone per ref).
R1="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/app --name refstable --ref main 2>/dev/null)"
R2="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/app --name refstable --ref dev 2>/dev/null)"
[ "$(id_field "$R1" CONTAINER_NAME)" = "$(id_field "$R2" CONTAINER_NAME)" ] ||
	fail "--ref changed the container identity (it must not enter the hash)"
ok "--ref does not enter the container identity (same name reuses one container across refs)"

# --- named identity is PER-REPO: same --name on a different repo must not collide
# Two remotes that share a basename (owner1/app, owner2/app) launched with the same
# --name must resolve to DISTINCT identities; otherwise the second launch would
# attach to (or --reclone wipe) the first repo's container/workspace.
P1="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner1/app --name shared 2>/dev/null)"
P2="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner2/app --name shared 2>/dev/null)"
[ "$(id_field "$P1" CONTAINER_NAME)" != "$(id_field "$P2" CONTAINER_NAME)" ] ||
	fail "two repos sharing a basename collide under the same --name"
[ "$(id_field "$P1" WORKSPACE_MOUNT)" != "$(id_field "$P2" WORKSPACE_MOUNT)" ] ||
	fail "two repos sharing a basename share a workspace path under the same --name"
ok "named identity is per-repo (owner1/app vs owner2/app, same --name, differ)"

# ... while the SAME repo expressed different ways (slug, full https URL, an uppercase
# .GIT extension, or a copied URL with a trailing slash) under the same --name stays
# stable, so reuse is not broken by spec form (the .GIT case also guards .sh/.ps1
# strip-case parity; the trailing-slash case guards the slash-trim before .git strip).
S1="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/app --name stable 2>/dev/null)"
S2="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo https://github.com/owner/app.git --name stable 2>/dev/null)"
S3="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/app.GIT --name stable 2>/dev/null)"
S4="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo https://github.com/owner/app.git/ --name stable 2>/dev/null)"
[ "$(id_field "$S1" CONTAINER_NAME)" = "$(id_field "$S2" CONTAINER_NAME)" ] ||
	fail "same repo via slug vs https URL produced different identities under the same --name"
[ "$(id_field "$S1" CONTAINER_NAME)" = "$(id_field "$S3" CONTAINER_NAME)" ] ||
	fail "uppercase .GIT extension produced a different identity (case-sensitive .git strip)"
[ "$(id_field "$S1" CONTAINER_NAME)" = "$(id_field "$S4" CONTAINER_NAME)" ] ||
	fail "a trailing slash on the clone URL produced a different identity (reuse would break)"
ok "named identity is spec-form stable (slug == https URL == owner/app.GIT == trailing slash)"

# --- cross-AGENT distinctness: the SAME repo+name under claude vs codex must get a
# DISTINCT workspace PATH (not only a distinct ws volume). Both agents always mount
# the global claude-config/codex-config volumes, and a delegated peer agent resumes
# sessions by cwd, so a shared /workspace/<slug> would let one agent's clone inherit
# the other's session history. The instance hash folds in the agent to keep the path
# per-container, matching the per-container agent-ws-<container> volume.
AC="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/app --name dual 2>/dev/null)"
AX="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" codex --isolated --repo owner/app --name dual 2>/dev/null)"
[ "$(id_field "$AC" WORKSPACE_MOUNT)" != "$(id_field "$AX" WORKSPACE_MOUNT)" ] ||
	fail "claude and codex share a workspace path for the same repo/name (session-history bleed)"
[ "$(id_field "$AC" WS_VOLUME)" != "$(id_field "$AX" WS_VOLUME)" ] ||
	fail "claude and codex share a workspace volume for the same repo/name"
ok "cross-agent identity is distinct (claude vs codex, same repo/name, differ in path + volume)"

# --- embedded http(s) credentials are rejected, not frozen into POWBOX_CLONE_REPO
# (a kept self-hosted container would expose the secret via docker inspect). The
# print-identity hook runs AFTER this check, so a rejected spec exits non-zero here.
if POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated \
	--repo 'https://x-access-token:ghp_smoketoken@github.com/owner/repo.git' --name credtest >/dev/null 2>&1; then
	fail "a clone URL with embedded credentials should be rejected"
fi
ok "embedded-credential clone URLs are rejected"

# ... and the scheme match is case-insensitive (RFC 3986), so an UPPERCASE scheme
# cannot smuggle the credential past the reject.
if POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated \
	--repo 'HTTPS://x-access-token:ghp_smoketoken@github.com/owner/repo.git' --name credtest >/dev/null 2>&1; then
	fail "an embedded-credential clone URL with an uppercase scheme should still be rejected"
fi
ok "embedded-credential URLs with an uppercase scheme are rejected"

# ... while an ssh:// spec (benign git@ SSH user, no secret; normalised to https in
# the container) is accepted and passed through unchanged, not mistaken for a credential.
SSHID="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo ssh://git@github.com/owner/repo.git --name sshok 2>/dev/null)"
[ "$(id_field "$SSHID" REPO_SPEC)" = "ssh://git@github.com/owner/repo.git" ] ||
	fail "ssh:// GitHub spec was rejected or altered by the launcher (should pass through)"
ok "ssh:// GitHub spec is accepted (normalised to https in-container, not treated as a credential)"

# --- control characters in identity inputs are rejected before they freeze into labels.
# cc-list/agent-list parse the labels back with a \x1f field separator and one-container-
# per-line reads, so a newline or a literal \x1f in --name/--repo/--ref would corrupt the
# listing; the launcher rejects them. The print-identity hook runs AFTER this check, so a
# rejected value exits non-zero here.
if POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/repo \
	--name "$(printf 'bad\nname')" >/dev/null 2>&1; then
	fail "a --name containing a newline should be rejected"
fi
ok "control characters in --name are rejected"
if POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/repo --name ok \
	--ref "$(printf 'a\x1fb')" >/dev/null 2>&1; then
	fail "a --ref containing a \\x1f unit separator should be rejected"
fi
ok "control characters in --ref are rejected"

# repo-slug: .git stripped, lowercased.
case "$(id_field "$N1" PROJECT_NAME)" in
repo-*) ok "repo-slug strips .git and lowercases (Repo.git → repo)" ;;
*) fail "repo-slug derivation wrong: $(id_field "$N1" PROJECT_NAME)" ;;
esac
[ "$(id_field "$N1" WS_VOLUME)" = "agent-ws-$(id_field "$N1" CONTAINER_NAME)" ] ||
	fail "WS_VOLUME is not agent-ws-<container>"
if [ -n "$(id_field "$N1" NM_VOLUME)" ] || [ -n "$(id_field "$N1" WT_VOLUME)" ]; then
	fail "isolated mode must not create nm/wt volumes"
fi
ok "isolated has agent-ws-<container> and no nm/wt volumes"

# --- unnamed → fresh every launch ---------------------------------------------
U1="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/repo 2>/dev/null)"
U2="$(POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --isolated --repo owner/repo 2>/dev/null)"
[ "$(id_field "$U1" CONTAINER_NAME)" != "$(id_field "$U2" CONTAINER_NAME)" ] ||
	fail "unnamed instances collided (should be fresh each launch)"
ok "unnamed instances are fresh each launch"

# --- self-hosted-only flags require --isolated --------------------------------
if POWBOX_PRINT_IDENTITY=1 "$LAUNCHER" claude --name foo >/dev/null 2>&1; then
	fail "--name without --isolated should error"
fi
ok "self-hosted-only flags are rejected without --isolated"

echo "Stage A passed ($pass checks)."

# --- Stage B — clone behavior against the image -------------------------------
if [ -n "${POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE:-}" ]; then
	echo "Stage B skipped (POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE is set)."
	echo "Self-hosted smoke test passed (Stage A only)."
	exit 0
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	if [ -n "${POWBOX_SMOKE_REQUIRE_IMAGE:-}" ]; then
		echo "FAIL: image '$IMAGE' not found and POWBOX_SMOKE_REQUIRE_IMAGE is set — Stage B (clone behavior) requires the image." >&2
		exit 1
	fi
	echo "Stage B skipped: image '$IMAGE' not found (build it to exercise the clone path)."
	echo "Self-hosted smoke test passed (Stage A only)."
	exit 0
fi

echo "Stage B — entrypoint clone behavior against $IMAGE"
WSVOL="powbox-smoke-ws-$$"
HV1="powbox-smoke-hl-a-$$"
HV2="powbox-smoke-hl-b-$$"
cleanup() {
	docker volume rm -f "$WSVOL" "$HV1" "$HV2" "${WSVOL}-ssh" "${WSVOL}-sshp" "${WSVOL}-scp" "${WSVOL}-slug" "${WSVOL}-fail" "${WSVOL}-ref" "${WSVOL}-path" "${WSVOL}-branch" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker volume create "$WSVOL" >/dev/null

run_seed() { # extra docker env... -> runs seed-workspace.sh as root over $WSVOL
	docker run --rm --user root \
		-e POWBOX_SELF_HOSTED=1 \
		-e POWBOX_WORKSPACE_DIR=/ws \
		-e GH_TOKEN= -e GITHUB_TOKEN= \
		"$@" \
		-v "${WSVOL}:/ws" \
		--entrypoint /usr/local/bin/seed-workspace.sh \
		"$IMAGE"
}

# clone-on-first-run
run_seed -e "POWBOX_CLONE_REPO=${PUBLIC_REPO}" >/dev/null 2>&1 ||
	fail "clone-on-first-run failed for $PUBLIC_REPO"
docker run --rm -v "${WSVOL}:/ws" --entrypoint /bin/sh "$IMAGE" -c '[ -e /ws/.git ]' ||
	fail "clone-on-first-run did not produce a .git"
ok "clone-on-first-run produced a checkout"

# reuse-skips-clone: a marker dropped in the tree must survive a second run
docker run --rm --user root -v "${WSVOL}:/ws" --entrypoint /bin/sh "$IMAGE" -c 'touch /ws/SMOKE_MARKER'
reuse_out="$(run_seed -e "POWBOX_CLONE_REPO=${PUBLIC_REPO}" 2>&1 || true)"
printf '%s' "$reuse_out" | grep -q "skipping clone" || fail "reuse did not skip the clone"
docker run --rm -v "${WSVOL}:/ws" --entrypoint /bin/sh "$IMAGE" -c '[ -e /ws/SMOKE_MARKER ]' ||
	fail "reuse re-cloned (marker was wiped)"
ok "reuse skips the clone and preserves the working tree"

# --reclone is a one-shot launcher action: it empties the (kept) volume, then the
# entrypoint clones fresh. Simulate the launcher's prep wipe, then re-seed; the
# marker must be gone and a new .git present.
docker run --rm --user root -v "${WSVOL}:/ws" --entrypoint /bin/sh "$IMAGE" \
	-c 'find /ws -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; true'
run_seed -e "POWBOX_CLONE_REPO=${PUBLIC_REPO}" >/dev/null 2>&1 ||
	fail "re-clone after a --reclone wipe failed"
docker run --rm -v "${WSVOL}:/ws" --entrypoint /bin/sh "$IMAGE" -c '[ ! -e /ws/SMOKE_MARKER ] && [ -e /ws/.git ]' ||
	fail "--reclone wipe + re-clone did not produce a clean checkout"
ok "--reclone (launcher empties the volume) yields a fresh clone"

# A bogus --ref does NOT fail the clone: seed clones the default branch first, then the
# post-clone checkout of the ref fails BENIGNLY — warn + stay on the default branch, still
# a valid checkout (vs. the old `clone --branch` form, which aborted the whole clone). A
# valid ref's happy path is just `git checkout`, exercised implicitly by the default clone.
docker volume create "${WSVOL}-ref" >/dev/null
ref_out="$(docker run --rm --user root \
	-e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws \
	-e GH_TOKEN= -e GITHUB_TOKEN= \
	-e "POWBOX_CLONE_REPO=${PUBLIC_REPO}" \
	-e "POWBOX_CLONE_REF=no-such-ref-zzz-9999" \
	-v "${WSVOL}-ref:/ws" \
	--entrypoint /usr/local/bin/seed-workspace.sh "$IMAGE" 2>&1 || true)"
docker run --rm -v "${WSVOL}-ref:/ws" --entrypoint /bin/sh "$IMAGE" -c '[ -e /ws/.git ]' ||
	fail "a bogus --ref aborted the clone (should fall back to the default branch)"
printf '%s' "$ref_out" | grep -q "POWBOX --ref WARNING" ||
	fail "a bogus --ref did not print the fallback warning"
docker volume rm -f "${WSVOL}-ref" >/dev/null 2>&1 || true
ok "a bogus --ref falls back to the default branch with a warning (clone still succeeds)"

# A --ref that is a TYPO matching a tracked PATH ($REF_PATH; octocat/Hello-World ships a
# top-level "README" file, which is NOT a ref) must ALSO fall back: a bare `git checkout
# README` would succeed as a path checkout and silently strand the tree on the default
# branch, so the ref is resolved to a commit first and an unresolved name degrades to the
# warning. Skipped when no tracked-non-ref path is known for a custom repo (see REF_PATH).
if [ -n "$REF_PATH" ]; then
	docker volume create "${WSVOL}-path" >/dev/null
	path_out="$(docker run --rm --user root \
		-e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws \
		-e GH_TOKEN= -e GITHUB_TOKEN= \
		-e "POWBOX_CLONE_REPO=${PUBLIC_REPO}" \
		-e "POWBOX_CLONE_REF=${REF_PATH}" \
		-v "${WSVOL}-path:/ws" \
		--entrypoint /usr/local/bin/seed-workspace.sh "$IMAGE" 2>&1 || true)"
	docker run --rm -v "${WSVOL}-path:/ws" --entrypoint /bin/sh "$IMAGE" -c '[ -e /ws/.git ]' ||
		fail "a path-matching --ref aborted the clone (should fall back to the default branch)"
	printf '%s' "$path_out" | grep -q "POWBOX --ref WARNING" ||
		fail "a path-matching --ref was silently checked out as a pathspec instead of warning"
	if printf '%s' "$path_out" | grep -q "checked out ref '${REF_PATH}'"; then
		fail "a path-matching --ref reported a successful ref checkout (pathspec ambiguity not rejected)"
	fi
	docker volume rm -f "${WSVOL}-path" >/dev/null 2>&1 || true
	ok "a path-matching --ref typo falls back with a warning (pathspec is not mistaken for a ref)"
else
	echo "  skip: path-matching --ref typo case (set POWBOX_SMOKE_REF_PATH to a tracked non-ref path for a custom repo)"
fi

# A valid NON-DEFAULT branch by bare name ($REF_BRANCH; octocat/Hello-World ships a "test"
# branch) is the primary --ref use case and MUST check out: a fresh clone materializes only
# the default branch as a local head, so the ref-resolution guard has to accept the
# refs/remotes/origin/* form too — verifying only the bare name would wrongly strand the
# user on the default branch. Skipped when no non-default branch is known for a custom repo.
if [ -n "$REF_BRANCH" ]; then
	docker volume create "${WSVOL}-branch" >/dev/null
	branch_out="$(docker run --rm --user root \
		-e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws \
		-e GH_TOKEN= -e GITHUB_TOKEN= \
		-e "POWBOX_CLONE_REPO=${PUBLIC_REPO}" \
		-e "POWBOX_CLONE_REF=${REF_BRANCH}" \
		-v "${WSVOL}-branch:/ws" \
		--entrypoint /usr/local/bin/seed-workspace.sh "$IMAGE" 2>&1 || true)"
	printf '%s' "$branch_out" | grep -q "checked out ref '${REF_BRANCH}'" ||
		fail "a valid non-default branch --ref was not checked out (origin/ tracking form rejected?)"
	if printf '%s' "$branch_out" | grep -q "POWBOX --ref WARNING"; then
		fail "a valid non-default branch --ref printed the fallback warning instead of checking out"
	fi
	# --user root: the clone above ran as root (run_seed; seed-workspace.sh does not chown —
	# that happens in the main entrypoint this test bypasses), so the tree is root-owned. The
	# default image user is `node`, and git refuses a repo owned by another uid ("dubious
	# ownership", CVE-2022-24765), printing to stderr and leaving stdout EMPTY — which we'd
	# read as a HEAD mismatch and wrongly fail. Inspect as the owning user instead. (The other
	# Stage-B checks are /bin/sh `[ -e ]` file tests, which are ownership-agnostic.)
	[ "$(docker run --rm --user root -v "${WSVOL}-branch:/ws" --entrypoint git "$IMAGE" -C /ws rev-parse --abbrev-ref HEAD 2>/dev/null)" = "${REF_BRANCH}" ] ||
		fail "a valid non-default branch --ref did not leave HEAD on that branch"
	docker volume rm -f "${WSVOL}-branch" >/dev/null 2>&1 || true
	ok "a valid non-default branch --ref checks out (remote-tracking ref is resolved, not rejected)"
else
	echo "  skip: non-default branch --ref case (set POWBOX_SMOKE_REF_BRANCH to a valid non-default branch for a custom repo)"
fi

# unauthenticated/failed clone → loud announcement + non-zero exit
docker volume create "${WSVOL}-fail" >/dev/null
set +e
fail_out="$(docker run --rm --user root \
	-e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws \
	-e GH_TOKEN= -e GITHUB_TOKEN= \
	-e "POWBOX_CLONE_REPO=this-org-does-not-exist-zzz/nope-9999" \
	-v "${WSVOL}-fail:/ws" \
	--entrypoint /usr/local/bin/seed-workspace.sh "$IMAGE" 2>&1)"
fail_rc=$?
set -e
docker volume rm -f "${WSVOL}-fail" >/dev/null 2>&1 || true
[ "$fail_rc" -ne 0 ] || fail "a failed clone should exit non-zero"
printf '%s' "$fail_out" | grep -q "POWBOX SELF-HOSTED CLONE FAILED" ||
	fail "a failed clone did not print the loud announcement"
printf '%s' "$fail_out" | grep -q "gh auth login" ||
	fail "the announcement is missing the gh-auth remedy"
ok "a failed clone announces loudly and exits non-zero"

# ssh:// GitHub URLs are normalised to HTTPS before cloning (the container has no SSH
# keys; the entrypoint's git@github.com: insteadOf historically missed ssh://). The
# pre-clone log line prints the RESOLVED url, so a fast-failing nonexistent ssh:// repo
# (fresh volume → not the reuse path) must show the https form, proving the normalise.
docker volume create "${WSVOL}-ssh" >/dev/null
ssh_out="$(docker run --rm --user root \
	-e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws \
	-e GH_TOKEN= -e GITHUB_TOKEN= \
	-e 'POWBOX_CLONE_REPO=ssh://git@github.com/this-org-does-not-exist-zzz/nope-9999.git' \
	-v "${WSVOL}-ssh:/ws" \
	--entrypoint /usr/local/bin/seed-workspace.sh "$IMAGE" 2>&1 || true)"
docker volume rm -f "${WSVOL}-ssh" >/dev/null 2>&1 || true
printf '%s' "$ssh_out" | grep -q 'https://github.com/this-org-does-not-exist-zzz/nope-9999.git' ||
	fail "ssh:// GitHub URL was not normalised to https before cloning"
ok "ssh:// GitHub URL is normalised to https before cloning"

# ... and an explicit-port, bare-host ssh:// URL (ssh://github.com:22/owner/repo.git —
# no git@ user, the form git emits for an origin on a custom SSH port) is normalised
# too. This covers the OTHER two normalisation axes the git@-form ssh test above does
# not: a missing git@ user AND a :port the entrypoint insteadOf (a prefix rewrite)
# cannot strip — so clone_url must, or it would fall through to a keyless SSH clone and
# fail. Same fast-fail proof as above.
docker volume create "${WSVOL}-sshp" >/dev/null
sshp_out="$(docker run --rm --user root \
	-e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws \
	-e GH_TOKEN= -e GITHUB_TOKEN= \
	-e 'POWBOX_CLONE_REPO=ssh://github.com:22/this-org-does-not-exist-zzz/nope-9999.git' \
	-v "${WSVOL}-sshp:/ws" \
	--entrypoint /usr/local/bin/seed-workspace.sh "$IMAGE" 2>&1 || true)"
docker volume rm -f "${WSVOL}-sshp" >/dev/null 2>&1 || true
printf '%s' "$sshp_out" | grep -q 'https://github.com/this-org-does-not-exist-zzz/nope-9999.git' ||
	fail "bare-host ported ssh:// GitHub URL (no git@, with :22) was not normalised to https before cloning"
ok "bare-host ported ssh:// GitHub URL (no git@, explicit :port) is normalised to https before cloning"

# scp-style GitHub remotes (git@github.com:owner/repo.git — the form inferred from a
# typical local checkout's origin) are normalised to HTTPS too: the insteadOf rewrite
# is installed only after gh auth succeeds, so an unauthenticated public clone would
# otherwise fail on the bare git@ URL. Same fast-fail proof as the ssh:// case above.
docker volume create "${WSVOL}-scp" >/dev/null
scp_out="$(docker run --rm --user root \
	-e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws \
	-e GH_TOKEN= -e GITHUB_TOKEN= \
	-e 'POWBOX_CLONE_REPO=git@github.com:this-org-does-not-exist-zzz/nope-9999.git' \
	-v "${WSVOL}-scp:/ws" \
	--entrypoint /usr/local/bin/seed-workspace.sh "$IMAGE" 2>&1 || true)"
docker volume rm -f "${WSVOL}-scp" >/dev/null 2>&1 || true
printf '%s' "$scp_out" | grep -q 'https://github.com/this-org-does-not-exist-zzz/nope-9999.git' ||
	fail "scp-style git@github.com: URL was not normalised to https before cloning"
ok "scp-style git@github.com: URL is normalised to https before cloning"

# A bare owner/repo slug with a TRAILING SLASH (e.g. owner/repo/ — a copied/pasted
# spec) is normalised to the canonical https://github.com/owner/repo.git: the slug
# branch trims trailing slashes BEFORE appending .git, so it cannot emit the invalid
# https://github.com/.../nope-9999/.git. The dot is ESCAPED here so the buggy form
# (.../nope-9999/.git) cannot satisfy the assertion via grep's '.' wildcard. Same
# fast-fail proof as the ssh:// case above.
docker volume create "${WSVOL}-slug" >/dev/null
slug_out="$(docker run --rm --user root \
	-e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws \
	-e GH_TOKEN= -e GITHUB_TOKEN= \
	-e 'POWBOX_CLONE_REPO=this-org-does-not-exist-zzz/nope-9999/' \
	-v "${WSVOL}-slug:/ws" \
	--entrypoint /usr/local/bin/seed-workspace.sh "$IMAGE" 2>&1 || true)"
docker volume rm -f "${WSVOL}-slug" >/dev/null 2>&1 || true
printf '%s' "$slug_out" | grep -q 'https://github\.com/this-org-does-not-exist-zzz/nope-9999\.git' ||
	fail "a trailing-slash owner/repo slug was not normalised to a clean https URL (saw .../nope-9999/.git?)"
ok "a trailing-slash owner/repo slug is normalised to a clean https URL before cloning"

# Single-mount hardlink invariant: within ONE volume (store + node_modules as
# subdirs, the self-hosted layout) link(2) succeeds; ACROSS two volumes it EXDEVs
# (the dir-mounted root-node_modules case the one-volume layout fixes). Run as root
# (like every other volume-writing step above): a fresh empty named volume's root is
# root-owned, and unlike a real launch this test does not run the launcher's chown
# pre-seed of the workspace volume (launch-agent.sh) — so node could not mkdir here.
# The link(2)/EXDEV result is a filesystem property, independent of the writing uid.
docker volume create "$HV1" >/dev/null
docker volume create "$HV2" >/dev/null
docker run --rm --user root -v "${HV1}:/ws" --entrypoint /bin/sh "$IMAGE" -c '
set -e
mkdir -p /ws/.worktrees/.pnpm-store /ws/node_modules /ws/.worktrees/task/node_modules
echo pkg > /ws/.worktrees/.pnpm-store/f
ln /ws/.worktrees/.pnpm-store/f /ws/node_modules/f
ln /ws/.worktrees/.pnpm-store/f /ws/.worktrees/task/node_modules/f
[ "$(stat -c %h /ws/.worktrees/.pnpm-store/f)" -ge 3 ]' ||
	fail "hardlink within one workspace volume failed (root + worktree node_modules)"
ok "store hardlinks into BOTH the root and a worktree node_modules (one mount)"
docker run --rm --user root -v "${HV1}:/store" -v "${HV2}:/nm" --entrypoint /bin/sh "$IMAGE" -c '
echo x > /store/g
if ln /store/g /nm/g 2>/dev/null; then exit 1; fi
exit 0' ||
	fail "cross-volume hardlink unexpectedly succeeded (EXDEV invariant broken)"
ok "cross-mount hardlink EXDEVs (confirms why dir-mounted root node_modules copies)"

echo "Stage B passed."
echo "Self-hosted smoke test passed."
