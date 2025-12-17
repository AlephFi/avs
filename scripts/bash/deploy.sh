#!/bin/bash
# Deploy AlephAVS via SAFE multisig

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source common utilities
source "$SCRIPT_DIR/common.sh"

# Change to project root
cd "$PROJECT_ROOT"

# Check environment variables
check_env

print_info "Deploying AlephAVS"
print_info "SAFE Address: $SAFE_ADDRESS"
print_info "Chain ID: $CHAIN_ID"
print_info "RPC URL: $RPC_URL"
print_info ""

print_warn "Note: Deployment creates new contracts (CREATE transactions)"
print_warn "SAFE multisig cannot directly create contracts"
print_warn "This script will deploy using forge script, then you can transfer ownership to SAFE"
print_info ""

# Run the deployment script
SCRIPT_PATH="script/DeployAlephAVS.s.sol:DeployAlephAVS"

print_info "Running deployment script: $SCRIPT_PATH"
print_info "This may take a few minutes..."

if forge script "$SCRIPT_PATH" \
    --rpc-url "$RPC_URL" \
    --sig "run()" \
    --broadcast; then
    
    print_info ""
    print_info "Deployment completed successfully!"
    print_info ""
    
    # Try to load deployment info
    if [ -f "deployments/$CHAIN_ID.json" ]; then
        ALEPH_AVS_PROXY=$(jq -r '.alephAVSProxyAddress // .alephAVS // empty' "deployments/$CHAIN_ID.json")
        PROXY_ADMIN=$(jq -r '.proxyAdmin // empty' "deployments/$CHAIN_ID.json")
        OWNER=$(jq -r '.owner // empty' "deployments/$CHAIN_ID.json")
        
        if [ -n "$ALEPH_AVS_PROXY" ]; then
            print_info "Deployed contracts:"
            print_info "  AlephAVS Proxy: $ALEPH_AVS_PROXY"
            if [ -n "$PROXY_ADMIN" ]; then
                print_info "  ProxyAdmin: $PROXY_ADMIN"
            fi
            if [ -n "$OWNER" ]; then
                print_info "  Current Owner: $OWNER"
            fi
            print_info ""
        fi
    fi
    
    print_info "Next steps:"
    print_info "1. Verify the deployment on block explorer"
    print_info "2. Transfer ProxyAdmin ownership to SAFE if needed:"
    print_info "   ./scripts/bash/submit_tx.sh <PROXY_ADMIN> \"transferOwnership(address)\" $SAFE_ADDRESS"
    print_info "3. Or use upgrade.sh for future upgrades (requires SAFE to be owner)"
    
else
    print_error "Deployment failed!"
    print_error "Please check the error messages above"
    exit 1
fi

