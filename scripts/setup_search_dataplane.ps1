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

# Extract resource token from a known endpoint env var (works without ARM list permissions).
# AILZ jumpbox MI typically lacks Reader on the RG, so list calls return [] -- we derive names instead.
$resourceToken = $null
foreach ($candidate in @($env:APP_CONFIG_ENDPOINT, $env:AZURE_APP_CONFIG_ENDPOINT, $env:AZURE_KEY_VAULT_ENDPOINT, $env:AZURE_CONTAINER_REGISTRY_ENDPOINT)) {
  if ($candidate -and $candidate -match '(?:appcs|kv|cr|st|srch)-?([a-z0-9]{8,})') {
    $resourceToken = $matches[1]
    break
  }
}
if ($resourceToken) {
  Write-Host "[>] Resource token derived from environment: $resourceToken"
}

$searchServiceName = $env:SEARCH_SERVICE_NAME
if (-not $searchServiceName) {
  # Prefer the general-purpose Search; AI Foundry provisions a private one named srch-aif-*
  $searchServiceName = az search service list -g $resourceGroup `
    --query "[?!(starts_with(name, 'srch-aif'))] | [0].name" -o tsv
}
if (-not $searchServiceName) {
  # Fallback: any Search service in the RG
  $searchServiceName = az search service list -g $resourceGroup --query "[0].name" -o tsv
}
if (-not $searchServiceName -and $resourceToken) {
  # Last resort: derive from token (MI may lack ARM list perms even when it has data-plane roles)
  $searchServiceName = "srch-$resourceToken"
  Write-Host "[>] Derived Search service name from token: $searchServiceName"
}
if (-not $searchServiceName) {
  throw "Could not resolve Search service name in resource group '$resourceGroup'. " +
        "Set `$env:SEARCH_SERVICE_NAME before re-running this script."
}
Write-Host "[>] Using Search service: $searchServiceName"

$storageAccountName = $env:STORAGE_ACCOUNT_NAME
if (-not $storageAccountName) {
  # Prefer accounts not used by AI Foundry (those start with "staif")
  $storageAccountName = az storage account list -g $resourceGroup `
    --query "[?!(starts_with(name, 'staif'))] | [0].name" -o tsv
}
if (-not $storageAccountName) {
  # Fallback: any storage account in the RG
  $storageAccountName = az storage account list -g $resourceGroup --query "[0].name" -o tsv
}
if (-not $storageAccountName -and $resourceToken) {
  # Last resort: derive from token (MI may lack ARM list perms even when it has data-plane roles)
  $storageAccountName = "st$resourceToken"
  Write-Host "[>] Derived Storage account name from token: $storageAccountName"
}
if (-not $storageAccountName) {
  Write-Host "[!] Storage account lookup returned empty. Diagnostics:"
  Write-Host "    az account show:"
  az account show --query "{name:name,id:id,user:user.name,user_type:user.type}" -o tsv 2>&1 | ForEach-Object { Write-Host "      $_" }
  Write-Host "    az storage account list -g $resourceGroup (raw):"
  az storage account list -g $resourceGroup -o tsv --query "[].name" 2>&1 | ForEach-Object { Write-Host "      $_" }
  throw "Could not resolve Storage account name in resource group '$resourceGroup'. " +
        "Either grant the current identity 'Reader' on the resource group, or set " +
        "`$env:STORAGE_ACCOUNT_NAME` before re-running this script."
}
Write-Host "[>] Using Storage account: $storageAccountName"

$aiServicesName = $env:AI_FOUNDRY_ACCOUNT_NAME
if (-not $aiServicesName) {
  $aiAccountsRaw = az cognitiveservices account list -g $resourceGroup -o json 2>$null
  if ($LASTEXITCODE -eq 0 -and $aiAccountsRaw) {
    $aiAccount = ($aiAccountsRaw | ConvertFrom-Json | Where-Object { $_.kind -eq 'AIServices' } | Select-Object -First 1)
    if ($aiAccount) {
      $aiServicesName = $aiAccount.name
    }
  }
}
if (-not $aiServicesName -and $resourceToken) {
  # Last resort: derive from token. Bicep's `aiFoundryName` is `aif-<token>`.
  $aiServicesName = "aif-$resourceToken"
  Write-Host "[>] Derived AI Services account name from token: $aiServicesName"
}
if (-not $aiServicesName) {
  throw "Could not resolve AI Services account name in resource group '$resourceGroup'. Set `$env:AI_FOUNDRY_ACCOUNT_NAME before re-running."
}

$embeddingDeploymentName = if ($env:EMBEDDING_DEPLOYMENT_NAME) { $env:EMBEDDING_DEPLOYMENT_NAME } else { 'text-embedding-3-small' }
$searchEndpoint = "https://$searchServiceName.search.windows.net"
$apiVersion = '2024-07-01'

Write-Host "[>] Ensuring embedding deployment '$embeddingDeploymentName'..."
$hasEmbeddingDeployment = $false
try {
  $null = az cognitiveservices account deployment show -g $resourceGroup -n $aiServicesName --deployment-name $embeddingDeploymentName 2>$null
  if ($LASTEXITCODE -eq 0) { $hasEmbeddingDeployment = $true }
} catch { }
if (-not $hasEmbeddingDeployment) {
  # SKU availability for text-embedding-* varies by region. Try GlobalStandard first
  # (works in Sweden Central / many EU regions where Standard is not offered),
  # then fall back to Standard for older regions. Continue on failure so the rest
  # of the data-plane setup can still complete — the embedding may already be
  # provisioned out-of-band by Bicep under a different deployment name.
  $embeddingSku = if ($env:EMBEDDING_DEPLOYMENT_SKU) { $env:EMBEDDING_DEPLOYMENT_SKU } else { 'GlobalStandard' }
  $skusToTry = @($embeddingSku)
  if ($embeddingSku -ne 'Standard') { $skusToTry += 'Standard' }
  $createdEmbedding = $false
  foreach ($sku in $skusToTry) {
    Write-Host "[>] Creating embedding deployment with sku='$sku' capacity=10..."
    $createOut = az cognitiveservices account deployment create -g $resourceGroup -n $aiServicesName `
      --deployment-name $embeddingDeploymentName `
      --model-name $embeddingDeploymentName --model-version 1 --model-format OpenAI `
      --sku-name $sku --sku-capacity 10 2>&1
    if ($LASTEXITCODE -eq 0) { $createdEmbedding = $true; break }
    Write-Host "[!] sku='$sku' failed: $($createOut | Out-String -Width 4096)".Trim()
  }
  if (-not $createdEmbedding) {
    Write-Host "[!] Could not create embedding deployment '$embeddingDeploymentName'. Continuing; the indexer skillset will fail until an embedding deployment with this name exists. Set `$env:EMBEDDING_DEPLOYMENT_NAME / `$env:EMBEDDING_DEPLOYMENT_SKU and re-run."
  }
}

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

# Datasource connection uses ResourceId form so Search authenticates to Storage via its system-assigned MI (no keys)
$conn = "ResourceId=$storageAccountId;"
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
  "container": {"name": "support-materials-src"}
}
"@ | Set-Content -Path (Join-Path $tmpDir 'support-ds.json') -Encoding UTF8

@"
{
  "name": "datasource-transcripts",
  "type": "azureblob",
  "credentials": {"connectionString": "$conn"},
  "container": {"name": "transcripts-src"}
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
