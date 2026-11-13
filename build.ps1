param(
  [ValidateSet("base", "layers", "agent", "all")]
  [string]$Target = "all",
  [string]$ClaudeVersion = "latest",
  [string]$CodexVersion = "latest",
  [string]$MuseVersion = "",
  [switch]$NoCache,
  [switch]$Pull
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

& (Join-Path $scriptDir "scripts/build-image.ps1") `
  -Target $Target `
  -ClaudeVersion $ClaudeVersion `
  -CodexVersion $CodexVersion `
  -MuseVersion $MuseVersion `
  -NoCache:$NoCache `
  -Pull:$Pull
