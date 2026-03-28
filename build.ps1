param(
  [ValidateSet("base", "claude", "codex", "all")]
  [string]$Target = "all",
  [string]$ClaudeVersion = "latest",
  [string]$CodexVersion = "latest",
  [switch]$NoCache,
  [switch]$Pull
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

& (Join-Path $scriptDir "scripts/build-image.ps1") `
  -Target $Target `
  -ClaudeVersion $ClaudeVersion `
  -CodexVersion $CodexVersion `
  -NoCache:$NoCache `
  -Pull:$Pull
