param(
  [Parameter(Mandatory = $true)]
  [string]$Image,
  [Parameter(Mandatory = $true)]
  [string[]]$Commands
)

$ErrorActionPreference = "Stop"

if ($Commands.Count -eq 0) {
  throw "At least one smoke-test command is required."
}

Write-Host "Smoke testing image: $Image"
$script = (@("set -e") + $Commands) -join "`n"
docker run --rm --entrypoint /bin/sh $Image -lc $script

if ($LASTEXITCODE -ne 0) {
  throw "Smoke test failed. See container output above."
}

Write-Host "Smoke test passed: all expected CLI tools were found."
