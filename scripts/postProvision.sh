#!/usr/bin/env bash
set -euo pipefail

echo "🔧 Running post-provision speech setup..."

while IFS='=' read -r key value; do
  [[ -z "${key:-}" ]] && continue
  value="${value%\"}"
  value="${value#\"}"
  export "$key=$value"
done < <(azd env get-values)

if [[ "${DEPLOY_SPEECH_SERVICE:-true}" =~ ^(false|False|0|no|NO)$ ]]; then
  echo "⏭️ DEPLOY_SPEECH_SERVICE=false, skipping speech setup."
  exit 0
fi

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
LOCATION="${AZURE_LOCATION:-}"
SPEECH_REGION="${AZURE_SPEECH_REGION:-${AZURE_AI_REGION:-$LOCATION}}"
APP_CONFIG_ENDPOINT="${APP_CONFIG_ENDPOINT:-}"
APP_CONFIG_LABEL="${APP_CONFIG_LABEL:-live-voice-practice}"
NETWORK_ISOLATION_VALUE="${NETWORK_ISOLATION:-${AZURE_NETWORK_ISOLATION:-false}}"
NETWORK_ISOLATION_ENABLED=false
if [[ "$NETWORK_ISOLATION_VALUE" =~ ^(true|True|1|yes|YES)$ ]]; then
  NETWORK_ISOLATION_ENABLED=true
fi

if [[ -z "$RESOURCE_GROUP" || -z "$SPEECH_REGION" ]]; then
  echo "❌ Missing AZURE_RESOURCE_GROUP or AZURE_LOCATION/AZURE_SPEECH_REGION."
  exit 1
fi

env_base="$(echo "${AZURE_ENV_NAME:-voicelab}" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
[[ -z "$env_base" ]] && env_base="voicelab"
resource_token="$(echo "${RESOURCE_TOKEN:-}" | tr -cd '[:alnum:]' | cut -c1-8)"
default_speech_name="${env_base}speech${resource_token}"
default_speech_name="${default_speech_name:0:40}"
SPEECH_ACCOUNT_NAME="${AZURE_SPEECH_RESOURCE_NAME:-$default_speech_name}"

echo "📦 Ensuring Speech resource '$SPEECH_ACCOUNT_NAME' in '$SPEECH_REGION'..."
if az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$SPEECH_ACCOUNT_NAME" >/dev/null 2>&1; then
  echo "✅ Speech resource already exists."
else
  az cognitiveservices account create \
    --name "$SPEECH_ACCOUNT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$SPEECH_REGION" \
    --kind SpeechServices \
    --sku S0 \
    --yes >/dev/null
  echo "✅ Speech resource created."
fi

SPEECH_RESOURCE_ID="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$SPEECH_ACCOUNT_NAME" --query id -o tsv)"
SPEECH_ENDPOINT="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$SPEECH_ACCOUNT_NAME" --query properties.endpoint -o tsv)"

if [[ "$NETWORK_ISOLATION_ENABLED" == true ]]; then
  echo "🔒 NETWORK_ISOLATION=true: enforcing private network for Speech..."
  az cognitiveservices account update \
    --name "$SPEECH_ACCOUNT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --public-network-access Disabled >/dev/null

  vnet_id="$(az network vnet list -g "$RESOURCE_GROUP" --query "[0].id" -o tsv 2>/dev/null || true)"
  pe_subnet_id="$(az network vnet subnet list -g "$RESOURCE_GROUP" --query "[?name=='pe-subnet']|[0].id" -o tsv 2>/dev/null || true)"

  if [[ -z "$pe_subnet_id" && -n "$vnet_id" ]]; then
    pe_subnet_id="$(az network vnet subnet list --ids "$vnet_id" --query "[?name=='pe-subnet']|[0].id" -o tsv 2>/dev/null || true)"
  fi

  if [[ -z "$pe_subnet_id" ]]; then
    echo "❌ Could not locate 'pe-subnet' to create Speech private endpoint."
    exit 1
  fi

  dns_zone_name="privatelink.cognitiveservices.azure.com"
  dns_zone_id="$(az network private-dns zone show -g "$RESOURCE_GROUP" -n "$dns_zone_name" --query id -o tsv 2>/dev/null || true)"
  if [[ -z "$dns_zone_id" ]]; then
    az network private-dns zone create -g "$RESOURCE_GROUP" -n "$dns_zone_name" >/dev/null
    dns_zone_id="$(az network private-dns zone show -g "$RESOURCE_GROUP" -n "$dns_zone_name" --query id -o tsv)"
  fi

  if [[ -n "$vnet_id" ]]; then
    vnet_name="$(basename "$vnet_id")"
    dns_link_name="${vnet_name}-speech-link"
    if ! az network private-dns link vnet show -g "$RESOURCE_GROUP" -z "$dns_zone_name" -n "$dns_link_name" >/dev/null 2>&1; then
      az network private-dns link vnet create \
        -g "$RESOURCE_GROUP" \
        -z "$dns_zone_name" \
        -n "$dns_link_name" \
        -v "$vnet_id" \
        -e false >/dev/null
    fi
  fi

  pe_name="${SPEECH_ACCOUNT_NAME}-pe"
  pe_name="${pe_name:0:80}"
  connection_name="${SPEECH_ACCOUNT_NAME}-conn"
  connection_name="${connection_name:0:80}"

  if ! az network private-endpoint show -g "$RESOURCE_GROUP" -n "$pe_name" >/dev/null 2>&1; then
    az network private-endpoint create \
      -g "$RESOURCE_GROUP" \
      -n "$pe_name" \
      --location "$SPEECH_REGION" \
      --subnet "$pe_subnet_id" \
      --private-connection-resource-id "$SPEECH_RESOURCE_ID" \
      --group-id account \
      --connection-name "$connection_name" >/dev/null
  fi

  if ! az network private-endpoint dns-zone-group show -g "$RESOURCE_GROUP" --endpoint-name "$pe_name" -n "speech-zone-group" >/dev/null 2>&1; then
    az network private-endpoint dns-zone-group create \
      -g "$RESOURCE_GROUP" \
      --endpoint-name "$pe_name" \
      -n "speech-zone-group" \
      --private-dns-zone "$dns_zone_id" \
      --zone-name "speech" >/dev/null
  fi

  echo "✅ Speech private endpoint and DNS configured."
fi

echo "🔐 Ensuring Container App identity has 'Cognitive Services User'..."
CONTAINER_APP_NAME="${AZURE_CONTAINER_APP_NAME:-}"
if [[ -z "$CONTAINER_APP_NAME" ]]; then
  CONTAINER_APP_NAME="$(az containerapp list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)"
fi

if [[ -n "$CONTAINER_APP_NAME" ]]; then
  PRINCIPAL_ID="$(az containerapp show -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" --query identity.principalId -o tsv 2>/dev/null || true)"
  if [[ -n "$PRINCIPAL_ID" ]]; then
    az role assignment create \
      --assignee-object-id "$PRINCIPAL_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "Cognitive Services User" \
      --scope "$SPEECH_RESOURCE_ID" >/dev/null 2>&1 || true
    echo "✅ Role assignment ensured for container app '$CONTAINER_APP_NAME'."
  else
    echo "⚠️ Container App '$CONTAINER_APP_NAME' has no managed identity principalId yet."
  fi
else
  echo "⚠️ No Container App found to assign role."
fi

if [[ -n "$APP_CONFIG_ENDPOINT" ]]; then
  echo "🧩 Writing Speech settings to App Configuration..."
  az appconfig kv set --endpoint "$APP_CONFIG_ENDPOINT" --key AZURE_SPEECH_ENDPOINT --value "$SPEECH_ENDPOINT" --label "$APP_CONFIG_LABEL" --yes >/dev/null
  az appconfig kv set --endpoint "$APP_CONFIG_ENDPOINT" --key AZURE_SPEECH_REGION --value "$SPEECH_REGION" --label "$APP_CONFIG_LABEL" --yes >/dev/null
  az appconfig kv set --endpoint "$APP_CONFIG_ENDPOINT" --key AZURE_INPUT_TRANSCRIPTION_MODEL --value "azure-speech" --label "$APP_CONFIG_LABEL" --yes >/dev/null
  echo "✅ App Configuration updated."
else
  echo "⚠️ APP_CONFIG_ENDPOINT not set. Skipping App Configuration updates."
fi

if [[ ! "${ENABLE_SEARCH_DATAPLANE_SETUP:-true}" =~ ^(false|False|0|no|NO)$ ]]; then
  echo "🔎 Running Search data-plane setup hook..."
  bash "$(dirname "$0")/setup_search_dataplane.sh"
else
  echo "⏭️ ENABLE_SEARCH_DATAPLANE_SETUP=false, skipping Search data-plane setup."
fi

if [[ ! "${ENABLE_COSMOS_SAMPLE_SEED:-true}" =~ ^(false|False|0|no|NO)$ ]]; then
  echo "🌱 Running Cosmos sample seed hook..."
  DATABASE_ACCOUNT_NAME="${DATABASE_ACCOUNT_NAME:-}"
  if [[ -z "$DATABASE_ACCOUNT_NAME" ]]; then
    DATABASE_ACCOUNT_NAME="$(az cosmosdb list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)"
  fi

  if [[ -n "$DATABASE_ACCOUNT_NAME" ]]; then
    DATABASE_NAME="${DATABASE_NAME:-}"
    if [[ -z "$DATABASE_NAME" ]]; then
      DATABASE_NAME="$(az cosmosdb sql database list -g "$RESOURCE_GROUP" -a "$DATABASE_ACCOUNT_NAME" --query "[0].name" -o tsv 2>/dev/null || true)"
    fi

    if [[ -n "$DATABASE_NAME" ]]; then
      export COSMOS_ENDPOINT="$(az cosmosdb show -g "$RESOURCE_GROUP" -n "$DATABASE_ACCOUNT_NAME" --query documentEndpoint -o tsv)"
      export COSMOS_KEY="$(az cosmosdb keys list -g "$RESOURCE_GROUP" -n "$DATABASE_ACCOUNT_NAME" --query primaryMasterKey -o tsv)"
      export COSMOS_DATABASE_NAME="$DATABASE_NAME"
      export COSMOS_SCENARIOS_CONTAINER="${SCENARIOS_DATABASE_CONTAINER:-scenarios}"
      export COSMOS_RUBRICS_CONTAINER="${RUBRICS_DATABASE_CONTAINER:-rubrics}"

      if command -v python >/dev/null 2>&1; then
        python scripts/seed_cosmos_samples.py --mode upsert
      elif command -v python3 >/dev/null 2>&1; then
        python3 scripts/seed_cosmos_samples.py --mode upsert
      else
        echo "⚠️ Python executable not found. Skipping Cosmos sample seed."
      fi
    else
      echo "⚠️ Cosmos database name could not be resolved. Skipping Cosmos sample seed."
    fi
  else
    echo "⚠️ Cosmos account name could not be resolved. Skipping Cosmos sample seed."
  fi
else
  echo "⏭️ ENABLE_COSMOS_SAMPLE_SEED=false, skipping Cosmos sample seed."
fi

echo "✅ post-provision speech setup completed."
