<#
.SYNOPSIS
    imds-workaround.ps1 - Opt-in Service Principal workaround for the
    Container Apps IMDS / managed-identity failure.

.DESCRIPTION
    See docs/troubleshooting-imds.md for context. Use this only when
    steps 1 and 2 (restart revision, re-provision) have not fixed the
    auth failure.

    Idempotent: reuses an existing SP (named sp-voicelab-imds-workaround
    by default) when present. Pass -RotateSecret to mint a new password.

    What it does:
      1. Pre-flight: confirm we have the Entra permission to create app
         registrations.
      2. Create (or reuse) an Entra app + service principal.
      3. Grant the SP the same data-plane RBAC the SystemAssigned MI
         needs (Cosmos data role, App Config data reader, AcrPull, etc).
      4. PATCH the Container App: add a secret with the SP password,
         and set AZURE_CLIENT_ID / TENANT_ID / CLIENT_SECRET env vars.
         DefaultAzureCredential will pick EnvironmentCredential before
         the broken IMDS sidecar.
      5. Persist SP metadata (NOT the secret) to .azure/<env>/imds-
         workaround.json so the cleanup script knows what to remove.

.PARAMETER RotateSecret
    Mint a new SP password instead of reusing the cached one. Use this
    when rotating credentials.

.PARAMETER SpName
    Override the default SP display name.
#>

[CmdletBinding()]
param(
    [switch] $RotateSecret,
    [string] $SpName = 'sp-voicelab-imds-workaround'
)

$ErrorActionPreference = 'Stop'

function Write-Green($msg)  { Write-Host $msg -ForegroundColor Green }
function Write-Blue($msg)   { Write-Host $msg -ForegroundColor Cyan }
function Write-Yellow($msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Red($msg)    { Write-Host $msg -ForegroundColor Red }

# --- Resolve azd env -------------------------------------------------------
Write-Blue "[imds-workaround] Reading azd env..."
$envValues = azd env get-values 2>$null
function Get-EnvVal {
    param([string]$Name)
    $line = $envValues | Select-String "^$Name=" | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line.ToString() -replace "^$Name=`"?([^`"]*)`"?.*", '$1')
}
$envName     = Get-EnvVal 'AZURE_ENV_NAME'
$rg          = Get-EnvVal 'AZURE_RESOURCE_GROUP'
$subId       = Get-EnvVal 'AZURE_SUBSCRIPTION_ID'
$tenantId    = Get-EnvVal 'AZURE_TENANT_ID'
$appName     = Get-EnvVal 'VOICELAB_APP_NAME'
$cosmosName  = Get-EnvVal 'COSMOS_ACCOUNT_NAME'
$appConfigEp = Get-EnvVal 'APP_CONFIG_ENDPOINT'

if (-not $tenantId) {
    $tenantId = az account show --query tenantId -o tsv 2>$null
    if ($tenantId) { Write-Yellow "  AZURE_TENANT_ID not in azd env; using az account tenant: $tenantId" }
}
if (-not $subId) {
    $subId = az account show --query id -o tsv 2>$null
}

if (-not $rg -or -not $subId -or -not $tenantId) {
    Write-Red "[imds-workaround] Missing AZURE_RESOURCE_GROUP / AZURE_SUBSCRIPTION_ID / AZURE_TENANT_ID."
    exit 1
}
if (-not $appName) {
    $appName = az containerapp list -g $rg --query "[?contains(name, 'voicelab')].name | [0]" -o tsv 2>$null
    if (-not $appName) { $appName = az containerapp list -g $rg --query '[0].name' -o tsv 2>$null }
}
if (-not $appName) { Write-Red "[imds-workaround] Could not resolve Container App name."; exit 1 }

Write-Green "  env=$envName rg=$rg app=$appName"

# --- Resolve metadata path -------------------------------------------------
$metaDir = Join-Path '.azure' $envName
if (-not (Test-Path $metaDir)) { New-Item -ItemType Directory -Path $metaDir -Force | Out-Null }
$metaPath = Join-Path $metaDir 'imds-workaround.json'

# --- Pre-flight: Entra permission ------------------------------------------
Write-Blue "[imds-workaround] Pre-flight: checking Entra permission to create app registrations..."
$preflightUri = 'https://graph.microsoft.com/v1.5/me/ownedObjects?$top=1'  # cheap me-call; if this fails we have bigger issues
$tokenJson = az account get-access-token --resource-type ms-graph --output json 2>$null
if (-not $tokenJson) {
    Write-Red "[imds-workaround] Could not get a Microsoft Graph token. Run 'az login' first."
    exit 1
}
$graphToken = ($tokenJson | ConvertFrom-Json).accessToken

# --- Look up existing SP ---------------------------------------------------
Write-Blue "[imds-workaround] Looking up existing SP '$SpName'..."
$listUri = "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$SpName'&`$select=id,appId,displayName"
$existingApp = $null
try {
    $resp = Invoke-RestMethod -Method Get -Uri $listUri -Headers @{ Authorization = "Bearer $graphToken" }
    if ($resp.value -and $resp.value.Count -gt 0) {
        $existingApp = $resp.value[0]
    }
} catch {
    Write-Red "[imds-workaround] Failed to query Graph for existing apps: $_"
    Write-Red "  Most likely cause: your Entra account lacks permission to read applications."
    Write-Red "  Required role: Application Developer (or higher). See docs/troubleshooting-imds.md."
    exit 1
}

$appObjectId = $null
$appId = $null
if ($existingApp) {
    $appObjectId = $existingApp.id
    $appId = $existingApp.appId
    Write-Yellow "  Reusing existing app: $($existingApp.displayName) (appId=$appId)"
} else {
    Write-Blue "  Creating new application '$SpName'..."
    $createBody = @{ displayName = $SpName; signInAudience = 'AzureADMyOrg' } | ConvertTo-Json
    try {
        $newApp = Invoke-RestMethod -Method Post -Uri 'https://graph.microsoft.com/v1.0/applications' `
            -Headers @{ Authorization = "Bearer $graphToken" } `
            -ContentType 'application/json' -Body $createBody
        $appObjectId = $newApp.id
        $appId = $newApp.appId
        Write-Green "  Created app: appId=$appId objectId=$appObjectId"
    } catch {
        Write-Red "[imds-workaround] Failed to create application registration."
        Write-Red "  Required Entra role: Application Developer (or higher)."
        Write-Red "  Error: $_"
        exit 1
    }
}

# --- Ensure service principal exists for the app ---------------------------
Write-Blue "[imds-workaround] Ensuring service principal exists..."
$spLookupUri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$appId'&`$select=id,appId"
$spResp = Invoke-RestMethod -Method Get -Uri $spLookupUri -Headers @{ Authorization = "Bearer $graphToken" }
if ($spResp.value -and $spResp.value.Count -gt 0) {
    $spPrincipalId = $spResp.value[0].id
    Write-Yellow "  Reusing existing SP: principalId=$spPrincipalId"
} else {
    $spBody = @{ appId = $appId } | ConvertTo-Json
    $newSp = Invoke-RestMethod -Method Post -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' `
        -Headers @{ Authorization = "Bearer $graphToken" } `
        -ContentType 'application/json' -Body $spBody
    $spPrincipalId = $newSp.id
    Write-Green "  Created SP: principalId=$spPrincipalId"
}

# --- Mint or reuse password ------------------------------------------------
$cachedSecret = $null
$cached = $null
if (Test-Path $metaPath) {
    try { $cached = Get-Content $metaPath -Raw | ConvertFrom-Json } catch { $cached = $null }
}
if ($cached -and $cached.appId -eq $appId -and $cached.secret -and -not $RotateSecret) {
    Write-Yellow "  Reusing cached secret from $metaPath"
    $cachedSecret = $cached.secret
}

if (-not $cachedSecret) {
    Write-Blue "[imds-workaround] Adding password credential..."
    $pwdBody = @{
        passwordCredential = @{
            displayName = 'azd-imds-workaround'
            endDateTime = (Get-Date).AddYears(1).ToString('o')
        }
    } | ConvertTo-Json -Depth 5
    $pwd = Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/applications/$appObjectId/addPassword" `
        -Headers @{ Authorization = "Bearer $graphToken" } `
        -ContentType 'application/json' -Body $pwdBody
    $cachedSecret = $pwd.secretText
    Write-Green "  Password minted (1 year expiry)"
}

# --- Persist metadata (not committed: .azure/ is gitignored) --------------
$metaObj = @{
    appId       = $appId
    appObjectId = $appObjectId
    principalId = $spPrincipalId
    tenantId    = $tenantId
    secret      = $cachedSecret
    createdAt   = (Get-Date).ToString('o')
    spName      = $SpName
}
$metaObj | ConvertTo-Json -Depth 5 | Set-Content -Path $metaPath -Encoding UTF8
Write-Green "  Persisted metadata to $metaPath"

# --- Wait for SP propagation (Azure AD eventual consistency) --------------
Write-Blue "[imds-workaround] Waiting 20s for SP to propagate to ARM..."
Start-Sleep -Seconds 20

# --- Role assignments ------------------------------------------------------
function Add-RoleIfMissing {
    param(
        [string]$Scope,
        [string]$RoleDefinitionName,
        [string]$RoleDefinitionId  # GUID for Built-in roles when name lookup is slow
    )
    Write-Blue "    -> $RoleDefinitionName on $Scope"
    $existing = az role assignment list --assignee $spPrincipalId --scope $Scope --role $RoleDefinitionName --query "[0].id" -o tsv 2>$null
    if ($existing) { Write-Yellow "       already assigned"; return }
    az role assignment create --assignee-object-id $spPrincipalId --assignee-principal-type ServicePrincipal `
        --role $RoleDefinitionName --scope $Scope --output none 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Green "       granted" } else { Write-Yellow "       failed (may already exist or scope unavailable)" }
}

$rgScope = "/subscriptions/$subId/resourceGroups/$rg"
Write-Blue "[imds-workaround] Granting ARM data-plane roles..."
Add-RoleIfMissing -Scope $rgScope -RoleDefinitionName 'App Configuration Data Reader'
Add-RoleIfMissing -Scope $rgScope -RoleDefinitionName 'AcrPull'
Add-RoleIfMissing -Scope $rgScope -RoleDefinitionName 'Key Vault Secrets User'
Add-RoleIfMissing -Scope $rgScope -RoleDefinitionName 'Cognitive Services User'
Add-RoleIfMissing -Scope $rgScope -RoleDefinitionName 'Cognitive Services OpenAI User'
Add-RoleIfMissing -Scope $rgScope -RoleDefinitionName 'Search Index Data Reader'
Add-RoleIfMissing -Scope $rgScope -RoleDefinitionName 'Search Index Data Contributor'
Add-RoleIfMissing -Scope $rgScope -RoleDefinitionName 'Storage Blob Data Reader'

# --- Cosmos DB SQL data-plane role (custom, not ARM RBAC) -----------------
if (-not $cosmosName) {
    $cosmosName = az cosmosdb list -g $rg --query '[0].name' -o tsv 2>$null
}
if ($cosmosName) {
    Write-Blue "[imds-workaround] Granting Cosmos DB Built-in Data Contributor on $cosmosName..."
    $cosmosScope = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.DocumentDB/databaseAccounts/$cosmosName"
    $existingCosmos = az cosmosdb sql role assignment list --account-name $cosmosName --resource-group $rg --query "[?principalId=='$spPrincipalId' && roleDefinitionId contains '00000000-0000-0000-0000-000000000002'].id | [0]" -o tsv 2>$null
    if ($existingCosmos) {
        Write-Yellow "  Cosmos data role already assigned"
    } else {
        az cosmosdb sql role assignment create `
            --account-name $cosmosName `
            --resource-group $rg `
            --scope $cosmosScope `
            --principal-id $spPrincipalId `
            --role-definition-id "$cosmosScope/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002" `
            --output none 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Green "  Cosmos data role granted" } else { Write-Yellow "  Cosmos data role grant failed (may already exist)" }
    }
} else {
    Write-Yellow "[imds-workaround] Cosmos account not found — skipping Cosmos data role"
}

# --- PATCH Container App with secret + env vars ---------------------------
Write-Blue "[imds-workaround] Patching Container App with EnvironmentCredential vars..."
$secretName = 'azure-client-secret'
az containerapp secret set --name $appName --resource-group $rg `
    --secrets "$secretName=$cachedSecret" --output none

az containerapp update --name $appName --resource-group $rg `
    --set-env-vars `
        "AZURE_CLIENT_ID=$appId" `
        "AZURE_TENANT_ID=$tenantId" `
        "AZURE_CLIENT_SECRET=secretref:$secretName" `
    --output none

Write-Green "  Env vars set on Container App"

# --- Restart revision so the env vars take effect -------------------------
Write-Blue "[imds-workaround] Restarting active revision..."
$rev = az containerapp revision list -n $appName -g $rg --query '[?properties.active].name | [0]' -o tsv 2>$null
if ($rev) {
    az containerapp revision restart -n $appName -g $rg --revision $rev --output none 2>&1 | Out-Null
    Write-Green "  Revision restarted: $rev"
}

Write-Host ""
Write-Green "[imds-workaround] Done. Validate with:"
Write-Host "  curl -fsS https://<fqdn>/api/health"
Write-Host ""
Write-Yellow "Metadata persisted to $metaPath (gitignored)."
Write-Yellow "To remove the workaround: ./scripts/imds-workaround-remove.ps1"
