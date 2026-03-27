#!/bin/sh

set -eu

YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
INFRA_DIR="$PROJECT_ROOT/infra"

echo "${CYAN}Initializing infrastructure submodule...${NC}"
git -C "$PROJECT_ROOT" submodule update --init --recursive
if [ $? -ne 0 ]; then
    echo "${YELLOW}Warning: Failed to initialize submodule. If infra folder is empty, provisioning will fail.${NC}"
fi

for FILE_NAME in manifest.json main.parameters.json; do
    SRC="$PROJECT_ROOT/$FILE_NAME"
    DST="$INFRA_DIR/$FILE_NAME"
    if [ -f "$SRC" ]; then
        echo "${CYAN}Applying project $FILE_NAME to infra...${NC}"
        cp -f "$SRC" "$DST"
    fi
done

if [ "${AZURE_SKIP_NETWORK_ISOLATION_WARNING:-}" = "1" ] || [ "${AZURE_SKIP_NETWORK_ISOLATION_WARNING:-}" = "true" ] || [ "${AZURE_SKIP_NETWORK_ISOLATION_WARNING:-}" = "t" ]; then
    exit 0
fi

NETWORK_ISOLATION_VALUE="${AZURE_NETWORK_ISOLATION:-${NETWORK_ISOLATION:-false}}"

if [ "$NETWORK_ISOLATION_VALUE" = "1" ] || [ "$NETWORK_ISOLATION_VALUE" = "true" ] || [ "$NETWORK_ISOLATION_VALUE" = "t" ]; then
    echo "${YELLOW}Warning!${NC} Network isolation is enabled."
    echo " - After provisioning, continue deployment from within private network access (VPN/Jumpbox)."

    echo -n "${BLUE}?${NC} Continue with Zero Trust provisioning? [Y/n]: "
    read confirmation

    if [ "$confirmation" != "Y" ] && [ "$confirmation" != "y" ] && [ -n "$confirmation" ]; then
        exit 1
    fi
fi

exit 0
