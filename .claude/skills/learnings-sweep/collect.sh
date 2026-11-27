#!/usr/bin/env bash
# Collect session-learnings reports from the throwaway branches of several
# repositories into one directory, and delete the source branches afterwards.
#
#   collect.sh list   [--also <glob>]... <checkout>...
#   collect.sh export [--also <glob>]... --into <dir> <checkout>...
#   collect.sh delete --from <dir> [--yes]
#
# <checkout> is a local working copy; only its `origin` URL is used, so the
# checkout itself is never fetched into, switched, or otherwise changed.
# Branches are read straight from each origin into a temporary store.
#
# list    prints one line per candidate branch: repo, branch, class, commit,
#         files. `report-only` means everything the branch adds over the
#         default branch is a report file; anything else is `mixed` (or
#         `unrelated` when it shares no history) and is never deleted.
# export  copies every report byte for byte to <dir>/reports/<repo>/ and writes
#         <dir>/MANIFEST.tsv, recording the source commit so a deleted branch
#         can be recreated while the remote still holds the object. The
#         manifest appears only once the whole export has succeeded, so an
#         interrupted export leaves nothing delete would act on.
# delete  removes the `report-only` branches the manifest lists, each under a
#         lease on the recorded commit, and only when the repository holding
#         <dir> has committed every aggregated copy with exactly the recorded
#         content, and no open pull request uses the branch as its head (in
#         any repository, so a fork's branch behind a PR upstream is held).
#         That check runs on github.com and on any host gh is logged in to
#         (GitHub Enterprise); an origin anywhere else, an SSH host alias
#         included, is held because nothing can rule out an open PR there.
#         A local path or file:// origin has no pull requests to check.
#         Without --yes it only prints what it would do.
#
# `learnings/*` is always collected; --also adds another branch glob (one `*`
# at most), for repositories that still carry older naming.

set -euo pipefail

die() {
	printf 'collect.sh: %s\n' "$*" >&2
	exit 1
}

REPORT_RE='(^|/)agent-session-learnings-[^/]*[.]md$'
STORE=""
cleanup() { [ -z "$STORE" ] || rm -rf "$STORE"; }
trap cleanup EXIT

# Split a git URL into URL_SCHEME and URL_HOST (both lowercased) and
# URL_PATH: scheme://[user@]host[:port]/path, scp-like [user@]host:path (a
# colon before any slash), or a local path with no host. A remote-helper
# prefix such as persistent-https:: is dropped first, but only a leading run
# of scheme characters counts as one, as in git itself: a `::` inside an IPv6
# host, a password or a path must not cut the URL short.
split_url() {
	local url="$1" rest authority head
	URL_SCHEME="" URL_HOST="" URL_PATH=""
	if [[ $url =~ ^[A-Za-z][A-Za-z0-9+.-]*:: ]]; then
		url="${url#*::}"
	fi
	case "$url" in
	*://*)
		URL_SCHEME="$(printf '%s' "${url%%://*}" | tr '[:upper:]' '[:lower:]')"
		rest="${url#*://}"
		if [ "$URL_SCHEME" = file ]; then
			URL_PATH="$rest"
			return 0
		fi
		authority="${rest%%/*}"
		[ "$authority" = "$rest" ] || URL_PATH="/${rest#*/}"
		authority="${authority##*@}"
		URL_HOST="${authority%:*}"
		;;
	*)
		head="${url%%:*}"
		if [ "$head" != "$url" ] && [[ $head != */* ]]; then
			URL_SCHEME=scp
			URL_PATH="${url#*:}"
			URL_HOST="${head##*@}"
		else
			URL_PATH="$url"
		fi
		;;
	esac
	URL_HOST="$(printf '%s' "$URL_HOST" | tr '[:upper:]' '[:lower:]')"
}

# Origin URL of a checkout, refused when it embeds a credential: the URL is
# written to the manifest, and a token must never land there. Over http(s)
# any user part may be a token, and an `@` anywhere is refused because a raw
# `/` in a password would hide where the user part ends. Elsewhere a user part
# is a login name (ssh://git@host/…, git@host:…) unless it carries a password.
# A relative local path is made absolute where git itself resolves it, so
# fetch, the manifest and delete all reach that origin: the top of a work
# tree, and outside one (a bare repository) the directory git ran in. A
# leading ~ is left to git, which expands it the same from anywhere.
origin_url() {
	local dir="$1" url rest top
	url="$(git -c safe.directory="$dir" -C "$dir" remote get-url origin 2>/dev/null)" ||
		die "$dir has no origin remote"
	split_url "$url"
	if [ -z "$URL_SCHEME" ] && [ "$URL_PATH" = "$url" ] && [[ $url != /* && $url != "~"* ]]; then
		top="$(git -c safe.directory="$dir" -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top=""
		[ -n "$top" ] || top="$(cd "$dir" && pwd -P)" || die "cannot locate the repository of $dir"
		url="$top/$url"
	fi
	rest="${url#*://}"
	case "$URL_SCHEME" in
	http | https | ftp | ftps) [[ $rest != *@* ]] ;;
	scp | file | "") true ;;
	*) [[ $rest != *@* ]] || [[ ${rest%%@*} != *:* ]] ;;
	esac || die "the origin URL of $dir embeds a credential; reset it to a plain URL first"
	printf '%s\n' "$url"
}

repo_label() {
	local name="${1##*/}"
	name="${name%.git}"
	printf '%s\n' "$name" | tr '[:upper:]' '[:lower:]'
}

# Where delete can ask about a URL's open pull requests: `local` for a path
# or file:// URL (no pull requests exist), `github <host> <owner/repo>` for
# github.com or a host gh is logged in to (GitHub Enterprise), and
# `unknown <host>` for anything else, an SSH host alias included.
pr_target() {
	local path
	split_url "$1"
	if [ -z "$URL_HOST" ]; then
		printf 'local\n'
		return 0
	fi
	path="${URL_PATH#/}"
	path="${path%/}"
	path="${path%.git}"
	[ "$URL_HOST" != ssh.github.com ] || URL_HOST=github.com
	if [[ $path =~ ^[^/]+/[^/]+$ ]] &&
		{ [ "$URL_HOST" = github.com ] || gh auth status --hostname "$URL_HOST" >/dev/null 2>&1; }; then
		printf 'github %s %s\n' "$URL_HOST" "$path"
	else
		printf 'unknown %s\n' "$URL_HOST"
	fi
}

# Fetch one origin's default branch and candidate branches into the store.
fetch_repo() {
	local label="$1" url="$2" head default glob
	shift 2
	head="$(git ls-remote --symref "$url" HEAD)" || die "cannot reach $url"
	default="$(printf '%s\n' "$head" | awk '$1 == "ref:" { sub("refs/heads/", "", $2); print $2; exit }')"
	[ -n "$default" ] || die "cannot determine the default branch of $url"
	local specs=("+refs/heads/${default}:refs/sweep/${label}/default")
	for glob in 'learnings/*' "$@"; do
		specs+=("+refs/heads/${glob}:refs/sweep/${label}/b/${glob}")
	done
	git -C "$STORE" fetch --quiet --no-tags "$url" "${specs[@]}" ||
		die "fetch from $url failed"
}

# A changed path is a report when it is a regular file named like one. A path
# holding a tab or a newline never is, so it cannot break the manifest.
is_report() {
	local mode="$1" path="$2"
	case "$mode" in 100644 | 100755) ;; *) return 1 ;; esac
	case "$path" in *$'\t'* | *$'\n'*) return 1 ;; esac
	[[ $path =~ $REPORT_RE ]]
}

# Write what a branch changes over <base> to the file <out>, NUL-separated.
# -z keeps git from quoting unusual paths, and the explicit flags keep a
# configured diff.renames or diff.ignoreSubmodules from hiding a change.
branch_changes() {
	git -C "$STORE" diff --raw -z --no-renames --ignore-submodules=none "$1" "$2" >"$3" ||
		die "cannot diff $2 against its default branch"
}

# Class of a fetched branch: report-only, mixed, or unrelated.
branch_class() {
	local label="$1" ref="$2" base meta path mode status any=0 bad=0
	base="$(git -C "$STORE" merge-base "$ref" "refs/sweep/${label}/default" 2>/dev/null)" || {
		printf 'unrelated\n'
		return 0
	}
	branch_changes "$base" "$ref" "$STORE/sweep-changes"
	while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
		any=1
		read -r _ mode _ _ status <<<"$meta"
		[ "$status" = A ] && is_report "$mode" "$path" || bad=1
	done <"$STORE/sweep-changes"
	if [ "$any" -eq 1 ] && [ "$bad" -eq 0 ]; then
		printf 'report-only\n'
	else
		printf 'mixed\n'
	fi
}

# Report files a branch adds or changes over the default branch.
branch_reports() {
	local label="$1" ref="$2" base meta path mode status
	base="$(git -C "$STORE" merge-base "$ref" "refs/sweep/${label}/default" 2>/dev/null)" || return 0
	branch_changes "$base" "$ref" "$STORE/sweep-changes"
	while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
		read -r _ mode _ _ status <<<"$meta"
		case "$status" in A | M) is_report "$mode" "$path" && printf '%s\n' "$path" ;; esac
	done <"$STORE/sweep-changes"
	return 0
}

cmd_scan() {
	local mode="$1" into="" also=() checkouts=() dir url label ref branch class sha date file blob dest stem n
	shift
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--also)
			[ "$#" -ge 2 ] || die "--also needs a branch glob"
			also+=("$2")
			shift 2
			;;
		--into)
			[ "$#" -ge 2 ] || die "--into needs a directory"
			into="$2"
			shift 2
			;;
		-*) die "unknown option $1" ;;
		*)
			checkouts+=("$1")
			shift
			;;
		esac
	done
	[ "${#checkouts[@]}" -gt 0 ] || die "name at least one checkout"
	# The label namespaces fetched refs, report directories and the deletion
	# key, so two origins sharing one would mix their branches: refuse that
	# before anything is fetched or written.
	local urls=() labels=() i j
	for i in "${!checkouts[@]}"; do
		dir="$(cd "${checkouts[$i]}" && pwd)" || die "no such checkout: ${checkouts[$i]}"
		urls+=("$(origin_url "$dir")")
		labels+=("$(repo_label "${urls[$i]}")")
		for ((j = 0; j < i; j++)); do
			[ "${labels[$j]}" != "${labels[$i]}" ] ||
				die "${urls[$j]} and ${urls[$i]} share the label ${labels[$i]}; sweep them in separate runs"
		done
	done
	local manifest=""
	if [ "$mode" = export ]; then
		[ -n "$into" ] || die "export needs --into <dir>"
		[ ! -e "$into/MANIFEST.tsv" ] && [ ! -e "$into/MANIFEST.tsv.partial" ] && [ ! -e "$into/reports" ] ||
			die "$into already holds an export; use a fresh directory per sweep"
		mkdir -p "$into/reports"
		manifest="$into/MANIFEST.tsv.partial"
		printf 'repo\turl\tbranch\tclass\tcommit\tcommit_date\tsource_path\tblob\taggregated_path\n' >"$manifest"
	fi
	STORE="$(mktemp -d)"
	git init --quiet --bare "$STORE"
	for i in "${!checkouts[@]}"; do
		url="${urls[$i]}"
		label="${labels[$i]}"
		fetch_repo "$label" "$url" ${also[@]+"${also[@]}"}
		while read -r ref sha; do
			[ -n "$ref" ] || continue
			branch="${ref#"refs/sweep/${label}/b/"}"
			class="$(branch_class "$label" "$ref")"
			if [ "$mode" = list ]; then
				printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$branch" "$class" "$sha" \
					"$(branch_reports "$label" "$ref" | tr '\n' ' ')"
				continue
			fi
			date="$(git -C "$STORE" log -1 --format=%cs "$ref")"
			branch_reports "$label" "$ref" >"$STORE/sweep-reports"
			while IFS= read -r file; do
				[ -n "$file" ] || continue
				blob="$(git -C "$STORE" rev-parse "${ref}:${file}")"
				# Same-named reports from other branches or folders get a
				# suffix; every candidate is checked, so no copy overwrites one.
				dest="reports/${label}/${file##*/}"
				if [ -e "$into/$dest" ]; then
					stem="${dest%.md}.from-$(printf '%s' "$branch" | tr '/' '-')"
					dest="${stem}.md"
					n=2
					while [ -e "$into/$dest" ]; do
						dest="${stem}-${n}.md"
						n=$((n + 1))
					done
				fi
				mkdir -p "$into/reports/${label}"
				git -C "$STORE" cat-file blob "$blob" >"$into/$dest"
				[ "$(git hash-object --no-filters "$into/$dest")" = "$blob" ] ||
					die "copy of ${label}:${branch}:${file} does not match its source"
				printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
					"$label" "$url" "$branch" "$class" "$sha" "$date" "$file" "$blob" "$dest" >>"$manifest"
			done <"$STORE/sweep-reports"
		done < <(git -C "$STORE" for-each-ref --format='%(refname) %(objectname)' "refs/sweep/${label}/b")
	done
	[ -z "$manifest" ] || mv "$manifest" "$into/MANIFEST.tsv"
}

# Open pull requests whose head is the branch, in any repository: a fork's
# branch can back a PR into its upstream, which a listing of the fork's own
# pull requests does not show. Prints a count, or `gone` when the branch no
# longer exists.
open_prs_for_head() {
	local host="$1" slug="$2" branch="$3"
	# shellcheck disable=SC2016 # GraphQL variables, not shell expansions
	gh api --hostname "$host" graphql \
		-f query='query($o: String!, $n: String!, $r: String!) { repository(owner: $o, name: $n) { ref(qualifiedName: $r) { associatedPullRequests(states: OPEN) { totalCount } } } }' \
		-f o="${slug%%/*}" -f n="${slug#*/}" -f r="refs/heads/${branch}" \
		--jq '.data.repository.ref | if . == null then "gone" else .associatedPullRequests.totalCount end'
}

# True when the commit at HEAD of the repository holding <dir> carries the
# aggregated copy with exactly the recorded content. The committed blob is what
# is compared, not the file on disk: a copy that is only staged, or that was
# altered on its way into the commit, does not make its source safe to delete.
# `HEAD:./<path>` resolves relative to <dir>, so no path ever passes through
# git's quoted path output.
row_is_safe() {
	local dir="$1" dest="$2" blob="$3"
	[ "$(git -C "$dir" rev-parse --quiet --verify "HEAD:./${dest}" 2>/dev/null)" = "$blob" ]
}

cmd_delete() {
	local from="" yes=0 repo url branch class sha dest blob kind host slug prs reason
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--from)
			[ "$#" -ge 2 ] || die "--from needs a directory"
			from="$2"
			shift 2
			;;
		--yes)
			yes=1
			shift
			;;
		*) die "unknown argument $1" ;;
		esac
	done
	[ -n "$from" ] && [ -f "$from/MANIFEST.tsv" ] || die "delete needs --from <dir> holding MANIFEST.tsv"
	git -C "$from" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
		die "$from is not inside a git repository, so nothing proves the reports were committed"
	# One decision per branch: every row of a branch must be safe.
	while IFS=$'\t' read -r repo url branch class sha; do
		reason=""
		[ "$class" = report-only ] || reason="class is $class"
		if [ -z "$reason" ]; then
			while IFS=$'\t' read -r dest blob; do
				row_is_safe "$from" "$dest" "$blob" || reason="aggregated copy $dest is not committed with the recorded content"
			done < <(awk -F'\t' -v r="$repo" -v b="$branch" 'NR > 1 && $1 == r && $3 == b { print $9 "\t" $8 }' "$from/MANIFEST.tsv")
		fi
		kind=local
		[ -n "$reason" ] || read -r kind host slug <<<"$(pr_target "$url")"
		if [ "$kind" = unknown ]; then
			reason="open pull requests cannot be checked on $host (not GitHub, or no gh login for it)"
		elif [ "$kind" = github ]; then
			prs="$(open_prs_for_head "$host" "$slug" "$branch" 2>/dev/null)" ||
				reason="could not check for open pull requests"
			if [ -z "$reason" ]; then
				case "$prs" in
				0) ;;
				gone) reason="the remote branch no longer exists" ;;
				[1-9]*) reason="an open pull request uses it as head" ;;
				*) reason="could not check for open pull requests" ;;
				esac
			fi
		fi
		if [ -n "$reason" ]; then
			printf 'held\t%s\t%s\t%s\n' "$repo" "$branch" "$reason"
		elif [ "$yes" -eq 0 ]; then
			printf 'would-delete\t%s\t%s\t%s\n' "$repo" "$branch" "$sha"
		elif git -C "$from" push --quiet --force-with-lease="refs/heads/${branch}:${sha}" "$url" ":refs/heads/${branch}" 2>/dev/null; then
			printf 'deleted\t%s\t%s\t%s\n' "$repo" "$branch" "$sha"
			printf '%s\t%s\t%s\n' "$repo" "$branch" "$sha" >>"$from/DELETED-BRANCHES.tsv"
		else
			printf 'held\t%s\t%s\tthe remote branch moved or the push was refused\n' "$repo" "$branch"
		fi
	done < <(awk -F'\t' 'NR > 1 { key = $1 "\t" $3; if (!(key in seen)) { seen[key] = 1; print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 } }' "$from/MANIFEST.tsv")
}

[ "$#" -gt 0 ] || die "usage: collect.sh list|export|delete … (see the header of this file)"
command="$1"
shift
case "$command" in
list | export) cmd_scan "$command" "$@" ;;
delete) cmd_delete "$@" ;;
*) die "unknown command $command" ;;
esac
