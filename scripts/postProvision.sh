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
  echo "[!]️ No ACR found in resource group; skipping registry wiring."
fi

if [[ -n "$APP_CONFIG_ENDPOINT" ]] && dataplane_should_run; then
  echo "[>] Writing app-specific settings to App Configuration..."
  appcfg_failed=0
  az appconfig kv set --endpoint "$APP_CONFIG_ENDPOINT" --key AZURE_INPUT_TRANSCRIPTION_MODEL --value "azure-speech" --label "$APP_CONFIG_LABEL" --auth-mode login --yes >/dev/null 2>&1 || appcfg_failed=1
  if [[ "$appcfg_failed" == 1 ]]; then
    if [[ "$NETWORK_ISOLATION_ENABLED" == true ]]; then
      echo "[!]️ App Configuration data-plane not reachable from current network (NI mode). Run this step from the jumpbox inside the vnet. Continuing."
    else
      echo "[!]️ App Configuration updates failed."
    fi
  else
    echo "[OK] App Configuration updated (AZURE_INPUT_TRANSCRIPTION_MODEL=azure-speech)."
  fi
elif [[ -n "$APP_CONFIG_ENDPOINT" ]]; then
  echo "[-] Skipping App Configuration writes (network isolation; not running from VNet)."
else
  echo "[!]️ APP_CONFIG_ENDPOINT not set. Skipping App Configuration updates."
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
          echo "[!]️ Python executable not found. Skipping Cosmos sample seed."
        fi
      else
        echo "[!]️ Cosmos database name could not be resolved. Skipping Cosmos sample seed."
      fi
    else
      echo "[!]️ Cosmos account name could not be resolved. Skipping Cosmos sample seed."
    fi
  fi
else
  echo "[-] ENABLE_COSMOS_SAMPLE_SEED=false, skipping Cosmos sample seed."
fi

if [[ "$NETWORK_ISOLATION_ENABLED" == true && "$RUN_FROM_JUMPBOX_ENABLED" != true ]]; then
  echo ""
  echo "ℹ️  Network isolation is enabled. Three data-plane steps were skipped because they"
  echo "   require VNet access (private endpoints):"
  echo "     - App Configuration writes (AZURE_INPUT_TRANSCRIPTION_MODEL)"
  echo "     - Cosmos sample seed (scenarios/rubrics)"
  echo "     - Azure AI Search data-plane setup"
  echo "   Connect to the jumpbox via Bastion, clone this repo, run 'azd auth login' and"
  echo "   then run './scripts/postProvision.sh' interactively to apply them."
fi

echo "[OK] post-provision hook completed."
