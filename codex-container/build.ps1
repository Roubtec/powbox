param(
  [string]$Version = "latest",
  [switch]$NoCache,
  [switch]$Pull
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir

& (Join-Path $rootDir "build.ps1") `
  -Target "codex" `
  -CodexVersion $Version `
  -NoCache:$NoCache `
  -Pull:$Pull
