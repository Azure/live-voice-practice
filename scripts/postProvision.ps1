Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "🔧 Running post-provision speech setup..."

& azd env get-values | ForEach-Object {
  if ($_ -match '^([^=]+)=(.*)$') {
    $k = $matches[1]
    $v = $matches[2] -replace '^"|"$'
    Set-Item -Path Env:$k -Value $v
  }
}

if ($env:DEPLOY_SPEECH_SERVICE -match '^(false|False|0|no|NO)$') {
  Write-Host "⏭️ DEPLOY_SPEECH_SERVICE=false, skipping speech setup."
  exit 0
}

$resourceGroup = $env:AZURE_RESOURCE_GROUP
$location = if ($env:AZURE_LOCATION) { $env:AZURE_LOCATION } else { $env:LOCATION }
$speechRegion = if ($env:AZURE_SPEECH_REGION) { $env:AZURE_SPEECH_REGION } elseif ($env:AZURE_AI_REGION) { $env:AZURE_AI_REGION } else { $location }
$appConfigEndpoint = $env:APP_CONFIG_ENDPOINT
$appConfigLabel = if ($env:APP_CONFIG_LABEL) { $env:APP_CONFIG_LABEL } else { 'live-voice-practice' }
$networkIsolationValue = if ($env:NETWORK_ISOLATION) { $env:NETWORK_ISOLATION } else { $env:AZURE_NETWORK_ISOLATION }
$networkIsolationEnabled = $networkIsolationValue -match '^(true|True|1|yes|YES)$'

if (-not $resourceGroup -or -not $speechRegion) {
  Write-Host "❌ Missing AZURE_RESOURCE_GROUP or AZURE_LOCATION/AZURE_SPEECH_REGION."
  exit 1
}

# Note: starting with bicep-ptn-aiml-landing-zone v1.1.0 the Azure Firewall
# Policy already ships the full jumpbox bootstrap FQDN allow-list by default
# (controlled by `extendFirewallForJumpboxBootstrap`). No post-provision hook
# is needed here. If you need to tweak it on an existing deployment, edit the
# Firewall Policy directly.

$envBase = (($env:AZURE_ENV_NAME ?? 'voicelab') -replace '[^a-zA-Z0-9]', '').ToLower()
if (-not $envBase) { $envBase = 'voicelab' }
$resourceToken = (($env:RESOURCE_TOKEN ?? '') -replace '[^a-zA-Z0-9]', '')
if ($resourceToken.Length -gt 8) { $resourceToken = $resourceToken.Substring(0, 8) }
$defaultSpeechName = "$envBase" + "speech" + "$resourceToken"
if ($defaultSpeechName.Length -gt 40) { $defaultSpeechName = $defaultSpeechName.Substring(0, 40) }
$speechAccountName = if ($env:AZURE_SPEECH_RESOURCE_NAME) { $env:AZURE_SPEECH_RESOURCE_NAME } else { $defaultSpeechName }

Write-Host "📦 Ensuring Speech resource '$speechAccountName' in '$speechRegion'..."
$exists = $false
try {
  $null = az cognitiveservices account show -g $resourceGroup -n $speechAccountName 2>$null
  if ($LASTEXITCODE -eq 0) { $exists = $true }
} catch { }

if (-not $exists) {
  az cognitiveservices account create --name $speechAccountName --resource-group $resourceGroup --location $speechRegion --kind SpeechServices --sku S0 --custom-domain $speechAccountName --yes | Out-Null
  Write-Host "✅ Speech resource created."
} else {
  Write-Host "✅ Speech resource already exists."
}

$speechResourceId = az cognitiveservices account show -g $resourceGroup -n $speechAccountName --query id -o tsv
$speechEndpoint = az cognitiveservices account show -g $resourceGroup -n $speechAccountName --query properties.endpoint -o tsv
$speechCustomSubDomain = az cognitiveservices account show -g $resourceGroup -n $speechAccountName --query properties.customSubDomainName -o tsv 2>$null
if (-not $speechCustomSubDomain) {
  Write-Host "🔧 Patching Speech resource with customSubDomainName '$speechAccountName'..."
  az resource update --ids $speechResourceId --set properties.customSubDomainName=$speechAccountName | Out-Null
  $speechEndpoint = az cognitiveservices account show -g $resourceGroup -n $speechAccountName --query properties.endpoint -o tsv
}

if ($networkIsolationEnabled) {
  Write-Host "🔒 NETWORK_ISOLATION=true: enforcing private network for Speech..."
  az resource update --ids $speechResourceId --set properties.publicNetworkAccess=Disabled | Out-Null

  $vnetName = az network vnet list -g $resourceGroup --query "[0].name" -o tsv 2>$null
  $peSubnetId = $null
  if ($vnetName) {
    $peSubnetId = az network vnet subnet show -g $resourceGroup --vnet-name $vnetName -n pe-subnet --query id -o tsv 2>$null
  }

  if (-not $peSubnetId) {
    Write-Host "❌ Could not locate 'pe-subnet' to create Speech private endpoint."
    exit 1
  }

  $dnsZoneName = 'privatelink.cognitiveservices.azure.com'
  $dnsZoneId = az network private-dns zone show -g $resourceGroup -n $dnsZoneName --query id -o tsv 2>$null
  if (-not $dnsZoneId) {
    az network private-dns zone create -g $resourceGroup -n $dnsZoneName | Out-Null
    $dnsZoneId = az network private-dns zone show -g $resourceGroup -n $dnsZoneName --query id -o tsv
  }

  $vnetId = if ($vnetName) { az network vnet list -g $resourceGroup --query "[0].id" -o tsv 2>$null } else { $null }
  if ($vnetId) {
    $dnsLinkName = "$vnetName-speech-link"
    $dnsLinkExists = $false
    try {
      $null = az network private-dns link vnet show -g $resourceGroup -z $dnsZoneName -n $dnsLinkName 2>$null
      if ($LASTEXITCODE -eq 0) { $dnsLinkExists = $true }
    } catch { }

    if (-not $dnsLinkExists) {
      az network private-dns link vnet create -g $resourceGroup -z $dnsZoneName -n $dnsLinkName -v $vnetId -e false | Out-Null
    }
  }

  $peName = "$speechAccountName-pe"
  if ($peName.Length -gt 80) { $peName = $peName.Substring(0, 80) }
  $connectionName = "$speechAccountName-conn"
  if ($connectionName.Length -gt 80) { $connectionName = $connectionName.Substring(0, 80) }

  $peExists = $false
  try {
    $null = az network private-endpoint show -g $resourceGroup -n $peName 2>$null
    if ($LASTEXITCODE -eq 0) { $peExists = $true }
  } catch { }

  if (-not $peExists) {
    az network private-endpoint create -g $resourceGroup -n $peName --location $speechRegion --subnet $peSubnetId --private-connection-resource-id $speechResourceId --group-id account --connection-name $connectionName | Out-Null
  }

  $zoneGroupExists = $false
  try {
    $null = az network private-endpoint dns-zone-group show -g $resourceGroup --endpoint-name $peName -n speech-zone-group 2>$null
    if ($LASTEXITCODE -eq 0) { $zoneGroupExists = $true }
  } catch { }

  if (-not $zoneGroupExists) {
    az network private-endpoint dns-zone-group create -g $resourceGroup --endpoint-name $peName -n speech-zone-group --private-dns-zone $dnsZoneId --zone-name speech | Out-Null
  }

  Write-Host "✅ Speech private endpoint and DNS configured."
}

Write-Host "🔐 Ensuring Container App identity has 'Cognitive Services User'..."
$containerAppName = $env:AZURE_CONTAINER_APP_NAME
if (-not $containerAppName) {
  $containerAppName = az containerapp list -g $resourceGroup --query "[0].name" -o tsv 2>$null
}

if ($containerAppName) {
  $principalId = az containerapp show -g $resourceGroup -n $containerAppName --query identity.principalId -o tsv 2>$null
  if ($principalId) {
    az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Cognitive Services User" --scope $speechResourceId 2>$null | Out-Null
    Write-Host "✅ Role assignment ensured for container app '$containerAppName'."
  } else {
    Write-Host "⚠️ Container App '$containerAppName' has no managed identity principalId yet."
  }
} else {
  Write-Host "⚠️ No Container App found to assign role."
}

Write-Host "📦 Ensuring ACR endpoint is persisted and Container App is bound to ACR via managed identity..."
$acrName = az acr list -g $resourceGroup --query "[0].name" -o tsv 2>$null
if ($acrName) {
  $acrLoginServer = az acr show -g $resourceGroup -n $acrName --query loginServer -o tsv 2>$null
  if ($acrLoginServer) {
    if (-not $env:AZURE_CONTAINER_REGISTRY_ENDPOINT -or $env:AZURE_CONTAINER_REGISTRY_ENDPOINT -ne $acrLoginServer) {
      azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT $acrLoginServer | Out-Null
      Write-Host "✅ AZURE_CONTAINER_REGISTRY_ENDPOINT set to '$acrLoginServer'."
    }
    if ($containerAppName) {
      $currentRegistry = az containerapp show -g $resourceGroup -n $containerAppName --query "properties.configuration.registries[?server=='$acrLoginServer'] | [0].identity" -o tsv 2>$null
      if ($currentRegistry -ne 'system') {
        az containerapp registry set -g $resourceGroup -n $containerAppName --server $acrLoginServer --identity system 2>$null | Out-Null
        Write-Host "✅ Container App '$containerAppName' bound to ACR '$acrLoginServer' via system-assigned identity."
      } else {
        Write-Host "✅ Container App registry binding already in place."
      }
    }
  }
} else {
  Write-Host "⚠️ No ACR found in resource group; skipping registry wiring."
}

if ($appConfigEndpoint) {
  Write-Host "🧩 Writing Speech settings to App Configuration..."
  $appConfigFailed = $false
  $kvOut = az appconfig kv set --endpoint $appConfigEndpoint --key AZURE_SPEECH_ENDPOINT --value $speechEndpoint --label $appConfigLabel --auth-mode login --yes 2>&1
  if ($LASTEXITCODE -ne 0) { $appConfigFailed = $true }
  $kvOut = az appconfig kv set --endpoint $appConfigEndpoint --key AZURE_SPEECH_REGION --value $speechRegion --label $appConfigLabel --auth-mode login --yes 2>&1
  if ($LASTEXITCODE -ne 0) { $appConfigFailed = $true }
  $kvOut = az appconfig kv set --endpoint $appConfigEndpoint --key AZURE_INPUT_TRANSCRIPTION_MODEL --value azure-speech --label $appConfigLabel --auth-mode login --yes 2>&1
  if ($LASTEXITCODE -ne 0) { $appConfigFailed = $true }
  if ($appConfigFailed) {
    if ($networkIsolationEnabled) {
      Write-Host "⚠️ App Configuration data-plane not reachable from current network (NI mode). Run this step from the jumpbox inside the vnet. Continuing."
    } else {
      Write-Host "⚠️ App Configuration updates failed. Last output: $kvOut"
    }
  } else {
    Write-Host "✅ App Configuration updated."
  }
} else {
  Write-Host "⚠️ APP_CONFIG_ENDPOINT not set. Skipping App Configuration updates."
}

if (-not ($env:ENABLE_SEARCH_DATAPLANE_SETUP -match '^(false|False|0|no|NO)$')) {
  if ($networkIsolationEnabled) {
    Write-Host "⏭️ NETWORK_ISOLATION=true: skipping Search data-plane setup (requires vnet access; run from jumpbox)."
  } else {
    Write-Host "🔎 Running Search data-plane setup hook..."
    & "$PSScriptRoot\setup_search_dataplane.ps1"
  }
} else {
  Write-Host "⏭️ ENABLE_SEARCH_DATAPLANE_SETUP=false, skipping Search data-plane setup."
}

if (-not ($env:ENABLE_COSMOS_SAMPLE_SEED -match '^(false|False|0|no|NO)$')) {
  if ($networkIsolationEnabled) {
    Write-Host "⏭️ NETWORK_ISOLATION=true: skipping Cosmos sample seed (requires vnet access; run from jumpbox)."
  } else {
  Write-Host "🌱 Running Cosmos sample seed hook..."
  $databaseAccountName = if ($env:DATABASE_ACCOUNT_NAME) { $env:DATABASE_ACCOUNT_NAME } else { az cosmosdb list -g $resourceGroup --query "[0].name" -o tsv }
  if ($databaseAccountName) {
    $databaseName = if ($env:DATABASE_NAME) { $env:DATABASE_NAME } else { az cosmosdb sql database list -g $resourceGroup -a $databaseAccountName --query "[0].name" -o tsv }
    if ($databaseName) {
      $env:COSMOS_ENDPOINT = az cosmosdb show -g $resourceGroup -n $databaseAccountName --query documentEndpoint -o tsv
      $env:COSMOS_KEY = az cosmosdb keys list -g $resourceGroup -n $databaseAccountName --query primaryMasterKey -o tsv
      $env:COSMOS_DATABASE_NAME = $databaseName
      $env:COSMOS_SCENARIOS_CONTAINER = if ($env:SCENARIOS_DATABASE_CONTAINER) { $env:SCENARIOS_DATABASE_CONTAINER } else { 'scenarios' }
      $env:COSMOS_RUBRICS_CONTAINER = if ($env:RUBRICS_DATABASE_CONTAINER) { $env:RUBRICS_DATABASE_CONTAINER } else { 'rubrics' }

      if (Get-Command python -ErrorAction SilentlyContinue) {
        python scripts/seed_cosmos_samples.py --mode upsert
      } else {
        Write-Host "⚠️ Python executable not found. Skipping Cosmos sample seed."
      }
    } else {
      Write-Host "⚠️ Cosmos database name could not be resolved. Skipping Cosmos sample seed."
    }
  } else {
    Write-Host "⚠️ Cosmos account name could not be resolved. Skipping Cosmos sample seed."
  }
  }
} else {
  Write-Host "⏭️ ENABLE_COSMOS_SAMPLE_SEED=false, skipping Cosmos sample seed."
}

Write-Host "✅ post-provision speech setup completed."
