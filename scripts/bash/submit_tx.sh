#!/bin/bash
# Generic script to submit any transaction to SAFE multisig

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source common utilities
source "$SCRIPT_DIR/common.sh"

# Change to project root
cd "$PROJECT_ROOT"

# Check environment variables
check_env

# Usage: ./submit_tx.sh <to> <function_signature> [args...]
# Example: ./submit_tx.sh 0x123... "initializeVault(uint8,address)" 0 0x456...

if [ $# -lt 2 ]; then
    print_error "Usage: $0 <to> <function_signature> [args...]"
    print_error "Example: $0 0x123... \"initializeVault(uint8,address)\" 0 0x456..."
    exit 1
fi

TO_ADDRESS=$1
FUNCTION_SIG=$2
shift 2
ARGS=("$@")

print_info "Submitting transaction to SAFE multisig"
print_info "SAFE Address: $SAFE_ADDRESS"
print_info "To: $TO_ADDRESS"
print_info "Function: $FUNCTION_SIG"
print_info "Args: ${ARGS[*]}"

# Encode function call
TX_DATA=$(encode_function_call "$TO_ADDRESS" "$FUNCTION_SIG" "${ARGS[@]}")

# Submit to SAFE
SAFE_TX_HASH=$(submit_to_safe "$TO_ADDRESS" "$TX_DATA" "0" "0")

if [ -n "$SAFE_TX_HASH" ]; then
    print_info "Transaction submitted to SAFE"
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

