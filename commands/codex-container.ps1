param(
  [string]$ProjectPath = ".",
  [switch]$Build,
  [switch]$Detach,
  [switch]$Shell,
  [switch]$Persist,
  [switch]$Resume,
  [switch]$Volatile,
  [string]$Exec = "",
  [string]$Ctx = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir

& (Join-Path $rootDir "scripts/launch-agent.ps1") `
  -Agent "codex" `
  -ProjectPath $ProjectPath `
  -Build:$Build `
  -Detach:$Detach `
  -Shell:$Shell `
  -Persist:$Persist `
  -Resume:$Resume `
  -Volatile:$Volatile `
  -Exec $Exec `
  -Ctx $Ctx
