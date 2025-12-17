#!/bin/bash
# Common utilities for SAFE multisig scripts

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load environment variables from .env file if it exists
if [ -f .env ]; then
    # Properly parse .env file, only exporting valid KEY=value pairs
    # This handles quoted values, spaces, and special characters correctly
    set -a
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Remove leading/trailing whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # Only process lines that match KEY=value pattern (KEY must start with letter or underscore)
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            export "$line"
        fi
    done < .env
    set +a
fi

# Default values
SAFE_ADDRESS="${SAFE_ADDRESS:-}"
RPC_URL="${RPC_URL:-}"
CHAIN_ID="${CHAIN_ID:-}"
SAFE_API_URL="${SAFE_API_URL:-}"

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if required environment variables are set
check_env() {
    local missing_vars=()
    
    if [ -z "$SAFE_ADDRESS" ]; then
        missing_vars+=("SAFE_ADDRESS")
    fi
    
    if [ -z "$RPC_URL" ]; then
        missing_vars+=("RPC_URL")
    fi
    
    if [ -z "$CHAIN_ID" ]; then
        missing_vars+=("CHAIN_ID")
    fi
    
    if [ ${#missing_vars[@]} -ne 0 ]; then
        print_error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        echo ""
        echo "Please set them in .env file or export them:"
        echo "  export SAFE_ADDRESS=0x..."
        echo "  export RPC_URL=https://..."
        echo "  export CHAIN_ID=1"
        exit 1
    fi
}

# Function to get SAFE API URL based on chain ID
get_safe_api_url() {
    case "$CHAIN_ID" in
        1)
            echo "https://safe-transaction-mainnet.safe.global"
            ;;
        11155111)
            echo "https://safe-transaction-sepolia.safe.global"
            ;;
        5)
            echo "https://safe-transaction-goerli.safe.global"
            ;;
        *)
            if [ -n "$SAFE_API_URL" ]; then
                echo "$SAFE_API_URL"
            else
                print_error "Unknown chain ID: $CHAIN_ID. Please set SAFE_API_URL manually."
                exit 1
            fi
            ;;
    esac
}

# Function to encode function call using cast
encode_function_call() {
    local contract_address=$1
    local function_signature=$2
    shift 2
    local args=("$@")
    
    # Note: contract_address is not used in calldata encoding, but kept for consistency
    # Filter out warnings and only get the actual calldata (lines starting with 0x)
    local calldata_result
    if [ ${#args[@]} -eq 0 ]; then
        calldata_result=$(cast calldata "$function_signature" 2>&1 | grep -E "^0x" | head -1)
    else
        calldata_result=$(cast calldata "$function_signature" "${args[@]}" 2>&1 | grep -E "^0x" | head -1)
    fi
    
    local exit_code=$?
    if [ $exit_code -ne 0 ] || [ -z "$calldata_result" ]; then
        print_error "Failed to encode function call: $function_signature"
        print_error "Exit code: $exit_code"
        print_error "Result: $calldata_result"
        return 1
    fi
    
    echo "$calldata_result"
}

# Function to simulate transaction
simulate_tx() {
    local to=$1
    local data=$2
    local value="${3:-0}"
    
    print_info "Simulating transaction..."
    forge script "$SCRIPT_PATH" \
        --rpc-url "$RPC_URL" \
        --sig "run()" \
        --broadcast \
        --skip-simulation false
}

# Function to generate transaction data from Foundry script
generate_tx_data() {
    local script_path=$1
    local function_name="${2:-run}"
    
    print_info "Generating transaction data from $script_path..."
    
    # Run script in simulation mode to get the transaction data
    # Redirect stderr to stdout to capture all output, but filter out non-JSON lines
    local forge_output
    local forge_exit_code
    
    # Use a temp file to capture output
    local temp_output=$(mktemp)
    
    # Run forge script and capture both exit code and output
    # Show progress indicator
    print_info "Running forge script (this may take a moment)..."
    
    if ! forge script "$script_path" \
        --rpc-url "$RPC_URL" \
        --sig "$function_name()" \
        --json > "$temp_output" 2>&1; then
        forge_exit_code=$?
        forge_output=$(cat "$temp_output")
        rm -f "$temp_output"
        
        print_error "Foundry script failed with exit code $forge_exit_code"
        print_error "Error output:"
        # Filter out JSON lines and show errors
        echo "$forge_output" | grep -v "^{" | grep -v "^\[" | head -20
        return 1
    fi
    
    forge_exit_code=0
    forge_output=$(cat "$temp_output")
    
    if [ $forge_exit_code -ne 0 ]; then
        print_error "Foundry script failed with exit code $forge_exit_code"
        print_error "Error output:"
        # Filter out JSON lines and show errors
        echo "$forge_output" | grep -v "^{" | grep -v "^\[" | head -20
        rm -f "$temp_output"
        return 1
    fi
    
    # Check if output contains valid JSON
    if ! echo "$forge_output" | jq -e '.' > /dev/null 2>&1; then
        print_error "Foundry script output is not valid JSON"
        print_error "Output:"
        echo "$forge_output" | head -30
        rm -f "$temp_output"
        return 1
    fi
    
    # Save valid JSON to temp file for parsing
    echo "$forge_output" > /tmp/tx_data.json
    
    # Try to extract transaction data from JSON first
    local tx_data=""
    if jq -e '.transactions[0].transaction.data' /tmp/tx_data.json > /dev/null 2>&1; then
        tx_data=$(jq -r '.transactions[0].transaction.data // empty' /tmp/tx_data.json)
    fi
    
    # If no transaction data in JSON (e.g., Safe contract scenario), extract from logs
    if [ -z "$tx_data" ] || [ "$tx_data" = "null" ]; then
        print_info "No transaction in JSON output, extracting from console logs..." >&2
        # Extract transaction data from JSON logs array (look for "Data: 0x..." in logs)
        # Handle multiple JSON objects in output by processing each line
        tx_data=$(cat /tmp/tx_data.json | jq -r 'if type == "array" then .[] else . end | select(.logs != null) | .logs[]? | select(contains("Data: 0x")) | match("Data: (0x[0-9a-fA-F]+)") | .captures[0].string' 2>/dev/null | head -1)
        
        # If jq extraction failed, try grep on raw output
        if [ -z "$tx_data" ] || [ "$tx_data" = "null" ]; then
            tx_data=$(echo "$forge_output" | grep -oE 'Data: 0x[0-9a-fA-F]+' | head -1 | sed 's/Data: //')
        fi
        
        if [ -z "$tx_data" ]; then
            print_error "Failed to extract transaction data from script output" >&2
            print_error "Available transactions: $(jq -r 'if type == "array" then .[0] else . end | .transactions | length // 0' /tmp/tx_data.json 2>/dev/null || echo '0')" >&2
            print_error "Script output (first 30 lines):" >&2
            cat /tmp/tx_data.json | head -30 >&2
            rm -f "$temp_output"
            return 1
        fi
    fi
    
    rm -f "$temp_output"
    
    if [ -z "$tx_data" ] || [ "$tx_data" = "null" ]; then
        print_error "Transaction data is empty or null"
        return 1
    fi
    
    echo "$tx_data"
}

# Function to submit transaction to SAFE
# Uses Safe SDK via Node.js helper script (like Aleph repository)
submit_to_safe() {
    local to=$1
    local data=$2
    local value="${3:-0}"
    local operation="${4:-0}"  # 0 = call, 1 = delegatecall (not used in Safe SDK approach)
    
    print_info "Submitting transaction to SAFE: $SAFE_ADDRESS"
    print_info "To: $to"
    print_info "Data length: ${#data} characters"
    print_info "Value: $value"
    
    # Check if PRIVATE_KEY is set (required for signing)
    if [ -z "$PRIVATE_KEY" ]; then
        print_error "PRIVATE_KEY is required to sign Safe transactions"
        print_error "Please set PRIVATE_KEY in your .env file"
        exit 1
    fi
    
    # Use the Node.js helper script to propose the transaction
    # This uses the Safe SDK like the Aleph repository does
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Capture output and exit code
    local safe_tx_hash_output
    # Run the script and capture both stdout and stderr, preserving exit code
    # Note: We need to temporarily disable set -e to capture the exit code
    set +e  # Temporarily disable exit on error to capture exit code
    safe_tx_hash_output=$("$script_dir/safe_propose.sh" "$to" "$data" "$value" 2>&1)
    local propose_exit_code=$?
    set -e  # Re-enable exit on error
    
    # Extract just the hash (filter out info messages)
    local safe_tx_hash=$(echo "$safe_tx_hash_output" | grep -E "^0x[a-fA-F0-9]{64}$" | tail -1)
    
    if [ $propose_exit_code -eq 0 ] && [ -n "$safe_tx_hash" ]; then
        print_info "Transaction proposed successfully!"
        print_info "Safe Transaction Hash: $safe_tx_hash"
        echo "$safe_tx_hash"
    else
        print_error "Failed to propose transaction (exit code: $propose_exit_code)"
        if [ -n "$safe_tx_hash_output" ]; then
            print_error "Output from safe_propose.sh:"
            # Output to stderr so it's visible even if stdout is being captured
            echo "$safe_tx_hash_output" >&2
        else
            print_error "No output from safe_propose.sh"
        fi
        exit 1
    fi
}

# Function to check transaction status
check_tx_status() {
    local safe_tx_hash=$1
    local safe_api_url=$(get_safe_api_url)
    
    # Try direct lookup first
    local response=$(curl -sL \
        "$safe_api_url/api/v1/multisig-transactions/$safe_tx_hash/")
    
    # If not found, try searching in Safe's transaction list
    if echo "$response" | jq -e '.detail' > /dev/null 2>&1 || [ -z "$response" ] || [ "$response" = "null" ]; then
        # Extract Safe address from the transaction hash context or use environment
        local safe_address="${SAFE_ADDRESS:-}"
        if [ -n "$safe_address" ]; then
            response=$(curl -sL \
                "$safe_api_url/api/v1/safes/$safe_address/multisig-transactions/?safe_tx_hash=$safe_tx_hash" | \
                jq '.results[0] // empty')
        fi
    fi
    
    if echo "$response" | jq -e '.isExecuted' > /dev/null 2>&1; then
        local is_executed=$(echo "$response" | jq -r '.isExecuted // "false"')
        local is_successful=$(echo "$response" | jq -r '.isSuccessful // "null"')
        local tx_hash=$(echo "$response" | jq -r '.txHash // "pending"')
        local confirmations=$(echo "$response" | jq -r '.confirmations | length // 0')
        
        if [ "$is_executed" = "true" ]; then
            # Check isSuccessful field explicitly
            if [ "$is_successful" = "false" ]; then
                print_error "Transaction executed but FAILED!"
                if [ "$tx_hash" != "null" ] && [ "$tx_hash" != "pending" ] && [ -n "$tx_hash" ]; then
                    print_error "On-chain Transaction Hash: $tx_hash"
                else
                    print_error "Transaction reverted (no on-chain tx hash - likely failed during execution)"
                fi
                print_error "This usually means the transaction reverted. Common causes:"
                print_error "  - ERC1967InvalidImplementation (implementation has no code)"
                print_error "  - Invalid parameters"
                print_error "  - Insufficient gas"
                print_error "Check the Safe UI for detailed error information."
                return 1
            elif [ "$is_successful" = "true" ]; then
                print_info "Transaction executed successfully!"
                print_info "Transaction Hash: $tx_hash"
                return 0
            else
                # isSuccessful is null but isExecuted is true
                # If txHash is null, it likely failed (reverted)
                if [ "$tx_hash" = "null" ] || [ "$tx_hash" = "pending" ] || [ -z "$tx_hash" ]; then
                    print_error "Transaction executed but likely FAILED (no on-chain tx hash)"
                    print_error "When isExecuted=true but txHash is null, the transaction usually reverted."
                    return 1
                else
                    print_info "Transaction executed (checking on-chain status...)"
                    print_info "Transaction Hash: $tx_hash"
                    return 0
                fi
            fi
        else
            print_warn "Transaction pending execution"
            print_info "Confirmations: $confirmations"
            return 1
        fi
    else
        print_error "Transaction not found in Safe API"
        print_error "This may mean:"
        print_error "  1. Transaction was never proposed"
        print_error "  2. Transaction was rejected/cancelled"
        print_error "  3. Transaction hash is incorrect"
        return 1
    fi
}

# Function to wait for transaction execution
wait_for_execution() {
    local safe_tx_hash=$1
    local max_wait="${2:-300}"  # Default 5 minutes
    local interval="${3:-10}"    # Check every 10 seconds
    
    print_info "Waiting for transaction execution (max $max_wait seconds)..."
    
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if check_tx_status "$safe_tx_hash"; then
            return 0
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done
    
    echo ""
    print_error "Transaction not executed within $max_wait seconds"
    return 1
}

# Function to verify contract on Etherscan
verify_contract() {
    local contract_address=$1
    local contract_name=$2
    local constructor_args="${3:-}"
    
    if [ -z "$contract_address" ] || [ -z "$contract_name" ]; then
        print_error "verify_contract: contract_address and contract_name are required"
        return 1
    fi
    
    # Check if ETHERSCAN_API_KEY is set
    if [ -z "$ETHERSCAN_API_KEY" ]; then
        print_warn "ETHERSCAN_API_KEY not set. Skipping verification for $contract_name at $contract_address"
        print_warn "To enable verification, set ETHERSCAN_API_KEY in .env"
        return 0
    fi
    
    # Get the verifier URL based on chain
    local verifier_url=""
    case "$CHAIN_ID" in
        1)
            verifier_url="https://api.etherscan.io/api"
            ;;
        11155111)
            verifier_url="https://api-sepolia.etherscan.io/api"
            ;;
        *)
            print_warn "Unknown chain ID $CHAIN_ID. Skipping verification."
            return 0
            ;;
    esac
    
    print_info "Verifying $contract_name at $contract_address on Etherscan..."
    
    # Build verify command
    # Contract name format: <path>:<ContractName>
    local verify_cmd="forge verify-contract $contract_address $contract_name"
    if [ -n "$constructor_args" ]; then
        verify_cmd="$verify_cmd --constructor-args $constructor_args"
    else
        # Try to guess constructor args from on-chain creation code
        verify_cmd="$verify_cmd --guess-constructor-args"
    fi
    verify_cmd="$verify_cmd --chain $CHAIN_ID --etherscan-api-key $ETHERSCAN_API_KEY --watch"
    
    # Run verification
    if eval "$verify_cmd" 2>&1; then
        print_info "✓ Successfully verified $contract_name at $contract_address"
        return 0
    else
        print_error "Failed to verify $contract_name at $contract_address"
        print_error "You can manually verify with:"
        print_error "  $verify_cmd"
        return 1
    fi
}

