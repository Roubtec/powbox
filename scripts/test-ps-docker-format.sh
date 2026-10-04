#!/usr/bin/env bash
# Hermetic tests that the PowerShell scripts' `docker --format` templates
# survive Windows PowerShell 5.1.
#
# Windows PowerShell 5.1 (and pwsh 7.2 or older) wraps a native argument in
# double quotes without escaping the ones inside it, so the callee's command-
# line parser drops them: `{{ index .Config.Labels "powbox.x" }}` reaches docker
# as `{{ index .Config.Labels powbox.x }}`, which Go's text/template rejects. A
# template therefore names a label or a mount path as a Go raw string (`...`),
# never as a "..." one.
#
# The guard: no tracked *.ps1 line may hold a double quote, bare or backtick-
# escaped, inside a `{{ ... }}` template action, matched per line with the
# extended regex below. It is about the template text, not the --format
# argument, so it also catches a template assembled in a variable from quoted
# pieces, and it leaves alone `--format "{{.Names}}"` (PowerShell's own quotes,
# removed before the call) and the Bash-quoted `podman inspect --format "..."`
# lines inside scripts/smoke-test-podman.ps1's probe script. Its blind spots: a
# `"` assembled at run time (from a variable or [char]34), a template that spans
# lines, and an action holding a `}` before the offending quote (which ends the
# `[^}]*` run early, as in {{if eq .Y `}` "a"}}). None exists today.
#
# With pwsh available, every `docker ... --format <expr>` call in a tracked
# *.ps1 is also found through the PowerShell parser, its template expression
# (or the `$fmt` assignment it names) evaluated with sample values, and the
# result handed to a fake docker under both $PSNativeCommandArgumentPassing =
# 'Legacy' (the passing Windows PowerShell 5.1 uses) and 'Standard'. On Linux,
# Legacy passing builds one Windows-style command line that .NET splits back
# into argv by the Windows rules, so it reproduces the quote stripping; a
# control template with an embedded `"` must come out changed, or the check
# skips honestly instead of passing vacuously.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0
skip=0
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}

ko() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		printf '       %s\n' "${@:2}"
	fi
}

skipped() {
	skip=$((skip + 1))
	printf '  skip %s\n' "$1"
}

# A double quote after `{{` with no `}` in between. Extended syntax: in basic
# regex syntax `\{` starts an interval.
QUOTED_ACTION_RE='\{\{[^}]*"'

# quoted_actions <file>: the offending lines, as <line>:<text>.
quoted_actions() {
	grep -nE -- "$QUOTED_ACTION_RE" "$1" || true
}

# The tracked *.ps1 files, relative to ROOT_DIR, one per line.
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	PS_FILES="$(git -C "$ROOT_DIR" ls-files -- '*.ps1')"
else
	PS_FILES="$(cd "$ROOT_DIR" && find . \( -name .git -o -name .worktrees -o -name node_modules \) -prune -o -type f -name '*.ps1' -print | sed 's#^\./##' | sort)"
fi

echo "Test: the guard regex flags quoted template actions and nothing else"
# want|line
FIXTURES=(
	"flag|docker inspect --format '{{ index .Config.Labels \"powbox.x\" }}' \$c"
	"flag|\$fmt = '{{.Name}}' + \$sep + '{{index .Config.Labels \"powbox.repo\"}}'"
	"flag|docker image inspect \$i --format \"{{ index .Config.Labels \`\"\$Label\`\" }}\""
	"flag|docker inspect --format \"{{range .Mounts}}{{if eq .Destination \`\"/x\`\"}}yes{{end}}{{end}}\" \$c"
	"pass|docker ps -a --format \"{{.Names}}\""
	"pass|'hc=\$(podman inspect --format \"{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Test}}{{else}}null{{end}}\" \"\$cid\")'"
	"pass|docker image inspect \$i --format ('{{ index .Config.Labels \`' + \$Label + '\` }}')"
	"pass|docker inspect --format '{{with .Config.Labels}}{{with (index . \`powbox.x\`)}}{{.}}{{end}}{{end}}' \$c"
)
for f in "${FIXTURES[@]}"; do
	want="${f%%|*}"
	line="${f#*|}"
	printf '%s\r\n' "$line" >"$WORK_ROOT/fixture.ps1"
	if [ -n "$(quoted_actions "$WORK_ROOT/fixture.ps1")" ]; then got=flag; else got=pass; fi
	if [ "$got" = "$want" ]; then
		ok "$want: $line"
	else
		ko "expected $want, got $got: $line"
	fi
done

echo "Test: no tracked *.ps1 holds a double quote inside a {{ ... }} action"
if [ -z "$PS_FILES" ]; then
	ko "found no *.ps1 file to scan under $ROOT_DIR"
else
	offenders=""
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		hits="$(quoted_actions "$ROOT_DIR/$rel" | tr -d '\r')"
		[ -z "$hits" ] || offenders+="$(printf '%s\n' "$hits" | sed "s#^#$rel:#")"$'\n'
	done <<<"$PS_FILES"
	if [ -z "$offenders" ]; then
		ok "$(printf '%s\n' "$PS_FILES" | grep -c .) files scanned; use a Go raw string (\`...\`) for a label name or path"
	else
		ko "double quote inside a template action; Windows PowerShell 5.1 strips it, use a Go raw string (\`...\`)" "${offenders%$'\n'}"
	fi
fi

echo "Test: every docker --format template reaches docker unchanged under Legacy argument passing"
if ! command -v pwsh >/dev/null 2>&1; then
	skipped "pwsh unavailable - Legacy argument passing not checked"
else
	FAKE_DIR="$WORK_ROOT/fake"
	mkdir -p "$FAKE_DIR"
	cat >"$FAKE_DIR/docker" <<'SHIM'
#!/bin/sh
printf '%s\0' "$@" >"$FAKE_ARGV"
SHIM
	chmod +x "$FAKE_DIR/docker"
	printf '%s\n' "$PS_FILES" >"$WORK_ROOT/files.txt"
	cat >"$WORK_ROOT/legacy.ps1" <<'PS'
param([string]$Root, [string]$ListFile, [string]$ArgvFile)
$ErrorActionPreference = 'Stop'
$env:FAKE_ARGV = $ArgvFile
$L = [System.Management.Automation.Language.Ast]

# The argv the fake docker received for `docker inspect --format <value> probe`.
function Get-FakeArgv([string]$Mode, [string]$Value) {
  $PSNativeCommandArgumentPassing = $Mode
  if (Test-Path -LiteralPath $ArgvFile) { Remove-Item -LiteralPath $ArgvFile }
  docker inspect --format $Value probe
  $bytes = [System.IO.File]::ReadAllBytes($ArgvFile)
  return ,$bytes
}
function Test-SameBytes($a, $b) {
  return [Convert]::ToBase64String($a) -ceq [Convert]::ToBase64String($b)
}
# A template with its control characters made visible, for one report line.
function Show-Template([string]$Value) {
  return $Value.Replace([string][char]31, '<US>').Replace("`t", '<TAB>').Replace("`n", '<LF>')
}
function Get-FormatArg([string]$Mode, [string]$Value) {
  $parts = [System.Text.Encoding]::UTF8.GetString((Get-FakeArgv $Mode $Value)).Split([char]0)
  return $parts[2]
}

# Control: the 5.1 bug must reproduce here, or the identity checks prove nothing.
$control = '{{ index .Config.Labels "powbox.x" }}'
if ((Get-FormatArg 'Legacy' $control) -ceq $control) {
  "SKIP`tthis pwsh does not strip embedded quotes under Legacy passing, so it cannot stand in for Windows PowerShell 5.1"
  return
}
"OK`tcontrol: a template with an embedded double quote is changed under Legacy passing"

# The only expression shapes a template may take here: string literals, the
# variables bound below, `+` and parentheses. Anything else is reported, not run.
$allowed = @('StringConstantExpressionAst', 'ExpandableStringExpressionAst', 'VariableExpressionAst',
  'BinaryExpressionAst', 'ParenExpressionAst', 'PipelineAst', 'CommandExpressionAst')
$bindings = @{ Label = 'powbox.example-label'; workspaceMount = '/workspace/example-0123abcd'; sep = [string][char]31 }

$rawSiteFiles = @{}
foreach ($rel in (Get-Content -LiteralPath $ListFile | Where-Object { $_ })) {
  $path = Join-Path $Root $rel
  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { "FAIL`t${rel}: does not parse: $($errors[0].Message)"; continue }
  $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'docker' }, $true)
  foreach ($cmd in $cmds) {
    $els = $cmd.CommandElements
    for ($i = 1; $i -lt $els.Count - 1; $i++) {
      if (-not ($els[$i] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $els[$i].Value -eq '--format')) { continue }
      $site = "${rel}:$($cmd.Extent.StartLineNumber)"
      $expr = $els[$i + 1]
      if ($expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $name = $expr.VariablePath.UserPath
        $scope = $cmd.Parent
        while ($scope -and -not ($scope -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $scope = $scope.Parent }
        if (-not $scope) { $scope = $ast }
        $assign = @($scope.FindAll({ param($n)
              $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
              $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
              $n.Left.VariablePath.UserPath -eq $name -and
              $n.Extent.EndOffset -le $cmd.Extent.StartOffset }, $true)) | Select-Object -Last 1
        if (-not $assign) { "FAIL`t${site}: no assignment to `$$name before the call"; continue }
        $expr = $assign.Right
      }
      $bad = @($expr.FindAll({ param($n) $true }, $true) | Where-Object { $allowed -notcontains $_.GetType().Name })
      if ($bad.Count -gt 0) { "FAIL`t${site}: unsupported template expression ($($bad[0].GetType().Name)): $($expr.Extent.Text)"; continue }
      try {
        $value = & {
          Set-StrictMode -Version Latest
          foreach ($k in $bindings.Keys) { Set-Variable -Name $k -Value $bindings[$k] }
          . ([scriptblock]::Create($expr.Extent.Text))
        }
        $value = [string]$value
      }
      catch { "FAIL`t${site}: cannot evaluate $($expr.Extent.Text): $_"; continue }
      $legacy = Get-FakeArgv 'Legacy' $value
      $standard = Get-FakeArgv 'Standard' $value
      $arg = (Get-FormatArg 'Standard' $value)
      $shown = Show-Template $value
      if (-not (Test-SameBytes $legacy $standard)) {
        "FAIL`t${site}: Legacy argv differs from Standard for $shown`tlegacy:   $(Show-Template (Get-FormatArg 'Legacy' $value))"
      }
      elseif ($arg -cne $value) {
        "FAIL`t${site}: the fake docker received $(Show-Template $arg) for $shown"
      }
      else {
        "OK`t${site}: $shown"
        if ($value.Contains('`')) { $rawSiteFiles[$rel] = $true }
      }
    }
  }
}
"RAW`t$((@($rawSiteFiles.Keys) | Sort-Object) -join ' ')"
PS
	out="$(PATH="$FAKE_DIR:$PATH" pwsh -NoProfile -NonInteractive -File "$WORK_ROOT/legacy.ps1" \
		-Root "$ROOT_DIR" -ListFile "$WORK_ROOT/files.txt" -ArgvFile "$WORK_ROOT/argv" 2>&1 | tr -d '\r')" || true
	raw_files=""
	saw_any=false
	while IFS=$'\t' read -r kind msg detail; do
		case "$kind" in
		OK)
			saw_any=true
			ok "$msg"
			;;
		FAIL)
			saw_any=true
			if [ -n "$detail" ]; then ko "$msg" "$detail"; else ko "$msg"; fi
			;;
		SKIP)
			saw_any=true
			skipped "$msg"
			;;
		RAW) raw_files="$msg" ;;
		*) [ -z "$kind$msg" ] || ko "unexpected harness output: $kind $msg" ;;
		esac
	done <<<"$out"
	$saw_any || ko "the Legacy-passing harness reported nothing" "$out"
	# The parser walk must keep finding the raw-string templates the regex guard
	# protects, so it cannot go blind without failing.
	if printf '%s' "$out" | grep -q '^SKIP'; then
		:
	else
		for want in commands/check-updates.ps1 scripts/build-image-lib.ps1 scripts/launch-agent.ps1 scripts/smoke-test-lib.ps1 shell/powbox.ps1; do
			case " $raw_files " in
			*" $want "*) ok "$want: its raw-string templates were checked" ;;
			*) ko "$want: no raw-string --format template found by the parser walk" ;;
			esac
		done
	fi
fi

echo
echo "PowerShell docker --format template tests: ${pass} passed, ${fail} failed, ${skip} skipped"
[ "$fail" -eq 0 ]
