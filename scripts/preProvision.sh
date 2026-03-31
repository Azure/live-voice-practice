#!/bin/sh

set -eu

YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
INFRA_DIR="$PROJECT_ROOT/infra"
MAIN_BICEP="$INFRA_DIR/main.bicep"

echo "${CYAN}Initializing infrastructure submodule...${NC}"
git -C "$PROJECT_ROOT" submodule update --init --recursive 2>/dev/null || true

# Fallback: when the repo was scaffolded via 'azd init' (ZIP download), the git
# index has no submodule gitlink entries, so 'git submodule update' silently does
# nothing and infra/ remains empty.  Detect that case and clone the landing-zone
# repo directly.
if [ ! -f "$MAIN_BICEP" ]; then
    echo "${CYAN}Submodule content not found. Cloning infra repo directly (azd init scenario)...${NC}"

    GITMODULES="$PROJECT_ROOT/.gitmodules"
    INFRA_URL=""
    INFRA_REF="main"  # safe default
    if [ -f "$GITMODULES" ]; then
        INFRA_URL=$(grep -m1 'url\s*=' "$GITMODULES" | sed 's/.*=\s*//' | tr -d '[:space:]')
        BRANCH_LINE=$(grep -m1 'branch\s*=' "$GITMODULES" | sed 's/.*=\s*//' | tr -d '[:space:]')
        if [ -n "$BRANCH_LINE" ]; then
            INFRA_REF="$BRANCH_LINE"
        fi
    fi
    if [ -z "$INFRA_URL" ]; then
        echo "${YELLOW}Error: Could not determine infra repository URL from .gitmodules.${NC}"
        exit 1
    fi
    echo "${CYAN}  Infra repo: $INFRA_URL @ $INFRA_REF (from .gitmodules)${NC}"

    # Remove the empty infra directory and clone at the correct tag
    if [ -d "$INFRA_DIR" ]; then rm -rf "$INFRA_DIR"; fi
    git -c advice.detachedHead=false clone --depth 1 --branch "$INFRA_REF" "$INFRA_URL" "$INFRA_DIR"
    if [ $? -ne 0 ]; then
        echo "${YELLOW}Error: Failed to clone infra repository ($INFRA_URL @ $INFRA_REF).${NC}"
        exit 1
    fi
    echo "${CYAN}Infrastructure submodule cloned successfully.${NC}"
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
