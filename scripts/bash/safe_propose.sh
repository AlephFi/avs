#!/bin/bash
# Helper script to propose Safe transactions using Node.js and Safe SDK
# This script bridges bash scripts to the Safe SDK functionality

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source common utilities
source "$SCRIPT_DIR/common.sh"

# Change to project root
cd "$PROJECT_ROOT"

# Check if Node.js is available
if ! command -v node &> /dev/null; then
    print_error "Node.js is required but not installed. Please install Node.js to use Safe transactions."
    exit 1
fi

# Check if required environment variables are set
if [ -z "$SAFE_ADDRESS" ]; then
    print_error "SAFE_ADDRESS not set"
    exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
    print_error "PRIVATE_KEY not set. This is required to sign the transaction."
    exit 1
fi

if [ -z "$RPC_URL" ]; then
    print_error "RPC_URL not set"
    exit 1
fi

if [ -z "$CHAIN_ID" ]; then
    print_error "CHAIN_ID not set"
    exit 1
fi

# Parameters: to, data, value (optional)
TO_ADDRESS=$1
TX_DATA=$2
VALUE="${3:-0}"

if [ -z "$TO_ADDRESS" ] || [ -z "$TX_DATA" ]; then
    print_error "Usage: $0 <to_address> <tx_data> [value]"
    exit 1
fi

# Create a temporary Node.js script in the project root so it can find node_modules
# Uses the same Safe SDK packages as the Aleph repository
TEMP_SCRIPT="$PROJECT_ROOT/tmp_safe_propose_$$.js"
cat > "$TEMP_SCRIPT" << 'EOF'
const SafeApiKit = require('@safe-global/api-kit').default;
const Safe = require('@safe-global/protocol-kit').default;
const { Wallet, getAddress, JsonRpcProvider } = require('ethers');

async function proposeTransaction() {
    console.log('Starting proposeTransaction function...');
    const safeAddress = process.env.SAFE_ADDRESS;
    let privateKey = process.env.PRIVATE_KEY;
    const rpcUrl = process.env.RPC_URL;
    const chainId = parseInt(process.env.CHAIN_ID);
    const toAddress = process.argv[2];
    const txData = process.argv[3];
    const value = process.argv[4] || '0';
    const safeApiKey = process.env.SAFE_API_KEY || '';

    console.log('Parameters loaded:', { safeAddress, chainId, toAddress, hasTxData: !!txData, hasApiKey: !!safeApiKey });

    // Ensure private key is properly formatted (remove any whitespace, ensure 0x prefix)
    if (privateKey) {
        privateKey = privateKey.trim();
        if (!privateKey.startsWith('0x')) {
            privateKey = '0x' + privateKey;
        }
    }

    if (!privateKey || privateKey.length < 66) {
        console.error('Error: Invalid PRIVATE_KEY format. Must be a hex string starting with 0x and 66 characters long.');
        process.exit(1);
    }
    console.log('Private key validated');

    // Initialize Safe SDK (protocol-kit)
    // Note: Safe.init accepts rpcUrl and privateKey directly (like Aleph repository)
    console.log('Initializing Safe SDK...');
    const safeSdk = await Safe.init({
        provider: rpcUrl,
        signer: privateKey,
        safeAddress: safeAddress
    });
    console.log('Safe SDK initialized successfully');

    // Create transaction (using transactions array format like Aleph)
    console.log('Creating Safe transaction...');
    
    // Set safeTxGas before creating transaction to ensure hash matches
    // GS013: require(success || safeTxGas != 0 || gasPrice != 0, "GS013");
    // Estimate gas for the transaction to avoid OutOfGas errors
    let safeTxGas = '1500000'; // Default fallback (higher than typical 500k to handle initializeVault)
    try {
        const provider = new JsonRpcProvider(rpcUrl);
        const gasEstimate = await provider.estimateGas({
            to: toAddress,
            data: txData,
            from: safeAddress
        });
        // Add 20% buffer to gas estimate to account for state changes
        // estimateGas returns a bigint in ethers v6
        const gasEstimateBigInt = typeof gasEstimate === 'bigint' ? gasEstimate : BigInt(gasEstimate);
        const gasWithBuffer = (gasEstimateBigInt * BigInt(120)) / BigInt(100);
        safeTxGas = gasWithBuffer.toString();
        console.log('Estimated gas:', gasEstimateBigInt.toString(), 'Using with buffer:', safeTxGas);
    } catch (error) {
        console.warn('Gas estimation failed, using default:', safeTxGas);
        console.warn('Error:', error.message);
        // If estimation fails, use a higher default for initializeVault operations
        // Based on actual usage: ~1,190,785 gas, so 1.5M should be safe
    }
    
    const safeTransaction = await safeSdk.createTransaction({
        transactions: [{
            to: toAddress,
            value: value,
            data: txData
        }],
        options: {
            safeTxGas: safeTxGas,
            baseGas: '0',
            gasPrice: '0',
            gasToken: '0x0000000000000000000000000000000000000000',
            refundReceiver: '0x0000000000000000000000000000000000000000'
        }
    });
    console.log('Safe transaction created');

    // Get transaction hash and sign it (hash is calculated from the transaction data including safeTxGas)
    const safeTxHash = await safeSdk.getTransactionHash(safeTransaction);
    const signatureOwner = await safeSdk.signHash(safeTxHash);

    // Initialize API Kit
    // Note: SafeApiKit requires either apiKey or txServiceUrl
    // If no apiKey is provided, we need to construct the txServiceUrl based on chainId
    let apiKit;
    if (safeApiKey) {
        apiKit = new SafeApiKit({
            chainId: BigInt(chainId),
            apiKey: safeApiKey
        });
    } else {
        // Construct txServiceUrl based on chainId (like mainnet, sepolia, etc.)
        const txServiceUrls = {
            1: 'https://safe-transaction-mainnet.safe.global',
            11155111: 'https://safe-transaction-sepolia.safe.global',
            5: 'https://safe-transaction-goerli.safe.global',
            100: 'https://safe-transaction-gnosis.safe.global',
            137: 'https://safe-transaction-polygon.safe.global',
            42161: 'https://safe-transaction-arbitrum.safe.global',
            10: 'https://safe-transaction-optimism.safe.global'
        };
        
        const txServiceUrl = txServiceUrls[chainId];
        if (!txServiceUrl) {
            console.error('Error: No Safe Transaction Service URL configured for chain ID:', chainId);
            console.error('Please set SAFE_API_KEY in your .env file or use a supported chain.');
            process.exit(1);
        }
        
        apiKit = new SafeApiKit({
            chainId: BigInt(chainId),
            txServiceUrl: txServiceUrl
        });
    }

    // Get sender address and checksum all addresses (like Aleph repository)
    const senderAddress = getAddress(new Wallet(privateKey).address);
    const checksummedSafeAddress = getAddress(safeAddress);
    
    // Get transaction data and normalize addresses
    // The transaction data already includes safeTxGas from the options we set above
    const transactionData = safeTransaction.data;
    
    console.log('Using safeTxGas:', transactionData.safeTxGas || '500000');
    
    // Normalize addresses (checksum them)
    const normalizedTransactionData = {
        ...transactionData,
        to: getAddress(transactionData.to),
        gasToken: transactionData.gasToken ? getAddress(transactionData.gasToken) : getAddress('0x0000000000000000000000000000000000000000'),
        refundReceiver: transactionData.refundReceiver ? getAddress(transactionData.refundReceiver) : getAddress('0x0000000000000000000000000000000000000000')
    };

    // Propose transaction (matches Aleph repository format)
    const proposalData = {
        safeAddress: checksummedSafeAddress,
        safeTransactionData: normalizedTransactionData,
        safeTxHash: safeTxHash,
        senderAddress: senderAddress,
        senderSignature: signatureOwner.data
    };

    try {
        await apiKit.proposeTransaction(proposalData);
        // Output hash to stdout (will be captured by bash)
        console.log(safeTxHash);
    } catch (error) {
        // Output errors to both stderr (for visibility) and stdout (for bash capture)
        const errorMsg = `Error proposing transaction: ${error.message}`;
        console.error(errorMsg);
        if (error.response) {
            const responseMsg = `Response status: ${error.response.status}, data: ${JSON.stringify(error.response.data)}`;
            console.error(responseMsg);
            console.log('ERROR:' + errorMsg + ' | ' + responseMsg);
        } else {
            console.log('ERROR:' + errorMsg);
        }
        process.exit(1);
    }
}

proposeTransaction().catch(error => {
    console.error('Fatal error:', error);
    console.error('Error stack:', error.stack);
    process.exit(1);
});
EOF

# Run the Node.js script from project root so it can find node_modules
print_info "Proposing Safe transaction using Safe SDK..."

# Change to project root to ensure node_modules are found
cd "$PROJECT_ROOT"

# Verify node_modules exists
if [ ! -d "node_modules" ]; then
    print_error "node_modules directory not found. Please run 'npm install' first."
    rm -f "$TEMP_SCRIPT"
    exit 1
fi

# Verify required packages are installed
if [ ! -d "node_modules/@safe-global/api-kit" ] || [ ! -d "node_modules/@safe-global/protocol-kit" ]; then
    print_error "Safe SDK packages not found. Please run 'npm install' first."
    rm -f "$TEMP_SCRIPT"
    exit 1
fi

# Capture both stdout and stderr separately
# Note: We're already in PROJECT_ROOT from the cd above
print_info "Running Node.js script with Safe SDK..."
print_info "Safe Address: $SAFE_ADDRESS"
print_info "Chain ID: $CHAIN_ID"
print_info "API Key set: $([ -n "$SAFE_API_KEY" ] && echo "Yes" || echo "No")"

# Run Node.js script with timeout to prevent hanging
# Use timeout command if available, otherwise rely on Node.js internal timeout
if command -v timeout &> /dev/null; then
    NODE_OUTPUT=$(timeout 60 bash -c "PRIVATE_KEY=\"$PRIVATE_KEY\" SAFE_ADDRESS=\"$SAFE_ADDRESS\" RPC_URL=\"$RPC_URL\" CHAIN_ID=\"$CHAIN_ID\" SAFE_API_KEY=\"${SAFE_API_KEY:-}\" node \"$TEMP_SCRIPT\" \"$TO_ADDRESS\" \"$TX_DATA\" \"$VALUE\" 2>&1")
    NODE_EXIT_CODE=$?
    if [ $NODE_EXIT_CODE -eq 124 ]; then
        print_error "Node.js script timed out after 60 seconds"
        NODE_EXIT_CODE=1
    fi
else
    # Fallback: run without timeout (rely on internal timeouts)
# Unset NODE_OPTIONS to prevent debugger from attaching
unset NODE_OPTIONS

# Run Node.js script with explicit no-debugger flag and timeout using background process
print_info "Executing Node.js script..."
(
    PRIVATE_KEY="$PRIVATE_KEY" SAFE_ADDRESS="$SAFE_ADDRESS" RPC_URL="$RPC_URL" CHAIN_ID="$CHAIN_ID" SAFE_API_KEY="${SAFE_API_KEY:-}" node --no-warnings "$TEMP_SCRIPT" "$TO_ADDRESS" "$TX_DATA" "$VALUE" 2>&1
) > /tmp/safe_propose_output.log 2>&1 &
NODE_PID=$!

# Wait for the process with a timeout (60 seconds)
TIMEOUT=60
ELAPSED=0
while kill -0 $NODE_PID 2>/dev/null && [ $ELAPSED -lt $TIMEOUT ]; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    # Show progress every 10 seconds
    if [ $((ELAPSED % 10)) -eq 0 ]; then
        echo -n "."
    fi
done
echo ""

# Check if process is still running
if kill -0 $NODE_PID 2>/dev/null; then
    print_error "Node.js script timed out after ${TIMEOUT} seconds"
    print_error "Killing process $NODE_PID..."
    kill -9 $NODE_PID 2>/dev/null
    NODE_EXIT_CODE=1
    NODE_OUTPUT=$(cat /tmp/safe_propose_output.log 2>/dev/null || echo "No output captured")
    print_error "Script output so far:"
    echo "$NODE_OUTPUT"
else
    # Process completed, get exit code
    wait $NODE_PID
    NODE_EXIT_CODE=$?
    NODE_OUTPUT=$(cat /tmp/safe_propose_output.log 2>/dev/null || echo "No output captured")
fi
fi

# Clean up
rm -f "$TEMP_SCRIPT"

# Check exit code first
if [ $NODE_EXIT_CODE -ne 0 ]; then
    print_error "Node.js script failed with exit code: $NODE_EXIT_CODE"
    print_error ""
    print_error "Full output:"
    echo "$NODE_OUTPUT"
    print_error ""
    # Check for specific error messages
    if echo "$NODE_OUTPUT" | grep -q "is not an owner or delegate"; then
        print_error "=========================================="
        print_error "PRIVATE_KEY does not correspond to a Safe owner"
        print_error "=========================================="
        print_error ""
        SENDER=$(echo "$NODE_OUTPUT" | grep -o "Sender=[^ ]*" | cut -d= -f2)
        print_error "Your PRIVATE_KEY corresponds to address: $SENDER"
        print_error ""
        print_error "This address is not one of the Safe owners."
        print_error "Please use a PRIVATE_KEY from one of the Safe owners listed above."
        print_error ""
        print_error "To check which address your PRIVATE_KEY corresponds to, run:"
        print_error "  cast wallet address --private-key \$PRIVATE_KEY"
    fi
    exit 1
fi

# Extract the transaction hash (should be the last line that matches the pattern)
SAFE_TX_HASH=$(echo "$NODE_OUTPUT" | grep -E "^0x[a-fA-F0-9]{64}$" | tail -1)

# Check if we got a transaction hash
if [ -z "$SAFE_TX_HASH" ]; then
    print_error "Failed to extract transaction hash from output"
    print_error "Node.js script output:"
    echo "$NODE_OUTPUT" | head -50
    # Check if there's an ERROR in the output
    if echo "$NODE_OUTPUT" | grep -q "ERROR:"; then
        ERROR_MSG=$(echo "$NODE_OUTPUT" | grep "ERROR:" | head -1 | sed 's/ERROR://')
        print_error "Error detected: $ERROR_MSG"
        # Check for common errors
        if echo "$NODE_OUTPUT" | grep -q "Not Found"; then
            print_error "The Safe address may not exist on this chain, or the API endpoint is incorrect."
            print_error "Please verify:"
            print_error "  1. Safe address: $SAFE_ADDRESS"
            print_error "  2. Chain ID: $CHAIN_ID"
            print_error "  3. Safe exists on Sepolia testnet"
        elif echo "$NODE_OUTPUT" | grep -q "is not an owner or delegate"; then
            print_error ""
            print_error "The PRIVATE_KEY does not correspond to a Safe owner."
            print_error "Please use a private key from one of the Safe owners:"
            echo "$NODE_OUTPUT" | grep -o "Current owners=\[.*\]" | sed 's/Current owners=\[/  - /' | sed 's/\]//' | sed "s/', '/\n  - /g" | sed "s/'//g"
            print_error ""
            print_error "To find the address of your PRIVATE_KEY, run:"
            print_error "  cast wallet address --private-key <your_private_key>"
        fi
        exit 1
    fi
    print_error "No transaction hash found. The script may have hung or failed silently."
    exit 1
fi

# Verify it's a valid hash
if [[ ! "$SAFE_TX_HASH" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
    print_error "Invalid transaction hash format: $SAFE_TX_HASH"
    print_error "Full output:"
    echo "$NODE_OUTPUT"
    exit 1
fi

echo "$SAFE_TX_HASH"

