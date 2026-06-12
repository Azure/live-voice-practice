<#
.SYNOPSIS
    imds-workaround-remove.ps1 - Removes the SP-based IMDS workaround
    set up by scripts/imds-workaround.ps1.

.DESCRIPTION
    Reverses the workaround when the underlying Container Apps IMDS bug
    has been resolved. Removes:
      - AZURE_CLIENT_ID / TENANT_ID / CLIENT_SECRET env vars from the
        Container App
      - The azure-client-secret entry from the Container App secrets
      - The Service Principal + its app registration
      - All role assignments granted to the SP
      - The local .azure/<env>/imds-workaround.json metadata file

    Run after Microsoft has confirmed the IMDS bug is fixed in your
    region/environment, and after re-deploying the app to confirm the
    SystemAssigned MI works again.

.PARAMETER KeepSp
    Skip deleting the Service Principal (only remove Container App
    bindings + role assignments). Useful if multiple environments
    share an SP.
#>

[CmdletBinding()]
param(
    [switch] $KeepSp
)

$ErrorActionPreference = 'Continue'

function Write-Green($msg)  { Write-Host $msg -ForegroundColor Green }
function Write-Blue($msg)   { Write-Host $msg -ForegroundColor Cyan }
function Write-Yellow($msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Red($msg)    { Write-Host $msg -ForegroundColor Red }

Write-Blue "[imds-workaround-remove] Reading azd env..."
$envValues = azd env get-values 2>$null
function Get-EnvVal {
    param([string]$Name)
    $line = $envValues | Select-String "^$Name=" | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line.ToString() -replace "^$Name=`"?([^`"]*)`"?.*", '$1')
}
$envName    = Get-EnvVal 'AZURE_ENV_NAME'
$rg         = Get-EnvVal 'AZURE_RESOURCE_GROUP'
$subId      = Get-EnvVal 'AZURE_SUBSCRIPTION_ID'
$appName    = Get-EnvVal 'VOICELAB_APP_NAME'
if (-not $appName) {
    $appName = az containerapp list -g $rg --query "[?contains(name, 'voicelab')].name | [0]" -o tsv 2>$null
}

$metaPath = Join-Path '.azure' $envName 'imds-workaround.json'
if (-not (Test-Path $metaPath)) {
    Write-Yellow "[imds-workaround-remove] No metadata file at $metaPath — nothing to remove."
    Write-Yellow "  (If the SP was created on a different machine, fetch it from there or"
    Write-Yellow "   pass the appId / principalId manually via az ad sp delete.)"
    exit 0
}

$meta = Get-Content $metaPath -Raw | ConvertFrom-Json
$appId = $meta.appId
$spPrincipalId = $meta.principalId
$appObjectId = $meta.appObjectId

Write-Green "  appId=$appId principalId=$spPrincipalId"

# --- Remove env vars + secret from Container App --------------------------
if ($appName) {
    Write-Blue "[imds-workaround-remove] Removing env vars from $appName..."
    az containerapp update -n $appName -g $rg `
        --remove-env-vars AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_CLIENT_SECRET `
        --output none 2>&1 | Out-Null

    Write-Blue "[imds-workaround-remove] Removing secret 'azure-client-secret' from Container App..."
    az containerapp secret remove -n $appName -g $rg --secret-names azure-client-secret --output none 2>&1 | Out-Null

    $rev = az containerapp revision list -n $appName -g $rg --query '[?properties.active].name | [0]' -o tsv 2>$null
    if ($rev) {
        az containerapp revision restart -n $appName -g $rg --revision $rev --output none 2>&1 | Out-Null
        Write-Green "  Revision restarted: $rev"
    }
} else {
    Write-Yellow "[imds-workaround-remove] Container App not found; skipping env-var cleanup"
}

# --- Remove role assignments scoped to SP ---------------------------------
Write-Blue "[imds-workaround-remove] Removing ARM role assignments for SP..."
$assignments = az role assignment list --assignee $spPrincipalId --all --query "[].id" -o tsv 2>$null
if ($assignments) {
    foreach ($id in ($assignments -split "`n")) {
        if ($id) {
            az role assignment delete --ids $id --output none 2>&1 | Out-Null
        }
    }
    Write-Green "  ARM role assignments removed"
}

# --- Cosmos data-plane role -----------------------------------------------
$cosmosName = az cosmosdb list -g $rg --query '[0].name' -o tsv 2>$null
if ($cosmosName) {
    $cosmosAssignmentId = az cosmosdb sql role assignment list --account-name $cosmosName --resource-group $rg --query "[?principalId=='$spPrincipalId'].id | [0]" -o tsv 2>$null
    if ($cosmosAssignmentId) {
        az cosmosdb sql role assignment delete --account-name $cosmosName --resource-group $rg --role-assignment-id $cosmosAssignmentId --yes --output none 2>&1 | Out-Null
        Write-Green "  Cosmos data role assignment removed"
    }
}

# --- Delete the application registration (cascades to SP) -----------------
if (-not $KeepSp -and $appObjectId) {
    Write-Blue "[imds-workaround-remove] Deleting app registration..."
    $tokenJson = az account get-access-token --resource-type ms-graph --output json 2>$null
    if ($tokenJson) {
        $graphToken = ($tokenJson | ConvertFrom-Json).accessToken
        try {
            Invoke-RestMethod -Method Delete -Uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" `
                -Headers @{ Authorization = "Bearer $graphToken" } | Out-Null
            Write-Green "  App registration deleted"
        } catch {
            Write-Yellow "  Failed to delete app registration: $_"
            Write-Yellow "  Manual: az ad app delete --id $appId"
        }
    }
}

# --- Remove metadata file --------------------------------------------------
Remove-Item $metaPath -Force -ErrorAction SilentlyContinue
Write-Green "[imds-workaround-remove] Done. Metadata file removed."
