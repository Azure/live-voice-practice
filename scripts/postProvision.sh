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
      REGISTRY_IDENTITY="system"
      if [[ "${USE_UAI:-}" == "true" ]]; then
        UAI_RESOURCE_ID="$(az containerapp show -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" --query "identity.userAssignedIdentities | keys(@) | [0]" -o tsv 2>/dev/null || true)"
        if [[ -n "$UAI_RESOURCE_ID" ]]; then REGISTRY_IDENTITY="$UAI_RESOURCE_ID"; fi
      fi
      CURRENT_IDENTITY="$(az containerapp show -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" --query "properties.configuration.registries[?server=='$ACR_LOGIN_SERVER'] | [0].identity" -o tsv 2>/dev/null || true)"
      if [[ "$CURRENT_IDENTITY" != "$REGISTRY_IDENTITY" ]]; then
        az containerapp registry set -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" --server "$ACR_LOGIN_SERVER" --identity "$REGISTRY_IDENTITY" >/dev/null 2>&1 || true
        if [[ "${USE_UAI:-}" == "true" ]]; then
          echo "[OK] Container App '$CONTAINER_APP_NAME' bound to ACR '$ACR_LOGIN_SERVER' via user-assigned identity."
        else
          echo "[OK] Container App '$CONTAINER_APP_NAME' bound to ACR '$ACR_LOGIN_SERVER' via system-assigned identity."
        fi
      else
        echo "[OK] Container App registry binding already in place."
      fi
    fi
  fi
else
  echo "[!] No ACR found in resource group; skipping registry wiring."
fi

# Workaround for upstream bug Azure/bicep-ptn-aiml-landing-zone#38:
# the Container App template injects AZURE_CLIENT_ID="" (empty string) when
# the deployment uses a System-Assigned managed identity. An empty
# AZURE_CLIENT_ID confuses azure-identity's DefaultAzureCredential and the
# IMDS proxy returns HTTP 500 'invalid_scope', breaking App Configuration,
# Cosmos DB and AI Search access at runtime. Until the upstream module is
# updated, strip the conflicting env vars here so SystemAssigned MI works.
#
# When USE_UAI=true is set, AZURE_CLIENT_ID is intentionally populated with
# the User-Assigned Identity's clientId by the bicep template; the strip
# would break UAI auth, so it is short-circuited here.
USE_UAI_LC="$(printf '%s' "${USE_UAI:-}" | tr '[:upper:]' '[:lower:]')"
if [[ "$USE_UAI_LC" == "true" || "$USE_UAI_LC" == "1" || "$USE_UAI_LC" == "yes" ]]; then
  echo "[OK] USE_UAI=$USE_UAI detected; preserving AZURE_CLIENT_ID/AZURE_TENANT_ID (UAI mode)."
elif [[ -n "${CONTAINER_APP_NAME:-}" ]]; then
  ID_TYPE="$(az containerapp show -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" --query "identity.type" -o tsv 2>/dev/null || true)"
  if [[ "$ID_TYPE" == *SystemAssigned* && "$ID_TYPE" != *UserAssigned* ]]; then
    ENV_NAMES="$(az containerapp show -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" --query "properties.template.containers[0].env[].name" -o tsv 2>/dev/null || true)"
    TO_REMOVE=()
    for n in AZURE_CLIENT_ID AZURE_TENANT_ID; do
      if echo "$ENV_NAMES" | grep -qx "$n"; then
        TO_REMOVE+=("$n")
      fi
    done
    if [[ ${#TO_REMOVE[@]} -gt 0 ]]; then
      echo "[>] Removing conflicting env vars from Container App (workaround for upstream issue #38): ${TO_REMOVE[*]}"
      if az containerapp update -g "$RESOURCE_GROUP" -n "$CONTAINER_APP_NAME" --remove-env-vars "${TO_REMOVE[@]}" -o none 2>/dev/null; then
        echo "[OK] Removed: ${TO_REMOVE[*]}. New revision will start with clean MI auth."
      else
        echo "[!] Failed to remove env vars; manual intervention may be required."
      fi
    else
      echo "[OK] No conflicting AZURE_CLIENT_ID/AZURE_TENANT_ID env vars present on Container App."
    fi
  fi
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

  # Under network isolation, AILZ Bicep gates off `appConfigPopulate` and
  # `cosmosConfigKeyVaultPopulate` (they perform ARM-proxied data-plane writes
  # that fail from public networks). When running from inside the VNet,
  # populate the equivalent keys here. To keep the hook fast and avoid the
  # accumulated cold-start cost of dozens of `az ... list/show` calls behind
  # private endpoints, names and IDs are *derived* from `RESOURCE_TOKEN` using
  # the AILZ naming abbreviations (see infra/constants/abbreviations.json), and
  # all key writes are batched into a single `az appconfig kv import`.
  if [[ "$NETWORK_ISOLATION_ENABLED" == true ]]; then
    echo "[>] Populating App Configuration (AILZ populate modules skipped under NI)..."

    if [[ -z "${RESOURCE_TOKEN:-}" ]]; then
      echo "[!] RESOURCE_TOKEN not available; cannot derive resource names. Skipping batch populate."
      appcfg_failures=$((appcfg_failures+1))
    else
      token="$RESOURCE_TOKEN"
      sub_id="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null || true)}"
      rg_path="/subscriptions/${sub_id}/resourceGroups/${RESOURCE_GROUP}"

      cosmos_name="cosmos-${token}"
      cosmos_db_name="cosmos-db${token}"
      search_name="srch-${token}"
      storage_name="st${token}"
      foundry_name="aif-${token}"
      kv_name="kv-${token}"
      acr_name="cr${token}"
      ca_env_name="cae-${token}"
      appcfg_name="appcs-${token}"
      appins_name="appi-${token}"
      log_name="log-${token}"

      cosmos_endpoint="https://${cosmos_name}.documents.azure.com:443/"
      search_endpoint="https://${search_name}.search.windows.net"
      kv_uri="https://${kv_name}.vault.azure.net/"
      storage_blob="https://${storage_name}.blob.core.windows.net/"
      foundry_endpoint="https://${foundry_name}.cognitiveservices.azure.com/"
      acr_login_server="${acr_name}.azurecr.io"

      cosmos_id="${rg_path}/providers/Microsoft.DocumentDB/databaseAccounts/${cosmos_name}"
      search_id="${rg_path}/providers/Microsoft.Search/searchServices/${search_name}"
      storage_id="${rg_path}/providers/Microsoft.Storage/storageAccounts/${storage_name}"
      foundry_id="${rg_path}/providers/Microsoft.CognitiveServices/accounts/${foundry_name}"
      kv_id="${rg_path}/providers/Microsoft.KeyVault/vaults/${kv_name}"
      ca_env_id="${rg_path}/providers/Microsoft.App/managedEnvironments/${ca_env_name}"
      appins_id="${rg_path}/providers/Microsoft.Insights/components/${appins_name}"
      log_id="${rg_path}/providers/Microsoft.OperationalInsights/workspaces/${log_name}"

      # App Insights connection string contains a per-component GUID and can't
      # be derived. Try azd env first; fall back to a single ARM call.
      appins_conn="${APPLICATIONINSIGHTS_CONNECTION_STRING:-}"
      if [[ -z "$appins_conn" ]]; then
        echo "[>] Fetching App Insights connection string (az resource show, no extension)..."
        # Use plain `az resource show` to avoid triggering an interactive
        # extension-install prompt for `application-insights` on first run.
        appins_conn="$(az resource show --ids "$appins_id" --query 'properties.ConnectionString' -o tsv 2>/dev/null || true)"
      fi

      tmp_file="$(mktemp -t appconfig-populate-XXXXXX.json)"
      python3 - "$tmp_file" <<EOF
import json, sys
data = {
  "AZURE_INPUT_TRANSCRIPTION_MODEL": "azure-speech",
  "AZURE_TENANT_ID": "${AZURE_TENANT_ID:-}",
  "SUBSCRIPTION_ID": "${sub_id}",
  "AZURE_RESOURCE_GROUP": "${RESOURCE_GROUP}",
  "LOCATION": "${AZURE_LOCATION:-}",
  "ENVIRONMENT_NAME": "${AZURE_ENV_NAME:-}",
  "RESOURCE_TOKEN": "${token}",
  "NETWORK_ISOLATION": "true",
  "LOG_LEVEL": "INFO",
  "ENABLE_CONSOLE_LOGGING": "true",
  "APPLICATIONINSIGHTS_CONNECTION_STRING": "${appins_conn}",
  "KEY_VAULT_RESOURCE_ID": "${kv_id}",
  "STORAGE_ACCOUNT_RESOURCE_ID": "${storage_id}",
  "APP_INSIGHTS_RESOURCE_ID": "${appins_id}",
  "LOG_ANALYTICS_RESOURCE_ID": "${log_id}",
  "CONTAINER_ENV_RESOURCE_ID": "${ca_env_id}",
  "AI_FOUNDRY_ACCOUNT_RESOURCE_ID": "${foundry_id}",
  "SEARCH_SERVICE_RESOURCE_ID": "${search_id}",
  "COSMOS_DB_ACCOUNT_RESOURCE_ID": "${cosmos_id}",
  "AI_FOUNDRY_ACCOUNT_NAME": "${foundry_name}",
  "APP_CONFIG_NAME": "${appcfg_name}",
  "APP_INSIGHTS_NAME": "${appins_name}",
  "CONTAINER_ENV_NAME": "${ca_env_name}",
  "CONTAINER_REGISTRY_NAME": "${acr_name}",
  "CONTAINER_REGISTRY_LOGIN_SERVER": "${acr_login_server}",
  "DATABASE_ACCOUNT_NAME": "${cosmos_name}",
  "DATABASE_NAME": "${cosmos_db_name}",
  "SEARCH_SERVICE_NAME": "${search_name}",
  "STORAGE_ACCOUNT_NAME": "${storage_name}",
  "KEY_VAULT_URI": "${kv_uri}",
  "STORAGE_BLOB_ENDPOINT": "${storage_blob}",
  "AI_FOUNDRY_ACCOUNT_ENDPOINT": "${foundry_endpoint}",
  "SEARCH_SERVICE_QUERY_ENDPOINT": "${search_endpoint}",
  "COSMOS_DB_ENDPOINT": "${cosmos_endpoint}",
  "AZURE_SPEECH_RESOURCE_ID": "${AZURE_SPEECH_RESOURCE_ID:-}",
  "AZURE_SPEECH_RESOURCE_NAME": "${AZURE_SPEECH_RESOURCE_NAME:-}",
  "AZURE_SPEECH_REGION": "${AZURE_SPEECH_REGION:-}",
  "AZURE_SPEECH_ENDPOINT": "${AZURE_SPEECH_ENDPOINT:-}",
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(data, f)
EOF

      kv_count="$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$tmp_file" 2>/dev/null || echo "?")"
      echo "[>] Importing $kv_count keys via batch..."
      if ! az appconfig kv import \
            --endpoint "$APP_CONFIG_ENDPOINT" \
            --source file \
            --format json \
            --path "$tmp_file" \
            --label "$APP_CONFIG_LABEL" \
            --content-type 'text/plain' \
            --auth-mode login \
            --yes >/dev/null 2>&1; then
        echo "[!] kv import failed."
        appcfg_failures=$((appcfg_failures+1))
      else
        echo "[OK] App Configuration populate complete ($kv_count keys via batch import)."
      fi
      rm -f "$tmp_file"
    fi
  else
    # Non-NI path: only the app-specific transcription flag is needed
    # (AILZ's Bicep populate module wrote everything else).
    appcfg_kv_set 'AZURE_INPUT_TRANSCRIPTION_MODEL' 'azure-speech' || appcfg_failures=$((appcfg_failures+1))
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
