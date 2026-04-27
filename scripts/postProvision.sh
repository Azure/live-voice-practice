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
LOCATION="${AZURE_LOCATION:-${LOCATION:-}}"
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

# Note: starting with bicep-ptn-aiml-landing-zone v1.1.0 the Azure Firewall
# Policy already ships the full jumpbox bootstrap FQDN allow-list by default
# (controlled by `extendFirewallForJumpboxBootstrap`). No post-provision hook
# is needed here. If you need to tweak it on an existing deployment, edit the
# Firewall Policy directly.

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
    --custom-domain "$SPEECH_ACCOUNT_NAME" \
    --yes >/dev/null
  echo "✅ Speech resource created."
fi

SPEECH_RESOURCE_ID="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$SPEECH_ACCOUNT_NAME" --query id -o tsv)"
SPEECH_ENDPOINT="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$SPEECH_ACCOUNT_NAME" --query properties.endpoint -o tsv)"
SPEECH_CUSTOM_SUBDOMAIN="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$SPEECH_ACCOUNT_NAME" --query properties.customSubDomainName -o tsv 2>/dev/null || true)"
if [[ -z "$SPEECH_CUSTOM_SUBDOMAIN" ]]; then
  echo "🔧 Patching Speech resource with customSubDomainName '$SPEECH_ACCOUNT_NAME'..."
  az resource update --ids "$SPEECH_RESOURCE_ID" --set "properties.customSubDomainName=$SPEECH_ACCOUNT_NAME" >/dev/null
  SPEECH_ENDPOINT="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$SPEECH_ACCOUNT_NAME" --query properties.endpoint -o tsv)"
fi

if [[ "$NETWORK_ISOLATION_ENABLED" == true ]]; then
  echo "🔒 NETWORK_ISOLATION=true: enforcing private network for Speech..."
  az resource update --ids "$SPEECH_RESOURCE_ID" --set properties.publicNetworkAccess=Disabled >/dev/null

  vnet_name="$(az network vnet list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)"
  pe_subnet_id=""
  if [[ -n "$vnet_name" ]]; then
    pe_subnet_id="$(az network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$vnet_name" -n pe-subnet --query id -o tsv 2>/dev/null || true)"
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

  if [[ -n "$vnet_name" ]]; then
    vnet_id="$(az network vnet list -g "$RESOURCE_GROUP" --query "[0].id" -o tsv 2>/dev/null || true)"
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

echo "📦 Ensuring ACR endpoint is persisted and Container App is bound to ACR via managed identity..."
ACR_NAME="$(az acr list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)"
if [[ -n "$ACR_NAME" ]]; then
  ACR_LOGIN_SERVER="$(az acr show -g "$RESOURCE_GROUP" -n "$ACR_NAME" --query loginServer -o tsv 2>/dev/null || true)"
  if [[ -n "$ACR_LOGIN_SERVER" ]]; then
    if [[ "${AZURE_CONTAINER_REGISTRY_ENDPOINT:-}" != "$ACR_LOGIN_SERVER" ]]; then
      azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT "$ACR_LOGIN_SERVER" >/dev/null
      echo "✅ AZURE_CONTAINER_REGISTRY_ENDPOINT set to '$ACR_LOGIN_SERVER'."
    fi
    if [[ -n "${CONTAINER_APP_NAME:-}" ]]; then
      CURRENT_IDENTITY="$(az containerapp show -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" --query "properties.configuration.registries[?server=='$ACR_LOGIN_SERVER'] | [0].identity" -o tsv 2>/dev/null || true)"
      if [[ "$CURRENT_IDENTITY" != "system" ]]; then
        az containerapp registry set -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" --server "$ACR_LOGIN_SERVER" --identity system >/dev/null 2>&1 || true
        echo "✅ Container App '$CONTAINER_APP_NAME' bound to ACR '$ACR_LOGIN_SERVER' via system-assigned identity."
      else
        echo "✅ Container App registry binding already in place."
      fi
    fi
  fi
else
  echo "⚠️ No ACR found in resource group; skipping registry wiring."
fi

if [[ -n "$APP_CONFIG_ENDPOINT" ]]; then
  echo "🧩 Writing Speech settings to App Configuration..."
  appcfg_failed=0
  az appconfig kv set --endpoint "$APP_CONFIG_ENDPOINT" --key AZURE_SPEECH_ENDPOINT --value "$SPEECH_ENDPOINT" --label "$APP_CONFIG_LABEL" --auth-mode login --yes >/dev/null 2>&1 || appcfg_failed=1
  az appconfig kv set --endpoint "$APP_CONFIG_ENDPOINT" --key AZURE_SPEECH_REGION --value "$SPEECH_REGION" --label "$APP_CONFIG_LABEL" --auth-mode login --yes >/dev/null 2>&1 || appcfg_failed=1
  az appconfig kv set --endpoint "$APP_CONFIG_ENDPOINT" --key AZURE_INPUT_TRANSCRIPTION_MODEL --value "azure-speech" --label "$APP_CONFIG_LABEL" --auth-mode login --yes >/dev/null 2>&1 || appcfg_failed=1
  if [[ "$appcfg_failed" == 1 ]]; then
    if [[ "$NETWORK_ISOLATION_ENABLED" == true ]]; then
      echo "⚠️ App Configuration data-plane not reachable from current network (NI mode). Run this step from the jumpbox inside the vnet. Continuing."
    else
      echo "⚠️ App Configuration updates failed."
    fi
  else
    echo "✅ App Configuration updated."
  fi
else
  echo "⚠️ APP_CONFIG_ENDPOINT not set. Skipping App Configuration updates."
fi

if [[ ! "${ENABLE_SEARCH_DATAPLANE_SETUP:-true}" =~ ^(false|False|0|no|NO)$ ]]; then
  if [[ "$NETWORK_ISOLATION_ENABLED" == true ]]; then
    echo "⏭️ NETWORK_ISOLATION=true: skipping Search data-plane setup (requires vnet access; run from jumpbox)."
  else
    echo "🔎 Running Search data-plane setup hook..."
    bash "$(dirname "$0")/setup_search_dataplane.sh"
  fi
else
  echo "⏭️ ENABLE_SEARCH_DATAPLANE_SETUP=false, skipping Search data-plane setup."
fi

if [[ ! "${ENABLE_COSMOS_SAMPLE_SEED:-true}" =~ ^(false|False|0|no|NO)$ ]]; then
  if [[ "$NETWORK_ISOLATION_ENABLED" == true ]]; then
    echo "⏭️ NETWORK_ISOLATION=true: skipping Cosmos sample seed (requires vnet access; run from jumpbox)."
  else
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
  fi
else
  echo "⏭️ ENABLE_COSMOS_SAMPLE_SEED=false, skipping Cosmos sample seed."
fi

echo "✅ post-provision speech setup completed."
