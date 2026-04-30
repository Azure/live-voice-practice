Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "🔎 Running Search data-plane setup..."

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
  Write-Host "⏭️ ENABLE_SEARCH_DATAPLANE_SETUP=false, skipping Search data-plane setup."
  exit 0
}

$resourceGroup = $env:AZURE_RESOURCE_GROUP
if (-not $resourceGroup) {
  throw "AZURE_RESOURCE_GROUP is required"
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
if (-not $searchServiceName) {
  throw "Could not resolve Search service name in resource group '$resourceGroup'. " +
        "Set `$env:SEARCH_SERVICE_NAME before re-running this script."
}

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
if (-not $storageAccountName) {
  throw "Could not resolve Storage account name in resource group '$resourceGroup'. " +
        "Either grant the current identity 'Reader' on the resource group, or set " +
        "`$env:STORAGE_ACCOUNT_NAME` before re-running this script."
}

$aiServicesName = $env:AI_FOUNDRY_ACCOUNT_NAME
if (-not $aiServicesName) {
  $aiAccountsRaw = az cognitiveservices account list -g $resourceGroup -o json
  if ($LASTEXITCODE -eq 0 -and $aiAccountsRaw) {
    $aiAccount = ($aiAccountsRaw | ConvertFrom-Json | Where-Object { $_.kind -eq 'AIServices' } | Select-Object -First 1)
    if ($aiAccount) {
      $aiServicesName = $aiAccount.name
    }
  }
}
if (-not $aiServicesName) {
  throw "Could not resolve AI Services account name"
}

$embeddingDeploymentName = if ($env:EMBEDDING_DEPLOYMENT_NAME) { $env:EMBEDDING_DEPLOYMENT_NAME } else { 'text-embedding-3-small' }
$searchEndpoint = "https://$searchServiceName.search.windows.net"
$apiVersion = '2024-07-01'

Write-Host "📦 Ensuring embedding deployment '$embeddingDeploymentName'..."
$hasEmbeddingDeployment = $false
try {
  $null = az cognitiveservices account deployment show -g $resourceGroup -n $aiServicesName --deployment-name $embeddingDeploymentName 2>$null
  if ($LASTEXITCODE -eq 0) { $hasEmbeddingDeployment = $true }
} catch { }
if (-not $hasEmbeddingDeployment) {
  az cognitiveservices account deployment create -g $resourceGroup -n $aiServicesName --deployment-name $embeddingDeploymentName --model-name $embeddingDeploymentName --model-version 1 --model-format OpenAI --sku-name Standard --sku-capacity 10 | Out-Null
}

Write-Host "🔐 Ensuring Search managed identity and OpenAI role assignment..."
az search service update -g $resourceGroup -n $searchServiceName --identity-type SystemAssigned | Out-Null
$searchPrincipalId = az search service show -g $resourceGroup -n $searchServiceName --query identity.principalId -o tsv
$aiServicesId = az cognitiveservices account show -g $resourceGroup -n $aiServicesName --query id -o tsv
$aiServicesEndpoint = az cognitiveservices account show -g $resourceGroup -n $aiServicesName --query properties.endpoint -o tsv
az role assignment create --assignee-object-id $searchPrincipalId --assignee-principal-type ServicePrincipal --role "Cognitive Services OpenAI User" --scope $aiServicesId 2>$null | Out-Null

$searchKey = az search admin-key show -g $resourceGroup --service-name $searchServiceName --query primaryKey -o tsv
$storageKey = az storage account keys list -g $resourceGroup -n $storageAccountName --query "[0].value" -o tsv

Write-Host "📁 Ensuring source containers and uploading sample files..."
az storage container create --name support-materials-src --account-name $storageAccountName --account-key $storageKey | Out-Null
az storage container create --name transcripts-src --account-name $storageAccountName --account-key $storageKey | Out-Null
if (Test-Path "samples/materials") {
  az storage blob upload-batch --account-name $storageAccountName --account-key $storageKey --destination support-materials-src --source samples/materials --pattern "*.pdf" | Out-Null
}
if (Test-Path "samples/transcripts") {
  az storage blob upload-batch --account-name $storageAccountName --account-key $storageKey --destination transcripts-src --source samples/transcripts --pattern "*.txt" | Out-Null
}

$conn = "DefaultEndpointsProtocol=https;AccountName=$storageAccountName;AccountKey=$storageKey;EndpointSuffix=core.windows.net"
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

az rest --skip-authorization-header --method put --url "$searchEndpoint/indexes/support-materials?api-version=$apiVersion" --headers 'Content-Type=application/json' "api-key=$searchKey" --body $supportIndexBody | Out-Null
az rest --skip-authorization-header --method put --url "$searchEndpoint/indexes/transcripts?api-version=$apiVersion" --headers 'Content-Type=application/json' "api-key=$searchKey" --body $transcriptsIndexBody | Out-Null
az rest --skip-authorization-header --method put --url "$searchEndpoint/datasources/datasource-support-materials?api-version=$apiVersion" --headers 'Content-Type=application/json' "api-key=$searchKey" --body $supportDsBody | Out-Null
az rest --skip-authorization-header --method put --url "$searchEndpoint/datasources/datasource-transcripts?api-version=$apiVersion" --headers 'Content-Type=application/json' "api-key=$searchKey" --body $transcriptsDsBody | Out-Null
az rest --skip-authorization-header --method put --url "$searchEndpoint/skillsets/skillset-support-materials?api-version=$apiVersion" --headers 'Content-Type=application/json' "api-key=$searchKey" --body $supportSkillsetBody | Out-Null
az rest --skip-authorization-header --method put --url "$searchEndpoint/skillsets/skillset-transcripts?api-version=$apiVersion" --headers 'Content-Type=application/json' "api-key=$searchKey" --body $transcriptsSkillsetBody | Out-Null
az rest --skip-authorization-header --method put --url "$searchEndpoint/indexers/support-materials-indexer?api-version=$apiVersion" --headers 'Content-Type=application/json' "api-key=$searchKey" --body $supportIndexerBody | Out-Null
az rest --skip-authorization-header --method put --url "$searchEndpoint/indexers/transcripts-indexer?api-version=$apiVersion" --headers 'Content-Type=application/json' "api-key=$searchKey" --body $transcriptsIndexerBody | Out-Null

try {
  & az rest --skip-authorization-header --method post --url "$searchEndpoint/indexers/support-materials-indexer/run?api-version=$apiVersion" --headers "api-key=$searchKey" | Out-Null
} catch { }
try {
  & az rest --skip-authorization-header --method post --url "$searchEndpoint/indexers/transcripts-indexer/run?api-version=$apiVersion" --headers "api-key=$searchKey" | Out-Null
} catch { }

Write-Host "✅ Search data-plane setup completed."
