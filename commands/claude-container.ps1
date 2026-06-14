param(
  [string]$ProjectPath = ".",
  [switch]$Build,
  [switch]$Detach,
  [switch]$Shell,
  [switch]$Persist,
  [switch]$Resume,
  [switch]$Continue,
  [switch]$Volatile,
  [string]$Ctx = "",
  [switch]$Isolated,
  [string]$Repo = "",
  [string]$Name = "",
  [string]$Ref = "",
  # -Fresh: documented alias for -Reclone (parity with bash --reclone | --fresh).
  [Alias("Fresh")]
  [switch]$Reclone
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
  -Continue:$Continue `
  -Volatile:$Volatile `
  -Ctx $Ctx `
  -Isolated:$Isolated `
  -Repo $Repo `
  -Name $Name `
  -Ref $Ref `
  -Reclone:$Reclone
