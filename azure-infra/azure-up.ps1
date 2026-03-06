# Provision and deploy this quickstart to Azure
# Usage: .\azure-up.ps1 [-SkipLogin]

Param(
    [switch]$SkipLogin
)

$ErrorActionPreference = "Stop"

Push-Location (Join-Path $PSScriptRoot "..")
try {
    if (-not $SkipLogin) {
        az account show --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Logging in to Azure CLI..." -ForegroundColor Yellow
            az login
            if ($LASTEXITCODE -ne 0) { throw "az login failed" }
        }

        azd auth login
        if ($LASTEXITCODE -ne 0) { throw "azd auth login failed" }
    }

    azd up
    if ($LASTEXITCODE -ne 0) { throw "azd up failed" }
}
finally {
    Pop-Location
}
