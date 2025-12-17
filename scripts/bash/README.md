# SAFE Multisig Scripts

This directory contains bash scripts for interacting with Gnosis Safe multisig wallets to execute AlephAVS operations.

## Prerequisites

1. **Environment Setup**
   - Create a `.env` file in the project root with:
     ```bash
     SAFE_ADDRESS=0x...          # Your SAFE multisig address
     RPC_URL=https://...         # RPC endpoint
     CHAIN_ID=1                  # Chain ID (1=mainnet, 11155111=sepolia)
     PRIVATE_KEY=0x...           # Private key of a Safe owner (for signing proposals)
     ALEPH_AVS_ADDRESS=0x...     # Optional: AlephAVS proxy address
     SAFE_API_KEY=...            # Optional: Safe API key (for higher rate limits)
     ```

2. **Required Tools**
   - `forge` (Foundry)
   - `cast` (Foundry)
   - `jq` (JSON processor)
   - `curl` (for API calls)
   - `node` (Node.js >= 18.0.0)
   - `npm` (Node Package Manager)

3. **Node.js Dependencies**
   - Install required packages:
     ```bash
     npm install
     ```
   - This installs:
     - `@safe-global/api-kit` - Safe API client for proposing transactions
     - `@safe-global/protocol-kit` - Safe protocol SDK for creating and signing transactions
     - `@safe-global/types-kit` - TypeScript types for Safe
     - `ethers` (v6) - Ethereum library

4. **SAFE API**
   - The scripts automatically detect the SAFE API URL based on `CHAIN_ID`
   - Supported chains: Mainnet, Sepolia, Goerli
   - For other chains, set `SAFE_API_URL` in `.env`
   - **Note**: The scripts use the Safe SDK (like the Aleph repository) to properly sign and propose transactions

## Scripts

### `common.sh`
Common utilities used by all scripts. Includes:
- Environment variable validation
- SAFE API URL resolution
- Transaction encoding
- SAFE transaction submission
- Status checking

### `deploy.sh`
Deploy AlephAVS via SAFE multisig.

**Usage:**
```bash
./scripts/bash/deploy.sh
```

**Note:** This script generates transaction data from the Foundry deployment script. For full SAFE integration, you may need to split deployment into separate steps (implementation + proxy).

### `upgrade.sh`
Upgrade AlephAVS implementation via SAFE multisig.

**Usage:**
```bash
./scripts/bash/upgrade.sh
```

**Requirements:**
- `ALEPH_AVS_ADDRESS` set in `.env` or `deployments/$CHAIN_ID.json`

### `initialize_vault.sh`
Initialize a vault via SAFE multisig.

**Usage:**
```bash
export VAULT_ADDRESS=0x...
export CLASS_ID=0  # Optional, defaults to 0
./scripts/bash/initialize_vault.sh
```

**Requirements:**
- `VAULT_ADDRESS` - The Aleph vault address to initialize
- `CLASS_ID` - Share class ID (default: 0)
- `ALEPH_AVS_ADDRESS` - Set in `.env` or `deployments/$CHAIN_ID.json`

### `submit_tx.sh`
Generic script to submit any transaction to SAFE.

**Usage:**
```bash
./scripts/bash/submit_tx.sh <to> <function_signature> [args...]
```

**Examples:**
```bash
# Initialize vault
./scripts/bash/submit_tx.sh \
  0x123... \
  "initializeVault(uint8,address)" \
  0 \
  0x456...

# Pause contract
./scripts/bash/submit_tx.sh \
  0x123... \
  "pause()"
```

### `check_tx.sh`
Check the status of a SAFE transaction.

**Usage:**
```bash
./scripts/bash/check_tx.sh <safe_tx_hash>
```

**Example:**
```bash
./scripts/bash/check_tx.sh 0xabc123...
```

## Workflow

1. **Prepare Transaction**
   ```bash
   # Set required environment variables
   export SAFE_ADDRESS=0x...
   export RPC_URL=https://...
   export CHAIN_ID=1
   ```

2. **Submit Transaction**
   ```bash
   ./scripts/bash/initialize_vault.sh
   ```

3. **Sign in SAFE**
   - Open your SAFE wallet
   - Find the pending transaction
   - Sign with required owners

4. **Execute Transaction**
   - Once threshold is met, execute the transaction in SAFE

5. **Verify Status**
   ```bash
   ./scripts/bash/check_tx.sh <safe_tx_hash>
   ```

## Advanced Usage

### Custom Function Calls

You can use `submit_tx.sh` to call any function:

```bash
# Example: Set operator AVS split
./scripts/bash/submit_tx.sh \
  $REWARDS_COORDINATOR \
  "setOperatorAVSSplit(address,address,uint96)" \
  $OPERATOR \
  $ALEPH_AVS_ADDRESS \
  0
```

### Batch Operations

For multiple operations, you can create a batch script:

```bash
#!/bin/bash
# batch_operations.sh

source ./scripts/bash/common.sh
check_env

# Operation 1
TX1=$(submit_to_safe $ADDRESS1 "function1()" "0" "0")
echo "TX1: $TX1"

# Operation 2
TX2=$(submit_to_safe $ADDRESS2 "function2(uint256)" "100" "0")
echo "TX2: $TX2"
```

## Troubleshooting

### Transaction Data Generation Fails
- Ensure Foundry scripts are compilable: `forge build`
- Check RPC URL is accessible
- Verify all required environment variables are set

### Safe Transaction Proposal Fails
- **Node.js not found**: Install Node.js (>= 18.0.0)
- **Missing dependencies**: Run `npm install` in the project root
- **PRIVATE_KEY not set**: Set `PRIVATE_KEY` in `.env` (must be a Safe owner's private key)
- **Invalid signature**: Ensure the `PRIVATE_KEY` corresponds to a Safe owner
- **API errors**: Check that `SAFE_ADDRESS` is correct and the Safe exists on the chain

### Common Issues
- **"PRIVATE_KEY is required"**: Add `PRIVATE_KEY=0x...` to your `.env` file
- **"Node.js is required"**: Install Node.js from https://nodejs.org/
- **"Cannot find module '@safe-global/safe-core-sdk'"**: Run `npm install`
- **Transaction not appearing in Safe**: Check that the private key belongs to a Safe owner

### SAFE API Errors
- Verify `CHAIN_ID` matches your network
- Check `SAFE_ADDRESS` is correct
- Ensure SAFE API is accessible for your chain

### Transaction Not Executing
- Check transaction has enough confirmations in SAFE
- Verify threshold is met
- Check transaction is not already executed

## Security Notes

- **Never commit `.env` files** with private keys
- **Verify transaction data** before signing in SAFE
- **Use testnets** for testing before mainnet deployment
- **Review all transactions** in SAFE UI before execution

## Integration with Foundry Scripts

These scripts work alongside Foundry scripts in `script/`:
- Foundry scripts generate transaction data
- Bash scripts submit to SAFE
- SAFE handles multisig execution

For operations that don't require multisig, you can still use Foundry scripts directly with `--broadcast`.

