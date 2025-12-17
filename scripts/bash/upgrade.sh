#!/bin/bash
# Upgrade AlephAVS via SAFE multisig

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source common utilities
source "$SCRIPT_DIR/common.sh"

# Change to project root
cd "$PROJECT_ROOT"

# Check environment variables
check_env

# Load AlephAVS proxy address
ALEPH_AVS_ADDRESS="${ALEPH_AVS_ADDRESS:-}"
if [ -z "$ALEPH_AVS_ADDRESS" ]; then
    # Try to load from deployments file
    if [ -f "deployments/$CHAIN_ID.json" ]; then
        ALEPH_AVS_ADDRESS=$(jq -r '.alephAVSProxyAddress // .alephAVS // empty' "deployments/$CHAIN_ID.json")
    fi
    
    if [ -z "$ALEPH_AVS_ADDRESS" ]; then
        print_error "ALEPH_AVS_ADDRESS not set. Please set it in .env or deployments/$CHAIN_ID.json"
        exit 1
    fi
fi

print_info "Upgrading AlephAVS via SAFE multisig"
print_info "SAFE Address: $SAFE_ADDRESS"
print_info "AlephAVS Proxy: $ALEPH_AVS_ADDRESS"
print_info "Chain ID: $CHAIN_ID"

# First, deploy the implementation contract on-chain (required before upgrade)
# The ERC1967InvalidImplementation error occurs when the implementation has no code on-chain
# Make sure ALEPH_AVS_IMPL_ADDRESS is not set so we deploy a new implementation
unset ALEPH_AVS_IMPL_ADDRESS
print_info "Deploying implementation contract on-chain..."
DEPLOY_OUTPUT=$(forge script script/UpgradeAlephAVS.s.sol:UpgradeAlephAVS \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --verify \
    --skip-simulation 2>&1)

# Extract implementation address from deployment
IMPL_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oE "AlephAVS Implementation deployed at: 0x[0-9a-fA-F]+" | grep -oE "0x[0-9a-fA-F]+" | tail -1)

if [ -z "$IMPL_ADDRESS" ]; then
    print_error "Failed to extract implementation address from deployment"
    print_error "Deployment output:"
    echo "$DEPLOY_OUTPUT" | tail -30
    exit 1
fi

print_info "Implementation deployed at: $IMPL_ADDRESS"

# Wait for the deployment transaction to be mined and verify implementation has code
print_info "Waiting for deployment transaction to be mined..."
MAX_WAIT=60
WAITED=0
CODE_SIZE=0
while [ $WAITED -lt $MAX_WAIT ]; do
    CODE_SIZE=$(cast code "$IMPL_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null | wc -c | tr -d ' ')
    if [ "$CODE_SIZE" -gt 10 ]; then
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    echo -n "."
done
echo ""

# Verify implementation has code on-chain (prevents ERC1967InvalidImplementation error)
# Expected code size for AlephAVS is around 48,000+ bytes
MIN_EXPECTED_SIZE=40000
if [ "$CODE_SIZE" -lt 10 ]; then
    print_error "Implementation contract has no code on-chain after waiting ${WAITED}s."
    print_error "Code size: $CODE_SIZE bytes"
    print_error "Address: $IMPL_ADDRESS"
    print_error "This will cause ERC1967InvalidImplementation error during upgrade."
    print_error "The deployment transaction may still be pending. Check recent transactions."
    exit 1
elif [ "$CODE_SIZE" -lt "$MIN_EXPECTED_SIZE" ]; then
    print_error "Implementation contract code size is too small: $CODE_SIZE bytes"
    print_error "Expected at least $MIN_EXPECTED_SIZE bytes for AlephAVS implementation"
    print_error "Address: $IMPL_ADDRESS"
    print_error "This will cause ERC1967InvalidImplementation error during upgrade."
    print_error "The contract may not have deployed correctly or is the wrong contract."
    exit 1
fi
print_info "Implementation verified on-chain (code size: $CODE_SIZE bytes)"

# Now generate transaction data for the upgrade (implementation is already deployed)
# Extract ProxyAdmin address first
PROXY_ADMIN_ADDRESS=$(source .env 2>/dev/null && forge script script/UpgradeAlephAVS.s.sol:UpgradeAlephAVS --rpc-url "$RPC_URL" 2>&1 | grep -oE 'ProxyAdmin address: 0x[0-9a-fA-F]+' | head -1 | sed 's/ProxyAdmin address: //' || echo "")
if [ -z "$PROXY_ADMIN_ADDRESS" ]; then
    print_error "Could not extract ProxyAdmin address from script output"
    exit 1
fi

# Generate transaction data directly using cast (more reliable than script simulation)
# This avoids issues with Foundry backend when using provided implementation address
print_info "Generating upgrade transaction data..."
TX_DATA=$(cast calldata "upgradeAndCall(address,address,bytes)" "$ALEPH_AVS_ADDRESS" "$IMPL_ADDRESS" "0x")

if [ -z "$TX_DATA" ] || [ "$TX_DATA" = "null" ] || [ "$TX_DATA" = "0x" ]; then
    print_error "Failed to generate transaction data"
    print_error "Please ensure:"
    print_error "  1. All required environment variables are set"
    print_error "  2. The Foundry script compiles successfully: forge build"
    print_error "  3. ALEPH_AVS_ADDRESS is set correctly"
    exit 1
fi

# Extract ProxyAdmin address from script output (transaction goes to ProxyAdmin, not proxy)
# We already ran the script above, so extract from that output
PROXY_ADMIN_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oE 'ProxyAdmin address: 0x[0-9a-fA-F]+' | head -1 | sed 's/ProxyAdmin address: //' || echo "")
if [ -z "$PROXY_ADMIN_ADDRESS" ]; then
    # Fallback: run script again just to get ProxyAdmin address
    PROXY_ADMIN_ADDRESS=$(source .env 2>/dev/null && forge script script/UpgradeAlephAVS.s.sol:UpgradeAlephAVS --rpc-url "$RPC_URL" 2>&1 | grep -oE 'ProxyAdmin address: 0x[0-9a-fA-F]+' | head -1 | sed 's/ProxyAdmin address: //' || echo "")
fi
if [ -z "$PROXY_ADMIN_ADDRESS" ]; then
    print_error "Could not extract ProxyAdmin address from script output"
    exit 1
fi

print_info "ProxyAdmin address: $PROXY_ADMIN_ADDRESS"

# Submit to SAFE (transaction goes to ProxyAdmin.upgradeAndCall)
SAFE_TX_HASH=$(submit_to_safe "$PROXY_ADMIN_ADDRESS" "$TX_DATA" "0" "0")

if [ -n "$SAFE_TX_HASH" ]; then
    print_info "Upgrade transaction submitted to SAFE"
    print_info "Safe Transaction Hash: $SAFE_TX_HASH"
    print_info ""
    print_info "Next steps:"
    print_info "1. Sign the transaction in SAFE"
    print_info "2. Execute the transaction once threshold is met"
    print_info "3. Check status with: ./scripts/bash/check_tx.sh $SAFE_TX_HASH"
else
    print_error "Failed to submit transaction"
    exit 1
fi

