#!/bin/bash
# Check SAFE transaction status

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source common utilities
source "$SCRIPT_DIR/common.sh"

# Change to project root
cd "$PROJECT_ROOT"

# Check environment variables
check_env

# Usage: ./check_tx.sh <safe_tx_hash>
if [ $# -lt 1 ]; then
    print_error "Usage: $0 <safe_tx_hash>"
    print_error "Example: $0 0x123..."
    exit 1
fi

SAFE_TX_HASH=$1

print_info "Checking transaction status"
print_info "Safe Transaction Hash: $SAFE_TX_HASH"

# Check status
if check_tx_status "$SAFE_TX_HASH"; then
    print_info "Transaction executed successfully!"
    exit 0
else
    print_warn "Transaction is pending"
    exit 1
fi

