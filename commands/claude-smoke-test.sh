#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

exec "${ROOT_DIR}/scripts/smoke-test-image.sh" "${1:-powbox-claude:latest}" \
	"claude --version >/dev/null" \
	"gh --version >/dev/null" \
	"node --version >/dev/null" \
	"npm --version >/dev/null" \
	"pnpm --version >/dev/null" \
	"pip3 --version >/dev/null" \
	"python3 --version >/dev/null" \
	"sqlcmd -? >/dev/null" \
	"sqlite3 --version >/dev/null" \
	"shellcheck --version >/dev/null" \
	"ping -V >/dev/null" \
	"nc -h >/dev/null 2>&1" \
	"bc --version >/dev/null" \
	"less --version >/dev/null" \
	"lsof -v >/dev/null 2>&1" \
	"tree --version >/dev/null" \
	"fd --version >/dev/null" \
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
