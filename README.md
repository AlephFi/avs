# Aleph AVS Contracts

Aleph AVS is an EigenLayer Actively Validated Service that lets delegated restakers allocate stake to external Aleph vaults while preserving EigenLayer security guarantees. The contracts in `src/` implement the on-chain AVS (`AlephAVS`) that orchestrates slashing, vault deposits, tokenization, and redemptions. For a protocol deep dive see `ALEPHAVS_DOCUMENTATION_EIGENLAYER.md`.

## Repository Layout
- `src/`: Core contracts, interfaces, and libraries:
  - **Contracts**: 
    - `AlephAVS.sol` - Main AVS contract that handles allocation, slashing, and unallocation
    - `AlephAVSPausable.sol` - Pausable functionality with role-based access control for allocate and unallocate flows
    - `ERC20Factory.sol` - Factory for creating slashed ERC20 tokens
    - `ERC20Token.sol` - Mintable/burnable ERC20 token implementation
  - **Libraries**: 
    - `AllocationManagement.sol` - Operator allocation management with sorted strategy arrays
    - `AlephVaultManagement.sol` - Vault operations, slashed token/strategy creation
    - `AlephValidation.sol` - Validation utilities for operators, vaults, strategies
    - `AlephSlashing.sol` - Slashing calculations and execution
    - `AlephUtils.sol` - Common utilities and constants
    - `UnallocateManagement.sol` - Two-step unallocation flow logic
    - `RewardsManagement.sol` - Rewards submission to RewardsCoordinator
- `script/`: Foundry scripts for deploying the AVS and running common operator/restaker flows:
  - `DeployAlephAVS.s.sol` - Deploy the AVS contract
  - `UpgradeAlephAVS.s.sol` - Upgrade the AVS contract
  - `InitializeVault.s.sol` - Initialize a vault for allocation
  - `OnboardOperator.s.sol` - Onboard an operator to the AVS
  - `AllocateToAlephVault.s.sol` - Allocate stake to a vault
  - `RequestUnallocate.s.sol` - Request unallocation (step 1 of two-step flow)
  - `CompleteUnallocate.s.sol` - Complete unallocation (step 2 of two-step flow)
  - `MintToken.s.sol` - Mint ERC20 tokens (for testing)
  - `DepositToStrategy.s.sol` - Deposit to EigenLayer strategy
  - `GenerateAuthSignature.s.sol` - Generate auth signatures for vault operations
- `test/`: Forge tests with EigenLayer/Aleph mocks that exercise allocation, slashing, unallocation, and vault flows.
- `docs/`: Documentation including user guides for unallocation flow.
- `config/`: JSON configuration consumed by the deployment and operator scripts.
- `deployments/`: Auto-generated JSON metadata per chain after running deployment scripts.

## Prerequisites
1. [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge >= 0.2.0, cast, anvil). Run `foundryup` after installation.
2. Git submodules or Forge libraries for EigenLayer, Aleph, and forge-std:
   ```bash
   git submodule update --init --recursive
   # or
   forge install
   ```
3. Node.js + pnpm (needed only for scripts that integrate with tooling outside this repo).

## Initial Setup
```bash
cp config/deployment.example.json config/deployment.json
# customize the per-chain addresses before broadcasting
```
Populate a `.env` file at the repo root (Forge automatically reads it). See `.env.example` for a template. Note that many addresses can be loaded from `config/deployment.json` or `deployments/<chainId>.json` automatically, so you only need to set:
```
RPC_URL=<https or wss endpoint>
PRIVATE_KEY=<hex signer key used by forge script>
CHAIN_ID=<optional; defaults to network chain id>
ETHERSCAN_API_KEY=<optional; enables --verify>
```
Additional variables are referenced by specific scripts (see the table below).

## Configuration Reference (`config/deployment.json`)
Each chain ID block must define the EigenLayer core contracts and Aleph-specific factories. Example:
```json
{
  "11155111": {
    "name": "Sepolia Testnet",
    "allocationManager": "0x...",
    "delegationManager": "0x...",
    "strategyManager": "0x...",
    "strategy": "0x...",
    "vaultFactory": "0x...",
    "rewardsCoordinator": "0x...",
    "strategyFactory": "0x...",
    "allocationDelay": 0,
    "metadataURI": "",
    "guardian": "0x..."
  }
}
```
- `vaultFactory`, `strategyFactory`: addresses from the Aleph/EigenLayer deployments used to spin up per-vault slashed strategies. Note: `ERC20Factory` is deployed automatically as part of the deployment script.
- `strategy`: address of the original LST strategy (not the slashed strategy). Slashed strategies are created dynamically per vault during initialization.
- `guardian`: address that can pause/unpause allocate and unallocate flows alongside the owner.
- `allocationDelay`, `metadataURI`: forwarded to the operator registration flow.
- **Note**: Strategies are now added dynamically via `initializeVault()` rather than at deployment time.

## Environment Variables by Script
| Script / Flow | Required Variables | Optional Variables |
| ------------- | ------------------ | ------------------ |
| `DeployAlephAVS.s.sol` | `PRIVATE_KEY`, `RPC_URL`, `CHAIN_ID` (or network), populated `config/deployment.json` | `DEPLOYER_ADDRESS` (if broadcasting from a remote signer), `ALEPH_OWNER_ADDRESS`, `ETHERSCAN_API_KEY` |
| `UpgradeAlephAVS.s.sol` | `PRIVATE_KEY`, `RPC_URL`, `ALEPH_AVS_ADDRESS` | `NEW_IMPLEMENTATION_ADDRESS` (if not provided, deploys new implementation) |
| `InitializeVault.s.sol` | `PRIVATE_KEY` (owner), `RPC_URL`, `ALEPH_VAULT_ADDRESS`, `CLASS_ID` | `ALEPH_AVS_ADDRESS` (loaded from deployments JSON if not set) |
| `OnboardOperator.s.sol` | `PRIVATE_KEY` (operator), `RPC_URL` | `ALEPH_AVS_ADDRESS`, `ALLOCATION_DELAY`, `DELEGATION_APPROVER`, `METADATA_URI` (loaded from deployments/config if not set) |
| `AllocateToAlephVault.s.sol` | `PRIVATE_KEY` (staker), `RPC_URL`, `ALEPH_VAULT_ADDRESS`, `ALLOCATE_AMOUNT`, `AUTH_SIGNER_PRIVATE_KEY`, `STRATEGY_DEPOSIT_SIGNER_PRIVATE_KEY` (same as `PRIVATE_KEY`) | `CLASS_ID`, `EXPIRY_BLOCK`, `STRATEGY_DEPOSIT_EXPIRY`, `ALEPH_AVS_ADDRESS` (loaded from deployments JSON if not set) |
| `RequestUnallocate.s.sol` | `PRIVATE_KEY` (token holder), `RPC_URL`, `ALEPH_VAULT_ADDRESS`, `UNALLOCATE_TOKEN_AMOUNT` | `ALEPH_AVS_ADDRESS` (loaded from deployments JSON if not set) |
| `CompleteUnallocate.s.sol` | `PRIVATE_KEY` (token holder), `RPC_URL`, `ALEPH_VAULT_ADDRESS` | `ALEPH_AVS_ADDRESS`, `STRATEGY_DEPOSIT_EXPIRY` (loaded from deployments JSON if not set) |
| `MintToken.s.sol` | `PRIVATE_KEY`, `RPC_URL`, `TOKEN_ADDRESS`, `MINT_AMOUNT` | `ALEPH_AVS_ADDRESS`, `MINT_TO_ADDRESS` (defaults to `msg.sender`) |

> Tip: Every script falls back to the JSON inside `config/deployment.json` or the deployment artefacts under `deployments/<chainId>.json` when an address env variable is missing, so keep those files current.

## Deployment & Operations Workflow
1. **Deploy AlephAVS**
   ```bash
   pnpm run script:deploy
   # or
   forge script script/DeployAlephAVS.s.sol:DeployAlephAVS \
     --rpc-url $RPC_URL \
     --broadcast \
     --verify
   ```
   - Reads the active chain configuration from `config/deployment.json`.
   - Deploys `AlephAVS` contract (proxy pattern) and `ERC20Factory`.
   - Initializes the contract with owner and guardian addresses (both can pause/unpause flows).
   - Persists artifacts to `deployments/<chainId>.json` and broadcast data under `broadcast/`.

2. **Onboard Operator**
   ```bash
   pnpm run script:onboard-operator
   # or
   forge script script/OnboardOperator.s.sol:OnboardOperator \
     --rpc-url $RPC_URL \
     --broadcast
   ```
   - Registers the operator in EigenLayer's `DelegationManager` (if not already registered)
   - Registers for AlephAVS operator sets
   - Allocates stake to vault strategies (if available)
   - Sets operator AVS split to 0 (100% to stakers)
   - **Note**: The operator must have deposited funds into an EigenLayer strategy first. Use EigenLayer's standard tools or `DepositToStrategy.s.sol`.

3. **Initialize Vaults (owner-only)**
   ```bash
   pnpm run script:initialize-vault
   # or
   forge script script/InitializeVault.s.sol:InitializeVault \
     --rpc-url $RPC_URL \
     --broadcast
   ```
   - Call `AlephAVS.initializeVault(classId, vaultAddress)` once per Aleph vault
   - Creates or retrieves the slashed ERC20 token via `ERC20Factory`
   - Creates or retrieves the corresponding slashed strategy via `StrategyFactory`
   - Adds both the LST strategy and slashed strategy to their respective operator sets
   - After initialization, the public mapping `vaultToSlashedStrategy` exposes the strategy address for stakers
   - The slashed token can be derived from the strategy using `strategy.underlyingToken()`

4. **Restaker Allocation**
   ```bash
   pnpm run script:allocate
   # or
   forge script script/AllocateToAlephVault.s.sol:AllocateToAlephVault \
     --rpc-url $RPC_URL \
     --broadcast
   ```
   - Ensure the restaker delegated to the Aleph operator via `DelegationManager.delegateTo`
   - The flow:
     1. Slashes the operator from the LST set
     2. Deposits funds into the external vault
     3. Mints slashed shares
     4. Deposits them into EigenLayer on behalf of the restaker
     5. Submits rewards to RewardsCoordinator

5. **Unallocation (Two-Step Flow)**
   The unallocation process is a two-step flow to ensure proper handling of vault redemptions:
   
   **Step 1: Request Unallocation**
   ```bash
   pnpm run script:request-unallocate
   # or
   forge script script/RequestUnallocate.s.sol:RequestUnallocate \
     --rpc-url $RPC_URL \
     --broadcast
   ```
   - Burns slashed tokens from the caller
   - Requests redemption from the vault
   - Stores pending unallocation amount
   
   **Step 2: Complete Unallocation**
   ```bash
   pnpm run script:complete-unallocate
   # or
   forge script script/CompleteUnallocate.s.sol:CompleteUnallocate \
     --rpc-url $RPC_URL \
     --broadcast
   ```
   - Withdraws redeemable amount from the vault
   - Deposits back into the original LST strategy
   - Clears pending unallocation
   
   **Note**: Use `getPendingUnallocateStatus()` to check when the vault has processed the redemption request and `completeUnallocate()` can be called. See `docs/UNALLOCATE_USER_GUIDE.md` for detailed instructions.


## Testing
- Run all Forge tests: `forge test -vv`
- Target a single test: `forge test --match-test test_InitializeVault`
- Run specific test file: `forge test --match-path test/LibraryUtils.t.sol`
- Generate coverage report: `forge coverage --ir-minimum --report summary`
- Use `FOUNDRY_PROFILE` or `FOUNDRY_ETH_RPC_URL` env vars if tests need chain state.
- The suite uses extensive mocks for EigenLayer managers and Aleph vaults; it is safe to run offline.

## Network Specification

### Sepolia Testnet (Chain ID: 11155111)

#### EigenLayer Contracts
- **AllocationManager**: `0x42583067658071247ec8CE0A516A58f682002d07`
- **DelegationManager**: `0xD4A7E1Bd8015057293f0D0A557088c286942e84b`
- **StrategyManager**: `0x2E3D6c0744b10eb0A4e6F679F71554a39Ec47a5D`
- **StrategyFactory**: `0x066cF95c1bf0927124DFB8B02B401bc23A79730D`
- **RewardsCoordinator**: `0x5ae8152fb88c26ff9ca5C014c94fca3c68029349`

#### Aleph Contracts
- **VaultFactory**: `0x23202D49C3D1fE5f13B43Ce5192884c812335239`

#### AlephAVS Deployments
- **AlephAVS (Proxy)**: `0x04e3f99C87002F22180513cc635EB49a183c031B`
- **AlephAVS (Implementation)**: `0xC5C3E03AC8F0251BDc4Ed0Ff281824FcD1C62C81`
- **ERC20Factory**: `0x5e1B58A97dFc1C371a099Ac927D6C9CE773DEFcb`
- **Owner**: `0xF441514a8540eB48BA90069e1C3728Db48F935F1`
- **Guardian**: `0xF441514a8540eB48BA90069e1C3728Db48F935F1`

### Ethereum Mainnet (Chain ID: 1)

#### EigenLayer Contracts
- **AllocationManager**: `0x948a420b8CC1d6BFd0B6087C2E7c344a2CD0bc39`
- **DelegationManager**: `0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A`
- **StrategyManager**: `0x858646372CC42E1A627fcE94aa7A7033e7CF075A`
- **StrategyFactory**: `0x5e4C39Ad7A3E881585e383dB9827EB4811f6F647`
- **RewardsCoordinator**: `0x7750d328b314EfFa365A0402CcfD489B80B0adda`

Reference: [EigenLayer Smart Contracts Documentation](https://docs.eigenlayer.xyz/eigenlayer/overview/smart-contracts/overview)

#### Aleph Contracts
- **VaultFactory**: `0x7a9aA939261fb51Ddc9491C929224417a8459229`

#### AlephAVS Deployments
- **AlephAVS (Proxy)**: `0x90c68BF0cAcA6B2a8ba7edE549C911f907B9eF79`
- **ERC20Factory**: `0xA3ED7a45d3609EC17A5392A56dDff85d2f1D1a19`
- **Guardian**: `0x60EDE74fF53c749970b2B4890E02F7756465d9eC`

#### RPC Endpoints
- **Sepolia**: Use public RPC endpoints or configure your own
- **Mainnet**: Use public RPC endpoints or configure your own

> **Tip**: For production deployments, use reliable RPC providers with rate limiting and authentication.

## Architecture Highlights

### Storage Optimization
- **No redundant storage**: The slashed token address is derived from the slashed strategy using `strategy.underlyingToken()` rather than stored separately.
- **Constant magnitudes**: All strategies use the same magnitude constant (`OPERATOR_SET_MAGNITUDE = 1e18`), eliminating the need for a per-strategy magnitude mapping.
- **Sorted strategy arrays**: Strategies are maintained in sorted order (by address) for efficient lookups and consistent allocation parameter construction.

### Library Organization
The codebase follows a modular library structure with design patterns:
- **AllocationManagement**: Handles operator set allocations with automatic strategy sorting and magnitude management.
- **AlephVaultManagement**: Manages vault interactions, slashed token/strategy creation, and deposit/redemption flows.
- **AlephValidation**: Centralized validation logic for operators, vaults, strategies, and delegations.
- **AlephSlashing**: Slashing calculations, magnitude computations, and slash execution.
- **UnallocateManagement**: Two-step unallocation flow logic with proportional distribution for multiple users.
- **RewardsManagement**: Rewards submission to RewardsCoordinator with validation.
- **AlephUtils**: Common utilities and constants for operator sets and strategy operations.

### Design Patterns Used
- **Factory Pattern**: ERC20Factory for token creation
- **Value Object Pattern**: VaultStrategies struct for encapsulating related data
- **RAII-like Pattern**: TokenApproval library for safe approval management
- **Builder Pattern**: ConstructorValidation for parameter validation
- **Dependency Injection**: All external contracts injected via constructor
- **Library Pattern**: Reusable libraries for common operations

This organization promotes code reuse, reduces duplication, and makes the codebase more maintainable while following SOLID principles.

### Pausable Functionality
The `AlephAVS` contract inherits from `AlephAVSPausable`, which provides role-based pause/unpause functionality for critical flows:
- **ALLOCATE_FLOW**: Can pause/unpause the allocation flow (owner and guardian roles)
- **UNALLOCATE_FLOW**: Can pause/unpause the unallocation flow (owner and guardian roles)

Both owner and guardian addresses (set during initialization) have permission to pause and unpause these flows. This provides an emergency mechanism to halt operations if needed.

## Common Troubleshooting
- **Configuration not found**: ensure the `CHAIN_ID` defined in `.env` exists as a key in `config/deployment.json`.
- **Operator set errors (`InvalidOperatorSet`)**: ensure the operator is properly registered using `OnboardOperator.s.sol` script.
- **Missing vault strategy**: call `initializeVault` before letting stakers allocate into that vault.
- **Signature failures**: regenerate `AuthLibrary.AuthSignature` and the EigenLayer `depositIntoStrategyWithSignature` payloads by rerunning the allocation script with fresh expiry values.
- **Unallocation not ready**: use `getPendingUnallocateStatus()` to check if the vault has processed the redemption request before calling `completeUnallocate()`.
- **Unallocation signature mismatch**: ensure you use `calculateCompleteUnallocateAmount()` to get the exact expected amount before generating the strategy deposit signature.

## Additional Resources
- `ALEPHAVS_DOCUMENTATION_EIGENLAYER.md`: end-to-end diagrams of restaker, operator, vault, and reward flows.
- `docs/UNALLOCATE_USER_GUIDE.md`: comprehensive guide for the two-step unallocation flow with examples and troubleshooting.
- [EigenLayer smart contract docs](https://docs.eigenlayer.xyz/eigenlayer/overview/smart-contracts/overview) for reference addresses.
- Aleph protocol documentation for vault configuration and NAV update processes.

## Contributing
1. Create a feature branch.
2. Run `forge fmt && forge test`.
3. Open a PR with a summary of the contract/script changes and any deployment considerations.

This README should give new contributors and operators enough context to configure, deploy, and interact with Aleph AVS from end to end. Refer to the in-repo documentation for deeper architectural detail or protocol-specific questions.
