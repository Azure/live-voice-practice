#!/usr/bin/env bash
#
# deploy.sh - Build with `az acr build` and update the container app.
#
# Build strategy:
#   - networkIsolation=true  -> build runs in the ACR Tasks agent pool attached
#                               to the VNet (ACR_TASK_AGENT_POOL from azd env),
#                               pushes to the private ACR over its private
#                               endpoint. No Docker required on this machine.
#   - networkIsolation=false -> build runs in the shared Microsoft-managed
#                               ACR Tasks pool. No Docker required either.
#

set -euo pipefail

# Colors
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo

#region Load azd env
envValues="$(azd env get-values 2>/dev/null || true)"
niFlag="$(echo "$envValues" | grep -i '^NETWORK_ISOLATION=' | cut -d'=' -f2- | tr -d '"' | tr -d '[:space:]' || true)"
agentPool="$(echo "$envValues" | grep -i '^ACR_TASK_AGENT_POOL=' | cut -d'=' -f2- | tr -d '"' | tr -d '[:space:]' || true)"
#endregion

#region Read APP_CONFIG_ENDPOINT
if [[ -n "${APP_CONFIG_ENDPOINT:-}" ]]; then
    echo -e "${GREEN}Using APP_CONFIG_ENDPOINT from environment: ${APP_CONFIG_ENDPOINT}${NC}"
else
    echo -e "${BLUE}Looking up APP_CONFIG_ENDPOINT from azd env...${NC}"
    APP_CONFIG_ENDPOINT="$(echo "$envValues" | grep -i '^APP_CONFIG_ENDPOINT=' | cut -d'=' -f2- | tr -d '"' | tr -d '[:space:]' || true)"
fi

if [[ -z "${APP_CONFIG_ENDPOINT:-}" ]]; then
    echo -e "${YELLOW}APP_CONFIG_ENDPOINT not found${NC}"
    echo "    Set it with: azd env set APP_CONFIG_ENDPOINT <endpoint>"
    exit 1
fi

echo -e "${GREEN}APP_CONFIG_ENDPOINT: ${APP_CONFIG_ENDPOINT}${NC}"
configName="${APP_CONFIG_ENDPOINT#https://}"
configName="${configName%.azconfig.io}"
configName="${configName%/}"
echo -e "${GREEN}App Configuration name: ${configName}${NC}"
echo
#endregion

#region Check Azure CLI login
echo -e "${BLUE}Checking Azure CLI login...${NC}"
az account show >/dev/null 2>&1 || { echo -e "${YELLOW}Not logged in. Run 'az login'.${NC}"; exit 1; }
echo -e "${GREEN}Azure CLI logged in${NC}"
echo
#endregion

#region Read values from App Configuration
label="live-voice-practice"
echo -e "${BLUE}Loading values from App Configuration (label=${label})...${NC}"

get_config_value() {
    key="$1"
    echo -e "${BLUE}Fetching '$key'...${NC}" >&2
    val="$(az appconfig kv show --name "$configName" --key "$key" --label "$label" --auth-mode login --query value -o tsv 2>&1)" || true
    if [[ -z "${val// /}" ]]; then
        echo -e "${YELLOW}Key '$key' not found${NC}" >&2
        return 1
    fi
    echo "$val"
}

acrName="$(get_config_value "CONTAINER_REGISTRY_NAME" || true)"
acrServer="$(get_config_value "CONTAINER_REGISTRY_LOGIN_SERVER" || true)"
rg="$(get_config_value "AZURE_RESOURCE_GROUP" || true)"
appName="$(get_config_value "VOICELAB_APP_NAME" || true)"

# Fallback to ARM control plane (handles NETWORK_ISOLATION=true where App Config
# data plane is unreachable from outside the VNet). These are not secrets.
if [[ -z "$rg" ]]; then
    rg="$(echo "$envValues" | sed -n 's/^AZURE_RESOURCE_GROUP="\?\([^"]*\)"\?/\1/p' | head -n1)"
    if [[ -z "$rg" ]]; then
        envName="$(echo "$envValues" | sed -n 's/^AZURE_ENV_NAME="\?\([^"]*\)"\?/\1/p' | head -n1)"
        [[ -n "$envName" ]] && rg="rg-$envName"
    fi
    [[ -n "$rg" ]] && echo -e "${YELLOW}Using AZURE_RESOURCE_GROUP from azd env: $rg${NC}"
fi
if [[ -n "$rg" && ( -z "$acrName" || -z "$acrServer" ) ]]; then
    acrName="$(az acr list -g "$rg" --query '[0].name' -o tsv 2>/dev/null || true)"
    if [[ -n "$acrName" ]]; then
        acrServer="$(az acr show -g "$rg" -n "$acrName" --query loginServer -o tsv 2>/dev/null || true)"
        echo -e "${YELLOW}Using ACR from control plane: $acrName ($acrServer)${NC}"
    fi
fi
if [[ -n "$rg" && -z "$appName" ]]; then
    appName="$(az containerapp list -g "$rg" --query "[?contains(name, 'voicelab')].name | [0]" -o tsv 2>/dev/null || true)"
    [[ -z "$appName" ]] && appName="$(az containerapp list -g "$rg" --query '[0].name' -o tsv 2>/dev/null || true)"
    [[ -n "$appName" ]] && echo -e "${YELLOW}Using Container App from control plane: $appName${NC}"
fi

if [[ -z "$acrName" || -z "$acrServer" || -z "$rg" || -z "$appName" ]]; then
    echo -e "${RED}Required values missing (App Config + control plane fallback both failed)${NC}"
    echo "   acrName=$acrName acrServer=$acrServer rg=$rg appName=$appName"
    exit 1
fi

echo -e "${GREEN}Values loaded:${NC}"
echo "   CONTAINER_REGISTRY_NAME = $acrName"
echo "   CONTAINER_REGISTRY_LOGIN_SERVER = $acrServer"
echo "   AZURE_RESOURCE_GROUP = $rg"
echo "   VOICELAB_APP_NAME = $appName"
echo
#endregion

#region Decide agent pool
agentPoolArgs=()
if [[ "$niFlag" == "true" ]]; then
    if [[ -z "$agentPool" ]]; then
        echo -e "${RED}NETWORK_ISOLATION=true but ACR_TASK_AGENT_POOL is empty.${NC}"
        echo "    The landing zone should expose it as an azd output (v1.1.0+)."
        echo "    Run 'azd provision' to refresh outputs, then retry."
        exit 1
    fi
    echo -e "${GREEN}Using ACR Tasks agent pool: ${agentPool} (VNet-attached)${NC}"
    agentPoolArgs=(--agent-pool "$agentPool")
else
    echo -e "${GREEN}Using ACR shared agent pool (public network)${NC}"
fi
echo
#endregion

#region Define tag
echo -e "${BLUE}Defining tag...${NC}"
if tag=$(git rev-parse --short HEAD 2>/dev/null); then
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        suffix=$(date +%Y%m%d%H%M%S)
        tag="${tag}-dirty-${suffix}"
    fi
else
    tag=$(date +%Y%m%d%H%M%S)
    echo -e "${YELLOW}Git not available, using timestamp: ${tag}${NC}"
fi
imageRef="voicelab:$tag"
imageRefLatest="voicelab:latest"
imageName="$acrServer/$imageRef"
echo -e "${GREEN}Tag: ${tag}${NC}"
echo -e "${GREEN}Image: ${imageName}${NC}"
echo
#endregion

#region Stage build context (skip heavy local-only dirs)
# 'az acr build .' walks every file in the working tree to apply .dockerignore,
# which is pathologically slow when frontend/node_modules and .venv are
# present. Stage only what the Dockerfile needs into a temp directory.
echo -e "${BLUE}Staging build context...${NC}"
stageDir="$(mktemp -d -t voicelab-src-XXXXXX)"
trap 'rm -rf "$stageDir"' EXIT
# Use rsync if available (fast, with excludes); fall back to cp otherwise.
if command -v rsync >/dev/null 2>&1; then
    rsync -a \
        --exclude='.git' \
        --exclude='.azure' \
        --exclude='.venv' \
        --exclude='.temp' \
        --exclude='.pytest_cache' \
        --exclude='.mypy_cache' \
        --exclude='node_modules' \
        --exclude='dist' \
        --exclude='build' \
        --exclude='infra' \
        --exclude='docs' \
        --exclude='__pycache__' \
        --exclude='*.log' \
        --exclude='*.pyc' \
        ./ "$stageDir/"
else
    # Fallback: tar pipe
    tar -cf - \
        --exclude='./.git' \
        --exclude='./.azure' \
        --exclude='./.venv' \
        --exclude='./.temp' \
        --exclude='./.pytest_cache' \
        --exclude='./.mypy_cache' \
        --exclude='./node_modules' \
        --exclude='./frontend/node_modules' \
        --exclude='./dist' \
        --exclude='./build' \
        --exclude='./infra' \
        --exclude='./docs' \
        --exclude='*.log' \
        --exclude='*.pyc' \
        . | tar -xf - -C "$stageDir"
fi
echo -e "${GREEN}Context: ${stageDir}${NC}"
echo
#endregion

#region Build and push via ACR Tasks
echo -e "${GREEN}Building and pushing with 'az acr build'...${NC}"
# --no-logs avoids az CLI streaming-log unicode crashes on some consoles.
az acr build \
    --registry "$acrName" \
    --resource-group "$rg" \
    --platform linux/amd64 \
    --image "$imageRef" \
    --image "$imageRefLatest" \
    --file Dockerfile \
    --no-logs \
    "${agentPoolArgs[@]}" \
    "$stageDir"
echo -e "${GREEN}Image built and pushed${NC}"
echo
#endregion

#region Update container app
echo -e "${GREEN}Updating container app...${NC}"
# Retry loop for the AcrPull race: when SystemAssigned MI was just bound to
# the Container Registry, the AcrPull role assignment can take 30-120s to
# propagate and the first 'containerapp update --image' fails with
# UNAUTHORIZED. We retry only on auth-shaped errors; any other failure
# fails fast.
maxAttempts=5
backoffSeconds=(15 30 60 120 120)
updateOk=false
for attempt in $(seq 1 "$maxAttempts"); do
    errFile="$(mktemp)"
    if az containerapp update --name "$appName" --resource-group "$rg" --image "$imageName" 2>"$errFile"; then
        cat "$errFile"
        rm -f "$errFile"
        updateOk=true
        break
    fi
    errText="$(cat "$errFile")"
    rm -f "$errFile"
    if ! echo "$errText" | grep -Eqi 'UNAUTHORIZED|denied|pull access denied|AuthorizationFailed|InvalidAuthenticationToken'; then
        echo "$errText"
        echo -e "${RED}Failed to update container app (non-retryable error)${NC}"
        exit 1
    fi
    if [[ "$attempt" -ge "$maxAttempts" ]]; then
        echo "$errText"
        echo -e "${RED}Failed to update container app after $maxAttempts attempts (AcrPull role propagation timeout)${NC}"
        echo "    Manual fix: confirm the Container App MI has AcrPull on the registry, then re-run azd deploy."
        exit 1
    fi
    idx=$((attempt - 1))
    sleepFor="${backoffSeconds[$idx]:-120}"
    echo -e "${YELLOW}AcrPull race detected (attempt ${attempt}/${maxAttempts}) — sleeping ${sleepFor}s before retry...${NC}"
    sleep "$sleepFor"
done
if [[ "$updateOk" != "true" ]]; then
    echo -e "${RED}Failed to update container app${NC}"
    exit 1
fi
echo -e "${GREEN}Container app updated${NC}"
echo
#endregion

#region Restart revision
echo -e "${BLUE}Restarting revision...${NC}"
revision=$(az containerapp revision list --name "$appName" --resource-group "$rg" --query '[0].name' -o tsv)
if [[ -n "$revision" ]]; then
    az containerapp revision restart --name "$appName" --resource-group "$rg" --revision "$revision"
    echo -e "${GREEN}Revision restarted: ${revision}${NC}"
fi
#endregion

echo
echo -e "${GREEN}Deploy completed successfully!${NC}"
echo "   Image: $imageName"
echo
