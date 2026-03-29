param(
  [string]$ProjectPath = ".",
  [switch]$Build,
  [switch]$Detach,
  [switch]$Shell,
  [switch]$Persist,
  [switch]$Resume,
  [switch]$Volatile
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir

& (Join-Path $rootDir "scripts/launch-agent.ps1") `
  -Agent "claude" `
  -ProjectPath $ProjectPath `
  -Build:$Build `
  -Detach:$Detach `
  -Shell:$Shell `
  -Persist:$Persist `
  -Resume:$Resume `
  -Volatile:$Volatile
