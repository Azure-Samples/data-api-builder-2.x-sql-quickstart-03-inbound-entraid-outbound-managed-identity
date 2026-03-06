# Configure Entra prerequisites for this quickstart
# Usage: .\entra-up.ps1

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "entra-setup.ps1"
if (-not (Test-Path $scriptPath)) {
    throw "entra-setup.ps1 not found at $scriptPath"
}

& $scriptPath
