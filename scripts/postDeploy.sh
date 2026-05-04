#!/usr/bin/env bash
#
# postDeploy.sh - Post-deploy smoke test for Live Voice Practice (POSIX).
# See scripts/postDeploy.ps1 for design notes.

set -uo pipefail

YELLOW='\033[0;33m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo
echo -e "${BLUE}[postDeploy] Running smoke test...${NC}"

envValues="$(azd env get-values 2>/dev/null || true)"
get_env_val() {
    local name="$1"
    local proc_val
    proc_val="$(printenv "$name" 2>/dev/null || true)"
    if [[ -n "$proc_val" ]]; then
        echo "${proc_val%\"}" | sed 's/^"//'
        return 0
    fi
    echo "$envValues" | sed -n "s/^${name}=\"\\?\\([^\"]*\\)\"\\?.*/\\1/p" | head -n1
}

rg="$(get_env_val AZURE_RESOURCE_GROUP)"
networkIsolation="$(get_env_val NETWORK_ISOLATION)"
skip="$(get_env_val SKIP_POSTDEPLOY_SMOKE_TEST)"

if [[ "$skip" == "true" ]]; then
    echo -e "${YELLOW}[postDeploy] SKIP_POSTDEPLOY_SMOKE_TEST=true - skipping${NC}"
    exit 0
fi
if [[ -z "$rg" ]]; then
    echo -e "${YELLOW}[postDeploy] AZURE_RESOURCE_GROUP not set; skipping${NC}"
    exit 0
fi

appName="$(get_env_val VOICELAB_APP_NAME)"
if [[ -z "$appName" ]]; then
    appName="$(az containerapp list -g "$rg" --query "[?contains(name, 'voicelab')].name | [0]" -o tsv 2>/dev/null || true)"
    [[ -z "$appName" ]] && appName="$(az containerapp list -g "$rg" --query '[0].name' -o tsv 2>/dev/null || true)"
fi
if [[ -z "$appName" ]]; then
    echo -e "${YELLOW}[postDeploy] Container App not found; skipping${NC}"
    exit 0
fi

fqdn="$(az containerapp show --name "$appName" --resource-group "$rg" --query 'properties.configuration.ingress.fqdn' -o tsv 2>/dev/null || true)"
if [[ -z "$fqdn" ]]; then
    echo -e "${YELLOW}[postDeploy] Could not resolve FQDN; skipping${NC}"
    exit 0
fi

healthUrl="https://${fqdn}/api/health"

niEnabled=false
case "$networkIsolation" in
    true|True|1|yes|YES) niEnabled=true ;;
esac

# Cert revocation servers are commonly blocked by the AILZ firewall;
# pass --ssl-no-revoke so curl on Windows hosts skips OCSP/CRL.
# On Linux/macOS curl, this flag is a no-op (always allowed).
CURL_REVOKE_FLAG="--ssl-no-revoke"

classify_health() {
    local body="$1"
    if [[ -z "$body" ]]; then
        echo -e "${RED}[postDeploy] Empty response from $healthUrl${NC}"
        return 2
    fi
    local status
    status="$(echo "$body" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print((d.get("checks",{}).get("scenarios",{}) or d).get("status",""))
except Exception:
    pass' 2>/dev/null || true)"

    case "$status" in
        ok)
            local count
            count="$(echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("checks",{}).get("scenarios",{}).get("scenarios_loaded","?"))' 2>/dev/null || echo '?')"
            echo -e "${GREEN}[postDeploy] Health OK - scenarios_loaded=${count}${NC}"
            return 0
            ;;
        degraded_no_cosmos|degraded_config_missing)
            echo -e "${YELLOW}[postDeploy] Health degraded ($status) - non-blocking${NC}"
            echo "  body: $body"
            return 0
            ;;
        degraded_auth_failure)
            echo -e "${RED}[postDeploy] Health DEGRADED (auth failure) - Cosmos unreachable via managed identity${NC}"
            echo "  body: $body"
            echo
            echo -e "${RED}  Likely the Container Apps IMDS sidecar issue. Try:${NC}"
            echo -e "${RED}    az containerapp revision restart -g $rg -n $appName --revision <latest>${NC}"
            return 1
            ;;
        *)
            echo -e "${YELLOW}[postDeploy] Unknown status '${status}' - non-blocking${NC}"
            echo "  body: $body"
            return 0
            ;;
    esac
}

direct_probe() {
    local url="$1"
    local body=""
    for i in 1 2 3 4 5 6; do
        local response
        response="$(curl -sS $CURL_REVOKE_FLAG -m 30 -w '\n__HTTP_CODE__:%{http_code}' "$url" 2>&1 || true)"
        local http_code
        http_code="$(echo "$response" | grep -oE '__HTTP_CODE__:[0-9]+$' | cut -d: -f2)"
        body="$(echo "$response" | sed 's/__HTTP_CODE__:[0-9]*$//')"
        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]] && [[ -n "$body" ]]; then
            printf '%s' "$body"
            return 0
        fi
        echo -e "${YELLOW}  attempt $i/6 failed (http=$http_code); retrying in 10s...${NC}" 1>&2
        sleep 10
    done
    return 1
}

jumpbox_probe() {
    local rg_="$1" fqdn_="$2"
    local vmName
    vmName="$(get_env_val TEST_VM_NAME)"
    if [[ -z "$vmName" ]]; then
        vmName="$(az vm list -g "$rg_" --query "[?contains(name, 'testvm') || contains(name, 'jumpbox')].name | [0]" -o tsv 2>/dev/null || true)"
    fi
    if [[ -z "$vmName" ]]; then
        echo -e "${YELLOW}[postDeploy] No jumpbox VM found; cannot probe inside VNet${NC}" 1>&2
        return 1
    fi
    if [[ -n "${HOSTNAME:-}" ]] && [[ "$vmName" == "$HOSTNAME"* ]]; then
        echo -e "${YELLOW}[postDeploy] We appear to be the jumpbox; direct probe should have worked${NC}" 1>&2
        return 1
    fi

    echo -e "${BLUE}[postDeploy] Falling back to jumpbox Run-Command via $vmName${NC}" 1>&2
    local vmState startedByUs=false
    vmState="$(az vm get-instance-view -g "$rg_" -n "$vmName" --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv 2>/dev/null || true)"
    if [[ "$vmState" != "PowerState/running" ]]; then
        echo -e "${YELLOW}[postDeploy] Starting jumpbox temporarily...${NC}" 1>&2
        az vm start -g "$rg_" -n "$vmName" >/dev/null 2>&1 || true
        startedByUs=true
    fi
    cleanup() {
        if [[ "$startedByUs" == "true" ]]; then
            az vm deallocate -g "$rg_" -n "$vmName" --no-wait >/dev/null 2>&1 || true
        fi
    }
    trap cleanup EXIT

    # The jumpbox is Windows -> use RunPowerShellScript with curl.exe + --ssl-no-revoke
    local probeScript
    probeScript=$(cat <<EOF
for (\$i = 1; \$i -le 6; \$i++) {
    \$out = curl.exe -sS --ssl-no-revoke -m 30 -w '__HTTP__%{http_code}' 'https://${fqdn_}/api/health' 2>&1
    if (\$out -match '__HTTP__([0-9]{3})$') {
        \$code = \$Matches[1]
        \$body = \$out -replace '__HTTP__[0-9]{3}$',''
        if (\$code -match '^2[0-9][0-9]$') { Write-Output \$body; exit 0 }
    }
    Start-Sleep -Seconds 10
}
Write-Output 'PROBE_FAILED'
exit 1
EOF
)
    local tmp
    tmp="$(mktemp)"
    printf '%s' "$probeScript" > "$tmp"
    local rcOutput
    rcOutput="$(az vm run-command invoke -g "$rg_" -n "$vmName" --command-id RunPowerShellScript --scripts "@$tmp" --query 'value[0].message' -o tsv 2>/dev/null || true)"
    rm -f "$tmp"
    printf '%s' "$rcOutput"
    return 0
}

echo -e "${BLUE}[postDeploy] Probing ${healthUrl} ...${NC}"
body=""
if body="$(direct_probe "$healthUrl")" && [[ -n "$body" ]]; then
    :
elif [[ "$niEnabled" == "true" ]]; then
    echo -e "${YELLOW}[postDeploy] Direct probe failed; trying jumpbox fallback (NETWORK_ISOLATION=true)${NC}"
    body="$(jumpbox_probe "$rg" "$fqdn" || true)"
fi

if [[ -z "$body" ]]; then
    echo -e "${RED}[postDeploy] Could not reach ${healthUrl}${NC}"
    echo "  Tail of Container App logs:"
    az containerapp logs show -n "$appName" -g "$rg" --tail 50 2>/dev/null || true
    exit 1
fi

classify_health "$body"
exit $?
