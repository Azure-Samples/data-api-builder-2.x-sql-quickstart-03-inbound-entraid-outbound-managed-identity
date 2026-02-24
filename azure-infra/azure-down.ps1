# Tear down this quickstart's Azure resources
# Usage: .\azure-down.ps1 [-NoPurge]
# By default, resources are purged (soft-delete removed). Pass -NoPurge to keep them recoverable.

Param(
    [switch]$NoPurge
)

$ErrorActionPreference = "Stop"

Push-Location (Join-Path $PSScriptRoot "..")
try {
    az account show --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Logging in to Azure CLI..." -ForegroundColor Yellow
        az login
        if ($LASTEXITCODE -ne 0) { throw "az login failed" }
    }

    if ($NoPurge) {
        azd down --force
    }
    else {
        azd down --force --purge
    }
    if ($LASTEXITCODE -ne 0) { throw "azd down failed" }

    # Clean up Entra ID resources (app registration, config resets)
    $entraDown = Join-Path $PSScriptRoot "entra-down.ps1"
    if (Test-Path $entraDown) {
        Write-Host "Running Entra teardown..." -ForegroundColor Yellow
        & $entraDown
    }

    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $mcpConfigFile = Join-Path $repoRoot ".github/mcp.json"
    $mcpServerName = "azure-sql-mcp-qs3"

    if (Test-Path $mcpConfigFile) {
        $mcpConfigRaw = Get-Content $mcpConfigFile -Raw
        if (-not [string]::IsNullOrWhiteSpace($mcpConfigRaw)) {
            $mcpConfig = $mcpConfigRaw | ConvertFrom-Json -AsHashtable
            if ($mcpConfig.ContainsKey('servers') -and $mcpConfig['servers'].ContainsKey($mcpServerName)) {
                $null = $mcpConfig['servers'].Remove($mcpServerName)
                $mcpConfig | ConvertTo-Json -Depth 100 | Out-File -FilePath $mcpConfigFile -Encoding utf8 -Force
                Write-Host "Removed MCP server entry: $mcpServerName" -ForegroundColor Green
            }
        }
    }
}
finally {
    Pop-Location
}
