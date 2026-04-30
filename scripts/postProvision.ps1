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
  $appConfigFailed = $false
  $kvOut = az appconfig kv set --endpoint $appConfigEndpoint --key AZURE_INPUT_TRANSCRIPTION_MODEL --value azure-speech --label $appConfigLabel --auth-mode login --yes 2>&1
  if ($LASTEXITCODE -ne 0) { $appConfigFailed = $true }
  if ($appConfigFailed) {
    if ($networkIsolationEnabled) {
      Write-Host "[!] App Configuration data-plane not reachable from current network (NI mode). Run this step from the jumpbox inside the vnet. Continuing."
    } else {
      Write-Host "[!] App Configuration updates failed. Last output: $kvOut"
    }
  } else {
    Write-Host "[OK] App Configuration updated (AZURE_INPUT_TRANSCRIPTION_MODEL=azure-speech)."
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
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
      Write-Host "[!] Python executable not found. Skipping Cosmos sample seed."
    } else {
      # Resolve Cosmos account name. Prefer env vars (AILZ bootstrap pre-populates
      # them from App Configuration); fall back to ARM list (needs Reader on RG)
      # and finally to deriving the name from the resource token.
      $databaseAccountName = $env:DATABASE_ACCOUNT_NAME
      if (-not $databaseAccountName) {
        $databaseAccountName = az cosmosdb list -g $resourceGroup --query "[0].name" -o tsv 2>$null
      }
      if (-not $databaseAccountName -and $resourceToken) {
        $databaseAccountName = "cosmos-$resourceToken"
        Write-Host "[>] Derived Cosmos account name from token: $databaseAccountName"
      }

      $databaseName = $env:DATABASE_NAME
      if (-not $databaseName -and $databaseAccountName) {
        $databaseName = az cosmosdb sql database list -g $resourceGroup -a $databaseAccountName --query "[0].name" -o tsv 2>$null
      }

      $cosmosEndpoint = $env:COSMOS_DB_ENDPOINT
      if (-not $cosmosEndpoint -and $databaseAccountName) {
        $cosmosEndpoint = az cosmosdb show -g $resourceGroup -n $databaseAccountName --query documentEndpoint -o tsv 2>$null
      }
      if (-not $cosmosEndpoint -and $databaseAccountName) {
        $cosmosEndpoint = "https://$databaseAccountName.documents.azure.com:443/"
      }

      if (-not $databaseAccountName) {
        Write-Host "[!] Cosmos account name could not be resolved. Skipping Cosmos sample seed."
      } elseif (-not $databaseName) {
        Write-Host "[!] Cosmos database name could not be resolved. Skipping Cosmos sample seed."
      } elseif (-not $cosmosEndpoint) {
        Write-Host "[!] Cosmos endpoint could not be resolved. Skipping Cosmos sample seed."
      } else {
        # Auth: DefaultAzureCredential. Bicep grants the executor / jumpbox MI
        # 'Cosmos DB Built-in Data Contributor' (data-plane) on the account.
        $env:COSMOS_ENDPOINT = $cosmosEndpoint
        $env:COSMOS_DATABASE_NAME = $databaseName
        $env:COSMOS_SCENARIOS_CONTAINER = if ($env:SCENARIOS_DATABASE_CONTAINER) { $env:SCENARIOS_DATABASE_CONTAINER } else { 'scenarios' }
        $env:COSMOS_RUBRICS_CONTAINER = if ($env:RUBRICS_DATABASE_CONTAINER) { $env:RUBRICS_DATABASE_CONTAINER } else { 'rubrics' }
        python scripts/seed_cosmos_samples.py --mode upsert
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
