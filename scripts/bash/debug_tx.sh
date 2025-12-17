#!/bin/bash
# Debug a failed transaction to get the exact error

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source common utilities
source "$SCRIPT_DIR/common.sh"

cd "$PROJECT_ROOT"

# Check environment variables
check_env

if [ $# -lt 1 ]; then
    print_error "Usage: $0 <transaction_hash>"
    print_error "Example: $0 0x123..."
    exit 1
fi

TX_HASH=$1
RPC_URL=$(grep "^RPC_URL=" .env 2>/dev/null | cut -d'=' -f2- | tr -d '"' | head -1)

if [ -z "$RPC_URL" ]; then
    print_error "RPC_URL not found in .env"
    exit 1
fi

print_info "Debugging transaction: $TX_HASH"
print_info ""

# Get transaction receipt
print_info "Getting transaction receipt..."
RECEIPT=$(cast receipt "$TX_HASH" --rpc-url "$RPC_URL" 2>&1)

if echo "$RECEIPT" | grep -q "not found"; then
    print_error "Transaction not found. It may still be pending."
    exit 1
fi

# Check if transaction failed
STATUS=$(echo "$RECEIPT" | grep -E "status.*(0|1)" | head -1 || echo "")
if echo "$STATUS" | grep -q "status.*0"; then
    print_error "Transaction FAILED!"
    print_info ""
    
    # Try to get revert reason
    print_info "Attempting to get revert reason..."
    REVERT_REASON=$(cast receipt "$TX_HASH" --rpc-url "$RPC_URL" 2>&1 | grep -i "revert\|error\|reason" || echo "")
    
    if [ -n "$REVERT_REASON" ]; then
        print_error "Revert reason:"
        echo "$REVERT_REASON"
    fi
    
    # Try to trace the transaction
    print_info ""
    print_info "Tracing transaction (this may take a moment)..."
    cast run "$TX_HASH" --rpc-url "$RPC_URL" 2>&1 | tail -50 || print_warn "Could not trace transaction"
    
else
    print_info "Transaction succeeded!"
fi

