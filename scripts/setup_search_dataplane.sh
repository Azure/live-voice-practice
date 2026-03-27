#!/usr/bin/env bash
set -euo pipefail

echo "🔎 Running Search data-plane setup..."

if [[ -z "${AZURE_RESOURCE_GROUP:-}" ]]; then
  while IFS='=' read -r key value; do
    [[ -z "${key:-}" ]] && continue
    value="${value%\"}"
    value="${value#\"}"
    export "$key=$value"
  done < <(azd env get-values)
fi

if [[ "${ENABLE_SEARCH_DATAPLANE_SETUP:-true}" =~ ^(false|False|0|no|NO)$ ]]; then
  echo "⏭️ ENABLE_SEARCH_DATAPLANE_SETUP=false, skipping Search data-plane setup."
  exit 0
fi

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "❌ AZURE_RESOURCE_GROUP is required"
  exit 1
fi

SEARCH_SERVICE_NAME="${SEARCH_SERVICE_NAME:-}"
if [[ -z "$SEARCH_SERVICE_NAME" ]]; then
  SEARCH_SERVICE_NAME="$(az search service list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)"
fi
if [[ -z "$SEARCH_SERVICE_NAME" ]]; then
  echo "❌ Could not resolve Search service name"
  exit 1
fi

STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-}"
if [[ -z "$STORAGE_ACCOUNT_NAME" ]]; then
  STORAGE_ACCOUNT_NAME="$(az storage account list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)"
fi
if [[ -z "$STORAGE_ACCOUNT_NAME" ]]; then
  echo "❌ Could not resolve Storage account name"
  exit 1
fi

AI_SERVICES_NAME="${AI_FOUNDRY_ACCOUNT_NAME:-}"
if [[ -z "$AI_SERVICES_NAME" ]]; then
  AI_SERVICES_NAME="$(az cognitiveservices account list -g "$RESOURCE_GROUP" --query "[?kind=='AIServices']|[0].name" -o tsv)"
fi
if [[ -z "$AI_SERVICES_NAME" ]]; then
  echo "❌ Could not resolve AI Services account name"
  exit 1
fi

EMBEDDING_DEPLOYMENT_NAME="${EMBEDDING_DEPLOYMENT_NAME:-text-embedding-3-small}"
SEARCH_ENDPOINT="https://${SEARCH_SERVICE_NAME}.search.windows.net"
API_VERSION="2024-07-01"

echo "📦 Ensuring embedding deployment '${EMBEDDING_DEPLOYMENT_NAME}'..."
if ! az cognitiveservices account deployment show -g "$RESOURCE_GROUP" -n "$AI_SERVICES_NAME" --deployment-name "$EMBEDDING_DEPLOYMENT_NAME" >/dev/null 2>&1; then
  az cognitiveservices account deployment create \
    -g "$RESOURCE_GROUP" \
    -n "$AI_SERVICES_NAME" \
    --deployment-name "$EMBEDDING_DEPLOYMENT_NAME" \
    --model-name "$EMBEDDING_DEPLOYMENT_NAME" \
    --model-version 1 \
    --model-format OpenAI \
    --sku-name Standard \
    --sku-capacity 10 >/dev/null
fi

echo "🔐 Ensuring Search managed identity and OpenAI role assignment..."
az search service update -g "$RESOURCE_GROUP" -n "$SEARCH_SERVICE_NAME" --identity-type SystemAssigned >/dev/null
SEARCH_PRINCIPAL_ID="$(az search service show -g "$RESOURCE_GROUP" -n "$SEARCH_SERVICE_NAME" --query identity.principalId -o tsv)"
AI_SERVICES_ID="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$AI_SERVICES_NAME" --query id -o tsv)"
AI_SERVICES_ENDPOINT="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$AI_SERVICES_NAME" --query properties.endpoint -o tsv)"
az role assignment create --assignee-object-id "$SEARCH_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal --role "Cognitive Services OpenAI User" --scope "$AI_SERVICES_ID" >/dev/null 2>&1 || true

SEARCH_KEY="$(az search admin-key show -g "$RESOURCE_GROUP" --service-name "$SEARCH_SERVICE_NAME" --query primaryKey -o tsv)"
STORAGE_KEY="$(az storage account keys list -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT_NAME" --query "[0].value" -o tsv)"

echo "📁 Ensuring source containers and uploading sample files..."
az storage container create --name support-materials-src --account-name "$STORAGE_ACCOUNT_NAME" --account-key "$STORAGE_KEY" >/dev/null
az storage container create --name transcripts-src --account-name "$STORAGE_ACCOUNT_NAME" --account-key "$STORAGE_KEY" >/dev/null
if [[ -d "samples/materials" ]]; then
  az storage blob upload-batch --account-name "$STORAGE_ACCOUNT_NAME" --account-key "$STORAGE_KEY" --destination support-materials-src --source samples/materials --pattern "*.pdf" >/dev/null
fi
if [[ -d "samples/transcripts" ]]; then
  az storage blob upload-batch --account-name "$STORAGE_ACCOUNT_NAME" --account-key "$STORAGE_KEY" --destination transcripts-src --source samples/transcripts --pattern "*.txt" >/dev/null
fi

CONN="DefaultEndpointsProtocol=https;AccountName=${STORAGE_ACCOUNT_NAME};AccountKey=${STORAGE_KEY};EndpointSuffix=core.windows.net"
TMP_DIR="${TMPDIR:-/tmp}/search-dataplane-setup"
mkdir -p "$TMP_DIR"

cat > "$TMP_DIR/support-index.json" <<'JSON'
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
JSON

cat > "$TMP_DIR/transcripts-index.json" <<'JSON'
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
JSON

cat > "$TMP_DIR/support-ds.json" <<JSON
{
  "name": "datasource-support-materials",
  "type": "azureblob",
  "credentials": {"connectionString": "$CONN"},
  "container": {"name": "support-materials-src"}
}
JSON

cat > "$TMP_DIR/transcripts-ds.json" <<JSON
{
  "name": "datasource-transcripts",
  "type": "azureblob",
  "credentials": {"connectionString": "$CONN"},
  "container": {"name": "transcripts-src"}
}
JSON

cat > "$TMP_DIR/support-skillset.json" <<JSON
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
      "resourceUri": "$AI_SERVICES_ENDPOINT",
      "deploymentId": "$EMBEDDING_DEPLOYMENT_NAME",
      "modelName": "$EMBEDDING_DEPLOYMENT_NAME",
      "inputs": [{"name":"text","source":"/document/content"}],
      "outputs": [{"name":"embedding","targetName":"contentVector"}]
    }
  ]
}
JSON

cat > "$TMP_DIR/transcripts-skillset.json" <<JSON
{
  "name": "skillset-transcripts",
  "skills": [
    {
      "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
      "name": "embed-transcript",
      "context": "/document",
      "resourceUri": "$AI_SERVICES_ENDPOINT",
      "deploymentId": "$EMBEDDING_DEPLOYMENT_NAME",
      "modelName": "$EMBEDDING_DEPLOYMENT_NAME",
      "inputs": [{"name":"text","source":"/document/content"}],
      "outputs": [{"name":"embedding","targetName":"transcriptVector"}]
    }
  ]
}
JSON

cat > "$TMP_DIR/support-indexer.json" <<'JSON'
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
JSON

cat > "$TMP_DIR/transcripts-indexer.json" <<'JSON'
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
JSON

search_rest() {
  local method="$1"
  local url="$2"
  local body_file="${3:-}"
  if [[ -n "$body_file" ]]; then
    az rest --skip-authorization-header --method "$method" --url "$url" --headers "Content-Type=application/json" "api-key=$SEARCH_KEY" --body "@$body_file" >/dev/null
  else
    az rest --skip-authorization-header --method "$method" --url "$url" --headers "Content-Type=application/json" "api-key=$SEARCH_KEY" >/dev/null
  fi
}

search_rest put "$SEARCH_ENDPOINT/indexes/support-materials?api-version=$API_VERSION" "$TMP_DIR/support-index.json"
search_rest put "$SEARCH_ENDPOINT/indexes/transcripts?api-version=$API_VERSION" "$TMP_DIR/transcripts-index.json"
search_rest put "$SEARCH_ENDPOINT/datasources/datasource-support-materials?api-version=$API_VERSION" "$TMP_DIR/support-ds.json"
search_rest put "$SEARCH_ENDPOINT/datasources/datasource-transcripts?api-version=$API_VERSION" "$TMP_DIR/transcripts-ds.json"
search_rest put "$SEARCH_ENDPOINT/skillsets/skillset-support-materials?api-version=$API_VERSION" "$TMP_DIR/support-skillset.json"
search_rest put "$SEARCH_ENDPOINT/skillsets/skillset-transcripts?api-version=$API_VERSION" "$TMP_DIR/transcripts-skillset.json"
search_rest put "$SEARCH_ENDPOINT/indexers/support-materials-indexer?api-version=$API_VERSION" "$TMP_DIR/support-indexer.json"
search_rest put "$SEARCH_ENDPOINT/indexers/transcripts-indexer?api-version=$API_VERSION" "$TMP_DIR/transcripts-indexer.json"

search_rest post "$SEARCH_ENDPOINT/indexers/support-materials-indexer/run?api-version=$API_VERSION" || true
search_rest post "$SEARCH_ENDPOINT/indexers/transcripts-indexer/run?api-version=$API_VERSION" || true

echo "✅ Search data-plane setup completed."
