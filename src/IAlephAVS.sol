// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IAVSRegistrar} from "eigenlayer-contracts/src/contracts/interfaces/IAVSRegistrar.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IAllocationManagerTypes} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IAlephVaultDeposit} from "Aleph/src/interfaces/IAlephVaultDeposit.sol";
import {IAlephVaultRedeem} from "Aleph/src/interfaces/IAlephVaultRedeem.sol";
import {IERC20Factory} from "./interfaces/IERC20Factory.sol";

/**
 * @title IAlephAVS
 * @notice Interface for the AlephAVS contract
 */
interface IAlephAVS is IAVSRegistrar {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when an operator registers for AlephAVS operator sets
     * @param operator The operator address
     * @param operatorSetIds The operator set IDs the operator registered for
     */
    event OperatorRegistered(address indexed operator, uint32[] operatorSetIds);

    /**
     * @notice Emitted when an operator deregisters from AlephAVS operator sets
     * @param operator The operator address
     * @param operatorSetIds The operator set IDs the operator deregistered from
     */
    event OperatorDeregistered(address indexed operator, uint32[] operatorSetIds);

    /**
     * @notice Emitted when an operator is slashed during allocation
     * @param operator The operator that was slashed
     * @param operatorSetId The operator set ID where the slash occurred
     * @param strategy The strategy that was slashed
     * @param underlyingToken The underlying token of the slashed strategy
     * @param amount The amount of tokens received from the slash
     * @param slashId The unique identifier for this slash event
     */
    event SlashExecuted(
        address indexed operator,
        uint32 operatorSetId,
        address indexed strategy,
        address indexed underlyingToken,
        uint256 amount,
        uint256 slashId
    );

    /**
     * @notice Emitted when an operator allocates funds to an Aleph vault
     * @param operator The operator who allocated the funds
     * @param alephVault The Aleph vault address funds were allocated to
     * @param originalStrategy The original LST strategy that was slashed
     * @param slashedStrategy The slashed strategy created for this vault
     * @param tokenAmount The amount of tokens slashed and allocated
     * @param amountToMint The amount of slashed tokens minted and distributed
     * @param vaultShares The vault shares received from the deposit
     * @param classId The share class ID used for the vault deposit
     */
    event AllocatedToAlephVault(
        address indexed operator,
        address indexed alephVault,
        address originalStrategy,
        address slashedStrategy,
        uint256 tokenAmount,
        uint256 amountToMint,
        uint256 vaultShares,
        uint8 classId
    );

    /**
     * @notice Emitted when a user requests to unallocate funds from an Aleph vault
     * @param tokenHolder The address that held the slashed tokens and requested unallocation
     * @param alephVault The Aleph vault address funds are being unallocated from
     * @param slashedStrategy The slashed strategy whose tokens were burned
     * @param tokenAmount The amount of slashed tokens burned
     * @param estAmountToRedeem The estimated amount that will be redeemed from the vault
     * @param batchId The batch ID for the redeem request
     * @param classId The share class ID used for the vault redemption
     */
    event UnallocateRequested(
        address indexed tokenHolder,
        address indexed alephVault,
        address slashedStrategy,
        uint256 tokenAmount,
        uint256 estAmountToRedeem,
        uint48 batchId,
        uint8 classId
    );

    /**
     * @notice Emitted when funds are unallocated from an Aleph vault
     * @param tokenHolder The address that held the slashed tokens and called unallocate
     * @param alephVault The Aleph vault address funds were unallocated from
     * @param originalStrategy The original LST strategy where tokens were deposited back
     * @param slashedStrategy The slashed strategy whose tokens were burned
     * @param amount The amount of tokens redeemed from the vault and deposited to the strategy
     * @param shares The shares received in the original LST strategy
     * @param classId The share class ID used for the vault redemption
     */
    event UnallocateCompleted(
        address indexed tokenHolder,
        address indexed alephVault,
        address originalStrategy,
        address slashedStrategy,
        uint256 amount,
        uint256 shares,
        uint8 classId
    );

    /**
     * @notice Emitted when a vault is initialized with its slashed token and strategy
     * @param vault The vault address that was initialized
     * @param originalToken The original token (vault's underlying token)
     * @param slashedToken The slashed token created for this vault
     * @param slashedStrategy The slashed strategy created for this vault
     */
    event VaultInitialized(
        address indexed vault,
        uint8 classId,
        address indexed originalToken,
        address indexed slashedToken,
        address slashedStrategy
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotRegisteredOperator();
    error InvalidAllocationManager();
    error Unauthorized();
    error InsufficientAllocation();
    error InvalidOperatorSet();
    error InvalidStrategyManager();
    error InvalidStrategy();
    error InvalidDelegationManager();
    error InvalidRewardsCoordinator();
    error InvalidVaultFactory();
    error InvalidVault();
    error InvalidStrategyFactory();
    error NotMemberOfOperatorSet();
    error AmountTooSmall();
    error MagnitudeOverflow();
    error InvalidAmount();
    error InsufficientBalance();
    error TokenAmountMismatch();
    error NotAlephOperator();
    error NoTokensReceived();
    error InvalidAlephOperator();
    error OperatorSplitNotZero();
    error InvalidClassId();
    error VaultAlreadyInitialized();
    error InsufficientOutput(uint256 actualAmount, uint256 minAmount);
    error VaultNotInitialized(address vault);
    error NoPendingUnallocation();

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Returns the ERC20 factory contract
     * @return The ERC20 factory contract address
     */
    function erc20Factory() external view returns (IERC20Factory);

    /**
     * @notice Returns the slashed strategy for a given vault
     * @param vault The vault address
     * @return The slashed strategy for the vault
     */
    function vaultToSlashedStrategy(address vault) external view returns (IStrategy);

    function vaultToOriginalStrategy(address vault) external view returns (IStrategy);

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allocates funds by slashing the operator, depositing to Aleph vault, and creating rewards submission
     * @param _alephVault The Aleph vault address to deposit to
     * @param _requestDepositParams Parameters for vault deposit (amount, authSignature, classId)
     */
    function allocate(address _alephVault, IAlephVaultDeposit.RequestDepositParams calldata _requestDepositParams)
        external;

    /**
     * @notice Requests to unallocate funds by redeeming slashed tokens from vault
     * @dev This is the first step of the two-step unallocate flow. Called by anyone who holds slashed strategy tokens.
     *
     * **How it works:**
     * 1. Burns the slashed tokens from the caller
     * 2. Calculates the estimated amount to redeem from the vault (based on current vault price per share)
     * 3. Requests redemption from the vault (the vault sees only the AVS as the allocator)
     * 4. Stores the estimated amount as pending unallocation for the caller
     *
     * **Important Notes:**
     * - The caller must hold at least `_tokenAmount` of slashed strategy tokens
     * - The estimated amount may differ from the actual amount redeemed due to vault price changes
     * - Multiple users can request unallocation; funds are distributed proportionally when available
     * - After calling this, the user must wait for the vault to process the redemption request
     * - Use `getPendingUnallocateStatus()` to check when `completeUnallocate()` can be called
     *
     * **Edge Cases:**
     * - If `_tokenAmount` is 0, reverts with `InvalidAmount`
     * - If vault is not initialized, reverts with `VaultNotInitialized`
     * - If calculated `estAmountToRedeem` is 0, reverts with `InvalidAmount`
     *
     * @param _alephVault The Aleph vault address to unallocate from (must be initialized)
     * @param _tokenAmount The amount of slashed strategy tokens to unallocate (must be > 0)
     * @return batchId The batch ID for the redeem request (used by the vault for tracking)
     * @return estAmountToRedeem The estimated amount that will be redeemed from the vault
     *
     * @custom:example
     * ```solidity
     * // User has 100 slashed tokens and wants to unallocate
     * (uint48 batchId, uint256 estAmount) = alephAVS.requestUnallocate(vaultAddress, 100e18);
     * // estAmount might be 95e18 if vault price per share is 0.95
     * ```
     */
    function requestUnallocate(address _alephVault, uint256 _tokenAmount)
        external
        returns (uint48 batchId, uint256 estAmountToRedeem);

    /**
     * @notice Completes the unallocation by withdrawing redeemable amount and depositing back to strategy
     * @dev This is the second step of the two-step unallocate flow. Called by the user who previously called `requestUnallocate`.
     *
     * **How it works:**
     * 1. Checks that the user has pending unallocation (from `requestUnallocate`)
     * 2. Calculates the expected amount based on proportional distribution (if multiple users have pending)
     * 3. Withdraws redeemable amount from the vault (if available)
     * 4. Caps the amount to actual available balances (vault redeemable + previously withdrawn)
     * 5. Deposits the amount back into the original LST strategy using the provided signature
     * 6. Clears the user's pending unallocation
     *
     * **Proportional Distribution:**
     * If multiple users have requested unallocation, the available funds are distributed proportionally:
     * - User's share = (userPendingAmount / totalPendingAmount) * totalRedeemableAmount
     * - If this is the last user, they receive all remaining withdrawn amount
     *
     * **Signature Requirements:**
     * - The signature must be generated using `calculateCompleteUnallocateAmount()` to get the exact expected amount
     * - Signature is for `depositIntoStrategyWithSignature()` in StrategyManager
     * - Must be signed by the caller (msg.sender) with the correct nonce
     * - Expiry must be in the future
     *
     * **Important Notes:**
     * - Call `getPendingUnallocateStatus()` first to check if unallocation can be completed
     * - Call `calculateCompleteUnallocateAmount()` to get the expected amount for signature generation
     * - The actual amount may be slightly less than expected due to rounding or insufficient funds
     * - If vault has no redeemable amount yet, wait for the vault to process the redemption request
     *
     * **Edge Cases:**
     * - If user has no pending unallocation, reverts with `NoPendingUnallocation`
     * - If vault has no redeemable amount and no previously withdrawn amount, reverts with `InvalidAmount`
     * - If signature is invalid or expired, the strategy deposit will fail
     * - If calculated amount is 0, reverts with `InvalidAmount`
     *
     * @param _alephVault The Aleph vault address to complete unallocation from (must be initialized)
     * @param _strategyDepositExpiry The expiry timestamp for the strategy deposit signature (must be in future)
     * @param _strategyDepositSignature The caller's EIP-712 signature for depositing back into the original LST strategy
     * @return amount The amount of tokens redeemed from the vault and deposited to the strategy
     * @return shares The shares received in the original LST strategy
     *
     * @custom:example
     * ```solidity
     * // First, check status and get expected amount
     * uint256 expectedAmount = alephAVS.calculateCompleteUnallocateAmount(userAddress, vaultAddress);
     * // Generate signature with expectedAmount
     * bytes memory sig = generateStrategyDepositSignature(expectedAmount, nonce, expiry);
     * // Complete unallocation
     * (uint256 amount, uint256 shares) = alephAVS.completeUnallocate(vaultAddress, expiry, sig);
     * ```
     */
    function completeUnallocate(
        address _alephVault,
        uint256 _strategyDepositExpiry,
        bytes calldata _strategyDepositSignature
    ) external returns (uint256 amount, uint256 shares);

    /**
     * @notice Calculates the estimated amount that will be redeemed from the vault for unallocation
     * @dev This view function allows callers to calculate the amount before calling unallocate,
     *      so they can create the signature for depositIntoStrategyWithSignature
     * @param _alephVault The Aleph vault address to unallocate from
     * @param _tokenAmount The amount of slashed strategy tokens to unallocate
     * @return estimatedAmount The estimated amount of tokens that will be redeemed from the vault
     * @return strategy The original LST strategy where tokens will be deposited
     * @return token The vault token that will be deposited to the strategy
     */
    function calculateUnallocateAmount(address _alephVault, uint256 _tokenAmount)
        external
        view
        returns (uint256 estimatedAmount, IStrategy strategy, IERC20 token);

    /**
     * @notice Returns the pending unallocation status for a user and vault
     * @dev This view function allows users to check if they can call completeUnallocate
     * @param _user The user address to check
     * @param _alephVault The Aleph vault address
     * @return userPendingAmount The user's pending unallocation amount
     * @return totalPendingAmount The total pending unallocation amount for the vault
     * @return redeemableAmount The amount currently redeemable from the vault
     * @return canComplete Whether the user can complete unallocation (has pending amount and vault has redeemable amount)
     */
    function getPendingUnallocateStatus(address _user, address _alephVault)
        external
        view
        returns (uint256 userPendingAmount, uint256 totalPendingAmount, uint256 redeemableAmount, bool canComplete);

    /**
     * @notice Calculates the expected amount that will be withdrawn in completeUnallocate
     * @dev This view function allows users to calculate the exact amount before calling `completeUnallocate`,
     *      so they can generate the strategy deposit signature with the correct amount.
     *
     * **Use this function to:**
     * 1. Get the expected amount for signature generation
     * 2. Verify if unallocation can be completed
     * 3. Check the amount before calling `completeUnallocate`
     *
     * **Calculation Logic:**
     * - If user is the only one with pending unallocation: gets all available redeemable amount
     * - If multiple users have pending: proportional distribution based on their pending amounts
     * - Formula: (userPendingAmount / totalPendingAmount) * totalRedeemableAmount
     * - Total redeemable = vault redeemable amount + previously withdrawn amount
     *
     * **Important:**
     * - This is a view function - no state changes
     * - The actual amount in `completeUnallocate` may be slightly different due to:
     *   - Rounding differences
     *   - Changes in vault redeemable amount between calls
     *   - Contract balance constraints
     * - Always use this amount for signature generation to ensure it matches
     *
     * @param _user The user address to calculate for
     * @param _alephVault The Aleph vault address
     * @return expectedAmount The expected amount that will be withdrawn and deposited to strategy (0 if no pending or no redeemable)
     *
     * @custom:example
     * ```solidity
     * uint256 expected = alephAVS.calculateCompleteUnallocateAmount(userAddress, vaultAddress);
     * if (expected > 0) {
     *     // Generate signature with expected amount
     *     bytes memory sig = generateSignature(expected, nonce, expiry);
     *     // Then call completeUnallocate
     * }
     * ```
     */
    function calculateCompleteUnallocateAmount(address _user, address _alephVault)
        external
        view
        returns (uint256 expectedAmount);

    /**
     * @notice Initializes a vault by creating its slashed token and strategy
     * @param _classId The share class ID for the vault
     * @param _vault The vault address to initialize
     * @param _lstStrategy The original LST strategy for the vault's underlying token
     * @return slashedStrategy The created slashed strategy address
     */
    function initializeVault(uint8 _classId, address _vault, IStrategy _lstStrategy)
        external
        returns (IStrategy slashedStrategy);
}
