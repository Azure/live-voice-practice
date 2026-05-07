Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "[>] Running Search data-plane setup..."

if (-not $env:AZURE_RESOURCE_GROUP) {
  & azd env get-values | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') {
      $k = $matches[1]
      $v = $matches[2] -replace '^"|"$'
      Set-Item -Path Env:$k -Value $v
    }
  }
}

if ($env:ENABLE_SEARCH_DATAPLANE_SETUP -match '^(false|False|0|no|NO)$') {
  Write-Host "[-] ENABLE_SEARCH_DATAPLANE_SETUP=false, skipping Search data-plane setup."
  exit 0
}

$resourceGroup = $env:AZURE_RESOURCE_GROUP
if (-not $resourceGroup) {
  throw "AZURE_RESOURCE_GROUP is required"
}

# App Configuration is the source of truth: Bicep writes resource names there
# at provision time. Read directly from it instead of inferring names from
# token derivation or ARM list calls (which fail when the executing identity
# lacks Reader on the RG -- typical for the AILZ jumpbox MI).
$appConfigEndpoint = $env:APP_CONFIG_ENDPOINT
$appConfigLabel = if ($env:APP_CONFIG_LABEL) { $env:APP_CONFIG_LABEL } else { 'live-voice-practice' }
$appConfigFallbackLabel = 'ai-lz'

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

$searchServiceName = $env:SEARCH_SERVICE_NAME
if (-not $searchServiceName) { $searchServiceName = Get-AppConfigValue 'SEARCH_SERVICE_NAME' }
if (-not $searchServiceName) {
  throw "Could not resolve SEARCH_SERVICE_NAME from env or App Configuration ('$appConfigEndpoint' label '$appConfigLabel'). Ensure APP_CONFIG_ENDPOINT is set and the current identity has 'App Configuration Data Reader'."
}
Write-Host "[>] Using Search service: $searchServiceName"

$storageAccountName = $env:STORAGE_ACCOUNT_NAME
if (-not $storageAccountName) { $storageAccountName = Get-AppConfigValue 'STORAGE_ACCOUNT_NAME' }
if (-not $storageAccountName) {
  throw "Could not resolve STORAGE_ACCOUNT_NAME from env or App Configuration. Ensure APP_CONFIG_ENDPOINT is set and the current identity has 'App Configuration Data Reader'."
}
Write-Host "[>] Using Storage account: $storageAccountName"

$aiServicesName = $env:AI_FOUNDRY_ACCOUNT_NAME
if (-not $aiServicesName) { $aiServicesName = Get-AppConfigValue 'AI_FOUNDRY_ACCOUNT_NAME' }
if (-not $aiServicesName) {
  throw "Could not resolve AI_FOUNDRY_ACCOUNT_NAME from env or App Configuration."
}

$embeddingDeploymentName = if ($env:EMBEDDING_DEPLOYMENT_NAME) { $env:EMBEDDING_DEPLOYMENT_NAME } else { 'text-embedding-3-small' }
$searchEndpoint = "https://$searchServiceName.search.windows.net"
$apiVersion = '2024-07-01'

# The embedding deployment is created by Bicep via the modelDeploymentList parameter
# in main.parameters.json. Do not (re)create it here — doing so masks parameter
# drift and burns quota on a duplicate deployment if the param file ever diverges.
# If the deployment is missing, the skillset PUT below will fail with a clear
# 'deployment not found' error from Azure AI Search.

Write-Host "[>] Resolving endpoints (RBAC + Search MI provisioned by Bicep)..."
$aiServicesEndpoint = az cognitiveservices account show -g $resourceGroup -n $aiServicesName --query properties.endpoint -o tsv
$subscriptionId = az account show --query id -o tsv
$storageAccountId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccountName"

Write-Host "[>] Ensuring source containers and uploading sample files (Entra ID auth)..."
az storage container create --name support-materials-src --account-name $storageAccountName --auth-mode login | Out-Null
az storage container create --name transcripts-src --account-name $storageAccountName --auth-mode login | Out-Null
if (Test-Path "samples/materials") {
  az storage blob upload-batch --account-name $storageAccountName --auth-mode login --destination support-materials-src --source samples/materials --pattern "*.pdf" --overwrite | Out-Null
}
if (Test-Path "samples/transcripts") {
  az storage blob upload-batch --account-name $storageAccountName --auth-mode login --destination transcripts-src --source samples/transcripts --pattern "*.txt" --overwrite | Out-Null
}

# Datasource connection uses ResourceId form so Search authenticates to Storage via its managed identity (no keys).
# When the Search service is provisioned with a User-Assigned Identity (UAI), the data source must
# explicitly reference that identity via an "identity" block; otherwise Search returns
# "Ensure managed identity is enabled for your service." Detect identity type at runtime so this
# script works for both SAI and UAI deployments.
$conn = "ResourceId=$storageAccountId;"
$searchIdentityType = az search service show -g $resourceGroup -n $searchServiceName --query "identity.type" -o tsv 2>$null
$searchUaiResourceId = ''
if ($searchIdentityType -and $searchIdentityType -match 'UserAssigned') {
  $searchUaiResourceId = az search service show -g $resourceGroup -n $searchServiceName --query "identity.userAssignedIdentities | keys(@) | [0]" -o tsv 2>$null
}
$dsIdentityFragment = ''
if ($searchUaiResourceId) {
  $dsIdentityFragment = ',"identity":{"@odata.type":"#Microsoft.Azure.Search.DataUserAssignedIdentity","userAssignedIdentity":"' + $searchUaiResourceId + '"}'
  Write-Host "[>] Search uses UAI; injecting userAssignedIdentity into datasources: $searchUaiResourceId"
}
$tmpDir = Join-Path $PSScriptRoot '.tmp-search'
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

@'
{
  "name": "support-materials",
  "fields": [
    {"name":"id","type":"Edm.String","key":true,"searchable":false,"filterable":true,"sortable":false,"facetable":false},
    {"name":"title","type":"Edm.String","searchable":true,"filterable":true,"sortable":true,"facetable":false},
    {"name":"sourcePath","type":"Edm.String","searchable":false,"filterable":true,"sortable":false,"facetable":false},
    {"name":"materialType","type":"Edm.String","searchable":true,"filterable":true,"sortable":false,"facetable":true},
    {"name":"content","type":"Edm.String","searchable":true,"filterable":false,"sortable":false,"facetable":false},
    {"name":"chunks","type":"Collection(Edm.String)","searchable":true,"filterable":false,"sortable":false,"facetable":false},
    {"name":"contentVector","type":"Collection(Edm.Single)","searchable":true,"retrievable":true,"dimensions":1536,"vectorSearchProfile":"vprofile"}
  ],
  "vectorSearch": {
    "algorithms": [
      {"name":"hnsw-config","kind":"hnsw","hnswParameters":{"metric":"cosine","m":4,"efConstruction":400,"efSearch":500}}
    ],
    "profiles": [
      {"name":"vprofile","algorithm":"hnsw-config"}
    ]
  },
  "semantic": {
    "configurations": [
      {"name":"default","prioritizedFields":{"titleField":{"fieldName":"title"},"prioritizedContentFields":[{"fieldName":"content"}]}}
    ]
  }
}
'@ | Set-Content -Path (Join-Path $tmpDir 'support-index.json') -Encoding UTF8

@'
{
  "name": "transcripts",
  "fields": [
    {"name":"id","type":"Edm.String","key":true,"searchable":false,"filterable":true,"sortable":false,"facetable":false},
    {"name":"title","type":"Edm.String","searchable":true,"filterable":true,"sortable":true,"facetable":false},
    {"name":"sourcePath","type":"Edm.String","searchable":false,"filterable":true,"sortable":false,"facetable":false},
    {"name":"transcriptText","type":"Edm.String","searchable":true,"filterable":false,"sortable":false,"facetable":false},
    {"name":"transcriptVector","type":"Collection(Edm.Single)","searchable":true,"retrievable":true,"dimensions":1536,"vectorSearchProfile":"vprofile"}
  ],
  "vectorSearch": {
    "algorithms": [
      {"name":"hnsw-config","kind":"hnsw","hnswParameters":{"metric":"cosine","m":4,"efConstruction":400,"efSearch":500}}
    ],
    "profiles": [
      {"name":"vprofile","algorithm":"hnsw-config"}
    ]
  },
  "semantic": {
    "configurations": [
      {"name":"default","prioritizedFields":{"titleField":{"fieldName":"title"},"prioritizedContentFields":[{"fieldName":"transcriptText"}]}}
    ]
  }
}
'@ | Set-Content -Path (Join-Path $tmpDir 'transcripts-index.json') -Encoding UTF8

@"
{
  "name": "datasource-support-materials",
  "type": "azureblob",
  "credentials": {"connectionString": "$conn"},
  "container": {"name": "support-materials-src"}$dsIdentityFragment
}
"@ | Set-Content -Path (Join-Path $tmpDir 'support-ds.json') -Encoding UTF8

@"
{
  "name": "datasource-transcripts",
  "type": "azureblob",
  "credentials": {"connectionString": "$conn"},
  "container": {"name": "transcripts-src"}$dsIdentityFragment
}
"@ | Set-Content -Path (Join-Path $tmpDir 'transcripts-ds.json') -Encoding UTF8

@"
{
  "name": "skillset-support-materials",
  "skills": [
    {
      "@odata.type": "#Microsoft.Skills.Text.SplitSkill",
      "name": "split-content",
      "context": "/document",
      "textSplitMode": "pages",
      "maximumPageLength": 3500,
      "pageOverlapLength": 500,
      "inputs": [{"name":"text","source":"/document/content"}],
      "outputs": [{"name":"textItems","targetName":"pages"}]
    },
    {
      "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
      "name": "embed-content",
      "context": "/document",
      "resourceUri": "$aiServicesEndpoint",
      "deploymentId": "$embeddingDeploymentName",
      "modelName": "$embeddingDeploymentName",
      "inputs": [{"name":"text","source":"/document/content"}],
      "outputs": [{"name":"embedding","targetName":"contentVector"}]
    }
  ]
}
"@ | Set-Content -Path (Join-Path $tmpDir 'support-skillset.json') -Encoding UTF8

@"
{
  "name": "skillset-transcripts",
  "skills": [
    {
      "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
      "name": "embed-transcript",
      "context": "/document",
      "resourceUri": "$aiServicesEndpoint",
      "deploymentId": "$embeddingDeploymentName",
      "modelName": "$embeddingDeploymentName",
      "inputs": [{"name":"text","source":"/document/content"}],
      "outputs": [{"name":"embedding","targetName":"transcriptVector"}]
    }
  ]
}
"@ | Set-Content -Path (Join-Path $tmpDir 'transcripts-skillset.json') -Encoding UTF8

@'
{
  "name": "support-materials-indexer",
  "dataSourceName": "datasource-support-materials",
  "targetIndexName": "support-materials",
  "skillsetName": "skillset-support-materials",
  "fieldMappings": [
    {"sourceFieldName":"metadata_storage_path","targetFieldName":"id","mappingFunction":{"name":"base64Encode"}},
    {"sourceFieldName":"metadata_storage_name","targetFieldName":"title"},
    {"sourceFieldName":"metadata_storage_path","targetFieldName":"sourcePath"}
  ],
  "outputFieldMappings": [
    {"sourceFieldName":"/document/content","targetFieldName":"content"},
    {"sourceFieldName":"/document/pages/*","targetFieldName":"chunks"},
    {"sourceFieldName":"/document/contentVector","targetFieldName":"contentVector"}
  ],
  "parameters": {"configuration": {"dataToExtract": "contentAndMetadata"}},
  "schedule": {"interval":"PT15M"}
}
'@ | Set-Content -Path (Join-Path $tmpDir 'support-indexer.json') -Encoding UTF8

@'
{
  "name": "transcripts-indexer",
  "dataSourceName": "datasource-transcripts",
  "targetIndexName": "transcripts",
  "skillsetName": "skillset-transcripts",
  "fieldMappings": [
    {"sourceFieldName":"metadata_storage_path","targetFieldName":"id","mappingFunction":{"name":"base64Encode"}},
    {"sourceFieldName":"metadata_storage_name","targetFieldName":"title"},
    {"sourceFieldName":"metadata_storage_path","targetFieldName":"sourcePath"}
  ],
  "outputFieldMappings": [
    {"sourceFieldName":"/document/content","targetFieldName":"transcriptText"},
    {"sourceFieldName":"/document/transcriptVector","targetFieldName":"transcriptVector"}
  ],
  "parameters": {"configuration": {"dataToExtract": "contentAndMetadata"}},
  "schedule": {"interval":"PT15M"}
}
'@ | Set-Content -Path (Join-Path $tmpDir 'transcripts-indexer.json') -Encoding UTF8

$supportIndexBody = '@' + (Join-Path $tmpDir 'support-index.json')
$transcriptsIndexBody = '@' + (Join-Path $tmpDir 'transcripts-index.json')
$supportDsBody = '@' + (Join-Path $tmpDir 'support-ds.json')
$transcriptsDsBody = '@' + (Join-Path $tmpDir 'transcripts-ds.json')
$supportSkillsetBody = '@' + (Join-Path $tmpDir 'support-skillset.json')
$transcriptsSkillsetBody = '@' + (Join-Path $tmpDir 'transcripts-skillset.json')
$supportIndexerBody = '@' + (Join-Path $tmpDir 'support-indexer.json')
$transcriptsIndexerBody = '@' + (Join-Path $tmpDir 'transcripts-indexer.json')

# All Search REST calls use AAD; az rest will inject the bearer token for the search.azure.com audience
$searchResource = 'https://search.azure.com'
az rest --resource $searchResource --method put --url "$searchEndpoint/indexes/support-materials?api-version=$apiVersion" --headers 'Content-Type=application/json' --body $supportIndexBody | Out-Null
az rest --resource $searchResource --method put --url "$searchEndpoint/indexes/transcripts?api-version=$apiVersion" --headers 'Content-Type=application/json' --body $transcriptsIndexBody | Out-Null
az rest --resource $searchResource --method put --url "$searchEndpoint/datasources/datasource-support-materials?api-version=$apiVersion" --headers 'Content-Type=application/json' --body $supportDsBody | Out-Null
az rest --resource $searchResource --method put --url "$searchEndpoint/datasources/datasource-transcripts?api-version=$apiVersion" --headers 'Content-Type=application/json' --body $transcriptsDsBody | Out-Null
az rest --resource $searchResource --method put --url "$searchEndpoint/skillsets/skillset-support-materials?api-version=$apiVersion" --headers 'Content-Type=application/json' --body $supportSkillsetBody | Out-Null
az rest --resource $searchResource --method put --url "$searchEndpoint/skillsets/skillset-transcripts?api-version=$apiVersion" --headers 'Content-Type=application/json' --body $transcriptsSkillsetBody | Out-Null
az rest --resource $searchResource --method put --url "$searchEndpoint/indexers/support-materials-indexer?api-version=$apiVersion" --headers 'Content-Type=application/json' --body $supportIndexerBody | Out-Null
az rest --resource $searchResource --method put --url "$searchEndpoint/indexers/transcripts-indexer?api-version=$apiVersion" --headers 'Content-Type=application/json' --body $transcriptsIndexerBody | Out-Null

# Helper: trigger an indexer run, treating 409 ('Another indexer invocation is
# currently in progress') as benign — the previous run already covers fresh
# blobs. Anything else is logged but doesn't fail the script.
function Invoke-IndexerRun {
  param([string]$indexerName)
  $url = "$searchEndpoint/indexers/$indexerName/run?api-version=$apiVersion"
  $output = & az rest --resource $searchResource --method post --url $url 2>&1
  if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Triggered indexer run: $indexerName"
    return
  }
  $msg = ($output | Out-String)
  if ($msg -match 'Another indexer invocation is currently in progress' -or $msg -match 'Conflict') {
    Write-Host "[i] Indexer '$indexerName' is already running; skipping new invocation."
  } else {
    Write-Host "[!] Failed to trigger indexer '$indexerName': $($msg.Trim())"
  }
}

Invoke-IndexerRun 'support-materials-indexer'
Invoke-IndexerRun 'transcripts-indexer'

Write-Host "[OK] Search data-plane setup completed."
