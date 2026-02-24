# Post-up hook -- deploys content after Bicep creates all resources
# Runs automatically after `azd provision` or `azd up`

$ErrorActionPreference = "Stop"

# All variables come from Bicep outputs (set by azd as env vars)
$resourceGroup     = $env:AZURE_RESOURCE_GROUP
$sqlServerName     = $env:AZURE_SQL_SERVER_NAME
$sqlServerFqdn     = $env:AZURE_SQL_SERVER_FQDN
$sqlDb             = $env:AZURE_SQL_DATABASE
$sqlAdminUser      = $env:AZURE_SQL_ADMIN_USER
$sqlAdminPassword  = $env:AZURE_SQL_ADMIN_PASSWORD
$acrName           = $env:AZURE_ACR_NAME
$webAppName        = $env:AZURE_WEB_APP_NAME
$webUrl            = $env:AZURE_WEB_APP_URL
$webFqdn           = $env:AZURE_WEB_APP_FQDN
$dabAppName        = $env:AZURE_CONTAINER_APP_API_NAME
$dabPrincipalId    = $env:AZURE_CONTAINER_APP_API_PRINCIPAL_ID
$dabFqdn           = $env:AZURE_CONTAINER_APP_API_FQDN
$token             = $env:AZURE_RESOURCE_TOKEN
$clientId          = $env:AZURE_CLIENT_ID
$inspectorName     = $env:AZURE_MCP_INSPECTOR_NAME
$inspectorFqdn     = $env:AZURE_MCP_INSPECTOR_FQDN

$sqlConn = "Server=tcp:$sqlServerFqdn,1433;Database=$sqlDb;User Id=$sqlAdminUser;Password=$sqlAdminPassword;Encrypt=true;TrustServerCertificate=true"

# Ensure SqlServer module (Invoke-Sqlcmd) is available
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Host "Installing SqlServer module..." -ForegroundColor Yellow
    Install-Module SqlServer -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop | Out-Null
}
Import-Module SqlServer -DisableNameChecking -ErrorAction Stop

# ── 1. Open SQL firewall for local machine ──

Write-Host "Adding client IP to SQL firewall..." -ForegroundColor Yellow
$myIp = (Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing).Content
az sql server firewall-rule create `
    --resource-group $resourceGroup `
    --server $sqlServerName `
    --name "azd-deploy-client" `
    --start-ip-address $myIp `
    --end-ip-address $myIp 2>$null | Out-Null
Write-Host "Firewall rule added ($myIp)" -ForegroundColor Green

# ── 2. Deploy database schema (dacpac) ──

Write-Host "Building database project..." -ForegroundColor Yellow
dotnet build database/database.sqlproj -c Release
if ($LASTEXITCODE -ne 0) { throw "Database build failed" }
Write-Host "Database built" -ForegroundColor Green

Write-Host "Deploying schema with sqlpackage..." -ForegroundColor Yellow
sqlpackage /Action:Publish `
    /SourceFile:database/bin/Release/database.dacpac `
    /TargetConnectionString:"$sqlConn" `
    /p:BlockOnPossibleDataLoss=false
if ($LASTEXITCODE -ne 0) { throw "Schema deployment failed" }
Write-Host "Schema deployed" -ForegroundColor Green

# ── 3. Set Entra admin on SQL Server ──

Write-Host "Setting Entra admin on SQL Server..." -ForegroundColor Yellow
$currentUser = az ad signed-in-user show --query "{objectId: id, upn: userPrincipalName}" | ConvertFrom-Json
az sql server ad-admin create `
    --resource-group $resourceGroup `
    --server $sqlServerName `
    --display-name $currentUser.upn `
    --object-id $currentUser.objectId | Out-Null
Write-Host "Entra admin set: $($currentUser.upn)" -ForegroundColor Green

# ── 4. Grant DAB managed identity access to database ──

Write-Host "Creating database user for DAB managed identity..." -ForegroundColor Yellow
$accessToken = az account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv
$createUserSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$dabAppName')
BEGIN
    CREATE USER [$dabAppName] FROM EXTERNAL PROVIDER;
END;
ALTER ROLE db_datareader ADD MEMBER [$dabAppName];
ALTER ROLE db_datawriter ADD MEMBER [$dabAppName];
"@
Invoke-Sqlcmd -ServerInstance $sqlServerFqdn -Database $sqlDb -AccessToken $accessToken -Query $createUserSql
Write-Host "Database user created and granted read/write" -ForegroundColor Green

# ── 5. Update dab-config.json with real auth values + CORS ──

Write-Host "Updating DAB config with EntraId auth and CORS..." -ForegroundColor Yellow
$tenantId = $env:AZURE_TENANT_ID
Push-Location data-api
dab configure `
    --runtime.host.authentication.provider "EntraId" `
    --runtime.host.authentication.jwt.audience "$clientId" `
    --runtime.host.authentication.jwt.issuer "https://login.microsoftonline.com/$tenantId/v2.0" `
    --runtime.host.cors.origins "http://localhost:5173" "$webUrl"
Pop-Location
Write-Host "DAB config updated" -ForegroundColor Green

# ── 6. Build and push DAB image to ACR ──

Write-Host "Preparing DAB config for Azure deployment..." -ForegroundColor Yellow
$apiDeployDir = "api-deploy-temp"
Copy-Item -Path "data-api" -Destination $apiDeployDir -Recurse -Force

Write-Host "Building DAB image in ACR..." -ForegroundColor Yellow
az acr build --registry $acrName --image dab-api:latest --file "$apiDeployDir/Dockerfile" $apiDeployDir/ | Out-Null
Remove-Item $apiDeployDir -Recurse -Force
Write-Host "Image pushed" -ForegroundColor Green

# ── 7. Update DAB container app with custom image ──

Write-Host "Updating DAB container app..." -ForegroundColor Yellow
az containerapp update `
    --name $dabAppName `
    --resource-group $resourceGroup `
    --image "$acrName.azurecr.io/dab-api:latest" | Out-Null
Write-Host "DAB updated" -ForegroundColor Green

# ── 8. Generate config.js and deploy web files ──

Write-Host "Deploying web files..." -ForegroundColor Yellow
$apiUrlAzure = "https://$dabFqdn"

$configContent = @"
const CONFIG = {
    apiUrlLocal: 'http://localhost:5000',
    apiUrlAzure: '$apiUrlAzure'
};
"@

# Write config to temp deploy folder
$deployDir = "web-deploy-temp"
Copy-Item -Path "web-app" -Destination $deployDir -Recurse -Force
$configContent | Out-File -FilePath "$deployDir/config.js" -Encoding utf8 -Force

# Build and push web image
az acr build --registry $acrName --image web-app:latest --file "$deployDir/Dockerfile" $deployDir/ | Out-Null
Remove-Item $deployDir -Recurse -Force
Write-Host "Web image pushed" -ForegroundColor Green

# ── 9. Update web container app with custom image ──

Write-Host "Updating web container app..." -ForegroundColor Yellow
az containerapp update `
    --name $webAppName `
    --resource-group $resourceGroup `
    --image "$acrName.azurecr.io/web-app:latest" | Out-Null
Write-Host "Web updated" -ForegroundColor Green

# ── 10. Build and push MCP Inspector image to ACR ──

Write-Host "Building MCP Inspector image in ACR..." -ForegroundColor Yellow
az acr build --registry $acrName --image mcp-inspector:latest --file mcp-inspector/Dockerfile mcp-inspector/ | Out-Null
Write-Host "Inspector image pushed" -ForegroundColor Green

# ── 11. Update MCP Inspector container app with custom image ──

Write-Host "Updating MCP Inspector container app..." -ForegroundColor Yellow
az containerapp update `
    --name $inspectorName `
    --resource-group $resourceGroup `
    --image "$acrName.azurecr.io/mcp-inspector:latest" | Out-Null
Write-Host "Inspector updated" -ForegroundColor Green

# ── 12. Update local config.js for dev ──

$configContent | Out-File -FilePath "web-app/config.js" -Encoding utf8 -Force
Write-Host "Local config.js updated" -ForegroundColor Green

# ── 13. Upsert repo-level MCP server entry for quickstart3 ──

$repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$githubDir = Join-Path $repoRoot ".github"
$mcpConfigFile = Join-Path $githubDir "mcp.json"
$mcpServerName = "azure-sql-mcp-qs3"
$mcpServerUrl = "https://$dabFqdn/mcp"

if (-not (Test-Path $githubDir)) {
    New-Item -Path $githubDir -ItemType Directory -Force | Out-Null
}

if (Test-Path $mcpConfigFile) {
    $mcpConfigRaw = Get-Content $mcpConfigFile -Raw
    if ([string]::IsNullOrWhiteSpace($mcpConfigRaw)) {
        $mcpConfig = @{}
    } else {
        $mcpConfig = $mcpConfigRaw | ConvertFrom-Json -AsHashtable
    }
} else {
    $mcpConfig = @{}
}

if (-not $mcpConfig.ContainsKey('servers') -or $null -eq $mcpConfig['servers']) {
    $mcpConfig['servers'] = @{}
}

$mcpConfig['servers'][$mcpServerName] = @{
    url = $mcpServerUrl
    type = 'http'
}

$mcpConfig | ConvertTo-Json -Depth 100 | Out-File -FilePath $mcpConfigFile -Encoding utf8 -Force
Write-Host "MCP config updated: $mcpServerName -> $mcpServerUrl" -ForegroundColor Green

# ── Summary ──

# Append Azure URLs and connection string to .azure-env
$azureEnvFile = "$PWD/.azure-env"
if (Test-Path $azureEnvFile) {
    $envContent = Get-Content $azureEnvFile -Raw
    if ($envContent -notmatch 'web-app-url=') {
        @"
web-app-url=$webUrl
sql-commander-url=https://$($env:AZURE_CONTAINER_APP_SQLCMDR_FQDN)
data-api-url=https://$dabFqdn
mcp-inspector-url=https://$inspectorFqdn
sql-connection-string=$sqlConn
"@ | Out-File -FilePath $azureEnvFile -Encoding utf8 -Append
        Write-Host "Azure URLs added to .azure-env" -ForegroundColor Green
    }
}

Write-Host "`n=== Deployment Complete ===" -ForegroundColor Cyan
Write-Host "Web:           $webUrl" -ForegroundColor White
Write-Host "API:           $apiUrlAzure" -ForegroundColor White
Write-Host "SQL Commander: https://$($env:AZURE_CONTAINER_APP_SQLCMDR_FQDN)" -ForegroundColor White
Write-Host "MCP Inspector: https://$inspectorFqdn" -ForegroundColor White
