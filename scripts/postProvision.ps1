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
  if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
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
    Write-Host "   Re-run interactively from the jumpbox/Bastion to apply them."
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
      $currentRegistry = az containerapp show -g $resourceGroup -n $containerAppName --query "properties.configuration.registries[?server=='$acrLoginServer'] | [0].identity" -o tsv 2>$null
      if ($currentRegistry -ne 'system') {
        az containerapp registry set -g $resourceGroup -n $containerAppName --server $acrLoginServer --identity system 2>$null | Out-Null
        Write-Host "[OK] Container App '$containerAppName' bound to ACR '$acrLoginServer' via system-assigned identity."
      } else {
        Write-Host "[OK] Container App registry binding already in place."
      }
    }
  }
} else {
  Write-Host "[!] No ACR found in resource group; skipping registry wiring."
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
    $args = @(
      'appconfig','kv','set',
      '--endpoint', $appConfigEndpoint,
      '--key', $Key,
      '--value', $Value,
      '--label', $appConfigLabel,
      '--content-type', $ContentType,
      '--auth-mode', 'login',
      '--yes'
    )
    $out = az @args 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Host "[!] kv set failed for '$Key': $out"
      return $false
    }
    return $true
  }

  $appConfigWriteFailures = 0

  # ── 1. App-specific flag (always written) ───────────────────────────────
  if (-not (Set-AppConfigKv -Key 'AZURE_INPUT_TRANSCRIPTION_MODEL' -Value 'azure-speech')) {
    $appConfigWriteFailures++
  }

  # ── 2. Under network isolation, the AILZ Bicep `appConfigPopulate` and
  #      `cosmosConfigKeyVaultPopulate` modules are gated off (they perform
  #      ARM-proxied data-plane writes that fail from public networks). When
  #      running from inside the VNet, populate the same keys here from the
  #      azd env (Bicep outputs) + control-plane discovery in the resource
  #      group. Idempotent: re-running just upserts.
  if ($networkIsolationEnabled) {
    Write-Host "[>] Populating App Configuration (AILZ populate modules skipped under NI)..."

    # 2a. Resolve resource names via control plane (azd outputs only expose
    #     APP_CONFIG_ENDPOINT, AZURE_SPEECH_*, ACR_TASK_AGENT_POOL, and the
    #     deployment flags; everything else must be discovered).
    $cosmosName    = $env:DATABASE_ACCOUNT_NAME
    if (-not $cosmosName) { $cosmosName = az cosmosdb list -g $resourceGroup --query "[0].name" -o tsv 2>$null }
    $cosmosEndpoint = $env:COSMOS_DB_ENDPOINT
    if (-not $cosmosEndpoint -and $cosmosName) {
      $cosmosEndpoint = az cosmosdb show -g $resourceGroup -n $cosmosName --query documentEndpoint -o tsv 2>$null
    }
    $cosmosId = if ($cosmosName) { az cosmosdb show -g $resourceGroup -n $cosmosName --query id -o tsv 2>$null } else { '' }
    $cosmosDbName = $env:DATABASE_NAME
    if (-not $cosmosDbName -and $cosmosName) {
      $cosmosDbName = az cosmosdb sql database list -g $resourceGroup --account-name $cosmosName --query "[0].name" -o tsv 2>$null
    }

    $searchName = $env:SEARCH_SERVICE_NAME
    if (-not $searchName) { $searchName = az search service list -g $resourceGroup --query "[0].name" -o tsv 2>$null }
    $searchEndpoint = if ($searchName) { "https://$searchName.search.windows.net" } else { '' }
    $searchId = if ($searchName) { az search service show -g $resourceGroup -n $searchName --query id -o tsv 2>$null } else { '' }

    $storageName = $env:STORAGE_ACCOUNT_NAME
    if (-not $storageName) {
      # Pick the first storage account whose name matches the AILZ pattern
      # `st<token>` (excludes AI Foundry's project storage `aifst...`).
      $storageName = az storage account list -g $resourceGroup --query "[?starts_with(name,'st') && !starts_with(name,'staifst')] | [0].name" -o tsv 2>$null
      if (-not $storageName) {
        $storageName = az storage account list -g $resourceGroup --query "[0].name" -o tsv 2>$null
      }
    }
    $storageId = if ($storageName) { az storage account show -g $resourceGroup -n $storageName --query id -o tsv 2>$null } else { '' }
    $storageBlobEndpoint = if ($storageName) { az storage account show -g $resourceGroup -n $storageName --query "primaryEndpoints.blob" -o tsv 2>$null } else { '' }

    $foundryName = $env:AI_FOUNDRY_ACCOUNT_NAME
    if (-not $foundryName) {
      $foundryName = az cognitiveservices account list -g $resourceGroup --query "[?kind=='AIServices'] | [0].name" -o tsv 2>$null
    }
    $foundryEndpoint = if ($foundryName) { az cognitiveservices account show -g $resourceGroup -n $foundryName --query "properties.endpoint" -o tsv 2>$null } else { '' }
    $foundryId = if ($foundryName) { az cognitiveservices account show -g $resourceGroup -n $foundryName --query id -o tsv 2>$null } else { '' }

    $kvName = az keyvault list -g $resourceGroup --query "[0].name" -o tsv 2>$null
    $kvUri = if ($kvName) { az keyvault show -g $resourceGroup -n $kvName --query "properties.vaultUri" -o tsv 2>$null } else { '' }
    $kvId = if ($kvName) { az keyvault show -g $resourceGroup -n $kvName --query id -o tsv 2>$null } else { '' }

    $acrName = az acr list -g $resourceGroup --query "[0].name" -o tsv 2>$null
    $acrLoginServer = if ($acrName) { az acr show -g $resourceGroup -n $acrName --query loginServer -o tsv 2>$null } else { '' }

    $caEnvName = az containerapp env list -g $resourceGroup --query "[0].name" -o tsv 2>$null
    $caEnvId = if ($caEnvName) { az containerapp env show -g $resourceGroup -n $caEnvName --query id -o tsv 2>$null } else { '' }

    $appCfgName = az appconfig list -g $resourceGroup --query "[0].name" -o tsv 2>$null

    $logAnalyticsName = az monitor log-analytics workspace list -g $resourceGroup --query "[0].name" -o tsv 2>$null
    $logAnalyticsId = if ($logAnalyticsName) { az monitor log-analytics workspace show -g $resourceGroup -n $logAnalyticsName --query id -o tsv 2>$null } else { '' }

    $appInsightsName = az monitor app-insights component show -g $resourceGroup --query "[0].name" -o tsv 2>$null
    if (-not $appInsightsName) {
      $appInsightsName = az resource list -g $resourceGroup --resource-type 'microsoft.insights/components' --query "[0].name" -o tsv 2>$null
    }
    $appInsightsId = if ($appInsightsName) { az resource show -g $resourceGroup -n $appInsightsName --resource-type 'microsoft.insights/components' --query id -o tsv 2>$null } else { '' }
    $appInsightsConnStr = if ($appInsightsName) { az monitor app-insights component show -g $resourceGroup -a $appInsightsName --query connectionString -o tsv 2>$null } else { '' }

    # 2b. Build the populate set. Keys mirror what AILZ's `appConfigPopulate`
    #     and `cosmosConfigKeyVaultPopulate` would have written. Empty strings
    #     are intentionally written when a resource doesn't exist (matches
    #     Bicep ternary behavior) so consumers see explicit empties.
    $populate = @(
      # General / Deployment
      @{ K = 'AZURE_TENANT_ID';                 V = ($env:AZURE_TENANT_ID); CT = 'text/plain' }
      @{ K = 'SUBSCRIPTION_ID';                 V = ($env:AZURE_SUBSCRIPTION_ID); CT = 'text/plain' }
      @{ K = 'AZURE_RESOURCE_GROUP';            V = $resourceGroup; CT = 'text/plain' }
      @{ K = 'LOCATION';                        V = ($env:AZURE_LOCATION); CT = 'text/plain' }
      @{ K = 'ENVIRONMENT_NAME';                V = ($env:AZURE_ENV_NAME); CT = 'text/plain' }
      @{ K = 'RESOURCE_TOKEN';                  V = $resourceToken; CT = 'text/plain' }
      @{ K = 'NETWORK_ISOLATION';               V = 'true'; CT = 'text/plain' }
      @{ K = 'LOG_LEVEL';                       V = 'INFO'; CT = 'text/plain' }
      @{ K = 'ENABLE_CONSOLE_LOGGING';          V = 'true'; CT = 'text/plain' }
      @{ K = 'APPLICATIONINSIGHTS_CONNECTION_STRING'; V = $appInsightsConnStr; CT = 'text/plain' }

      # Resource IDs
      @{ K = 'KEY_VAULT_RESOURCE_ID';           V = $kvId; CT = 'text/plain' }
      @{ K = 'STORAGE_ACCOUNT_RESOURCE_ID';     V = $storageId; CT = 'text/plain' }
      @{ K = 'APP_INSIGHTS_RESOURCE_ID';        V = $appInsightsId; CT = 'text/plain' }
      @{ K = 'LOG_ANALYTICS_RESOURCE_ID';       V = $logAnalyticsId; CT = 'text/plain' }
      @{ K = 'CONTAINER_ENV_RESOURCE_ID';       V = $caEnvId; CT = 'text/plain' }
      @{ K = 'AI_FOUNDRY_ACCOUNT_RESOURCE_ID';  V = $foundryId; CT = 'text/plain' }
      @{ K = 'SEARCH_SERVICE_RESOURCE_ID';      V = $searchId; CT = 'text/plain' }
      @{ K = 'COSMOS_DB_ACCOUNT_RESOURCE_ID';   V = $cosmosId; CT = 'text/plain' }

      # Resource Names
      @{ K = 'AI_FOUNDRY_ACCOUNT_NAME';         V = $foundryName; CT = 'text/plain' }
      @{ K = 'APP_CONFIG_NAME';                 V = $appCfgName; CT = 'text/plain' }
      @{ K = 'APP_INSIGHTS_NAME';               V = $appInsightsName; CT = 'text/plain' }
      @{ K = 'CONTAINER_ENV_NAME';              V = $caEnvName; CT = 'text/plain' }
      @{ K = 'CONTAINER_REGISTRY_NAME';         V = $acrName; CT = 'text/plain' }
      @{ K = 'CONTAINER_REGISTRY_LOGIN_SERVER'; V = $acrLoginServer; CT = 'text/plain' }
      @{ K = 'DATABASE_ACCOUNT_NAME';           V = $cosmosName; CT = 'text/plain' }
      @{ K = 'DATABASE_NAME';                   V = $cosmosDbName; CT = 'text/plain' }
      @{ K = 'SEARCH_SERVICE_NAME';             V = $searchName; CT = 'text/plain' }
      @{ K = 'STORAGE_ACCOUNT_NAME';            V = $storageName; CT = 'text/plain' }

      # Endpoints / URIs
      @{ K = 'KEY_VAULT_URI';                   V = $kvUri; CT = 'text/plain' }
      @{ K = 'STORAGE_BLOB_ENDPOINT';           V = $storageBlobEndpoint; CT = 'text/plain' }
      @{ K = 'AI_FOUNDRY_ACCOUNT_ENDPOINT';     V = $foundryEndpoint; CT = 'text/plain' }
      @{ K = 'SEARCH_SERVICE_QUERY_ENDPOINT';   V = $searchEndpoint; CT = 'text/plain' }
      @{ K = 'COSMOS_DB_ENDPOINT';              V = $cosmosEndpoint; CT = 'text/plain' }

      # Speech (Bicep populates these via outputs as well; mirror for the gated case)
      @{ K = 'AZURE_SPEECH_RESOURCE_ID';        V = ($env:AZURE_SPEECH_RESOURCE_ID); CT = 'text/plain' }
      @{ K = 'AZURE_SPEECH_RESOURCE_NAME';      V = ($env:AZURE_SPEECH_RESOURCE_NAME); CT = 'text/plain' }
      @{ K = 'AZURE_SPEECH_REGION';             V = ($env:AZURE_SPEECH_REGION); CT = 'text/plain' }
      @{ K = 'AZURE_SPEECH_ENDPOINT';           V = ($env:AZURE_SPEECH_ENDPOINT); CT = 'text/plain' }
    )

    foreach ($entry in $populate) {
      if (-not (Set-AppConfigKv -Key $entry.K -Value $entry.V -ContentType $entry.CT)) {
        $appConfigWriteFailures++
      }
    }
    Write-Host "[OK] App Configuration populate complete ($($populate.Count) keys; $appConfigWriteFailures failures)."
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
    Write-Host "[>] Running Cosmos sample seed hook..."
    # The jumpbox bootstrap installs Python 3.11 but `python` is not always on
    # PATH for non-interactive sessions; try the `py` launcher and `python3`
    # before giving up.
    $pythonExe = $null
    foreach ($candidate in @('python', 'py', 'python3')) {
      $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
      if ($cmd) { $pythonExe = $cmd.Source; break }
    }
    if (-not $pythonExe) {
      Write-Host "[!] Python executable not found (tried: python, py, python3). Skipping Cosmos sample seed."
    } else {
      Write-Host "[>] Using Python: $pythonExe"
      # Resource names were resolved at startup from App Configuration (the
      # source of truth populated by Bicep). Use them directly; only derive
      # endpoint as the very last fallback.
      $databaseAccountName = $env:DATABASE_ACCOUNT_NAME
      $databaseName        = $env:DATABASE_NAME
      $cosmosEndpoint      = $env:COSMOS_DB_ENDPOINT
      if (-not $cosmosEndpoint -and $databaseAccountName) {
        $cosmosEndpoint = "https://$databaseAccountName.documents.azure.com:443/"
      }

      if (-not $databaseAccountName) {
        Write-Host "[!] Cosmos account name could not be resolved from App Configuration. Skipping Cosmos sample seed."
      } elseif (-not $databaseName) {
        Write-Host "[!] Cosmos database name could not be resolved from App Configuration. Skipping Cosmos sample seed."
      } elseif (-not $cosmosEndpoint) {
        Write-Host "[!] Cosmos endpoint could not be resolved. Skipping Cosmos sample seed."
      } else {
        # Auth: DefaultAzureCredential. Bicep grants the executor / jumpbox MI
        # 'Cosmos DB Built-in Data Contributor' (data-plane) on the account.
        $env:COSMOS_ENDPOINT = $cosmosEndpoint
        $env:COSMOS_DATABASE_NAME = $databaseName
        $env:COSMOS_SCENARIOS_CONTAINER = if ($env:SCENARIOS_DATABASE_CONTAINER) { $env:SCENARIOS_DATABASE_CONTAINER } else { 'scenarios' }
        $env:COSMOS_RUBRICS_CONTAINER = if ($env:RUBRICS_DATABASE_CONTAINER) { $env:RUBRICS_DATABASE_CONTAINER } else { 'rubrics' }
        & $pythonExe scripts/seed_cosmos_samples.py --mode upsert
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
