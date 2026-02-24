# Remove Entra prerequisites for this quickstart
# Usage: .\entra-down.ps1

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "entra-teardown.ps1"
if (-not (Test-Path $scriptPath)) {
    throw "entra-teardown.ps1 not found at $scriptPath"
}

& $scriptPath
