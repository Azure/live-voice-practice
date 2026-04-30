#!/usr/bin/env bash
# Intentionally NOT using `set -e`: this script makes many `az` calls that
# return non-zero exit codes (e.g. ResourceNotFound on first run, idempotent
# Conflict on re-run) which we handle explicitly via `$?`. We still want
# unset-var detection and pipefail to catch real bugs.
set -uo pipefail

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

echo "[>] Running post-provision hook..."

while IFS='=' read -r key value; do
  [[ -z "${key:-}" ]] && continue
  value="${value%\"}"
  value="${value#\"}"
  export "$key=$value"
done < <(azd env get-values)

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
APP_CONFIG_ENDPOINT="${APP_CONFIG_ENDPOINT:-}"
APP_CONFIG_LABEL="${APP_CONFIG_LABEL:-live-voice-practice}"
NETWORK_ISOLATION_VALUE="${NETWORK_ISOLATION:-${AZURE_NETWORK_ISOLATION:-false}}"
NETWORK_ISOLATION_ENABLED=false
if [[ "$NETWORK_ISOLATION_VALUE" =~ ^(true|True|1|yes|YES)$ ]]; then
  NETWORK_ISOLATION_ENABLED=true
fi

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "[X] Missing AZURE_RESOURCE_GROUP."
  exit 1
fi

# When NETWORK_ISOLATION=true, data-plane operations (Cosmos seed, Search index
# setup, App Configuration writes) require connectivity to the VNet private
# endpoints, i.e. running from inside the VNet (jumpbox/Bastion VM or via VPN).
# Mirror the GPT-RAG zero-trust UX: prompt the user interactively. If the
# session is non-interactive (e.g. azd hook in CI), skip data-plane steps.
RUN_FROM_JUMPBOX_ENABLED=false
if [[ "$NETWORK_ISOLATION_ENABLED" == true ]]; then
  echo ""
  echo "[>] Zero Trust / Network Isolation enabled."
  echo "   Data-plane steps (Cosmos seed, Search index setup, App Configuration writes)"
  echo "   require connectivity to the VNet private endpoints."
  echo "   Ensure you run scripts/postProvision.sh from within the VNet (jumpbox via"
  echo "   Bastion or VPN). Otherwise these steps will be skipped."
  if [[ -t 0 ]]; then
    read -r -p "[?] Are you running this script from inside the VNet or via VPN? [Y/n]: " _ni_answer
    if [[ -z "${_ni_answer:-}" || "${_ni_answer:-}" =~ ^(y|Y|yes|YES|true|True|1)$ ]]; then
      RUN_FROM_JUMPBOX_ENABLED=true
      echo "[OK] Continuing with data-plane post-provisioning."
    else
      echo "[-] Data-plane steps will be skipped. Re-run from the jumpbox to apply them."
    fi
  else
    echo "[-] Non-interactive shell detected; data-plane steps will be skipped."
    echo "   Re-run interactively from the jumpbox/Bastion to apply them."
  fi
fi

dataplane_should_run() {
  if [[ "$NETWORK_ISOLATION_ENABLED" != true ]]; then
    return 0
  fi
  if [[ "$RUN_FROM_JUMPBOX_ENABLED" == true ]]; then
    return 0
  fi
  return 1
}

echo "[>] Ensuring ACR endpoint is persisted and Container App is bound to ACR via managed identity..."
CONTAINER_APP_NAME="${AZURE_CONTAINER_APP_NAME:-}"
if [[ -z "$CONTAINER_APP_NAME" ]]; then
  CONTAINER_APP_NAME="$(az containerapp list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)"
fi
ACR_NAME="$(az acr list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)"
if [[ -n "$ACR_NAME" ]]; then
  ACR_LOGIN_SERVER="$(az acr show -g "$RESOURCE_GROUP" -n "$ACR_NAME" --query loginServer -o tsv 2>/dev/null || true)"
  if [[ -n "$ACR_LOGIN_SERVER" ]]; then
    if [[ "${AZURE_CONTAINER_REGISTRY_ENDPOINT:-}" != "$ACR_LOGIN_SERVER" ]]; then
      azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT "$ACR_LOGIN_SERVER" >/dev/null
      echo "[OK] AZURE_CONTAINER_REGISTRY_ENDPOINT set to '$ACR_LOGIN_SERVER'."
    fi
    if [[ -n "${CONTAINER_APP_NAME:-}" ]]; then
      CURRENT_IDENTITY="$(az containerapp show -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" --query "properties.configuration.registries[?server=='$ACR_LOGIN_SERVER'] | [0].identity" -o tsv 2>/dev/null || true)"
      if [[ "$CURRENT_IDENTITY" != "system" ]]; then
        az containerapp registry set -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" --server "$ACR_LOGIN_SERVER" --identity system >/dev/null 2>&1 || true
        echo "[OK] Container App '$CONTAINER_APP_NAME' bound to ACR '$ACR_LOGIN_SERVER' via system-assigned identity."
      else
        echo "[OK] Container App registry binding already in place."
      fi
    fi
  fi
else
  echo "[!] No ACR found in resource group; skipping registry wiring."
fi

if [[ -n "$APP_CONFIG_ENDPOINT" ]] && dataplane_should_run; then
  echo "[>] Writing app-specific settings to App Configuration..."

  # Helper: idempotent kv set with structured logging.
  appcfg_kv_set() {
    local key="$1"
    local value="${2:-}"
    local ct="${3:-text/plain}"
    if ! az appconfig kv set \
          --endpoint "$APP_CONFIG_ENDPOINT" \
          --key "$key" \
          --value "$value" \
          --label "$APP_CONFIG_LABEL" \
          --content-type "$ct" \
          --auth-mode login \
          --yes >/dev/null 2>&1; then
      echo "[!] kv set failed for '$key'"
      return 1
    fi
    return 0
  }

  appcfg_failures=0

  # 1. App-specific flag (always written).
  appcfg_kv_set 'AZURE_INPUT_TRANSCRIPTION_MODEL' 'azure-speech' || appcfg_failures=$((appcfg_failures+1))

  # 2. Under network isolation, the AILZ Bicep `appConfigPopulate` and
  #    `cosmosConfigKeyVaultPopulate` modules are gated off (they perform
  #    ARM-proxied data-plane writes that fail from public networks). When
  #    running from inside the VNet, populate the same keys here from azd
  #    env (Bicep outputs) + control-plane discovery in the resource group.
  #    Idempotent: re-running just upserts.
  if [[ "$NETWORK_ISOLATION_ENABLED" == true ]]; then
    echo "[>] Populating App Configuration (AILZ populate modules skipped under NI)..."

    cosmos_name="${DATABASE_ACCOUNT_NAME:-$(az cosmosdb list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)}"
    cosmos_endpoint="${COSMOS_DB_ENDPOINT:-}"
    if [[ -z "$cosmos_endpoint" && -n "$cosmos_name" ]]; then
      cosmos_endpoint="$(az cosmosdb show -g "$RESOURCE_GROUP" -n "$cosmos_name" --query documentEndpoint -o tsv 2>/dev/null || true)"
    fi
    cosmos_id=""
    [[ -n "$cosmos_name" ]] && cosmos_id="$(az cosmosdb show -g "$RESOURCE_GROUP" -n "$cosmos_name" --query id -o tsv 2>/dev/null || true)"
    cosmos_db_name="${DATABASE_NAME:-}"
    if [[ -z "$cosmos_db_name" && -n "$cosmos_name" ]]; then
      cosmos_db_name="$(az cosmosdb sql database list -g "$RESOURCE_GROUP" -a "$cosmos_name" --query "[0].name" -o tsv 2>/dev/null || true)"
    fi

    search_name="${SEARCH_SERVICE_NAME:-$(az search service list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)}"
    search_endpoint=""
    [[ -n "$search_name" ]] && search_endpoint="https://${search_name}.search.windows.net"
    search_id=""
    [[ -n "$search_name" ]] && search_id="$(az search service show -g "$RESOURCE_GROUP" -n "$search_name" --query id -o tsv 2>/dev/null || true)"

    storage_name="${STORAGE_ACCOUNT_NAME:-}"
    if [[ -z "$storage_name" ]]; then
      storage_name="$(az storage account list -g "$RESOURCE_GROUP" --query "[?starts_with(name,'st') && !starts_with(name,'staifst')] | [0].name" -o tsv 2>/dev/null || true)"
      [[ -z "$storage_name" ]] && storage_name="$(az storage account list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)"
    fi
    storage_id=""
    storage_blob=""
    if [[ -n "$storage_name" ]]; then
      storage_id="$(az storage account show -g "$RESOURCE_GROUP" -n "$storage_name" --query id -o tsv 2>/dev/null || true)"
      storage_blob="$(az storage account show -g "$RESOURCE_GROUP" -n "$storage_name" --query primaryEndpoints.blob -o tsv 2>/dev/null || true)"
    fi

    foundry_name="${AI_FOUNDRY_ACCOUNT_NAME:-$(az cognitiveservices account list -g "$RESOURCE_GROUP" --query "[?kind=='AIServices'] | [0].name" -o tsv 2>/dev/null || true)}"
    foundry_endpoint=""
    foundry_id=""
    if [[ -n "$foundry_name" ]]; then
      foundry_endpoint="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$foundry_name" --query "properties.endpoint" -o tsv 2>/dev/null || true)"
      foundry_id="$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$foundry_name" --query id -o tsv 2>/dev/null || true)"
    fi

    kv_name="$(az keyvault list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)"
    kv_uri=""
    kv_id=""
    if [[ -n "$kv_name" ]]; then
      kv_uri="$(az keyvault show -g "$RESOURCE_GROUP" -n "$kv_name" --query "properties.vaultUri" -o tsv 2>/dev/null || true)"
      kv_id="$(az keyvault show -g "$RESOURCE_GROUP" -n "$kv_name" --query id -o tsv 2>/dev/null || true)"
    fi

    acr_name="$(az acr list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)"
    acr_login_server=""
    [[ -n "$acr_name" ]] && acr_login_server="$(az acr show -g "$RESOURCE_GROUP" -n "$acr_name" --query loginServer -o tsv 2>/dev/null || true)"

    ca_env_name="$(az containerapp env list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)"
    ca_env_id=""
    [[ -n "$ca_env_name" ]] && ca_env_id="$(az containerapp env show -g "$RESOURCE_GROUP" -n "$ca_env_name" --query id -o tsv 2>/dev/null || true)"

    appcfg_name="$(az appconfig list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)"

    log_name="$(az monitor log-analytics workspace list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)"
    log_id=""
    [[ -n "$log_name" ]] && log_id="$(az monitor log-analytics workspace show -g "$RESOURCE_GROUP" -n "$log_name" --query id -o tsv 2>/dev/null || true)"

    appins_name="$(az resource list -g "$RESOURCE_GROUP" --resource-type 'microsoft.insights/components' --query "[0].name" -o tsv 2>/dev/null || true)"
    appins_id=""
    appins_conn=""
    if [[ -n "$appins_name" ]]; then
      appins_id="$(az resource show -g "$RESOURCE_GROUP" -n "$appins_name" --resource-type 'microsoft.insights/components' --query id -o tsv 2>/dev/null || true)"
      appins_conn="$(az monitor app-insights component show -g "$RESOURCE_GROUP" -a "$appins_name" --query connectionString -o tsv 2>/dev/null || true)"
    fi

    # Mirror what AILZ's appConfigPopulate / cosmosConfigKeyVaultPopulate
    # would have written. Empty values are intentional (matches Bicep ternary).
    declare -a populate_keys=(
      "AZURE_TENANT_ID|${AZURE_TENANT_ID:-}|text/plain"
      "SUBSCRIPTION_ID|${AZURE_SUBSCRIPTION_ID:-}|text/plain"
      "AZURE_RESOURCE_GROUP|$RESOURCE_GROUP|text/plain"
      "LOCATION|${AZURE_LOCATION:-}|text/plain"
      "ENVIRONMENT_NAME|${AZURE_ENV_NAME:-}|text/plain"
      "RESOURCE_TOKEN|${RESOURCE_TOKEN:-}|text/plain"
      "NETWORK_ISOLATION|true|text/plain"
      "LOG_LEVEL|INFO|text/plain"
      "ENABLE_CONSOLE_LOGGING|true|text/plain"
      "APPLICATIONINSIGHTS_CONNECTION_STRING|${appins_conn}|text/plain"
      "KEY_VAULT_RESOURCE_ID|${kv_id}|text/plain"
      "STORAGE_ACCOUNT_RESOURCE_ID|${storage_id}|text/plain"
      "APP_INSIGHTS_RESOURCE_ID|${appins_id}|text/plain"
      "LOG_ANALYTICS_RESOURCE_ID|${log_id}|text/plain"
      "CONTAINER_ENV_RESOURCE_ID|${ca_env_id}|text/plain"
      "AI_FOUNDRY_ACCOUNT_RESOURCE_ID|${foundry_id}|text/plain"
      "SEARCH_SERVICE_RESOURCE_ID|${search_id}|text/plain"
      "COSMOS_DB_ACCOUNT_RESOURCE_ID|${cosmos_id}|text/plain"
      "AI_FOUNDRY_ACCOUNT_NAME|${foundry_name}|text/plain"
      "APP_CONFIG_NAME|${appcfg_name}|text/plain"
      "APP_INSIGHTS_NAME|${appins_name}|text/plain"
      "CONTAINER_ENV_NAME|${ca_env_name}|text/plain"
      "CONTAINER_REGISTRY_NAME|${acr_name}|text/plain"
      "CONTAINER_REGISTRY_LOGIN_SERVER|${acr_login_server}|text/plain"
      "DATABASE_ACCOUNT_NAME|${cosmos_name}|text/plain"
      "DATABASE_NAME|${cosmos_db_name}|text/plain"
      "SEARCH_SERVICE_NAME|${search_name}|text/plain"
      "STORAGE_ACCOUNT_NAME|${storage_name}|text/plain"
      "KEY_VAULT_URI|${kv_uri}|text/plain"
      "STORAGE_BLOB_ENDPOINT|${storage_blob}|text/plain"
      "AI_FOUNDRY_ACCOUNT_ENDPOINT|${foundry_endpoint}|text/plain"
      "SEARCH_SERVICE_QUERY_ENDPOINT|${search_endpoint}|text/plain"
      "COSMOS_DB_ENDPOINT|${cosmos_endpoint}|text/plain"
      "AZURE_SPEECH_RESOURCE_ID|${AZURE_SPEECH_RESOURCE_ID:-}|text/plain"
      "AZURE_SPEECH_RESOURCE_NAME|${AZURE_SPEECH_RESOURCE_NAME:-}|text/plain"
      "AZURE_SPEECH_REGION|${AZURE_SPEECH_REGION:-}|text/plain"
      "AZURE_SPEECH_ENDPOINT|${AZURE_SPEECH_ENDPOINT:-}|text/plain"
    )

    populate_count=0
    for entry in "${populate_keys[@]}"; do
      IFS='|' read -r k v ct <<< "$entry"
      if ! appcfg_kv_set "$k" "$v" "$ct"; then
        appcfg_failures=$((appcfg_failures+1))
      fi
      populate_count=$((populate_count+1))
    done
    echo "[OK] App Configuration populate complete ($populate_count keys; $appcfg_failures failures)."
  fi

  if [[ "$appcfg_failures" -gt 0 ]]; then
    if [[ "$NETWORK_ISOLATION_ENABLED" == true ]]; then
      echo "[!] $appcfg_failures App Configuration writes failed. If you are not running from inside the VNet, re-run this script from the jumpbox."
    else
      echo "[!] $appcfg_failures App Configuration writes failed."
    fi
  fi
elif [[ -n "$APP_CONFIG_ENDPOINT" ]]; then
  echo "[-] Skipping App Configuration writes (network isolation; not running from VNet)."
else
  echo "[!] APP_CONFIG_ENDPOINT not set. Skipping App Configuration updates."
fi

if [[ ! "${ENABLE_SEARCH_DATAPLANE_SETUP:-true}" =~ ^(false|False|0|no|NO)$ ]]; then
  if dataplane_should_run; then
    echo "[>] Running Search data-plane setup hook..."
    bash "$(dirname "$0")/setup_search_dataplane.sh"
  else
    echo "[-] Skipping Search data-plane setup (network isolation; not running from VNet)."
    echo "   Re-run scripts/postProvision.sh from the jumpbox/Bastion to apply it."
  fi
else
  echo "[-] ENABLE_SEARCH_DATAPLANE_SETUP=false, skipping Search data-plane setup."
fi

if [[ ! "${ENABLE_COSMOS_SAMPLE_SEED:-true}" =~ ^(false|False|0|no|NO)$ ]]; then
  if ! dataplane_should_run; then
    echo "[-] Skipping Cosmos sample seed (network isolation; not running from VNet)."
    echo "   Re-run scripts/postProvision.sh from the jumpbox/Bastion to apply it."
  else
    echo "[>] Running Cosmos sample seed hook..."
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
          echo "[!] Python executable not found. Skipping Cosmos sample seed."
        fi
      else
        echo "[!] Cosmos database name could not be resolved. Skipping Cosmos sample seed."
      fi
    else
      echo "[!] Cosmos account name could not be resolved. Skipping Cosmos sample seed."
    fi
  fi
else
  echo "[-] ENABLE_COSMOS_SAMPLE_SEED=false, skipping Cosmos sample seed."
fi

if [[ "$NETWORK_ISOLATION_ENABLED" == true && "$RUN_FROM_JUMPBOX_ENABLED" != true ]]; then
  echo ""
  echo "[i]  Network isolation is enabled. Three data-plane steps were skipped because they"
  echo "   require VNet access (private endpoints):"
  echo "     - App Configuration writes (AZURE_INPUT_TRANSCRIPTION_MODEL)"
  echo "     - Cosmos sample seed (scenarios/rubrics)"
  echo "     - Azure AI Search data-plane setup"
  echo "   Connect to the jumpbox via Bastion, clone this repo, run 'azd auth login' and"
  echo "   then run './scripts/postProvision.sh' interactively to apply them."
fi

echo "[OK] post-provision hook completed."
