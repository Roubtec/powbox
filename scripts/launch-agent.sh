#!/usr/bin/env bash
set -euo pipefail

AGENT="${1:?usage: launch-agent.sh <claude|codex> [project-path | repo-spec] [--build] [--detach] [--shell] [--volatile] [--persist] [--resume] [--continue] [--exec <task> (codex only)] [--isolated [--repo <spec>] [--name <label>] [--ref <branch>] [--reclone]]}"
shift

case "$AGENT" in
claude | codex) ;;
*)
	echo "Unknown agent: $AGENT" >&2
	exit 1
	;;
esac

PROJECT_PATH="."
POSITIONAL_SET=false
BUILD=false
DETACH=false
SHELL_ONLY=false
VOLATILE=false
PERSIST=false
RESUME=false
CONTINUE=false
EXEC_TASK=""
CTX_VALUES=()
# Self-hosted ("--isolated") mode: the container clones the repo into a private
# per-instance volume instead of bind-mounting a host dir. All of the following
# stay inert (and dir-mounted mode stays byte-for-byte unchanged) unless
# ISOLATED is set.
ISOLATED=false
REPO_FLAG=""
INSTANCE_NAME=""
CLONE_REF=""
RECLONE=false

while [ "$#" -gt 0 ]; do
	case "$1" in
	--build)
		BUILD=true
		;;
	--isolated)
		ISOLATED=true
		;;
	--repo)
		shift
		REPO_FLAG="${1:?missing spec for --repo}"
		;;
	--name)
		shift
		INSTANCE_NAME="${1:?missing label for --name}"
		;;
	--ref)
		shift
		CLONE_REF="${1:?missing branch for --ref}"
		;;
	--reclone | --fresh)
		RECLONE=true
		;;
	--detach)
		DETACH=true
		;;
	--shell)
		SHELL_ONLY=true
		;;
	--volatile)
		VOLATILE=true
		;;
	--persist)
		PERSIST=true
		;;
	--resume)
		RESUME=true
		;;
	--continue)
		CONTINUE=true
		;;
	--ctx)
		shift
		if [ "$#" -eq 0 ]; then
			echo "Error: missing path for --ctx" >&2
			exit 1
		fi
		CTX_VALUES+=("$1")
		;;
	--exec)
		if [ "$AGENT" != "codex" ]; then
			echo "--exec is only supported for codex." >&2
			exit 1
		fi
		shift
		EXEC_TASK="${1:?missing task for --exec}"
		;;
	--*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	*)
		if [ "$POSITIONAL_SET" = true ]; then
			echo "Unexpected extra positional argument: $1" >&2
			exit 1
		fi
		PROJECT_PATH="$1"
		POSITIONAL_SET=true
		;;
	esac
	shift
done

# Reject the self-hosted-only flags when --isolated was not given, so a typo
# fails loudly instead of silently launching the unchanged dir-mounted mode.
if [ "$ISOLATED" != true ]; then
	if [ -n "$REPO_FLAG" ] || [ -n "$INSTANCE_NAME" ] || [ -n "$CLONE_REF" ] || [ "$RECLONE" = true ]; then
		echo "Error: --repo/--name/--ref/--reclone require --isolated." >&2
		exit 1
	fi
fi

# In dir-mounted mode the positional is a host project directory and must exist;
# in self-hosted mode it is re-interpreted as the repo spec (resolved below) and
# is NOT a host path, so the directory checks/canonicalisation are skipped.
if [ "$ISOLATED" != true ]; then
	if [ ! -d "$PROJECT_PATH" ]; then
		echo "Error: project path does not exist: ${PROJECT_PATH}" >&2
		exit 1
	fi
fi

if [ "$ISOLATED" != true ]; then
	PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd -P)"
	# Only strip the trailing slash when the path is not the filesystem root ("/"), since
	# stripping "/" would produce an empty string and break basename and Docker bind-mount paths.
	if [ "$PROJECT_PATH" != "/" ]; then
		PROJECT_PATH="${PROJECT_PATH%/}"
	fi
	PROJECT_BASENAME="$(basename "$PROJECT_PATH")"
fi

project_hash() {
	local input="${1:-}"
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum | cut -c1-12
	elif command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 | cut -c1-12
	elif command -v openssl >/dev/null 2>&1; then
		printf '%s' "$input" | openssl dgst -sha256 | sed 's/^.* //' | cut -c1-12
	else
		echo "Error: no hashing command found (need sha256sum, shasum, or openssl)." >&2
		echo "" >&2
		echo "A unique hash of the project path is used to generate the container name." >&2
		echo "Without it, containers for different projects may share the same name, causing" >&2
		echo "one project's container to be silently reused for another — which can be destructive." >&2
		echo "" >&2
		echo "Install one of the following and retry:" >&2
		echo "  sha256sum  — part of GNU coreutils (Linux, Git Bash, WSL)" >&2
		echo "  shasum     — bundled with Perl (macOS, many Linux distros)" >&2
		echo "  openssl    — https://www.openssl.org/" >&2
		return 1
	fi
}

# Canonical "host/owner/repo" key for a repo spec (lowercased, .git stripped, any
# userinfo removed) so that different repos sharing a basename get distinct
# identities, while the SAME repo expressed different ways (owner/repo slug, https
# URL, scp-style git@host:path) maps to one stable key. Folded into a NAMED
# instance's discriminator below; see the comment there. Must stay in lockstep
# with launch-agent.ps1's Get-Powbox-RepoIdentity so the two launchers agree.
repo_identity() {
	local spec="${1:-}" id authority rest
	case "$spec" in
	*://*)
		# scheme://[user@]host[:port]/path → host[:port]/path. Strip userinfo from
		# the AUTHORITY only (a user[:pass]@ before the first '/'), not an '@' that
		# appears later in the path — mirroring launch-agent.ps1's `^[^@/]*@`, so the
		# two launchers agree on a URL whose path happens to contain an '@'.
		id="${spec#*://}"
		authority="${id%%/*}"
		rest="${id#"$authority"}"
		id="${authority#*@}${rest}"
		;;
	*@*:*)
		# scp-style user@host:owner/repo → host/owner/repo (first ':' → '/')
		id="${spec#*@}"
		id="${id%%:*}/${id#*:}"
		;;
	*)
		# bare owner/repo slug → default host (matches the github.com default the
		# clone step applies to a slug)
		id="github.com/$spec"
		;;
	esac
	# Lowercase BEFORE stripping .git so an uppercase extension (.GIT/.Git) is also
	# removed — matching launch-agent.ps1's case-insensitive `-replace '\.git$'`, so
	# the two launchers (and repo.GIT vs repo.git here) agree on the identity.
	id="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
	# Trim trailing slashes BEFORE stripping .git so a URL copied with a trailing
	# separator (https://github.com/owner/app.git/) normalises to the same identity as
	# the bare form — otherwise the .git strip misses (the suffix is '/'), the slash
	# stays, and relaunching the same --name spawns a second container instead of
	# reattaching to the existing clone. Mirrors launch-agent.ps1's `-replace '/+$'`.
	id="${id%"${id##*[!/]}"}"
	printf '%s' "${id%.git}"
}

# Full SHA256 of stdin, used for ctx mount-set labels. Kept separate from
# project_hash, whose 12-char truncation is part of the container-name contract.
powbox_sha256_stdin() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | awk '{print $1}'
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 | sed 's/^.* //'
	else
		echo "Error: no hashing command found (need sha256sum, shasum, or openssl)." >&2
		return 1
	fi
}

powbox_warn() {
	echo "Warning: $*" >&2
}

powbox_trim() {
	local s="$1" c
	while [ -n "$s" ]; do
		c="${s:0:1}"
		case "$c" in
		" " | $'\t' | $'\r') s="${s:1}" ;;
		*) break ;;
		esac
	done
	while [ -n "$s" ]; do
		c="${s: -1}"
		case "$c" in
		" " | $'\t' | $'\r') s="${s:0:${#s}-1}" ;;
		*) break ;;
		esac
	done
	printf '%s' "$s"
}

powbox_strip_yaml_comment() {
	local s="$1" out="" quote="" c next prev_blank=true
	local i
	for ((i = 0; i < ${#s}; i++)); do
		c="${s:i:1}"
		if [ -z "$quote" ]; then
			case "$c" in
			"'")
				quote="'"
				out+="$c"
				prev_blank=false
				;;
			'"')
				quote='"'
				out+="$c"
				prev_blank=false
				;;
			"#")
				if [ "$prev_blank" = true ]; then
					break
				fi
				out+="$c"
				prev_blank=false
				;;
			" " | $'\t')
				out+="$c"
				prev_blank=true
				;;
			*)
				out+="$c"
				prev_blank=false
				;;
			esac
		elif [ "$quote" = "'" ]; then
			out+="$c"
			if [ "$c" = "'" ]; then
				next="${s:i+1:1}"
				if [ "$next" = "'" ]; then
					out+="$next"
					i=$((i + 1))
				else
					quote=""
				fi
			fi
		else
			out+="$c"
			if [ "$c" = "\\" ]; then
				next="${s:i+1:1}"
				if [ -n "$next" ]; then
					out+="$next"
					i=$((i + 1))
				fi
			elif [ "$c" = '"' ]; then
				quote=""
			fi
		fi
	done
	printf '%s' "$out"
}

powbox_parse_yaml_scalar() {
	local raw outvar first c next out="" esc context
	raw="$(powbox_trim "$(powbox_strip_yaml_comment "$1")")"
	outvar="$2"
	context="$3"
	if [ -z "$raw" ]; then
		printf -v "$outvar" '%s' ""
		return 0
	fi
	first="${raw:0:1}"
	if [ "$first" = "'" ]; then
		local i
		for ((i = 1; i < ${#raw}; i++)); do
			c="${raw:i:1}"
			if [ "$c" = "'" ]; then
				next="${raw:i+1:1}"
				if [ "$next" = "'" ]; then
					out+="'"
					i=$((i + 1))
				elif [ "$i" -eq $((${#raw} - 1)) ]; then
					printf -v "$outvar" '%s' "$out"
					return 0
				else
					powbox_warn "$context has trailing content after a quoted scalar; skipping."
					return 1
				fi
			else
				out+="$c"
			fi
		done
		powbox_warn "$context has an unterminated single-quoted scalar; skipping."
		return 1
	fi
	if [ "$first" = '"' ]; then
		local i
		for ((i = 1; i < ${#raw}; i++)); do
			c="${raw:i:1}"
			if [ "$c" = "\\" ]; then
				i=$((i + 1))
				if [ "$i" -ge "${#raw}" ]; then
					powbox_warn "$context has a dangling escape in a double-quoted scalar; skipping."
					return 1
				fi
				esc="${raw:i:1}"
				case "$esc" in
				'"' | "\\" | "/") out+="$esc" ;;
				b) out+=$'\b' ;;
				f) out+=$'\f' ;;
				n) out+=$'\n' ;;
				r) out+=$'\r' ;;
				t) out+=$'\t' ;;
				*)
					powbox_warn "$context uses an unsupported YAML escape \\${esc}; skipping."
					return 1
					;;
				esac
			elif [ "$c" = '"' ]; then
				if [ "$i" -eq $((${#raw} - 1)) ]; then
					printf -v "$outvar" '%s' "$out"
					return 0
				fi
				powbox_warn "$context has trailing content after a quoted scalar; skipping."
				return 1
			else
				out+="$c"
			fi
		done
		powbox_warn "$context has an unterminated double-quoted scalar; skipping."
		return 1
	fi
	printf -v "$outvar" '%s' "$raw"
}

powbox_split_yaml_key_value() {
	local line parsed_key parsed_value
	line="$(powbox_trim "$(powbox_strip_yaml_comment "$1")")"
	if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_.-]*):($|[[:space:]].*)$ ]]; then
		parsed_key="${BASH_REMATCH[1]}"
		parsed_value="${BASH_REMATCH[2]}"
		printf -v "$2" '%s' "$parsed_key"
		printf -v "$3" '%s' "$parsed_value"
		return 0
	fi
	return 1
}

powbox_file_has_top_section() {
	local file="$1" section="$2" line stripped key value
	[ -f "$file" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		stripped="$(powbox_trim "$(powbox_strip_yaml_comment "$line")")"
		[ -n "$stripped" ] || continue
		case "${line:0:1}" in
		" " | $'\t') continue ;;
		esac
		if powbox_split_yaml_key_value "$line" key value && [ "$key" = "$section" ]; then
			return 0
		fi
	done <"$file"
	return 1
}

powbox_effective_ctx_config_present() {
	local workspace="$1"
	if powbox_file_has_top_section "${workspace}/.powbox.local.yml" ctx; then
		return 0
	fi
	powbox_file_has_top_section "${workspace}/.powbox.yml" ctx
}

powbox_local_shadow_config_present() {
	local workspace="$1"
	powbox_file_has_top_section "${workspace}/.powbox.local.yml" shadow
}

# A deliberately bounded .NET repo detector for the worktrees-volume-only gate.
# Solutions are recognized at the repo root; project files are recognized there
# or exactly one directory below it (for layouts such as src/App.csproj).
# Fixed-depth finds avoid an unbounded recursive scan. They are deliberately
# case-insensitive and include dot-prefixed direct children, matching the
# PowerShell launcher on every host. Inaccessible or concurrently removed child
# dirs are skipped. Keep this predicate in sync with the PowerShell launcher and
# the identity fixtures in smoke-test-selfhosted.{sh,ps1}.
dotnet_repo_present() {
	local project_root="$1"
	while IFS= read -r -d ''; do
		return 0
	done < <(
		find "$project_root" -mindepth 1 -maxdepth 1 -type f \
			\( -iname '*.sln' -o -iname '*.slnx' -o -iname '*.csproj' -o -iname '*.fsproj' -o -iname '*.vbproj' \) \
			-print0 2>/dev/null
	)
	while IFS= read -r -d ''; do
		return 0
	done < <(
		find "$project_root" -mindepth 2 -maxdepth 2 -type f \
			\( -iname '*.csproj' -o -iname '*.fsproj' -o -iname '*.vbproj' \) \
			-print0 2>/dev/null
	)
	return 1
}

powbox_parse_ctx_finish_object() {
	if [ "$ctx_obj_open" != true ]; then
		return 0
	fi
	if [ "$ctx_obj_bad" = true ]; then
		ctx_obj_open=false
		return 0
	fi
	if [ "$ctx_obj_path_set" != true ] || [ -z "$ctx_obj_path" ]; then
		powbox_warn "${ctx_obj_origin} is missing required path; skipping."
		ctx_obj_open=false
		return 0
	fi
	POWBOX_PARSE_CTX_PATHS+=("$ctx_obj_path")
	POWBOX_PARSE_CTX_NAMES+=("$ctx_obj_name")
	POWBOX_PARSE_CTX_MODES+=("$ctx_obj_mode")
	POWBOX_PARSE_CTX_SHORT_FORMS+=(false)
	POWBOX_PARSE_CTX_ORIGINS+=("$ctx_obj_origin")
	ctx_obj_open=false
}

powbox_parse_ctx_file() {
	local file="$1" line stripped key value value_trim rest parsed
	local line_no=0 in_ctx=false
	local ctx_obj_open=false ctx_obj_bad=false ctx_obj_path_set=false
	local ctx_obj_path="" ctx_obj_name="" ctx_obj_mode="" ctx_obj_origin=""
	POWBOX_PARSE_CTX_PRESENT=false
	POWBOX_PARSE_CTX_PATHS=()
	POWBOX_PARSE_CTX_NAMES=()
	POWBOX_PARSE_CTX_MODES=()
	POWBOX_PARSE_CTX_SHORT_FORMS=()
	POWBOX_PARSE_CTX_ORIGINS=()
	[ -f "$file" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		line="${line%$'\r'}"
		stripped="$(powbox_trim "$(powbox_strip_yaml_comment "$line")")"
		[ -n "$stripped" ] || continue

		case "${line:0:1}" in
		" " | $'\t') ;;
		*)
			if [ "$in_ctx" = true ]; then
				powbox_parse_ctx_finish_object
			fi
			in_ctx=false
			if ! powbox_split_yaml_key_value "$line" key value; then
				continue
			fi
			if [ "$key" = "ctx" ]; then
				POWBOX_PARSE_CTX_PRESENT=true
				value_trim="$(powbox_trim "$value")"
				case "$value_trim" in
				"")
					in_ctx=true
					;;
				"[]")
					in_ctx=false
					;;
				*)
					powbox_warn "${file}:${line_no}: unsupported inline ctx value; use a block list or ctx: []."
					;;
				esac
			fi
			continue
			;;
		esac

		[ "$in_ctx" = true ] || continue
		if [ "${stripped:0:1}" = "-" ]; then
			powbox_parse_ctx_finish_object
			rest="$(powbox_trim "${stripped:1}")"
			if [ -z "$rest" ]; then
				ctx_obj_open=true
				ctx_obj_bad=false
				ctx_obj_path_set=false
				ctx_obj_path=""
				ctx_obj_name=""
				ctx_obj_mode=""
				ctx_obj_origin="${file}:${line_no}"
				continue
			fi
			if powbox_split_yaml_key_value "$rest" key value; then
				case "$key" in
				path | name | mode) ;;
				*)
					if powbox_parse_yaml_scalar "$rest" parsed "${file}:${line_no}: ctx entry"; then
						POWBOX_PARSE_CTX_PATHS+=("$parsed")
						POWBOX_PARSE_CTX_NAMES+=("")
						POWBOX_PARSE_CTX_MODES+=("")
						POWBOX_PARSE_CTX_SHORT_FORMS+=(true)
						POWBOX_PARSE_CTX_ORIGINS+=("${file}:${line_no}")
					fi
					continue
					;;
				esac
				ctx_obj_open=true
				ctx_obj_bad=false
				ctx_obj_path_set=false
				ctx_obj_path=""
				ctx_obj_name=""
				ctx_obj_mode=""
				ctx_obj_origin="${file}:${line_no}"
				case "$key" in
				path | name | mode)
					if powbox_parse_yaml_scalar "$value" parsed "${file}:${line_no}: ctx.${key}"; then
						case "$key" in
						path)
							ctx_obj_path="$parsed"
							ctx_obj_path_set=true
							;;
						name) ctx_obj_name="$parsed" ;;
						mode) ctx_obj_mode="$parsed" ;;
						esac
					else
						ctx_obj_bad=true
					fi
					;;
				esac
			else
				if powbox_parse_yaml_scalar "$rest" parsed "${file}:${line_no}: ctx entry"; then
					POWBOX_PARSE_CTX_PATHS+=("$parsed")
					POWBOX_PARSE_CTX_NAMES+=("")
					POWBOX_PARSE_CTX_MODES+=("")
					POWBOX_PARSE_CTX_SHORT_FORMS+=(true)
					POWBOX_PARSE_CTX_ORIGINS+=("${file}:${line_no}")
				fi
			fi
			continue
		fi

		if [ "$ctx_obj_open" = true ]; then
			if ! powbox_split_yaml_key_value "$stripped" key value; then
				powbox_warn "${file}:${line_no}: unsupported ctx object syntax; skipping entry."
				ctx_obj_bad=true
				continue
			fi
			case "$key" in
			path | name | mode)
				if powbox_parse_yaml_scalar "$value" parsed "${file}:${line_no}: ctx.${key}"; then
					case "$key" in
					path)
						ctx_obj_path="$parsed"
						ctx_obj_path_set=true
						;;
					name) ctx_obj_name="$parsed" ;;
					mode) ctx_obj_mode="$parsed" ;;
					esac
				else
					ctx_obj_bad=true
				fi
				;;
			*)
				powbox_warn "${file}:${line_no}: unsupported ctx object key '${key}'; skipping entry."
				ctx_obj_bad=true
				;;
			esac
		else
			powbox_warn "${file}:${line_no}: ctx property without a list item; skipping."
		fi
	done <"$file"
	if [ "$in_ctx" = true ]; then
		powbox_parse_ctx_finish_object
	fi
}

powbox_load_effective_ctx_config() {
	local workspace="$1"
	local base_present=false local_present=false
	local -a base_paths=() base_names=() base_modes=() base_short_forms=() base_origins=()
	local -a local_paths=() local_names=() local_modes=() local_short_forms=() local_origins=()

	powbox_parse_ctx_file "${workspace}/.powbox.yml"
	if [ "$POWBOX_PARSE_CTX_PRESENT" = true ]; then
		base_present=true
		base_paths=("${POWBOX_PARSE_CTX_PATHS[@]}")
		base_names=("${POWBOX_PARSE_CTX_NAMES[@]}")
		base_modes=("${POWBOX_PARSE_CTX_MODES[@]}")
		base_short_forms=("${POWBOX_PARSE_CTX_SHORT_FORMS[@]}")
		base_origins=("${POWBOX_PARSE_CTX_ORIGINS[@]}")
	fi

	powbox_parse_ctx_file "${workspace}/.powbox.local.yml"
	if [ "$POWBOX_PARSE_CTX_PRESENT" = true ]; then
		local_present=true
		local_paths=("${POWBOX_PARSE_CTX_PATHS[@]}")
		local_names=("${POWBOX_PARSE_CTX_NAMES[@]}")
		local_modes=("${POWBOX_PARSE_CTX_MODES[@]}")
		local_short_forms=("${POWBOX_PARSE_CTX_SHORT_FORMS[@]}")
		local_origins=("${POWBOX_PARSE_CTX_ORIGINS[@]}")
	fi

	POWBOX_CTX_CONFIG_PRESENT=false
	POWBOX_CTX_CONFIG_PATHS=()
	POWBOX_CTX_CONFIG_NAMES=()
	POWBOX_CTX_CONFIG_MODES=()
	POWBOX_CTX_CONFIG_SHORT_FORMS=()
	POWBOX_CTX_CONFIG_ORIGINS=()
	if [ "$local_present" = true ]; then
		POWBOX_CTX_CONFIG_PRESENT=true
		POWBOX_CTX_CONFIG_PATHS=("${local_paths[@]}")
		POWBOX_CTX_CONFIG_NAMES=("${local_names[@]}")
		POWBOX_CTX_CONFIG_MODES=("${local_modes[@]}")
		POWBOX_CTX_CONFIG_SHORT_FORMS=("${local_short_forms[@]}")
		POWBOX_CTX_CONFIG_ORIGINS=("${local_origins[@]}")
	elif [ "$base_present" = true ]; then
		POWBOX_CTX_CONFIG_PRESENT=true
		POWBOX_CTX_CONFIG_PATHS=("${base_paths[@]}")
		POWBOX_CTX_CONFIG_NAMES=("${base_names[@]}")
		POWBOX_CTX_CONFIG_MODES=("${base_modes[@]}")
		POWBOX_CTX_CONFIG_SHORT_FORMS=("${base_short_forms[@]}")
		POWBOX_CTX_CONFIG_ORIGINS=("${base_origins[@]}")
	fi
}

powbox_expand_leading_tilde() {
	local path="$1"
	if [ "$path" = "~" ] && [ -n "${HOME:-}" ]; then
		printf '%s' "$HOME"
	elif [[ "$path" == \~/* ]] && [ -n "${HOME:-}" ]; then
		printf '%s/%s' "$HOME" "${path#"~/"}"
	else
		printf '%s' "$path"
	fi
}

powbox_path_is_absolute() {
	case "$1" in
	/* | [A-Za-z]:/* | [A-Za-z]:\\* | \\\\*) return 0 ;;
	*) return 1 ;;
	esac
}

powbox_resolve_config_ctx_dir() {
	local raw="$1" workspace="$2" origin="$3" outvar="$4" path resolved_path
	path="$(powbox_expand_leading_tilde "$raw")"
	if ! powbox_path_is_absolute "$path"; then
		path="${workspace}/${path}"
	fi
	if [ ! -d "$path" ]; then
		powbox_warn "${origin}: context path does not exist or is not a directory; skipping: ${raw}"
		return 1
	fi
	resolved_path="$(cd "$path" && pwd -P)" || {
		powbox_warn "${origin}: failed to resolve context path; skipping: ${raw}"
		return 1
	}
	if [ "$resolved_path" != "/" ]; then
		resolved_path="${resolved_path%/}"
	fi
	printf -v "$outvar" '%s' "$resolved_path"
}

powbox_resolve_cli_ctx_dir() {
	local raw="$1" outvar="$2" path resolved_path
	path="$(powbox_expand_leading_tilde "$raw")"
	if [ ! -d "$path" ]; then
		echo "Error: context path does not exist: ${raw}" >&2
		exit 1
	fi
	resolved_path="$(cd "$path" && pwd -P)" || {
		echo "Error: failed to resolve context path: ${raw}" >&2
		exit 1
	}
	if [ "$resolved_path" != "/" ]; then
		resolved_path="${resolved_path%/}"
	fi
	printf -v "$outvar" '%s' "$resolved_path"
}

powbox_path_basename() {
	local path="$1"
	path="${path%/}"
	printf '%s' "${path##*/}"
}

powbox_validate_ctx_name() {
	local name="$1"
	[ -n "$name" ] || return 1
	[ "$name" != "." ] || return 1
	[ "$name" != ".." ] || return 1
	case "$name" in
	*/* | *\\*) return 1 ;;
	esac
	return 0
}

powbox_add_ctx_mount() {
	local name="$1" path="$2" mode="$3" origin="$4" strict="${5:-false}" duplicate
	if ! powbox_validate_ctx_name "$name"; then
		if [ "$strict" = true ]; then
			echo "Error: context mount name derived from ${path} is not a usable single path segment: ${name}" >&2
			exit 1
		fi
		powbox_warn "${origin}: context mount name is not a usable single path segment; skipping: ${name}"
		return 1
	fi
	for duplicate in "${CTX_MOUNT_NAMES[@]}"; do
		if [ "$duplicate" = "$name" ]; then
			if [ "$strict" = true ]; then
				echo "Error: duplicate ctx target name '${name}' across --ctx values. Add an alias to disambiguate." >&2
				exit 1
			fi
			powbox_warn "${origin}: duplicate ctx target name '${name}'; skipping later entry. Add a name: alias to disambiguate."
			return 1
		fi
	done
	CTX_MOUNT_NAMES+=("$name")
	CTX_MOUNT_PATHS+=("$path")
	CTX_MOUNT_MODES+=("$mode")
}

powbox_parse_cli_ctx_value() {
	local raw="$1" out_path="$2" out_name="$3" out_mode="$4" path name="" mode=ro alias_candidate
	if [ -z "$raw" ]; then
		echo "Error: --ctx value has an empty path." >&2
		exit 1
	fi
	path="$raw"
	case "$path" in
	*:ro)
		mode=ro
		path="${path%:ro}"
		;;
	*:rw)
		mode=rw
		path="${path%:rw}"
		;;
	esac
	if [ -z "$path" ]; then
		echo "Error: --ctx value has an empty path: ${raw}" >&2
		exit 1
	fi
	if [[ "$path" == *=* ]]; then
		alias_candidate="${path%%=*}"
		if powbox_validate_ctx_name "$alias_candidate"; then
			name="$alias_candidate"
			path="${path#*=}"
			if [ -z "$path" ]; then
				echo "Error: --ctx value has an empty path: ${raw}" >&2
				exit 1
			fi
		fi
	fi
	printf -v "$out_path" '%s' "$path"
	printf -v "$out_name" '%s' "$name"
	printf -v "$out_mode" '%s' "$mode"
}

powbox_byte_less() {
	local LC_ALL=C
	[[ "$1" < "$2" ]]
}

powbox_ctx_sorted_indices() {
	local -a sorted=()
	local i j pos existing
	for i in "${!CTX_MOUNT_NAMES[@]}"; do
		pos="${#sorted[@]}"
		for ((j = 0; j < ${#sorted[@]}; j++)); do
			existing="${sorted[$j]}"
			if powbox_byte_less "${CTX_MOUNT_NAMES[$i]}" "${CTX_MOUNT_NAMES[$existing]}"; then
				pos="$j"
				break
			fi
		done
		sorted=("${sorted[@]:0:$pos}" "$i" "${sorted[@]:$pos}")
	done
	POWBOX_CTX_SORTED_INDICES=("${sorted[@]}")
}

powbox_emit_ctx_canonical() {
	local i
	powbox_ctx_sorted_indices
	for i in "${POWBOX_CTX_SORTED_INDICES[@]}"; do
		printf '%s\0%s\0%s\0' "${CTX_MOUNT_NAMES[$i]}" "${CTX_MOUNT_PATHS[$i]}" "${CTX_MOUNT_MODES[$i]}"
	done
}

powbox_ctx_hash() {
	powbox_emit_ctx_canonical | powbox_sha256_stdin
}

powbox_derive_ctx_mounts() {
	local workspace="$1" resolved raw_path raw_name raw_mode raw_short_form mode name origin i cli_mode
	CTX_DESIRED_PRESENT=false
	CTX_HASH=""
	CTX_MOUNT_NAMES=()
	CTX_MOUNT_PATHS=()
	CTX_MOUNT_MODES=()

	if [ "${#CTX_VALUES[@]}" -gt 0 ]; then
		CTX_DESIRED_PRESENT=true
		for i in "${!CTX_VALUES[@]}"; do
			powbox_parse_cli_ctx_value "${CTX_VALUES[$i]}" raw_path raw_name cli_mode
			powbox_resolve_cli_ctx_dir "$raw_path" resolved
			if [ -n "$raw_name" ]; then
				name="$raw_name"
			else
				name="$(powbox_path_basename "$resolved")"
			fi
			powbox_add_ctx_mount "$name" "$resolved" "$cli_mode" "--ctx" true
		done
		CTX_HASH="$(powbox_ctx_hash)"
		return 0
	fi

	if [ "$ISOLATED" = true ]; then
		return 0
	fi

	powbox_load_effective_ctx_config "$workspace"
	if [ "$POWBOX_CTX_CONFIG_PRESENT" != true ]; then
		return 0
	fi
	CTX_DESIRED_PRESENT=true
	for i in "${!POWBOX_CTX_CONFIG_PATHS[@]}"; do
		raw_path="${POWBOX_CTX_CONFIG_PATHS[$i]}"
		raw_name="${POWBOX_CTX_CONFIG_NAMES[$i]}"
		raw_mode="${POWBOX_CTX_CONFIG_MODES[$i]}"
		raw_short_form="${POWBOX_CTX_CONFIG_SHORT_FORMS[$i]}"
		origin="${POWBOX_CTX_CONFIG_ORIGINS[$i]}"

		mode="$raw_mode"
		if [ -z "$mode" ]; then
			if [ "$raw_short_form" = true ]; then
				case "$raw_path" in
				*:ro)
					mode=ro
					raw_path="${raw_path%:ro}"
					;;
				*:rw)
					mode=rw
					raw_path="${raw_path%:rw}"
					;;
				*)
					mode=ro
					;;
				esac
			else
				mode=ro
			fi
		fi
		case "$mode" in
		ro | rw) ;;
		*)
			powbox_warn "${origin}: unsupported ctx mode '${mode}'; expected ro or rw; skipping."
			continue
			;;
		esac
		if [ -z "$raw_path" ]; then
			powbox_warn "${origin}: ctx entry has an empty path; skipping."
			continue
		fi
		if ! powbox_resolve_config_ctx_dir "$raw_path" "$workspace" "$origin" resolved; then
			continue
		fi
		if [ -n "$raw_name" ]; then
			name="$raw_name"
		else
			name="$(powbox_path_basename "$resolved")"
		fi
		powbox_add_ctx_mount "$name" "$resolved" "$mode" "$origin" || true
	done
	CTX_HASH="$(powbox_ctx_hash)"
}

powbox_yaml_double_quote() {
	local s="${1//$/\$\$}" out="" c
	local i
	for ((i = 0; i < ${#s}; i++)); do
		c="${s:i:1}"
		case "$c" in
		"\\") out+="\\\\" ;;
		'"') out+="\\\"" ;;
		$'\n') out+="\\n" ;;
		$'\r') out+="\\r" ;;
		$'\t') out+="\\t" ;;
		*) out+="$c" ;;
		esac
	done
	printf '"%s"' "$out"
}

powbox_write_ctx_compose_overlay() {
	local file="$1" i read_only_value target
	{
		printf 'services:\n'
		printf '  agent:\n'
		printf '    volumes:\n'
		for i in "${!CTX_MOUNT_NAMES[@]}"; do
			if [ "${CTX_MOUNT_MODES[$i]}" = ro ]; then
				read_only_value=true
			else
				read_only_value=false
			fi
			target="/ctx/${CTX_MOUNT_NAMES[$i]}"
			printf '      - type: bind\n'
			printf '        source: %s\n' "$(powbox_yaml_double_quote "${CTX_MOUNT_PATHS[$i]}")"
			printf '        target: %s\n' "$(powbox_yaml_double_quote "$target")"
			printf '        read_only: %s\n' "$read_only_value"
		done
	} >"$file"
}

powbox_warn_if_local_config_not_ignored() {
	local workspace="$1"
	[ -f "${workspace}/.powbox.local.yml" ] || return 0
	command -v git >/dev/null 2>&1 || return 0
	git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
	if ! git -C "$workspace" check-ignore -q -- .powbox.local.yml; then
		powbox_warn ".powbox.local.yml exists but is not ignored by git. Add it to .gitignore to keep local-only host paths out of commits."
	fi
}

# Per-instance volume names that only exist in one mode. Declared empty up front
# so referencing them under `set -u` in the other mode is always safe.
NM_VOLUME=""
WT_VOLUME=""
WS_VOLUME=""
# Whether to mount the dir-mounted node_modules volume. Only set true for a
# project that actually looks like one that needs it (see below); a non-dev
# folder mounted for research or file management gets neither volume, so Docker
# never auto-creates empty node_modules/ and .worktrees/ mountpoint dirs in the
# host folder. This flag keeps its historical name and meaning — the JS/powbox
# gate — because PNPM_STORE_DIR and the pnpm wrapper's regression guard key on it.
MOUNT_WORKSPACE_VOLUMES=false
# Whether to mount the dir-mounted worktrees volume (a SUPERSET gate): true
# whenever MOUNT_WORKSPACE_VOLUMES is, PLUS for a Go- or .NET-only repo. Those
# projects want the persistent worktrees volume and language caches but have no
# use for an isolated node_modules mount, which would only litter the host.
MOUNT_WORKTREES_VOLUME=false
DOTNET_REPO_PRESENT=false
WORKTREES_ONLY_REPO_DESCRIPTION="worktrees-only repo"
REPO_SPEC=""

if [ "$ISOLATED" = true ]; then
	# --- Self-hosted (isolated) identity -------------------------------------
	# Resolve the repo to clone. Precedence: explicit --repo wins; else if the
	# positional is an existing directory, infer it from that dir's `origin`
	# remote (the "standing inside a repo" convenience); else the positional
	# itself is the repo spec (an owner/repo slug or a clone URL).
	if [ -n "$REPO_FLAG" ]; then
		REPO_SPEC="$REPO_FLAG"
	elif [ -d "$PROJECT_PATH" ]; then
		REPO_SPEC="$(git -C "$PROJECT_PATH" remote get-url origin 2>/dev/null || true)"
		if [ -z "$REPO_SPEC" ]; then
			echo "Error: --isolated needs a repo to clone (owner/repo or a clone URL)." >&2
			echo "None was given and 'git remote get-url origin' found nothing in ${PROJECT_PATH}." >&2
			echo "Pass it explicitly, e.g. --repo owner/repo, or --repo https://github.com/owner/repo.git" >&2
			exit 1
		fi
		# Redact any userinfo (token) from the displayed origin URL so an embedded
		# credential is not echoed to the terminal/scrollback (sed mirrors
		# seed-workspace.sh's redact_url); the real spec is still used below.
		echo "Self-hosted mode: inferred repo from origin in ${PROJECT_PATH}: $(printf '%s' "$REPO_SPEC" | sed -E 's#(://)[^/]*@#\1#')" >&2
	else
		REPO_SPEC="$PROJECT_PATH"
	fi

	# Reject a clone URL that embeds a credential in its authority (e.g. a PAT URL
	# https://<token>@github.com/owner/repo.git). Self-hosted containers are kept by
	# default, so the spec is frozen into POWBOX_CLONE_REPO in the container env where
	# `docker inspect` would expose the secret long after launch. The container
	# authenticates via gh (established before the clone), so an embedded credential is
	# never needed — fail fast. Only http(s) userinfo is a secret; an ssh:// URL's
	# `git@` is a benign SSH user (key auth) and is normalised to HTTPS in the
	# container, so it is left alone. The error never echoes the userinfo itself.
	#
	# URL schemes are case-insensitive (RFC 3986), so the scheme is lower-cased before
	# matching — otherwise HTTPS://<token>@host/… would slip past a case-sensitive
	# http(s) pattern and the secret would be frozen into the env anyway. (The
	# PowerShell launcher's -match/-replace are case-insensitive by default, so this
	# keeps the two in parity.)
	case "$REPO_SPEC" in
	*://*)
		_ru_scheme="$(printf '%s' "${REPO_SPEC%%://*}" | tr '[:upper:]' '[:lower:]')"
		case "$_ru_scheme" in
		http | https)
			_ru_authority="${REPO_SPEC#*://}"
			_ru_authority="${_ru_authority%%/*}"
			case "$_ru_authority" in
			*@*)
				echo "Error: the clone URL embeds a credential in its authority (userinfo before '@')." >&2
				echo "Self-hosted containers are kept, so this would persist the secret in the container" >&2
				echo "environment (visible via 'docker inspect'). The container authenticates via gh, so" >&2
				echo "drop the credential and pass a plain URL or slug, e.g. --repo owner/repo." >&2
				exit 1
				;;
			esac
			unset _ru_authority
			;;
		esac
		unset _ru_scheme
		;;
	esac

	# Reject control characters in any value frozen into a container label. cc-list /
	# agent-list parse the labels back with a \x1f field separator and one-container-
	# per-line reads, so a newline or a literal \x1f in --name/--repo/--ref would split
	# a record or shift fields and corrupt the listing (display quoting can't undo a real
	# newline). No legitimate repo spec, ref, or name contains a control char, so fail
	# fast here rather than at display time. The flag-name prefix is split on the FIRST
	# ':' only, so a repo spec's own ':' (https://…, git@host:path) is preserved.
	for _cc_pair in "--name:$INSTANCE_NAME" "--repo:$REPO_SPEC" "--ref:$CLONE_REF"; do
		case "${_cc_pair#*:}" in
		*[[:cntrl:]]*)
			echo "Error: ${_cc_pair%%:*} must not contain control characters (newlines, tabs, etc.)." >&2
			exit 1
			;;
		esac
	done
	unset _cc_pair

	# repo-slug: basename, strip a trailing .git, lowercase + sanitise — the same
	# shape as the dir-mounted PROJECT_BASENAME handling above. Lowercase BEFORE the
	# .git strip so an uppercase .GIT/.Git extension is removed too (POSIX %.git is
	# case-sensitive), matching the PowerShell launcher's case-insensitive strip.
	REPO_BASENAME="$(basename "$REPO_SPEC" | tr '[:upper:]' '[:lower:]')"
	REPO_BASENAME="${REPO_BASENAME%.git}"
	REPO_SLUG="$(printf '%s' "$REPO_BASENAME" | tr -cs 'a-z0-9._-' '-' | sed 's/^-//; s/-$//')"
	if [ -z "$REPO_SLUG" ]; then
		echo "Error: could not derive a repo slug from '${REPO_SPEC}'." >&2
		exit 1
	fi

	# Instance discriminator: --name <label> if given (named → deterministic →
	# reusable: same clone + session history across launches), else a
	# high-resolution timestamp + pid + random token so two same-second unnamed
	# launches never collide (unnamed → fresh every launch). The instance hash is
	# SHA256(label)[:12], reusing the dir-mounted 12-char hash shape.
	#
	# A NAMED discriminator folds in the canonical repo identity, so the same --name
	# used for two different repos that share a basename (owner1/app vs owner2/app)
	# resolves to distinct identities instead of one shared app-<hash> — which would
	# otherwise let the second launch attach to (or --reclone wipe) the first repo's
	# container and workspace. It ALSO folds in the agent, so the same repo+name under
	# both agents (cc vs cx) gets distinct PROJECT_NAMEs and therefore distinct
	# /workspace/<slug> paths — the per-instance workspace volume is already keyed per
	# container (agent-ws-<container>), so without this the two agents would share one
	# in-container cwd while holding independent clones, and a delegated peer agent
	# (both config volumes are always mounted) resumes sessions by cwd and would pick
	# up the other clone's history. The unnamed branch already gets a globally-unique
	# timestamp, so it needs no repo/agent discriminator.
	if [ -n "$INSTANCE_NAME" ]; then
		INSTANCE_LABEL="$(repo_identity "$REPO_SPEC")|$AGENT|$INSTANCE_NAME"
	else
		INSTANCE_LABEL="ts-$(date -u +%Y%m%d%H%M%S)-$$-${RANDOM}${RANDOM}"
	fi
	INSTANCE_HASH="$(project_hash "$INSTANCE_LABEL")"
	# Cosmetic, human-readable slug from --name, folded into PROJECT_NAME so the
	# container/workspace name and `cc-list` show WHICH instance without an inspect. It
	# does NOT own identity: the 12-char hash above (which hashes the RAW --name) does,
	# so two --names that slugify alike — "Feature A" and "feature/a" both → feature-a —
	# stay distinct containers (told apart by the hash and the powbox.instance-name
	# label). Sanitise to the repo-slug shape, cap the length, and drop it entirely if it
	# empties out so a punctuation-only name never weakens the hash-based identity. Empty
	# for unnamed launches (no --name → no slug, so PROJECT_NAME is unchanged there).
	NAME_SLUG="$(printf '%s' "$INSTANCE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-' | sed 's/^[-.]*//; s/[-.]*$//' | cut -c1-32 | sed 's/[-.]*$//')"
	PROJECT_NAME="${REPO_SLUG}${NAME_SLUG:+-${NAME_SLUG}}-${INSTANCE_HASH}"
else
	# --- Dir-mounted identity (unchanged) ------------------------------------
	# On Windows (MSYS/Cygwin), the filesystem is typically case-insensitive and the terminal
	# may report paths with inconsistent capitalisation, so we normalise to lowercase before
	# hashing — matching PowerShell's ToLowerInvariant() behaviour.
	# On Linux and macOS the filesystem is case-sensitive, so two paths differing only by case
	# are genuinely distinct directories; lowercasing would risk hash collisions between different
	# workspaces. We therefore preserve the path as-is on those platforms.
	case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*)
		PROJECT_HASH_INPUT="$(printf '%s' "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]')"
		;;
	*)
		PROJECT_HASH_INPUT="$PROJECT_PATH"
		;;
	esac
	PROJECT_HASH="$(project_hash "$PROJECT_HASH_INPUT")"
	PROJECT_NAME="$(printf '%s' "$PROJECT_BASENAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-' | sed 's/^-//; s/-$//')-$PROJECT_HASH"
	# Root node_modules and the worktrees+store volumes are keyed by the OUTER
	# container (agent + project), NOT just the project — i.e. "${AGENT}-${PROJECT_NAME}",
	# which is CONTAINER_NAME (defined just below). This MUST match agent-podman-*'s
	# per-container keying: a project's Claude and Codex containers can run at the same
	# time, and they mount these volumes at the SAME in-container paths. Two live agents
	# sharing one writable node_modules tree (or one pnpm store) corrupt each other —
	# concurrent installs race, and a build in one agent reads a tree the other is
	# relinking. Per-container volumes give each agent its own node_modules, virtual
	# store, pnpm store, and worktree disk budget. The cost is lost cross-agent dedup
	# (two stores, two node_modules per project); correctness for simultaneous agents
	# is worth it. The subpackage node_modules are already per-container (tmpfs shadows).
	NM_VOLUME="agent-nm-${AGENT}-${PROJECT_NAME}"
	# Per-container worktrees volume. Holds the git worktrees AND the pnpm store under
	# ONE mount so pnpm hardlinks package files into per-worktree node_modules
	# instead of copying them. ext4, persistent, container-local, and (now) private to
	# this one container — so two agents never overcommit one shared worktree volume.
	WT_VOLUME="agent-wt-${AGENT}-${PROJECT_NAME}"
	# Mount those volumes only when the host folder looks like a project that uses
	# them: a JS/Node project (package.json — covers npm/yarn/pnpm — or
	# pnpm-workspace.yaml), one that has opted into powbox via committed .powbox.yml
	# (e.g. a non-JS repo that still wants persistent worktrees), or one with a
	# local-only shadow: key. A research/file-management folder, including one with
	# only local ctx: mounts, gets no node_modules/.worktrees mounts and no host litter.
	# The entrypoint's shadow loop independently finds nothing to shadow for such a
	# folder, so launcher and entrypoint stay consistent.
	if [ -f "$PROJECT_PATH/package.json" ] ||
		[ -f "$PROJECT_PATH/pnpm-workspace.yaml" ] ||
		[ -f "$PROJECT_PATH/.powbox.yml" ] ||
		powbox_local_shadow_config_present "$PROJECT_PATH"; then
		MOUNT_WORKSPACE_VOLUMES=true
	fi
	# The worktrees volume has WIDER, non-Node triggers: go.mod and a bounded .NET
	# predicate (root *.sln/*.slnx/*.csproj/*.fsproj/*.vbproj, or project files
	# exactly one directory below the root). A pure Go or .NET repo gets agent-wt-*
	# (persistent caches + worktrees) but NOT agent-nm-* — no empty node_modules/
	# litter on the host. PNPM_STORE_DIR stays keyed to the JS/powbox gate above,
	# so the pnpm wrapper's host-litter warning still fires for a stray root
	# `pnpm install` in a Go/.NET-only repo.
	if dotnet_repo_present "$PROJECT_PATH"; then
		DOTNET_REPO_PRESENT=true
	fi
	if [ "$MOUNT_WORKSPACE_VOLUMES" = true ] || [ -f "$PROJECT_PATH/go.mod" ] || [ "$DOTNET_REPO_PRESENT" = true ]; then
		MOUNT_WORKTREES_VOLUME=true
	fi
	if [ -f "$PROJECT_PATH/go.mod" ] && [ "$DOTNET_REPO_PRESENT" = true ]; then
		WORKTREES_ONLY_REPO_DESCRIPTION="Go/.NET repo"
	elif [ -f "$PROJECT_PATH/go.mod" ]; then
		WORKTREES_ONLY_REPO_DESCRIPTION="go.mod-only repo"
	elif [ "$DOTNET_REPO_PRESENT" = true ]; then
		WORKTREES_ONLY_REPO_DESCRIPTION=".NET-only repo"
	fi
fi

CONTAINER_NAME="${AGENT}-${PROJECT_NAME}"
WORKSPACE_MOUNT="/workspace/${PROJECT_NAME}"
# pnpm store path under the workspace mount (same mount as .worktrees/<task> in
# both modes — a per-container volume in dir-mounted mode, the one workspace volume
# in self-hosted mode — so per-worktree `pnpm install` hardlinks from the store).
WT_STORE_DIR="${WORKSPACE_MOUNT}/.worktrees/.pnpm-store"
# Go caches beside the pnpm store, under the same persistent mount. Their
# in-container defaults (~/go/pkg/mod, ~/.cache/go-build) sit OUTSIDE every
# volume, so container recreation cold-downloads all modules and rebuilds
# everything; pointing GOMODCACHE/GOCACHE here survives recreation in both
# modes. Deliberately SHARED across a project's worktrees (unlike the
# golangci-lint analysis cache): the module cache is content-addressed with its
# own locking and the build cache is designed for concurrent builds, so sharing
# is safe and is the whole point (warm caches for every worktree).
WT_GOMODCACHE_DIR="${WORKSPACE_MOUNT}/.worktrees/.gomodcache"
WT_GOCACHE_DIR="${WORKSPACE_MOUNT}/.worktrees/.gocache"
# ccache compiler cache beside the Go caches, same persistent mount and same
# sharing rationale: content-addressed and lock-safe under concurrent builds, so
# it is deliberately SHARED across a project's worktrees (warm objects for all).
# Its in-container default (~/.cache/ccache) dies with the container. Opt-in per
# build (baked binary + persistent dir only; no global CC/CXX interposition).
WT_CCACHE_DIR="${WORKSPACE_MOUNT}/.worktrees/.ccache"
# NuGet's global packages folder beside the other shared, persistent caches.
# NUGET_PACKAGES is the documented override and the global packages folder is
# designed for reuse by many projects/processes; NuGet coordinates concurrent
# access with filesystem locks. Sharing it across this repo's worktrees avoids
# duplicate restores while each outer agent container keeps its own volume.
WT_NUGET_PACKAGES_DIR="${WORKSPACE_MOUNT}/.worktrees/.nuget"
# Per-container rootless Podman storage (images + named volumes) so an in-sandbox
# agent's containers and their data persist across restarts. Keyed by the OUTER
# container (agent + project), NOT just the project: a project's Claude and Codex
# containers can run concurrently, and two Podman instances with separate
# runroots/namespaces sharing one graphroot corrupt each other's metadata and
# lifecycle state. A shared image cache is a separate concern (additionalimagestores).
PODMAN_VOLUME="agent-podman-${CONTAINER_NAME}"
if [ "$ISOLATED" = true ]; then
	# The one per-instance workspace volume that REPLACES the host bind mount plus
	# the dir-mounted agent-nm-*/agent-wt-* shadows: the clone, node_modules,
	# .worktrees, and the pnpm store, Go/NuGet caches, and ccache all live inside it as
	# ordinary subdirs (one mount → pnpm hardlinks everywhere, including the root
	# node_modules). Keyed by the full container name, like PODMAN_VOLUME, so it is
	# part of the container's identity. Mounted via compose.selfhosted.yml (merged
	# by target path).
	WS_VOLUME="agent-ws-${CONTAINER_NAME}"
fi

# Internal/testing hook: print the resolved identity and exit before touching
# Docker. Lets the self-hosted smoke test assert naming (named→deterministic,
# unnamed→fresh, repo-slug derivation) without building or launching anything.
if [ "${POWBOX_PRINT_IDENTITY:-}" = "1" ]; then
	if [ "$ISOLATED" = true ]; then printf 'mode=isolated\n'; else printf 'mode=dir-mounted\n'; fi
	printf 'PROJECT_NAME=%s\n' "$PROJECT_NAME"
	printf 'CONTAINER_NAME=%s\n' "$CONTAINER_NAME"
	printf 'WORKSPACE_MOUNT=%s\n' "$WORKSPACE_MOUNT"
	printf 'PODMAN_VOLUME=%s\n' "$PODMAN_VOLUME"
	printf 'NM_VOLUME=%s\n' "$NM_VOLUME"
	printf 'WT_VOLUME=%s\n' "$WT_VOLUME"
	printf 'WS_VOLUME=%s\n' "$WS_VOLUME"
	printf 'MOUNT_WORKSPACE_VOLUMES=%s\n' "$MOUNT_WORKSPACE_VOLUMES"
	printf 'MOUNT_WORKTREES_VOLUME=%s\n' "$MOUNT_WORKTREES_VOLUME"
	if [ "$ISOLATED" = true ] || [ "$MOUNT_WORKSPACE_VOLUMES" = true ]; then
		printf 'PNPM_STORE_DIR=%s\n' "$WT_STORE_DIR"
	else
		printf 'PNPM_STORE_DIR=\n'
	fi
	if [ "$ISOLATED" = true ] || [ "$MOUNT_WORKTREES_VOLUME" = true ]; then
		printf 'NUGET_PACKAGES=%s\n' "$WT_NUGET_PACKAGES_DIR"
	else
		printf 'NUGET_PACKAGES=\n'
	fi
	printf 'REPO_SPEC=%s\n' "$REPO_SPEC"
	printf 'CLONE_REF=%s\n' "$CLONE_REF"
	exit 0
fi

CTX_CONFIG_PRESENT=false
if [ "$ISOLATED" != true ]; then
	powbox_warn_if_local_config_not_ignored "$PROJECT_PATH"
	if powbox_effective_ctx_config_present "$PROJECT_PATH"; then
		CTX_CONFIG_PRESENT=true
	fi
fi

CTX_DESIRED_PRESENT=false
CTX_HASH=""
CTX_MOUNT_NAMES=()
CTX_MOUNT_PATHS=()
CTX_MOUNT_MODES=()
if [ "$RESUME" != true ]; then
	powbox_derive_ctx_mounts "$PROJECT_PATH"
fi

if [ "${POWBOX_PRINT_CTX:-}" = "1" ]; then
	printf 'CTX_CONFIG_PRESENT=%s\n' "$CTX_CONFIG_PRESENT"
	printf 'CTX_DESIRED_PRESENT=%s\n' "$CTX_DESIRED_PRESENT"
	printf 'CTX_HASH=%s\n' "$CTX_HASH"
	printf 'CTX_MOUNT_COUNT=%s\n' "${#CTX_MOUNT_NAMES[@]}"
	for i in "${!CTX_MOUNT_NAMES[@]}"; do
		printf 'CTX_MOUNT_%s_NAME=%s\n' "$i" "${CTX_MOUNT_NAMES[$i]}"
		printf 'CTX_MOUNT_%s_PATH=%s\n' "$i" "${CTX_MOUNT_PATHS[$i]}"
		printf 'CTX_MOUNT_%s_MODE=%s\n' "$i" "${CTX_MOUNT_MODES[$i]}"
	done
	if [ -n "${POWBOX_CTX_OVERLAY_OUT:-}" ] && [ "${#CTX_MOUNT_NAMES[@]}" -gt 0 ]; then
		powbox_write_ctx_compose_overlay "$POWBOX_CTX_OVERLAY_OUT"
		printf 'CTX_OVERLAY=%s\n' "$POWBOX_CTX_OVERLAY_OUT"
	fi
	exit 0
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_ARGS=(-p powbox -f "${ROOT_DIR}/compose.shared.yml" -f "${ROOT_DIR}/compose.agent.yml")
# Self-hosted overlay: replaces the host workspace BIND mount in compose.shared.yml
# with the per-instance named volume (merged by target path /workspace/<slug>).
# Added after the shared file so its volume entry wins; the fuse/netdev overlays
# appended later only add devices, so ordering with them is irrelevant.
if [ "$ISOLATED" = true ]; then
	COMPOSE_ARGS+=(-f "${ROOT_DIR}/compose.selfhosted.yml")
fi

# Ensure named volumes exist (compose won't auto-create external volumes). Both
# config volumes are always created/mounted so the non-primary agent can be
# spun up in-container with its own persistent login and skills.
# agent-podman-imagestore is the single GLOBAL read-only image cache shared by
# every container across all projects (consumed via Podman additionalimagestores).
# It is infra, like the config volumes — created here, never per-container.
SHARED_VOLUMES=(agent-gh-config agent-zsh-history claude-config codex-config agent-podman-imagestore)
for vol in "${SHARED_VOLUMES[@]}"; do
	if ! docker volume inspect "$vol" >/dev/null 2>&1; then
		docker volume create "$vol" >/dev/null
	fi
done

# In dir-mounted mode WORKSPACE_PATH is the host bind source. In self-hosted mode
# the workspace mount comes from compose.selfhosted.yml (which overrides the bind
# by target path), so WORKSPACE_PATH is unused — set it to a harmless "." that
# still parses as a valid short-syntax mount source, and export the volume name
# the overlay interpolates into its external `name:`.
if [ "$ISOLATED" = true ]; then
	export WORKSPACE_PATH="."
	export POWBOX_WS_VOLUME="$WS_VOLUME"
else
	export WORKSPACE_PATH="$PROJECT_PATH"
fi
export PROJECT_NAME

GH_HOST_CONFIG_DIR="${GH_HOST_CONFIG_DIR:-$HOME/.config/gh}"
GIT_CONFIG_PATH="${GIT_CONFIG_PATH:-$HOME/.gitconfig}"

CONTAINER_EXISTS=false
CONTAINER_RUNNING=false

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
	CONTAINER_EXISTS=true
	if [ "$(docker container inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]; then
		CONTAINER_RUNNING=true
	fi
fi

if [ "$BUILD" = true ]; then
	"${ROOT_DIR}/scripts/build-image.sh" agent
fi

if [ "$RESUME" = true ]; then
	if [ "$CONTAINER_EXISTS" != true ]; then
		echo "No persisted container named ${CONTAINER_NAME} was found. Start it once normally, or with --persist if you want to be explicit." >&2
		exit 1
	fi
	if [ "${#CTX_VALUES[@]}" -gt 0 ]; then
		echo "Note: --ctx is ignored with --resume; container will resume with its existing mounts. Omit --resume to apply ctx changes." >&2
	elif [ "$CTX_CONFIG_PRESENT" = true ]; then
		echo "Note: configured ctx mounts are ignored with --resume; container will resume with its existing mounts. Omit --resume to apply ctx changes." >&2
	fi
	if [ "$CONTINUE" = true ]; then
		echo "Note: --continue is ignored with --resume; container will restart with the CMD it was originally created with. Omit --resume to apply a continue-flag change." >&2
	fi
	if [ "$RECLONE" = true ]; then
		echo "Note: --reclone is ignored with --resume; the existing checkout is left untouched. Omit --resume to wipe and re-clone." >&2
	fi
	if [ -n "$CLONE_REF" ]; then
		echo "Note: --ref is ignored on resume; the existing checkout is left untouched." >&2
	fi
	# A running container (e.g. launched --detach, or its terminal was lost)
	# can't be `docker start`ed — that errors — so reattach instead. Mirrors the
	# reuse path below; cci/cxi reach this with --resume against a named instance
	# that may well still be running.
	if [ "$CONTAINER_RUNNING" = true ]; then
		if [ "$DETACH" = true ]; then
			echo "Container ${CONTAINER_NAME} is already running."
			exit 0
		fi
		exec docker attach "$CONTAINER_NAME"
	fi
	if [ "$DETACH" = true ]; then
		exec docker start "$CONTAINER_NAME"
	fi
	exec docker start -ai "$CONTAINER_NAME"
fi

# Self-hosted --reclone: wipe and re-seed an existing named container's clone.
# A reused container is started in place (reuse block below) and never re-runs the
# prep/create flow, so --reclone removes the stopped container to force that flow;
# the prep step then empties the (kept) agent-ws-* volume and the entrypoint clones
# fresh. The wipe is one-shot — nothing about it is frozen into the container.
if [ "$ISOLATED" = true ] && [ "$RECLONE" = true ] && [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	if [ "$CONTAINER_RUNNING" = true ]; then
		echo "Container ${CONTAINER_NAME} is running; stop it before --reclone (it re-clones on recreate)." >&2
		exit 1
	fi
	echo "--reclone: recreating ${CONTAINER_NAME} so it re-seeds its workspace from a fresh clone."
	if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
		if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
			echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
			exit 1
		fi
	fi
	CONTAINER_EXISTS=false
fi

# --ref only takes effect when seed-workspace actually CLONES, and it clones only when
# the per-instance workspace volume holds no checkout: a brand-new instance, or a
# --reclone (whose prep empties the volume). Whenever that volume is already populated,
# seed-workspace keeps the existing checkout and --ref is silently ignored — so WARN.
# Gate on the VOLUME, not CONTAINER_EXISTS: that also covers a container pruned while its
# agent-ws-* volume survived (e.g. agent-prune-stopped), and stays correct when a later
# block recreates the container (the kept volume is reused, so --ref still won't apply).
# The volume is created by the prep step further below, so on a genuine first launch it
# does not exist yet here and no warning fires. Benign by design — these are attended
# launches and the agent/user can switch refs in-container.
if [ "$ISOLATED" = true ] && [ -n "$CLONE_REF" ] && [ "$RECLONE" != true ] &&
	docker volume inspect "$WS_VOLUME" >/dev/null 2>&1; then
	echo "Note: --ref '${CLONE_REF}' applies only to a fresh clone; ${CONTAINER_NAME} keeps the existing checkout in its workspace volume. Use --reclone to re-clone at this ref, or switch branches inside the container." >&2
fi

if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	# Context mounts are frozen at container creation. When this launch has an
	# explicit desired set (CLI --ctx, ctx: in config, or explicit ctx: []), compare
	# the canonical mount-set hash label and recreate stopped mismatches. When there
	# is no desired set, keep whatever ctx mounts the container already has.
	if [ "$CTX_DESIRED_PRESENT" = true ]; then
		EXISTING_CTX_HASH="$(docker inspect --format '{{with .Config.Labels}}{{with index . "powbox.ctx-hash"}}{{.}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
		if [ "$EXISTING_CTX_HASH" != "$CTX_HASH" ]; then
			if [ "$CONTAINER_RUNNING" = true ]; then
				echo "Container ${CONTAINER_NAME} is running with a different ctx mount set. Stop the container first, then relaunch with the new ctx configuration." >&2
				exit 1
			fi
			if [ -z "$EXISTING_CTX_HASH" ]; then
				echo "Context mount set changed (existing container has no powbox.ctx-hash label, now '${CTX_HASH}'); recreating container."
			else
				echo "Context mount set changed (was '${EXISTING_CTX_HASH}', now '${CTX_HASH}'); recreating container."
			fi
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	else
		EXISTING_CTX_DESTS="$(docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | awk '$0 == "/ctx" || index($0, "/ctx/") == 1 { print }' | paste -sd ', ' - || true)"
		if [ -n "$EXISTING_CTX_DESTS" ]; then
			echo "Note: container has ctx mounts from a previous session (${EXISTING_CTX_DESTS}). Use --volatile to start fresh or --ctx/config ctx to change them."
		fi
	fi
fi

# Resolve which host devices rootless Podman will receive this launch into a
# normalised set string ("fuse,tun" / "fuse" / "tun" / "none"). The device list is
# frozen at container creation — `docker start` can't add /dev/fuse or /dev/net/tun
# to an existing container — so this is recorded as a label and a change recreates a
# stopped container (mirrors ctx mount-set and --continue handling). 'auto' resolves
# against the launcher host's /dev here, so the same host yields a stable value;
# 'on' forces both devices, 'off' neither. The compose-file selection below derives
# from the same value, so the label and the actual attach never disagree.
case "${POWBOX_PODMAN:-${POWBOX_FUSE:-auto}}" in
on) PODMAN_DEVICE_MODE="fuse,tun" ;;
off) PODMAN_DEVICE_MODE="none" ;;
*)
	PODMAN_DEVICE_MODE=""
	[ -e /dev/fuse ] && PODMAN_DEVICE_MODE="fuse"
	[ -e /dev/net/tun ] && PODMAN_DEVICE_MODE="${PODMAN_DEVICE_MODE:+${PODMAN_DEVICE_MODE},}tun"
	[ -n "$PODMAN_DEVICE_MODE" ] || PODMAN_DEVICE_MODE="none"
	;;
esac

# Detect whether the --continue flag state differs from what the container was created with.
# The CMD is frozen at container creation, so a flag change only takes effect after recreation.
# Missing label on an existing container predates this flag — treat it as "true" so the old
# auto-resume default remains in effect for reused containers until the user explicitly opts out,
# at which point this branch recycles the container to honour the new intent.
if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	EXISTING_CONTINUE="$(docker inspect --format '{{with .Config.Labels}}{{with index . "powbox.continue"}}{{.}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
	if [ -z "$EXISTING_CONTINUE" ]; then
		EXISTING_CONTINUE="true"
	fi
	WANT_CONTINUE="false"
	if [ "$CONTINUE" = true ]; then
		WANT_CONTINUE="true"
	fi
	if [ "$EXISTING_CONTINUE" != "$WANT_CONTINUE" ]; then
		if [ "$CONTAINER_RUNNING" = true ]; then
			echo "Note: container ${CONTAINER_NAME} is running; --continue=${WANT_CONTINUE} is ignored because the existing process was started with --continue=${EXISTING_CONTINUE}. Attaching to the running process. Stop it and relaunch to apply the flag change." >&2
		else
			echo "Continue flag changed (was '${EXISTING_CONTINUE}', now '${WANT_CONTINUE}'); recreating container."
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	fi
fi

# Detect whether the existing container's node_modules + .worktrees mounts still match
# what THIS launch wants, and recreate a stopped container when they do NOT. The expected
# mount at each destination depends on the (split) host-litter gate:
#   * JS/powbox project ($MOUNT_WORKSPACE_VOLUMES=true)  -> BOTH per-agent volumes
#     agent-{nm,wt}-<container>;
#   * Go/.NET-only repo ($MOUNT_WORKTREES_VOLUME=true only) -> ONLY agent-wt-<container>
#     (language caches + worktrees), NO node_modules mount;
#   * non-dev folder (both gates false)                    -> NO mount at all.
# This covers three upgrade/mismatch paths:
#   * predates the .worktrees volume entirely (no .worktrees mount) — it still
#     has a tmpfs .worktrees shadow and points pnpm at the old shared store, so worktree
#     installs never hardlink even after the image is rebuilt;
#   * predates the per-agent volume RENAME — it mounts the old project-keyed
#     agent-{nm,wt}-<project> instead of agent-{nm,wt}-<container>. A bare `docker start`
#     keeps the stale source, so a project's Claude and Codex would still share one
#     writable node_modules / pnpm store and race — exactly what per-agent keying exists
#     to prevent; and
#   * predates the host-litter gate (or the SPLIT gate), OR the folder changed shape —
#     it still mounts node_modules/.worktrees in a non-dev folder (or node_modules in a
#     Go/.NET-only repo), so a bare `docker start` keeps re-creating empty mountpoint dirs
#     in the host folder and the gate never takes effect for the upgraded container.
#     Recreating without those mounts is what stops the litter.
# Mere presence of a .worktrees mount can't distinguish these, so we compare the actual
# mounted volume NAME at each destination to the expected name (empty = expect no mount).
# Warn (don't disrupt) if it is currently running. Self-hosted mode is skipped
# ($ISOLATED): its node_modules/.worktrees are subdirs INSIDE the one workspace volume,
# not separate mounts, so there is nothing to compare — and a steady-state non-dev reuse
# (no mounts present, none expected) compares equal and is correctly left alone.
if [ "$ISOLATED" != true ] && [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	EXPECTED_NM_MOUNT=""
	EXPECTED_WT_MOUNT=""
	if [ "$MOUNT_WORKSPACE_VOLUMES" = true ]; then
		EXPECTED_NM_MOUNT="$NM_VOLUME"
	fi
	if [ "$MOUNT_WORKTREES_VOLUME" = true ]; then
		EXPECTED_WT_MOUNT="$WT_VOLUME"
	fi
	WT_MOUNT_NAME="$(docker inspect --format "{{range .Mounts}}{{if eq .Destination \"${WORKSPACE_MOUNT}/.worktrees\"}}{{.Name}}{{end}}{{end}}" "$CONTAINER_NAME" 2>/dev/null || true)"
	NM_MOUNT_NAME="$(docker inspect --format "{{range .Mounts}}{{if eq .Destination \"${WORKSPACE_MOUNT}/node_modules\"}}{{.Name}}{{end}}{{end}}" "$CONTAINER_NAME" 2>/dev/null || true)"
	if [ "$WT_MOUNT_NAME" != "$EXPECTED_WT_MOUNT" ] || [ "$NM_MOUNT_NAME" != "$EXPECTED_NM_MOUNT" ]; then
		RECREATE_STALE_MOUNTS=0
		if [ "$MOUNT_WORKSPACE_VOLUMES" = true ]; then
			if [ "$CONTAINER_RUNNING" = true ]; then
				echo "Note: container ${CONTAINER_NAME} uses outdated workspace volumes (node_modules/.worktrees not keyed per-agent, or missing); it may share a writable node_modules/pnpm store with another agent and worktree installs won't hardlink. Stop it and relaunch (or use --volatile) to migrate to the per-agent volumes." >&2
			else
				echo "Container ${CONTAINER_NAME} uses outdated workspace volumes (not keyed per-agent); recreating it so node_modules/.worktrees use agent-{nm,wt}-${CONTAINER_NAME} and worktree installs hardlink from the co-located pnpm store."
				RECREATE_STALE_MOUNTS=1
			fi
		elif [ "$MOUNT_WORKTREES_VOLUME" = true ]; then
			if [ "$CONTAINER_RUNNING" = true ]; then
				echo "Note: container ${CONTAINER_NAME} does not match this ${WORKTREES_ONLY_REPO_DESCRIPTION}'s expected mounts (only .worktrees = agent-wt-${CONTAINER_NAME}, no node_modules volume); Go/NuGet caches and worktrees won't persist correctly or an empty node_modules/ keeps appearing in the host folder. Stop it and relaunch (or use --volatile) to fix the mounts." >&2
			else
				echo "Container ${CONTAINER_NAME} does not match this ${WORKTREES_ONLY_REPO_DESCRIPTION}'s expected mounts; recreating it with only the .worktrees volume (agent-wt-${CONTAINER_NAME} — persistent Go/NuGet caches + worktrees) and no node_modules mount."
				RECREATE_STALE_MOUNTS=1
			fi
		else
			if [ "$CONTAINER_RUNNING" = true ]; then
				echo "Note: container ${CONTAINER_NAME} still mounts node_modules/.worktrees, but this folder isn't a dev project — those mounts keep re-creating empty node_modules/.worktrees dirs in the host folder. Stop it and relaunch (or use --volatile) to drop the mounts and leave no host litter." >&2
			else
				echo "Container ${CONTAINER_NAME} mounts node_modules/.worktrees but this folder isn't a dev project; recreating it without those mounts so it leaves no host litter."
				RECREATE_STALE_MOUNTS=1
			fi
		fi
		if [ "$RECREATE_STALE_MOUNTS" = 1 ]; then
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	fi
fi

# NUGET_PACKAGES is frozen in Config.Env when a container is created. A container
# from before persistent NuGet caching can already have the correct .worktrees
# mount (JS/Go dir-mounted projects), while self-hosted mode has no separate mount
# to compare at all; either shape would otherwise exit through reuse above the new
# EXTRA_ENV assembly and keep restoring into ephemeral ~/.nuget/packages forever.
# Compare the exact expected path for every worktrees-backed launch. Follow the
# mount-mismatch lifecycle: warn without disrupting a running process, and
# recreate a stopped mismatch so the new environment takes effect.
if { [ "$ISOLATED" = true ] || [ "$MOUNT_WORKTREES_VOLUME" = true ]; } &&
	[ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	EXISTING_CONTAINER_ENV="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
	EXISTING_NUGET_PACKAGES=""
	while IFS= read -r env_entry; do
		case "$env_entry" in
		NUGET_PACKAGES=*)
			EXISTING_NUGET_PACKAGES="${env_entry#NUGET_PACKAGES=}"
			break
			;;
		esac
	done <<<"$EXISTING_CONTAINER_ENV"
	if [ "$EXISTING_NUGET_PACKAGES" != "$WT_NUGET_PACKAGES_DIR" ]; then
		EXISTING_NUGET_DISPLAY="${EXISTING_NUGET_PACKAGES:-<unset>}"
		if [ "$CONTAINER_RUNNING" = true ]; then
			echo "Note: container ${CONTAINER_NAME} was created with NUGET_PACKAGES='${EXISTING_NUGET_DISPLAY}', but this launch expects '${WT_NUGET_PACKAGES_DIR}'. Container environment is fixed at creation; stop it and relaunch (or use --volatile) to enable persistent NuGet packages." >&2
		else
			echo "Container ${CONTAINER_NAME} was created with NUGET_PACKAGES='${EXISTING_NUGET_DISPLAY}'; recreating it with '${WT_NUGET_PACKAGES_DIR}' so NuGet packages persist."
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	fi
	unset EXISTING_CONTAINER_ENV EXISTING_NUGET_PACKAGES EXISTING_NUGET_DISPLAY env_entry
fi

# Detect whether the existing container predates the per-container Podman storage
# volume. Such a container was created before rootless-Podman support, so its
# /home/node/.local/share/containers is ephemeral (no agent-podman-* mount) and
# it was launched without /dev/fuse — pulled images and podman volumes would not
# persist, even after the image is rebuilt. Recreate a stopped container that
# lacks the mount so the new volume + device attach; warn (don't disrupt) if it
# is currently running.
if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	HAS_PODMAN_MOUNT="$(docker inspect --format "{{range .Mounts}}{{if eq .Destination \"/home/node/.local/share/containers\"}}yes{{end}}{{end}}" "$CONTAINER_NAME" 2>/dev/null || true)"
	if [ -z "$HAS_PODMAN_MOUNT" ]; then
		if [ "$CONTAINER_RUNNING" = true ]; then
			echo "Note: container ${CONTAINER_NAME} predates the per-container Podman storage volume; nested-container images and volumes won't persist and the podman devices (/dev/fuse, /dev/net/tun) aren't attached. Stop it and relaunch (or use --volatile) to enable persistent rootless Podman storage." >&2
		else
			echo "Container ${CONTAINER_NAME} predates the per-container Podman storage volume; recreating it so rootless Podman images and volumes persist."
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	fi
fi

# Detect whether the existing container was created with a different rootless-Podman
# device set than this launch resolves (POWBOX_PODMAN changed, or the host's /dev
# visibility changed under `auto`). The device list is frozen at creation, so a
# stopped container first created with POWBOX_PODMAN=off — or under `auto` on a host
# that couldn't see the devices — can't gain /dev/fuse or /dev/net/tun on `docker
# start`: nested Podman would stay on vfs with no default networking. Recreate a
# stopped mismatch so the new device set attaches; warn (don't disrupt) a running
# one. A container with no recorded label predates this check — leave it alone, since
# we can't know what it was created with and the storage-mount check above already
# recreates truly pre-Podman containers.
if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	EXISTING_PODMAN_DEVICES="$(docker inspect --format '{{with .Config.Labels}}{{with index . "powbox.podman-devices"}}{{.}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
	if [ -n "$EXISTING_PODMAN_DEVICES" ] && [ "$EXISTING_PODMAN_DEVICES" != "$PODMAN_DEVICE_MODE" ]; then
		if [ "$CONTAINER_RUNNING" = true ]; then
			echo "Note: container ${CONTAINER_NAME} is running with Podman devices '${EXISTING_PODMAN_DEVICES}'; this launch resolves to '${PODMAN_DEVICE_MODE}'. The device set is fixed at container creation — stop it and relaunch (or use --volatile) to apply the change." >&2
		else
			echo "Podman device set changed (was '${EXISTING_PODMAN_DEVICES}', now '${PODMAN_DEVICE_MODE}'); recreating container."
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	fi
fi

if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	if [ "$CONTAINER_RUNNING" = true ]; then
		if [ "$DETACH" = true ]; then
			echo "Container ${CONTAINER_NAME} is already running."
			exit 0
		fi
		exec docker attach "$CONTAINER_NAME"
	fi

	if [ "$DETACH" = true ]; then
		exec docker start "$CONTAINER_NAME"
	fi

	exec docker start -ai "$CONTAINER_NAME"
fi

# Self-hosted capability guard (Task 001a, Approach B). The clone-into-volume path
# for --isolated lives entirely in the BASE image layer (seed-workspace.sh plus
# entrypoint-core.sh's clone call), so an agent image whose base predates
# self-hosted mode would create the workspace volume but never clone into it —
# landing the agent in an EMPTY checkout with no loud failure. The base stamps a
# static powbox.base.selfhosted=1 label (inherited by the agent image); if the
# resolved image lacks it, fail fast here with an actionable message instead. Only
# reached on the create/recreate path (the resume/reuse branches above already
# exec'd out), i.e. exactly when a clone would run. Skipped when the image is
# absent — that is a missing-image problem the build/compose flow handles, not a
# stale base. A pre-label image (built before this label existed) also lacks it and
# is correctly rejected: it genuinely cannot self-host.
if [ "$ISOLATED" = true ] && docker image inspect powbox-agent:latest >/dev/null 2>&1; then
	selfhosted_cap="$(docker image inspect powbox-agent:latest \
		--format '{{ index .Config.Labels "powbox.base.selfhosted" }}' 2>/dev/null || true)"
	case "$selfhosted_cap" in
	"" | "<no value>")
		echo "Error: this agent image's base predates self-hosted mode, so --isolated would create the" >&2
		echo "workspace volume but start you in an EMPTY checkout (the clone step lives in the base layer)." >&2
		echo "Rebuild the base + agent, then relaunch:" >&2
		echo "  agent-full-rebuild    # or: build.sh all   (build.ps1 all on Windows)" >&2
		exit 1
		;;
	esac
	unset selfhosted_cap
fi

if [ "$SHELL_ONLY" = true ]; then
	CMD=(zsh)
	if [ "$CONTINUE" = true ]; then
		echo "Note: --continue has no effect with --shell; this launch opens a plain zsh." >&2
	fi
elif [ "$AGENT" = "codex" ] && [ -n "$EXEC_TASK" ]; then
	CMD=(codex exec "$EXEC_TASK")
	if [ "$CONTINUE" = true ]; then
		echo "Note: --continue has no effect with --exec; codex exec always starts a fresh non-interactive session." >&2
	fi
elif [ "$AGENT" = "claude" ]; then
	if [ "$CONTINUE" = true ]; then
		# Pre-flight check: only pass --continue if a session history exists for this
		# working directory. Claude stores sessions in ~/.claude/projects/<slug>/,
		# where <slug> is the cwd with every non-alphanumeric, non-dash character
		# replaced by '-' (verified empirically against '/', '.', '_', spaces, '+',
		# and uppercase; case is preserved and adjacent dashes are not collapsed).
		# Passing --continue when no session exists makes claude print "No
		# conversation found" and exit instead of falling back to a fresh session.
		# The check runs inside the container where claude-config is mounted.
		# The single quotes are deliberate: $PWD, $HOME, and $slug must expand in
		# the container's shell at runtime, not in this launcher.
		# shellcheck disable=SC2016
		CMD=(sh -c 'slug=$(printf %s "$PWD" | sed "s/[^a-zA-Z0-9-]/-/g"); if ls "$HOME/.claude/projects/$slug"/*.jsonl >/dev/null 2>&1; then exec claude --dangerously-skip-permissions --continue; else exec claude --dangerously-skip-permissions; fi')
	else
		CMD=(claude --dangerously-skip-permissions)
	fi
else
	if [ "$CONTINUE" = true ]; then
		# Codex resume --last already filters to the current cwd and falls through to
		# a fresh interactive session when nothing resumable exists there.
		CMD=(codex resume --last --dangerously-bypass-approvals-and-sandbox)
	else
		CMD=(codex --dangerously-bypass-approvals-and-sandbox)
	fi
fi

GIT_CONFIG_ARGS=()
if [ -f "$GIT_CONFIG_PATH" ]; then
	GIT_CONFIG_ARGS=(-v "${GIT_CONFIG_PATH}:/home/node/.gitconfig-host:ro")
fi

GH_CONFIG_ARGS=()
if [ -d "$GH_HOST_CONFIG_DIR" ]; then
	GH_CONFIG_ARGS=(-v "${GH_HOST_CONFIG_DIR}:/home/node/.config/gh-host:ro")
fi

CTX_LABEL_ARGS=()
if [ "$CTX_DESIRED_PRESENT" = true ]; then
	CTX_LABEL_ARGS=(--label "powbox.ctx-hash=${CTX_HASH}")
fi

# Pre-create and chown the per-instance volumes to node so the entrypoint (which
# runs as node) can write into them. Self-hosted mode has ONE workspace volume
# (it must be node-owned before the entrypoint clones into it) and no nm/wt
# shadows; dir-mounted mode has the separate node_modules + worktrees shadows.
if [ "$ISOLATED" = true ]; then
	# The per-instance workspace volume is declared external in compose.selfhosted.yml,
	# and compose validates external volumes (erroring if absent) BEFORE it would honour
	# the ad-hoc `-v "${WS_VOLUME}:/mnt/workspace"` below — so on a first launch the prep
	# run would die with "External volume does not exist" and never create the container
	# (making even the loud-clone-failure drop-to-zsh path unreachable). Pre-create the
	# volume here so the prep step can chown it to node and clone into it. The dir-mounted
	# nm/wt/podman volumes need no such step because nothing declares them external (the
	# ad-hoc `-v` auto-creates them). Idempotent via the inspect guard, like SHARED_VOLUMES.
	if ! docker volume inspect "$WS_VOLUME" >/dev/null 2>&1; then
		docker volume create "$WS_VOLUME" >/dev/null
	fi
	# Seed the workspace volume so the entrypoint (running as node) can clone into
	# it. Two things are required:
	#   - chown it to node, and
	#   - leave it NON-EMPTY (a single placeholder file) WHEN IT WOULD OTHERWISE BE
	#     EMPTY. Docker re-initialises an EMPTY named volume from the image on every
	#     mount; because the workspace mounts at the nested /workspace/<slug> (a path
	#     absent from the image), that re-init recreates the volume root as root:root
	#     on the real run, clobbering this chown and leaving node unable to write the
	#     clone. Docker leaves a NON-empty volume untouched, so the placeholder makes
	#     the chown stick. seed-workspace.sh empties the dir again just before cloning.
	#     Only write it when the volume is empty: a REUSED instance (recreated for a
	#     non-reclone reason — a ctx or Podman-device change, or the stopped
	#     container pruned while its agent-ws-* volume remains) already holds a .git
	#     checkout, which is non-empty (so the chown sticks without help) and which
	#     seed-workspace.sh's reuse path does NOT clean — writing the placeholder there
	#     would leave a stray untracked .powbox-ws-init in the agent's working tree.
	# --reclone is a one-shot, launcher-driven wipe: empty the workspace volume here
	# (the container was recreated above) so the entrypoint re-clones into a clean
	# dir; the now-empty volume then gets the placeholder below. The volume itself is
	# kept. Nothing persists the wipe, so a later restart of a named instance never
	# re-wipes the agent's work.
	# The single quotes are deliberate: $(ls -A ...) must run in the prep
	# container's shell, not in this launcher.
	# shellcheck disable=SC2016
	WS_PREP_CMD='mkdir -p /mnt/workspace /mnt/containers /mnt/podman-imagestore && chown node:node /mnt/workspace /mnt/containers /mnt/podman-imagestore && { [ -n "$(ls -A /mnt/workspace 2>/dev/null)" ] || : > /mnt/workspace/.powbox-ws-init; }'
	if [ "$RECLONE" = true ]; then
		WS_PREP_CMD='find /mnt/workspace -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; '"$WS_PREP_CMD"
	fi
	docker compose "${COMPOSE_ARGS[@]}" run --rm --no-deps --user root --entrypoint /bin/sh \
		-v "${WS_VOLUME}:/mnt/workspace" \
		-v "${PODMAN_VOLUME}:/mnt/containers" \
		-v "agent-podman-imagestore:/mnt/podman-imagestore" \
		agent \
		-lc "$WS_PREP_CMD"
else
	# Always pre-create the per-container Podman store + the global image store; add
	# the node_modules/worktrees volumes only when this project uses them (see the
	# split MOUNT_WORKSPACE_VOLUMES / MOUNT_WORKTREES_VOLUME gates — a Go/.NET-only
	# repo gets just the worktrees volume) so a non-dev folder leaves no host litter.
	PREP_VOL_ARGS=(
		-v "${PODMAN_VOLUME}:/mnt/containers"
		-v "agent-podman-imagestore:/mnt/podman-imagestore"
	)
	PREP_PATHS="/mnt/containers /mnt/podman-imagestore"
	if [ "$MOUNT_WORKSPACE_VOLUMES" = true ]; then
		PREP_VOL_ARGS+=(-v "${NM_VOLUME}:/mnt/node_modules")
		PREP_PATHS="/mnt/node_modules $PREP_PATHS"
	fi
	if [ "$MOUNT_WORKTREES_VOLUME" = true ]; then
		PREP_VOL_ARGS+=(-v "${WT_VOLUME}:/mnt/worktrees")
		PREP_PATHS="/mnt/worktrees $PREP_PATHS"
	fi
	docker compose "${COMPOSE_ARGS[@]}" run --rm --no-deps --user root --entrypoint /bin/sh \
		"${PREP_VOL_ARGS[@]}" \
		agent \
		-lc "mkdir -p $PREP_PATHS && chown node:node $PREP_PATHS"
fi

RUN_ARGS=()
if [ "$DETACH" = true ]; then
	RUN_ARGS+=(-d)
elif [ "$VOLATILE" = true ] && [ "$PERSIST" != true ]; then
	RUN_ARGS+=(--rm)
fi

# Pass the host devices rootless Podman needs through to the agent, each in its
# own compose overlay (`docker compose run` has no --device flag, only `docker
# run` does, so a device must be declared in a compose file added to the -f chain):
#   compose.fuse.yml   -> /dev/fuse    (fuse-overlayfs overlay storage driver;
#                                       absence just falls back to the vfs driver)
#   compose.netdev.yml -> /dev/net/tun (slirp4netns/pasta nested networking;
#                                       absence breaks every default `podman run`)
# POWBOX_PODMAN gates both (POWBOX_FUSE is the deprecated alias):
#   on   -> force both. Use on Docker Desktop / WSL2, where the devices live in the
#          Docker VM and the launcher's host shell cannot see them to auto-detect.
#          If the Docker host cannot expose a forced device the run hard-fails —
#          intentional for callers who demand a working nested runtime.
#   off  -> neither (Podman still runs: vfs storage, networking only via
#          --network=host/none).
#   auto -> attach each device independently when the launcher's host shell can see
#          it (reliable where /dev is shared, e.g. native Linux / WSL; under-detects
#          on Docker Desktop — use `on` there). The two are detected separately so a
#          host exposing /dev/net/tun but not /dev/fuse still gets networking on vfs.
if [ -z "${POWBOX_PODMAN:-}" ] && [ -n "${POWBOX_FUSE:-}" ]; then
	echo "Note: POWBOX_FUSE is deprecated; use POWBOX_PODMAN (it now gates both /dev/fuse and /dev/net/tun)." >&2
fi
# Attach each compose overlay from the already-resolved PODMAN_DEVICE_MODE so the
# devices actually passed match the powbox.podman-devices label recorded below.
case ",${PODMAN_DEVICE_MODE}," in
*,fuse,*) COMPOSE_ARGS+=(-f "${ROOT_DIR}/compose.fuse.yml") ;;
esac
case ",${PODMAN_DEVICE_MODE}," in
*,tun,*) COMPOSE_ARGS+=(-f "${ROOT_DIR}/compose.netdev.yml") ;;
esac

# PRIMARY_AGENT selects which agent the unified image runs and seeds as primary.
# Both API keys flow through via compose.agent.yml so a delegated peer agent can
# authenticate too.
EXTRA_ENV=(-e "CONTAINER_NAME=$CONTAINER_NAME" -e "PRIMARY_AGENT=$AGENT")
# Point pnpm at the co-located store only when this project actually mounts the
# worktrees volume the store lives in (dir-mounted JS/powbox project) or in
# self-hosted mode (store is a subdir of the one workspace volume). Omitting it for a
# non-dev dir-mounted folder stops the entrypoint from mkdir-ing .worktrees/.pnpm-store
# onto the host bind mount — pnpm just keeps its image-default store there instead.
if [ "$ISOLATED" = true ] || [ "$MOUNT_WORKSPACE_VOLUMES" = true ]; then
	EXTRA_ENV+=(-e "PNPM_STORE_DIR=$WT_STORE_DIR")
fi
# Point the Go module + build caches, ccache, and NuGet global packages into the
# same persistent mount — keyed on the WIDER worktrees gate (or self-hosted mode,
# where .worktrees is a subdir of the one workspace volume), NOT the JS gate
# above: a Go/.NET-only repo mounts only the worktrees volume. Omitting them for a
# non-dev dir-mounted folder stops the entrypoint from mkdir-ing cache dirs onto
# the host bind mount — go/ccache/NuGet keep their image-default (container-
# ephemeral) cache paths there instead. Plain env is all these tools need (no
# `go env -w`, ccache, or NuGet config), matching the PNPM_STORE_DIR precedent; the
# entrypoint pre-creates the dirs (guarded, warn-don't-abort).
if [ "$ISOLATED" = true ] || [ "$MOUNT_WORKTREES_VOLUME" = true ]; then
	EXTRA_ENV+=(
		-e "GOMODCACHE=$WT_GOMODCACHE_DIR"
		-e "GOCACHE=$WT_GOCACHE_DIR"
		-e "CCACHE_DIR=$WT_CCACHE_DIR"
		-e "NUGET_PACKAGES=$WT_NUGET_PACKAGES_DIR"
	)
fi

# Dir-mounted mode only: tell the entrypoint the workspace's HOST bind-mount source
# (and the launching user's home) so the workspace-perms heal can REFUSE to chown a
# mount that is actually a system or home directory. A `cc`/`cx` accidentally run from
# ~ (e.g. /root on a VPS) would otherwise bind-mount the whole home tree and re-own it
# to node, breaking sshd's StrictModes chain on ~/.ssh and locking the user out of the
# host. POWBOX_WORKSPACE_DIR pairs the container mountpoint (/workspace/<slug>) with that
# source so the entrypoint records the per-mount marker map (/run/powbox/workspace-sources)
# both heal- and fix-workspace-perms.sh classify on — mountinfo is only their fallback.
# PROJECT_PATH is `pwd -P`-resolved above, so it is the real absolute path on every mount
# layout (a separate /home reads it back correctly as /home/<user>, not the shallow /<user>
# mountinfo would show). Self-hosted mode has no bind mount, so it is irrelevant there.
if [ "$ISOLATED" != true ]; then
	# Resolve $HOME to its PHYSICAL path (pwd -P) the same way PROJECT_PATH was above.
	# The entrypoint compares this home against the mountinfo-derived source, which is
	# always physical; if /home is itself a symlink (e.g. /home -> /mnt/home) the raw
	# $HOME=/home/alice would never equal the source's /mnt/home/alice, and the heal
	# could chown the whole home tree. Fall back to the raw value when it cannot be
	# resolved (unset, missing dir, no access) — no worse than forwarding it un-resolved.
	HOST_HOME="${HOME:-}"
	if [ -n "$HOST_HOME" ]; then
		HOST_HOME="$(cd "$HOST_HOME" 2>/dev/null && pwd -P)" || HOST_HOME="${HOME:-}"
	fi
	EXTRA_ENV+=(
		-e "POWBOX_WORKSPACE_HOST_PATH=$PROJECT_PATH"
		-e "POWBOX_WORKSPACE_HOST_HOME=$HOST_HOME"
		-e "POWBOX_WORKSPACE_DIR=$WORKSPACE_MOUNT"
	)
fi

# Self-hosted clone inputs. The entrypoint (after gh auth) clones POWBOX_CLONE_REPO
# at POWBOX_CLONE_REF into POWBOX_WORKSPACE_DIR, and skips the clone when a .git
# already exists (reuse — the agent owns its tree). These env vars are frozen at
# container creation; --reclone is NOT one of them on purpose — it is a one-shot
# launcher action (the prep step below empties the volume so the entrypoint clones
# fresh), so a reused container never re-wipes the agent's work on a later restart.
SELFHOSTED_LABEL=()
if [ "$ISOLATED" = true ]; then
	EXTRA_ENV+=(
		-e "POWBOX_SELF_HOSTED=1"
		-e "POWBOX_CLONE_REPO=$REPO_SPEC"
		-e "POWBOX_CLONE_REF=$CLONE_REF"
		-e "POWBOX_WORKSPACE_DIR=$WORKSPACE_MOUNT"
	)
	# Label self-hosted containers so tooling/lists can distinguish them from
	# dir-mounted ones (they already share the claude-/codex- name prefix). The
	# instance-name label stores the --name verbatim (as entered, pre-slugify) so
	# cc-list/agent-list can tell apart two names that slugify alike; repo + ref give
	# the list enough to reconstruct the exact resume command. ref records what was
	# REQUESTED at creation and is not re-applied on resume (see the --ref warning).
	SELFHOSTED_LABEL=(
		--label "powbox.self-hosted=true"
		--label "powbox.instance-name=${INSTANCE_NAME}"
		--label "powbox.repo=${REPO_SPEC}"
		--label "powbox.ref=${CLONE_REF}"
	)
fi

# In dir-mounted mode the root node_modules and .worktrees are separate per-container
# named volumes mounted over the bind mount — but only for a project that uses them
# (the split MOUNT_WORKSPACE_VOLUMES / MOUNT_WORKTREES_VOLUME gates: a JS/powbox
# project gets both, a Go/.NET-only repo gets just .worktrees); a non-dev folder gets
# neither, so Docker never creates empty node_modules/.worktrees mountpoints in the
# host folder. In self-hosted mode they are ordinary subdirs of the one workspace
# volume (mounted via compose.selfhosted.yml), so no extra -v args are added here.
WORKSPACE_VOL_ARGS=()
if [ "$ISOLATED" != true ] && [ "$MOUNT_WORKSPACE_VOLUMES" = true ]; then
	WORKSPACE_VOL_ARGS+=(-v "${NM_VOLUME}:${WORKSPACE_MOUNT}/node_modules")
fi
if [ "$ISOLATED" != true ] && [ "$MOUNT_WORKTREES_VOLUME" = true ]; then
	WORKSPACE_VOL_ARGS+=(-v "${WT_VOLUME}:${WORKSPACE_MOUNT}/.worktrees")
fi

CONTINUE_LABEL="false"
if [ "$CONTINUE" = true ]; then
	CONTINUE_LABEL="true"
fi

# Seed the GLOBAL shared image store from a dedicated, short-lived, DETACHED
# writer — the ONLY container that mounts agent-podman-imagestore read-write. The
# agent container below mounts the same volume read-only, so a runaway process in
# one project can't poison the cache every other project resolves images from.
# Detached so the launch never blocks on pulls; idempotent and quick once
# populated (seed-image-store.sh skips images already present, and its flock
# serializes concurrent writers). Only meaningful on the overlay path — an
# additionalimagestores entry must match the consumer's driver, and consumers
# only enable overlay when /dev/fuse is present — so gate it on the resolved fuse
# device. Best-effort: a writer that can't start must never abort the agent launch.
case ",${PODMAN_DEVICE_MODE}," in
*,fuse,*)
	# Go straight to entrypoint-core.sh (firewall + XDG + the writer-role Podman
	# setup) instead of the default entrypoint-agent.sh, so the writer skips the
	# per-agent skill/config seeding and stays lean — it only needs egress and a
	# Podman that can pull. AGENT_CONFIG_DIR is required by core but unused here, so
	# point it at a throwaway path; AGENT_SETUP_HOOK is cleared so no agent hook runs.
	docker compose "${COMPOSE_ARGS[@]}" run --rm -d --no-deps \
		--entrypoint /usr/local/bin/entrypoint-core.sh \
		-e POWBOX_IMAGE_STORE_ROLE=writer \
		-e AGENT_CONFIG_DIR=/tmp/powbox-imgstore-writer \
		-e AGENT_SETUP_HOOK= \
		-v "agent-podman-imagestore:/mnt/podman-imagestore" \
		agent \
		seed-image-store.sh seed >/dev/null 2>&1 || true
	;;
esac

CTX_COMPOSE_DIR=""
CTX_COMPOSE_FILE=""
cleanup_ctx_compose_file() {
	if [ -n "$CTX_COMPOSE_FILE" ]; then
		rm -f "$CTX_COMPOSE_FILE"
	fi
	if [ -n "$CTX_COMPOSE_DIR" ]; then
		rmdir "$CTX_COMPOSE_DIR" 2>/dev/null || true
	fi
}
trap cleanup_ctx_compose_file EXIT

FINAL_COMPOSE_ARGS=("${COMPOSE_ARGS[@]}")
if [ "${#CTX_MOUNT_NAMES[@]}" -gt 0 ]; then
	CTX_COMPOSE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/powbox-compose-ctx.XXXXXX")"
	CTX_COMPOSE_FILE="${CTX_COMPOSE_DIR}/overlay.yml"
	powbox_write_ctx_compose_overlay "$CTX_COMPOSE_FILE"
	FINAL_COMPOSE_ARGS+=(-f "$CTX_COMPOSE_FILE")
fi

docker compose "${FINAL_COMPOSE_ARGS[@]}" run "${RUN_ARGS[@]}" \
	--name "$CONTAINER_NAME" \
	--label "powbox.continue=${CONTINUE_LABEL}" \
	--label "powbox.podman-devices=${PODMAN_DEVICE_MODE}" \
	"${CTX_LABEL_ARGS[@]}" \
	"${SELFHOSTED_LABEL[@]}" \
	"${EXTRA_ENV[@]}" \
	"${GIT_CONFIG_ARGS[@]}" \
	"${GH_CONFIG_ARGS[@]}" \
	"${WORKSPACE_VOL_ARGS[@]}" \
	-v "${PODMAN_VOLUME}:/home/node/.local/share/containers" \
	-v "agent-podman-imagestore:/mnt/podman-imagestore:ro" \
	-w "${WORKSPACE_MOUNT}" \
	agent \
	"${CMD[@]}"
