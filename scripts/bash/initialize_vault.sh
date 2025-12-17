#!/bin/bash
# Initialize vault via SAFE multisig

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source common utilities
source "$SCRIPT_DIR/common.sh"

# Change to project root
cd "$PROJECT_ROOT"

# Check environment variables
check_env

# Required parameters
ALEPH_AVS_ADDRESS="${ALEPH_AVS_ADDRESS:-}"
VAULT_ADDRESS="${ALEPH_VAULT_ADDRESS:-${VAULT_ADDRESS:-}}"
CLASS_ID="${CLASS_ID:-0}"
LST_STRATEGY_ADDRESS="${LST_STRATEGY_ADDRESS:-}"

if [ -z "$ALEPH_AVS_ADDRESS" ]; then
    # Try to load from deployments file
    if [ -f "deployments/$CHAIN_ID.json" ]; then
        ALEPH_AVS_ADDRESS=$(jq -r '.alephAVS // .alephAVSProxyAddress // empty' "deployments/$CHAIN_ID.json")
    fi
    
    if [ -z "$ALEPH_AVS_ADDRESS" ]; then
        print_error "ALEPH_AVS_ADDRESS not set. Please set it in .env or deployments/$CHAIN_ID.json"
        exit 1
    fi
fi

if [ -z "$VAULT_ADDRESS" ]; then
    print_error "ALEPH_VAULT_ADDRESS (or VAULT_ADDRESS) not set. Please set it in .env:"
    print_error "  export ALEPH_VAULT_ADDRESS=0x..."
    exit 1
fi

# Get LST strategy address
if [ -z "$LST_STRATEGY_ADDRESS" ]; then
    # Try to load from config/deployment.json
    if [ -f "config/deployment.json" ]; then
        LST_STRATEGY_ADDRESS=$(jq -r ".\"$CHAIN_ID\".strategy // empty" "config/deployment.json")
    fi
    
    if [ -z "$LST_STRATEGY_ADDRESS" ] || [ "$LST_STRATEGY_ADDRESS" = "null" ] || [ "$LST_STRATEGY_ADDRESS" = "0x0000000000000000000000000000000000000000" ]; then
        print_error "LST_STRATEGY_ADDRESS not set. Please set it in .env or config/deployment.json:"
        print_error "  export LST_STRATEGY_ADDRESS=0x..."
        print_error "  or add 'strategy' field to config/deployment.json for chain ID $CHAIN_ID"
        exit 1
    fi
fi

print_info "Initializing vault via SAFE multisig"
print_info "SAFE Address: $SAFE_ADDRESS"
print_info "AlephAVS: $ALEPH_AVS_ADDRESS"
print_info "Vault: $VAULT_ADDRESS (ALEPH_VAULT_ADDRESS)"
print_info "Class ID: $CLASS_ID"
print_info "LST Strategy: $LST_STRATEGY_ADDRESS"
print_info ""

# Pre-flight validation
print_info "Running pre-flight checks..."
print_info ""

# Check if Safe has OWNER role
print_info "Checking if Safe has OWNER role..."
OWNER_ROLE=$(cast call "$ALEPH_AVS_ADDRESS" "OWNER()(bytes32)" --rpc-url "$RPC_URL" 2>/dev/null | grep -v "Warning:" || echo "")
if [ -n "$OWNER_ROLE" ] && [ "$OWNER_ROLE" != "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
    HAS_OWNER_ROLE=$(cast call "$ALEPH_AVS_ADDRESS" "hasRole(bytes32,address)(bool)" "$OWNER_ROLE" "$SAFE_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null | grep -v "Warning:" || echo "false")
    if [ "$HAS_OWNER_ROLE" != "true" ]; then
        print_error "SAFE_ADDRESS ($SAFE_ADDRESS) does NOT have the OWNER role!"
        print_error "The initializeVault function requires the OWNER role."
        print_error "Please grant the OWNER role to the Safe address first."
        exit 1
    else
        print_info "✓ Safe has OWNER role"
    fi
else
    print_warn "Could not verify OWNER role (this is okay if contract uses different access control)"
fi

# Check if vault is already initialized
print_info "Checking if vault is already initialized..."
EXISTING_SLASHED_STRATEGY=$(cast call "$ALEPH_AVS_ADDRESS" "vaultToSlashedStrategy(address)(address)" "$VAULT_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null | grep -v "Warning:" || echo "")
if [ -n "$EXISTING_SLASHED_STRATEGY" ] && [ "$EXISTING_SLASHED_STRATEGY" != "0x0000000000000000000000000000000000000000" ]; then
    print_error "Vault is already initialized!"
    print_error "Existing slashed strategy: $EXISTING_SLASHED_STRATEGY"
    print_error "The transaction will revert with VaultAlreadyInitialized"
    exit 1
else
    print_info "✓ Vault is not yet initialized"
fi

# Check for orphaned tokens/strategies from previous failed transactions
print_info "Checking for orphaned tokens/strategies..."
ERC20_FACTORY=$(cast call "$ALEPH_AVS_ADDRESS" "erc20Factory()(address)" --rpc-url "$RPC_URL" 2>/dev/null | grep -v "Warning:" || echo "")
if [ -n "$ERC20_FACTORY" ] && [ "$ERC20_FACTORY" != "0x0000000000000000000000000000000000000000" ]; then
    TOKEN_COUNT=$(cast call "$ERC20_FACTORY" "getTokenCount()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null | grep -v "Warning:" || echo "0")
    if [ "$TOKEN_COUNT" -gt 0 ]; then
        print_warn "Found $TOKEN_COUNT existing token(s) in factory"
        print_warn "If a previous transaction partially succeeded, you may need to clean up orphaned tokens"
        print_warn "This could cause StrategyAlreadyExists errors if the same token is reused"
    fi
fi

print_info ""

# Generate transaction data
# initializeVault(uint8 _classId, address _vault, IStrategy _lstStrategy)
print_info "Encoding function call..."
print_info "  Function: initializeVault(uint8,address,address)"
print_info "  Args: classId=$CLASS_ID, vault=$VAULT_ADDRESS, strategy=$LST_STRATEGY_ADDRESS"

TX_DATA=$(encode_function_call \
    "$ALEPH_AVS_ADDRESS" \
    "initializeVault(uint8,address,address)" \
    "$CLASS_ID" \
    "$VAULT_ADDRESS" \
    "$LST_STRATEGY_ADDRESS")

if [ -z "$TX_DATA" ]; then
    print_error "Failed to encode function call"
    print_error "Please check:"
    print_error "  1. All addresses are valid (not zero address)"
    print_error "  2. Function signature is correct"
    print_error "  3. Arguments are in the correct format"
    exit 1
fi

print_info "✓ Transaction data encoded successfully"
print_info "  Calldata: ${TX_DATA:0:50}..."
print_info ""

# Submit to SAFE
print_info "Submitting to SAFE API..."
SAFE_TX_HASH=$(submit_to_safe "$ALEPH_AVS_ADDRESS" "$TX_DATA" "0" "0")

if [ -n "$SAFE_TX_HASH" ]; then
    print_info "Initialize vault transaction submitted to SAFE"
    print_info "Safe Transaction Hash: $SAFE_TX_HASH"
    print_info ""
    print_info "Next steps:"
    print_info "1. Sign the transaction in SAFE"
    print_info "2. Execute the transaction once threshold is met"
    print_info "3. Wait for execution (or run: ./scripts/bash/check_tx.sh $SAFE_TX_HASH)"
    print_info ""
    
    # Ask if user wants to wait and verify
    read -p "Wait for transaction execution and verify contracts? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Waiting for transaction execution..."
        if wait_for_execution "$SAFE_TX_HASH" 600; then
            print_info ""
            print_info "Transaction executed! Verifying newly created contracts..."
            print_info ""
            
            # Get the slashed token and strategy addresses
            SLASHED_STRATEGY=$(cast call "$ALEPH_AVS_ADDRESS" "vaultToSlashedStrategy(address)(address)" "$VAULT_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null | grep -v "Warning:" || echo "")
            
            if [ -n "$SLASHED_STRATEGY" ] && [ "$SLASHED_STRATEGY" != "0x0000000000000000000000000000000000000000" ]; then
                print_info "Found slashed strategy: $SLASHED_STRATEGY"
                
                # Get the slashed token address from the strategy
                SLASHED_TOKEN=$(cast call "$SLASHED_STRATEGY" "underlyingToken()(address)" --rpc-url "$RPC_URL" 2>/dev/null | grep -v "Warning:" || echo "")
                
                if [ -n "$SLASHED_TOKEN" ] && [ "$SLASHED_TOKEN" != "0x0000000000000000000000000000000000000000" ]; then
                    print_info "Found slashed token: $SLASHED_TOKEN"
                    print_info ""
                    
                    # Verify the ERC20Token contract
                    # Note: The strategy is a BeaconProxy from EigenLayer, which should already be verified
                    print_info "Verifying slashed token (ERC20Token)..."
                    # Get constructor args if needed (ERC20Token constructor takes: name, symbol, decimals, owner)
                    # Since we can't easily get constructor args from on-chain, we'll verify without them
                    # The verifier should be able to match the bytecode
                    verify_contract "$SLASHED_TOKEN" "src/ERC20Token.sol:ERC20Token" || print_warn "Verification failed, but contract is deployed"
                    
                    print_info ""
                    print_info "Verification complete!"
                    print_info "  Slashed Token: $SLASHED_TOKEN"
                    print_info "  Slashed Strategy: $SLASHED_STRATEGY"
                else
                    print_warn "Could not retrieve slashed token address"
                fi
            else
                print_warn "Could not retrieve slashed strategy address. Transaction may not have completed yet."
            fi
        else
            print_warn "Transaction not executed yet. You can verify contracts later with:"
            print_warn "  ./scripts/bash/check_tx.sh $SAFE_TX_HASH"
        fi
    else
        print_info "Skipping automatic verification."
        print_info "To verify manually after execution:"
        print_info "  1. Get slashed strategy: cast call $ALEPH_AVS_ADDRESS \"vaultToSlashedStrategy(address)(address)\" $VAULT_ADDRESS --rpc-url \$RPC_URL"
        print_info "  2. Get slashed token: cast call <slashed_strategy> \"underlyingToken()(address)\" --rpc-url \$RPC_URL"
        print_info "  3. Verify: forge verify-contract <slashed_token> src/ERC20Token.sol:ERC20Token --chain $CHAIN_ID --etherscan-api-key \$ETHERSCAN_API_KEY"
    fi
else
    print_error "Failed to submit transaction"
    exit 1
fi

