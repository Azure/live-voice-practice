# Intentionally NOT using `Set-StrictMode -Version Latest` or
# `$ErrorActionPreference = 'Stop'`: this script makes many `az` calls that
# return non-zero exit codes (e.g. ResourceNotFound on first run, idempotent
# Conflict on re-run) which we handle explicitly via `$LASTEXITCODE`. Strict
# mode also breaks pragmatic patterns like `$env:OPTIONAL_VAR ?? 'default'`.
$ErrorActionPreference = 'Continue'

# Note: starting with bicep-ptn-aiml-landing-zone v1.1.4 the Azure AI Speech
# account, its private endpoint, DNS zone group, RBAC (CognitiveServicesUser
# on the Container App MI + executor + test VM) and the AppConfig keys
# AZURE_SPEECH_ENDPOINT / AZURE_SPEECH_REGION / AZURE_SPEECH_RESOURCE_NAME /
# AZURE_SPEECH_RESOURCE_ID are all created by the Bicep template (closes #35
# upstream). This hook only handles the bits that are *application-specific*
# and not part of the generic landing zone:
#   - AZURE_INPUT_TRANSCRIPTION_MODEL=azure-speech App Config flag
#   - ACR endpoint persistence + Container App MI registry binding
#   - Search index data-plane setup
#   - Cosmos sample seed
# All Azure AI Speech control-plane work has been removed from this script.

Write-Host "[>] Running post-provision hook..."

& azd env get-values | ForEach-Object {
  if ($_ -match '^([^=]+)=(.*)$') {
    $k = $matches[1]
    $v = $matches[2] -replace '^"|"$'
    Set-Item -Path Env:$k -Value $v
  }
}

$resourceGroup = $env:AZURE_RESOURCE_GROUP
$appConfigEndpoint = $env:APP_CONFIG_ENDPOINT
$appConfigLabel = if ($env:APP_CONFIG_LABEL) { $env:APP_CONFIG_LABEL } else { 'live-voice-practice' }
$appConfigFallbackLabel = 'ai-lz'
$networkIsolationValue = if ($env:NETWORK_ISOLATION) { $env:NETWORK_ISOLATION } else { $env:AZURE_NETWORK_ISOLATION }
$networkIsolationEnabled = $networkIsolationValue -match '^(true|True|1|yes|YES)$'

if (-not $resourceGroup) {
  Write-Host "[X] Missing AZURE_RESOURCE_GROUP."
  exit 1
}

# Derive resource token from a known endpoint env var so we can fall back to
# composing resource names when the executing identity lacks Reader on the RG
# (typical for the AILZ jumpbox MI, which only holds data-plane roles on
# specific resources).
$resourceToken = $env:RESOURCE_TOKEN
if (-not $resourceToken) {
  foreach ($candidate in @($env:APP_CONFIG_ENDPOINT, $env:AZURE_APP_CONFIG_ENDPOINT, $env:AZURE_KEY_VAULT_ENDPOINT, $env:AZURE_CONTAINER_REGISTRY_ENDPOINT)) {
    if ($candidate -and $candidate -match '(?:appcs|kv|cr|st|srch)-?([a-z0-9]{8,})') {
      $resourceToken = $matches[1]
      break
    }
  }
}

# Helper: read a key from App Configuration (the source of truth populated by
# Bicep at provision time). Returns $null on miss/error so callers can fall
# back to env vars or token-derived names.
function Get-AppConfigValue {
  param([string]$key)
  if (-not $appConfigEndpoint) { return $null }
  # Try the configured label first (fast path), then fall back to listing all
  # labels for the key. Bicep's `param appConfigLabel string = 'ai-lz'` is
  # the actual default, but downstream pipelines may override it. Querying
  # with `--label '*'` covers every case without us guessing.
  $val = az appconfig kv show --endpoint $appConfigEndpoint --key $key --label $appConfigLabel --auth-mode login --query value -o tsv 2>$null
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($val)) { return $val.Trim() }
  $listJson = az appconfig kv list --endpoint $appConfigEndpoint --key $key --label '*' --auth-mode login -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $listJson) { return $null }
  try {
    $items = $listJson | ConvertFrom-Json
    foreach ($item in @($items)) {
      if ($item -and -not [string]::IsNullOrWhiteSpace($item.value)) { return $item.value.Trim() }
    }
  } catch { }
  return $null
}

# Resolve resource names from App Configuration first (canonical source of
# truth: Bicep writes them with label '$appConfigLabel'), then env vars, then
# token derivation as a last resort. Export to env so downstream hooks
# (setup_search_dataplane, seed_cosmos_samples) inherit the same values.
if (-not $env:DATABASE_ACCOUNT_NAME)    { $env:DATABASE_ACCOUNT_NAME    = Get-AppConfigValue 'DATABASE_ACCOUNT_NAME' }
if (-not $env:DATABASE_NAME)            { $env:DATABASE_NAME            = Get-AppConfigValue 'DATABASE_NAME' }
if (-not $env:COSMOS_DB_ENDPOINT)       { $env:COSMOS_DB_ENDPOINT       = Get-AppConfigValue 'COSMOS_DB_ENDPOINT' }
if (-not $env:SEARCH_SERVICE_NAME)      { $env:SEARCH_SERVICE_NAME      = Get-AppConfigValue 'SEARCH_SERVICE_NAME' }
if (-not $env:STORAGE_ACCOUNT_NAME)     { $env:STORAGE_ACCOUNT_NAME     = Get-AppConfigValue 'STORAGE_ACCOUNT_NAME' }
if (-not $env:AI_FOUNDRY_ACCOUNT_NAME)  { $env:AI_FOUNDRY_ACCOUNT_NAME  = Get-AppConfigValue 'AI_FOUNDRY_ACCOUNT_NAME' }

# When NETWORK_ISOLATION=true, data-plane operations (Cosmos seed, Search index
# setup, App Configuration writes) require connectivity to private endpoints,
# i.e. running from inside the VNet (jumpbox/Bastion VM or via VPN).
# Mirror the GPT-RAG zero-trust UX: prompt the user interactively. If the
# session is non-interactive (e.g. azd hook in CI), skip data-plane steps.
if ($networkIsolationEnabled) {
  Write-Host ""
  Write-Host "[>] Zero Trust / Network Isolation enabled."
  Write-Host "   Data-plane steps (Cosmos seed, Search index setup, App Configuration writes)"
  Write-Host "   require connectivity to the VNet private endpoints."
  Write-Host "   Ensure you run scripts/postProvision.ps1 from within the VNet (jumpbox via"
  Write-Host "   Bastion or VPN). Otherwise these steps will be skipped."
  if ($env:RUN_FROM_JUMPBOX -match '^(true|True|1|yes|YES)$') {
    $runFromJumpboxEnabled = $true
    Write-Host "[OK] RUN_FROM_JUMPBOX=true detected; continuing with data-plane post-provisioning non-interactively."
  } elseif ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    $answer = Read-Host "[?] Are you running this script from inside the VNet or via VPN? [Y/n]"
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(y|Y|yes|YES|true|True|1)$') {
      $runFromJumpboxEnabled = $true
      Write-Host "[OK] Continuing with data-plane post-provisioning."
    } else {
      $runFromJumpboxEnabled = $false
      Write-Host "[-] Data-plane steps will be skipped. Re-run from the jumpbox to apply them."
    }
  } else {
    $runFromJumpboxEnabled = $false
    Write-Host "[-] Non-interactive shell detected; data-plane steps will be skipped."
    Write-Host "   Re-run interactively from the jumpbox/Bastion, OR set RUN_FROM_JUMPBOX=true to bypass the prompt."
  }
} else {
  $runFromJumpboxEnabled = $false
}

function Test-DataplaneShouldRun {
  if (-not $networkIsolationEnabled) { return $true }
  if ($runFromJumpboxEnabled) { return $true }
  return $false
}

Write-Host "[>] Ensuring ACR endpoint is persisted and Container App is bound to ACR via managed identity..."
$containerAppName = $env:AZURE_CONTAINER_APP_NAME
if (-not $containerAppName) {
  $containerAppName = az containerapp list -g $resourceGroup --query "[0].name" -o tsv 2>$null
}
$acrName = az acr list -g $resourceGroup --query "[0].name" -o tsv 2>$null
if ($acrName) {
  $acrLoginServer = az acr show -g $resourceGroup -n $acrName --query loginServer -o tsv 2>$null
  if ($acrLoginServer) {
    if (-not $env:AZURE_CONTAINER_REGISTRY_ENDPOINT -or $env:AZURE_CONTAINER_REGISTRY_ENDPOINT -ne $acrLoginServer) {
      azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT $acrLoginServer | Out-Null
      Write-Host "[OK] AZURE_CONTAINER_REGISTRY_ENDPOINT set to '$acrLoginServer'."
    }
    if ($containerAppName) {
      $useUaiFlag = ($env:USE_UAI -eq 'true')
      $registryIdentity = 'system'
      if ($useUaiFlag) {
        $uaiResourceId = az containerapp show -g $resourceGroup -n $containerAppName --query "identity.userAssignedIdentities | keys(@) | [0]" -o tsv 2>$null
        if ($uaiResourceId) { $registryIdentity = $uaiResourceId }
      }
      $currentRegistry = az containerapp show -g $resourceGroup -n $containerAppName --query "properties.configuration.registries[?server=='$acrLoginServer'] | [0].identity" -o tsv 2>$null
      if ($currentRegistry -ne $registryIdentity) {
        az containerapp registry set -g $resourceGroup -n $containerAppName --server $acrLoginServer --identity $registryIdentity 2>$null | Out-Null
        $idLabel = if ($useUaiFlag) { 'user-assigned identity' } else { 'system-assigned identity' }
        Write-Host "[OK] Container App '$containerAppName' bound to ACR '$acrLoginServer' via $idLabel."
      } else {
        Write-Host "[OK] Container App registry binding already in place."
      }
    }
  }
} else {
  Write-Host "[!] No ACR found in resource group; skipping registry wiring."
}

# Workaround for upstream bug Azure/bicep-ptn-aiml-landing-zone#38:
# the Container App template injects AZURE_CLIENT_ID="" (empty string) when
# the deployment uses a System-Assigned managed identity. An empty
# AZURE_CLIENT_ID confuses azure-identity's DefaultAzureCredential and the
# IMDS proxy returns HTTP 500 'invalid_scope', breaking App Configuration,
# Cosmos DB and AI Search access at runtime. Until the upstream module is
# updated, strip the conflicting env vars here so SystemAssigned MI works.
#
# When USE_UAI=true is set, AZURE_CLIENT_ID is intentionally populated with
# the User-Assigned Identity's clientId by the bicep template; the strip
# would break UAI auth, so it is short-circuited here.
$useUai = (Get-Content env:USE_UAI -ErrorAction SilentlyContinue) -as [string]
if ($useUai -and ($useUai.ToLower() -in @('true','1','yes'))) {
  Write-Host "[OK] USE_UAI=$useUai detected; preserving AZURE_CLIENT_ID/AZURE_TENANT_ID (UAI mode)."
} elseif ($containerAppName) {
  $idType = az containerapp show -g $resourceGroup -n $containerAppName --query "identity.type" -o tsv 2>$null
  if ($idType -and $idType -match 'SystemAssigned' -and $idType -notmatch 'UserAssigned') {
    $envVarNames = az containerapp show -g $resourceGroup -n $containerAppName --query "properties.template.containers[0].env[].name" -o tsv 2>$null
    $toRemove = @()
    foreach ($n in @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID')) {
      if ($envVarNames -split "`r?`n" -contains $n) { $toRemove += $n }
    }
    if ($toRemove.Count -gt 0) {
      Write-Host "[>] Removing conflicting env vars from Container App (workaround for upstream issue #38): $($toRemove -join ', ')"
      az containerapp update -g $resourceGroup -n $containerAppName --remove-env-vars @toRemove -o none 2>$null
      if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Removed: $($toRemove -join ', '). New revision will start with clean MI auth."
      } else {
        Write-Host "[!] Failed to remove env vars (exit=$LASTEXITCODE); manual intervention may be required."
      }
    } else {
      Write-Host "[OK] No conflicting AZURE_CLIENT_ID/AZURE_TENANT_ID env vars present on Container App."
    }
  }
}

if ($appConfigEndpoint -and (Test-DataplaneShouldRun)) {
  Write-Host "[>] Writing app-specific settings to App Configuration..."

  # Helper: idempotent kv set with structured logging. Returns $true on success.
  function Set-AppConfigKv {
    param(
      [Parameter(Mandatory)] [string]$Key,
      [string]$Value,
      [string]$ContentType = 'text/plain'
    )
    if ($null -eq $Value) { $Value = '' }
    $kvArgs = @(
      'appconfig','kv','set',
      '--endpoint', $appConfigEndpoint,
      '--key', $Key,
      '--value', $Value,
      '--label', $appConfigLabel,
      '--content-type', $ContentType,
      '--auth-mode', 'login',
      '--yes'
    )
    $out = az @kvArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Host "[!] kv set failed for '$Key': $out"
      return $false
    }
    return $true
  }

  $appConfigWriteFailures = 0

  # Under network isolation, AILZ Bicep gates off `appConfigPopulate` and
  # `cosmosConfigKeyVaultPopulate` (they perform ARM-proxied data-plane writes
  # that fail from public networks). When running from inside the VNet,
  # populate the equivalent keys here. To keep the hook fast and avoid the
  # accumulated cold-start cost of dozens of `az ... list/show` calls behind
  # private endpoints, names and IDs are *derived* from `RESOURCE_TOKEN`
  # using the AILZ naming abbreviations (see infra/constants/abbreviations.json),
  # and all key writes are batched into a single `az appconfig kv import`.
  if ($networkIsolationEnabled) {
    Write-Host "[>] Populating App Configuration (AILZ populate modules skipped under NI)..."

    if (-not $resourceToken) {
      Write-Host "[!] RESOURCE_TOKEN not available; cannot derive resource names. Skipping batch populate."
      $appConfigWriteFailures++
    } else {
      $token = $resourceToken
      $subId = if ($env:AZURE_SUBSCRIPTION_ID) { $env:AZURE_SUBSCRIPTION_ID } else { az account show --query id -o tsv 2>$null }
      $rgPath = "/subscriptions/$subId/resourceGroups/$resourceGroup"

      # Derived names (AILZ patterns from infra/constants/abbreviations.json).
      $cosmosName       = "cosmos-$token"
      $cosmosDbName     = "cosmos-db$token"
      $searchName       = "srch-$token"
      $storageName      = "st$token"
      $foundryName      = "aif-$token"
      $kvName           = "kv-$token"
      $acrName          = "cr$token"
      $caEnvName        = "cae-$token"
      $appCfgName       = "appcs-$token"
      $appInsightsName  = "appi-$token"
      $logName          = "log-$token"

      # Derived endpoints / URIs.
      $cosmosEndpoint        = "https://$cosmosName.documents.azure.com:443/"
      $searchEndpoint        = "https://$searchName.search.windows.net"
      $kvUri                 = "https://$kvName.vault.azure.net/"
      $storageBlobEndpoint   = "https://$storageName.blob.core.windows.net/"
      $foundryEndpoint       = "https://$foundryName.cognitiveservices.azure.com/"
      $acrLoginServer        = "$acrName.azurecr.io"

      # Derived resource IDs.
      $cosmosId      = "$rgPath/providers/Microsoft.DocumentDB/databaseAccounts/$cosmosName"
      $searchId      = "$rgPath/providers/Microsoft.Search/searchServices/$searchName"
      $storageId     = "$rgPath/providers/Microsoft.Storage/storageAccounts/$storageName"
      $foundryId     = "$rgPath/providers/Microsoft.CognitiveServices/accounts/$foundryName"
      $kvId          = "$rgPath/providers/Microsoft.KeyVault/vaults/$kvName"
      $caEnvId       = "$rgPath/providers/Microsoft.App/managedEnvironments/$caEnvName"
      $appInsightsId = "$rgPath/providers/Microsoft.Insights/components/$appInsightsName"
      $logId         = "$rgPath/providers/Microsoft.OperationalInsights/workspaces/$logName"

      # App Insights connection string is the only value that can't be derived
      # purely from the token (contains a per-component GUID). Try azd env
      # first (free); fall back to a single ARM call.
      $appInsightsConnStr = $env:APPLICATIONINSIGHTS_CONNECTION_STRING
      if (-not $appInsightsConnStr) {
        Write-Host "[>] Fetching App Insights connection string (az resource show, no extension)..."
        # Use plain `az resource show` to avoid triggering an interactive
        # extension-install prompt for `application-insights` on first run.
        $appInsightsConnStr = az resource show --ids $appInsightsId --query 'properties.ConnectionString' -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $appInsightsConnStr) {
          Write-Host "[!] Could not fetch App Insights connection string; writing empty value."
          $appInsightsConnStr = ''
        }
      }

      # Build flat dict for `az appconfig kv import --format json`.
      # Mirrors the keys AILZ's gated `appConfigPopulate` would have written.
      $populate = [ordered]@{
        AZURE_INPUT_TRANSCRIPTION_MODEL       = 'azure-speech'
        AZURE_TENANT_ID                       = $env:AZURE_TENANT_ID
        SUBSCRIPTION_ID                       = $subId
        AZURE_RESOURCE_GROUP                  = $resourceGroup
        LOCATION                              = $env:AZURE_LOCATION
        ENVIRONMENT_NAME                      = $env:AZURE_ENV_NAME
        RESOURCE_TOKEN                        = $token
        NETWORK_ISOLATION                     = 'true'
        LOG_LEVEL                             = 'INFO'
        ENABLE_CONSOLE_LOGGING                = 'true'
        APPLICATIONINSIGHTS_CONNECTION_STRING = $appInsightsConnStr
        KEY_VAULT_RESOURCE_ID                 = $kvId
        STORAGE_ACCOUNT_RESOURCE_ID           = $storageId
        APP_INSIGHTS_RESOURCE_ID              = $appInsightsId
        LOG_ANALYTICS_RESOURCE_ID             = $logId
        CONTAINER_ENV_RESOURCE_ID             = $caEnvId
        AI_FOUNDRY_ACCOUNT_RESOURCE_ID        = $foundryId
        SEARCH_SERVICE_RESOURCE_ID            = $searchId
        COSMOS_DB_ACCOUNT_RESOURCE_ID         = $cosmosId
        AI_FOUNDRY_ACCOUNT_NAME               = $foundryName
        APP_CONFIG_NAME                       = $appCfgName
        APP_INSIGHTS_NAME                     = $appInsightsName
        CONTAINER_ENV_NAME                    = $caEnvName
        CONTAINER_REGISTRY_NAME               = $acrName
        CONTAINER_REGISTRY_LOGIN_SERVER       = $acrLoginServer
        DATABASE_ACCOUNT_NAME                 = $cosmosName
        DATABASE_NAME                         = $cosmosDbName
        SEARCH_SERVICE_NAME                   = $searchName
        STORAGE_ACCOUNT_NAME                  = $storageName
        KEY_VAULT_URI                         = $kvUri
        STORAGE_BLOB_ENDPOINT                 = $storageBlobEndpoint
        AI_FOUNDRY_ACCOUNT_ENDPOINT           = $foundryEndpoint
        SEARCH_SERVICE_QUERY_ENDPOINT         = $searchEndpoint
        COSMOS_DB_ENDPOINT                    = $cosmosEndpoint
        AZURE_SPEECH_RESOURCE_ID              = $env:AZURE_SPEECH_RESOURCE_ID
        AZURE_SPEECH_RESOURCE_NAME            = $env:AZURE_SPEECH_RESOURCE_NAME
        AZURE_SPEECH_REGION                   = $env:AZURE_SPEECH_REGION
        AZURE_SPEECH_ENDPOINT                 = $env:AZURE_SPEECH_ENDPOINT
      }

      # Coerce nulls to empty strings so the JSON file always serialises cleanly.
      $populateClean = [ordered]@{}
      foreach ($k in $populate.Keys) {
        $v = $populate[$k]
        $populateClean[$k] = if ($null -eq $v) { '' } else { "$v" }
      }

      $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) "appconfig-populate-$([Guid]::NewGuid().ToString('N')).json"
      try {
        $populateClean | ConvertTo-Json | Out-File -FilePath $tmpFile -Encoding utf8 -NoNewline
        Write-Host "[>] Importing $($populateClean.Count) keys via batch..."
        $importOut = az appconfig kv import `
          --endpoint $appConfigEndpoint `
          --source file `
          --format json `
          --path $tmpFile `
          --label $appConfigLabel `
          --content-type 'text/plain' `
          --auth-mode login `
          --yes 2>&1
        if ($LASTEXITCODE -ne 0) {
          Write-Host "[!] kv import failed: $importOut"
          $appConfigWriteFailures++
        } else {
          Write-Host "[OK] App Configuration populate complete ($($populateClean.Count) keys via batch import)."
        }
      } finally {
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
      }
    }
  } else {
    # Non-NI path: only the app-specific transcription flag is needed
    # (AILZ's Bicep populate module wrote everything else).
    if (-not (Set-AppConfigKv -Key 'AZURE_INPUT_TRANSCRIPTION_MODEL' -Value 'azure-speech')) {
      $appConfigWriteFailures++
    }
  }

  if ($appConfigWriteFailures -gt 0) {
    if ($networkIsolationEnabled) {
      Write-Host "[!] $appConfigWriteFailures App Configuration writes failed. If you are not running from inside the VNet, re-run this script from the jumpbox."
    } else {
      Write-Host "[!] $appConfigWriteFailures App Configuration writes failed."
    }
  }
} elseif ($appConfigEndpoint) {
  Write-Host "[-] Skipping App Configuration writes (network isolation; not running from VNet)."
} else {
  Write-Host "[!] APP_CONFIG_ENDPOINT not set. Skipping App Configuration updates."
}

if (-not ($env:ENABLE_SEARCH_DATAPLANE_SETUP -match '^(false|False|0|no|NO)$')) {
  if (Test-DataplaneShouldRun) {
    Write-Host "[>] Running Search data-plane setup hook..."
    & "$PSScriptRoot\setup_search_dataplane.ps1"
  } else {
    Write-Host "[-] Skipping Search data-plane setup (network isolation; not running from VNet)."
    Write-Host "   Re-run scripts/postProvision.ps1 from the jumpbox/Bastion to apply it."
  }
} else {
  Write-Host "[-] ENABLE_SEARCH_DATAPLANE_SETUP=false, skipping Search data-plane setup."
}

if (-not ($env:ENABLE_COSMOS_SAMPLE_SEED -match '^(false|False|0|no|NO)$')) {
  if (-not (Test-DataplaneShouldRun)) {
    Write-Host "[-] Skipping Cosmos sample seed (network isolation; not running from VNet)."
    Write-Host "   Re-run scripts/postProvision.ps1 from the jumpbox/Bastion to apply it."
  } else {
    Write-Host "[>] Running Cosmos sample seed hook (PowerShell + REST API)..."
    # Resolve names from App Configuration (source of truth populated by Bicep).
    # We deliberately do NOT call `az cosmosdb list` here because the jumpbox
    # SAMI in network-isolated deployments only has data-plane roles
    # (Cosmos DB Built-in Data Contributor) and lacks ARM Reader, so
    # `az resource list` / `az cosmosdb list` returns []. App Configuration
    # is the canonical source and is reachable via private endpoint.
    $databaseAccountName = $env:DATABASE_ACCOUNT_NAME
    $databaseName        = $env:DATABASE_NAME
    $cosmosEndpoint      = $env:COSMOS_DB_ENDPOINT
    if (-not $databaseAccountName) { $databaseAccountName = Get-AppConfigValue 'DATABASE_ACCOUNT_NAME' }
    if (-not $databaseName)        { $databaseName        = Get-AppConfigValue 'DATABASE_NAME' }
    if (-not $cosmosEndpoint)      { $cosmosEndpoint      = Get-AppConfigValue 'COSMOS_DB_ENDPOINT' }
    if (-not $cosmosEndpoint -and $databaseAccountName) {
      $cosmosEndpoint = "https://$databaseAccountName.documents.azure.com:443/"
    }
    $scenariosContainer = if ($env:SCENARIOS_DATABASE_CONTAINER) { $env:SCENARIOS_DATABASE_CONTAINER } else { Get-AppConfigValue 'SCENARIOS_DATABASE_CONTAINER' }
    $rubricsContainer   = if ($env:RUBRICS_DATABASE_CONTAINER)   { $env:RUBRICS_DATABASE_CONTAINER }   else { Get-AppConfigValue 'RUBRICS_DATABASE_CONTAINER' }
    if (-not $scenariosContainer) { $scenariosContainer = 'scenarios' }
    if (-not $rubricsContainer)   { $rubricsContainer   = 'rubrics' }

    if (-not $databaseName) {
      Write-Host "[!] DATABASE_NAME not found in App Configuration. Cannot seed Cosmos. (App Config endpoint: $appConfigEndpoint)"
    } elseif (-not $cosmosEndpoint) {
      Write-Host "[!] COSMOS_DB_ENDPOINT not found in App Configuration and DATABASE_ACCOUNT_NAME unavailable. Cannot seed Cosmos."
    } else {
      Write-Host "[>] Cosmos endpoint:  $cosmosEndpoint"
      Write-Host "[>] Database:         $databaseName"
      Write-Host "[>] Scenarios cont.:  $scenariosContainer"
      Write-Host "[>] Rubrics cont.:    $rubricsContainer"

      # Acquire AAD token for Cosmos data-plane.
      $tokenJson = az account get-access-token --resource https://cosmos.azure.com -o json 2>&1 | Out-String
      try {
        $tokenObj = $tokenJson | ConvertFrom-Json
        $aadToken = $tokenObj.accessToken
      } catch {
        $aadToken = $null
      }
      if (-not $aadToken) {
        Write-Host "[!] Failed to acquire AAD token for https://cosmos.azure.com. Skipping Cosmos seed."
        Write-Host "    az output: $tokenJson"
      } else {
        $cosmosBase = $cosmosEndpoint.TrimEnd('/')

        function Invoke-CosmosUpsertItem {
          param(
            [string]$Base,
            [string]$Db,
            [string]$Container,
            [string]$Token,
            [string]$PartitionKeyValue,
            [hashtable]$Item
          )
          $url = "$Base/dbs/$Db/colls/$Container/docs"
          # Partition key header MUST be a JSON array as a string.
          $pkHeader = '["' + $PartitionKeyValue + '"]'
          # Cosmos REST API requires the Authorization header value to be URL-encoded
          # (per https://learn.microsoft.com/rest/api/cosmos-db/access-control-on-cosmosdb-resources).
          # Without encoding, the server returns "The format of value 'type=aad&ver=1.0&sig=...' is invalid."
          $authValue = 'type%3Daad%26ver%3D1.0%26sig%3D' + $Token
          $headers = @{
            'Authorization'                   = $authValue
            'x-ms-version'                    = '2018-12-31'
            'x-ms-date'                       = ([DateTime]::UtcNow.ToString('R'))
            'x-ms-documentdb-is-upsert'       = 'true'
            'x-ms-documentdb-partitionkey'    = $pkHeader
            'Content-Type'                    = 'application/json'
            'Accept'                          = 'application/json'
          }
          $body = $Item | ConvertTo-Json -Depth 50 -Compress
          return Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -ErrorAction Stop
        }

        function Invoke-CosmosSeedFolder {
          param(
            [string]$Base,
            [string]$Db,
            [string]$Container,
            [string]$Token,
            [string]$Folder,
            [string]$IdSourceKey
          )
          $stats = [ordered]@{ attempted = 0; upserted = 0; failed = 0 }
          if (-not (Test-Path $Folder)) {
            Write-Host "[-] $Folder does not exist; skipping container '$Container'."
            return $stats
          }
          $files = Get-ChildItem -Path $Folder -Filter *.json -File -ErrorAction SilentlyContinue
          if (-not $files) {
            Write-Host "[-] No *.json files under $Folder; skipping container '$Container'."
            return $stats
          }
          foreach ($file in $files) {
            $stats.attempted++
            try {
              $raw = Get-Content -Path $file.FullName -Raw -Encoding UTF8
              $obj = $raw | ConvertFrom-Json
              if (-not $obj.$IdSourceKey) {
                throw "Missing required key '$IdSourceKey' in $($file.Name)"
              }
              $idValue = [string]$obj.$IdSourceKey
              # Convert PSCustomObject to hashtable so we can add 'id' without
              # mutating the original parsed structure.
              $itemHt = @{}
              foreach ($prop in $obj.PSObject.Properties) {
                $itemHt[$prop.Name] = $prop.Value
              }
              $itemHt['id'] = $idValue

              Invoke-CosmosUpsertItem -Base $Base -Db $Db -Container $Container -Token $Token -PartitionKeyValue $idValue -Item $itemHt | Out-Null
              $stats.upserted++
              Write-Host "[upserted] $Container : $idValue (from $($file.Name))"
            } catch {
              $stats.failed++
              Write-Host "[failed]   $Container : $($file.Name) -> $_"
            }
          }
          return $stats
        }

        $scenariosFolder = Join-Path (Get-Location) 'samples/scenarios'
        $rubricsFolder   = Join-Path (Get-Location) 'samples/rubrics'

        $scenarioStats = Invoke-CosmosSeedFolder -Base $cosmosBase -Db $databaseName -Container $scenariosContainer -Token $aadToken -Folder $scenariosFolder -IdSourceKey 'scenarioId'
        $rubricStats   = Invoke-CosmosSeedFolder -Base $cosmosBase -Db $databaseName -Container $rubricsContainer   -Token $aadToken -Folder $rubricsFolder   -IdSourceKey 'rubricId'

        Write-Host ""
        Write-Host "Scenarios summary: attempted=$($scenarioStats.attempted) upserted=$($scenarioStats.upserted) failed=$($scenarioStats.failed)"
        Write-Host "Rubrics   summary: attempted=$($rubricStats.attempted)   upserted=$($rubricStats.upserted)   failed=$($rubricStats.failed)"
        if (($scenarioStats.failed + $rubricStats.failed) -gt 0) {
          Write-Host "[!] Some Cosmos seed operations failed. See log above."
        }
      }
    }
  }
} else {
  Write-Host "[-] ENABLE_COSMOS_SAMPLE_SEED=false, skipping Cosmos sample seed."
}

if ($networkIsolationEnabled -and -not $runFromJumpboxEnabled) {
  Write-Host ""
  Write-Host "[i]  Network isolation is enabled. Three data-plane steps were skipped because they"
  Write-Host "   require VNet access (private endpoints):"
  Write-Host "     - App Configuration writes (AZURE_INPUT_TRANSCRIPTION_MODEL)"
  Write-Host "     - Cosmos sample seed (scenarios/rubrics)"
  Write-Host "     - Azure AI Search data-plane setup"
  Write-Host "   Connect to the jumpbox via Bastion, clone this repo, run 'azd auth login' and"
  Write-Host "   then run './scripts/postProvision.ps1' interactively to apply them."
}

Write-Host "[OK] post-provision hook completed."
