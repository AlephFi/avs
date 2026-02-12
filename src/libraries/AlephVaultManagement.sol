// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20 as IERC20Eigen} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Math} from "Aleph/src/libraries/ERC4626Math.sol";
import {IAlephVault} from "Aleph/src/interfaces/IAlephVault.sol";
import {IAlephVaultDeposit} from "Aleph/src/interfaces/IAlephVaultDeposit.sol";
import {IAlephVaultRedeem} from "Aleph/src/interfaces/IAlephVaultRedeem.sol";
import {IAlephVaultFactory} from "Aleph/src/interfaces/IAlephVaultFactory.sol";
import {IStrategyFactory} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyFactory.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IERC20Factory} from "../interfaces/IERC20Factory.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IMintableBurnableERC20} from "../interfaces/IMintableBurnableERC20.sol";
import {AlephUtils} from "./AlephUtils.sol";
import {AlephValidation} from "./AlephValidation.sol";

/**
 * @title AlephVaultManagement
 * @notice Library for vault management operations
 * @dev Provides functions for vault interactions, slashed token/strategy creation, deposits, withdrawals, and calculations
 */
library AlephVaultManagement {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidAlephVault();

    /*//////////////////////////////////////////////////////////////
                        VAULT TOKEN/STRATEGY HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the vault token
     * @param _vaultFactory The Aleph Vault Factory
     * @param _vault The vault address
     * @return vaultToken The vault's underlying token
     */
    function getVaultToken(IAlephVaultFactory _vaultFactory, address _vault) internal view returns (IERC20 vaultToken) {
        AlephValidation.validateVault(_vaultFactory, _vault);
        vaultToken = IERC20(address(IAlephVault(_vault).underlyingToken()));
    }

    /**
     * @notice Gets the vault token and validates the provided strategy
     * @param _vaultFactory The Aleph Vault Factory
     * @param _vault The vault address
     * @param _strategy The strategy to validate (must match vault's underlying token)
     * @return vaultToken The vault's underlying token
     */
    function getVaultTokenAndStrategy(IAlephVaultFactory _vaultFactory, address _vault, IStrategy _strategy)
        internal
        view
        returns (IERC20 vaultToken)
    {
        vaultToken = getVaultToken(_vaultFactory, _vault);
        AlephValidation.validateStrategy(address(_strategy));
        if (address(_strategy.underlyingToken()) != address(vaultToken)) {
            revert AlephValidation.InvalidStrategy();
        }
    }

    /**
     * @notice Creates or gets the slashed token for a vault
     * @param _erc20Factory The ERC20 Factory
     * @param _vault The vault address
     * @param _originalToken The original token (vault's underlying token)
     * @return slashedToken The slashed token address
     */
    function createSlashedTokenForVault(IERC20Factory _erc20Factory, address _vault, IERC20 _originalToken)
        internal
        returns (IERC20 slashedToken)
    {
        // Create new slashed token
        // Naming convention: "al" prefix stands for "Aleph"
        // Format: "al<OriginalTokenName>-<VaultName>"
        string memory _vaultName = IAlephVault(_vault).name();
        string memory _originalName = IERC20Metadata(address(_originalToken)).name();
        string memory _originalSymbol = IERC20Metadata(address(_originalToken)).symbol();

        string memory _tokenName = string.concat("al", _originalName, "-", _vaultName);
        string memory _tokenSymbol = string.concat("al", _originalSymbol, "-", _vaultName);

        address _slashedTokenAddress =
            _erc20Factory.createToken(_tokenName, _tokenSymbol, IERC20Metadata(address(_originalToken)).decimals());

        slashedToken = IERC20(_slashedTokenAddress);
    }

    /**
     * @notice Creates or gets the slashed strategy for a vault
     * @param _strategyFactory The Strategy Factory
     * @param _vault The vault address
     * @param _originalToken The original token (vault's underlying token)
     * @param _erc20Factory The ERC20 Factory
     * @return slashedToken The slashed token
     * @return slashedStrategy The slashed strategy
     */
    function createSlashedStrategyForVault(
        IStrategyFactory _strategyFactory,
        address _vault,
        IERC20 _originalToken,
        mapping(address => IStrategy) storage _vaultToSlashedStrategy,
        IERC20Factory _erc20Factory
    ) internal returns (IERC20 slashedToken, IStrategy slashedStrategy) {
        slashedToken = createSlashedTokenForVault(_erc20Factory, _vault, _originalToken);

        // Convert to IERC20Eigen for StrategyFactory (uses @openzeppelin/contracts IERC20)
        // Note: StrategyFactory expects IERC20 from @openzeppelin/contracts, which is IERC20Eigen
        IERC20Eigen _slashedTokenEigen = IERC20Eigen(address(slashedToken));

        // Check if a strategy already exists for this token (edge case: partial transaction)
        // This should never happen with CREATE, but we handle it gracefully
        IStrategy _existingStrategy = _strategyFactory.deployedStrategies(_slashedTokenEigen);

        if (address(_existingStrategy) != address(0)) {
            // Strategy already exists - reuse it (this handles edge cases from partial transactions)
            slashedStrategy = _existingStrategy;
        } else {
            // Deploy a new strategy for the newly created slashed token
            slashedStrategy = _strategyFactory.deployNewStrategy(_slashedTokenEigen);
        }

        // Store in mapping for easy querying
        _vaultToSlashedStrategy[_vault] = slashedStrategy;
    }

    /*//////////////////////////////////////////////////////////////
                        VAULT OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits tokens to an Aleph vault synchronously
     * @param _vault The vault address
     * @param _requestDepositParams The deposit parameters
     * @param _tokenAmount The token amount to deposit (may differ from _requestDepositParams.amount due to rounding)
     * @return shares The number of shares minted
     */
    function depositToAlephVault(
        address _vault,
        IAlephVaultDeposit.RequestDepositParams calldata _requestDepositParams,
        uint256 _tokenAmount
    ) internal returns (uint256 shares) {
        IERC20 _vaultToken = IERC20(IAlephVault(_vault).underlyingToken());
        // Use actual balance to handle rebasing tokens (e.g. stETH) where
        // transfers can lose 1-2 wei due to share rounding.
        uint256 _depositAmount = _vaultToken.balanceOf(address(this));
        SafeERC20.forceApprove(_vaultToken, _vault, _depositAmount);

        IAlephVaultDeposit.RequestDepositParams memory adjustedParams = IAlephVaultDeposit.RequestDepositParams({
            classId: _requestDepositParams.classId,
            amount: _depositAmount,
            authSignature: _requestDepositParams.authSignature
        });

        if (!IAlephVault(_vault).isTotalAssetsValid(_requestDepositParams.classId)) {
            IAlephVaultDeposit(_vault).requestDeposit(adjustedParams);
            shares = 0;
        } else {
            shares = IAlephVaultDeposit(_vault).syncDeposit(adjustedParams);
        }
        SafeERC20.forceApprove(_vaultToken, _vault, 0);
    }

    /**
     * @notice Calculates the amount of slashed tokens to mint based on the amount to deposit
     * @param _classId The share class ID
     * @param _vault The vault address
     * @param _slashedToken The slashed token address
     * @param _amount The amount deposited to the vault
     * @return The amount of slashed tokens to mint
     */
    function calculateAmountToMint(uint8 _classId, address _vault, address _slashedToken, uint256 _amount)
        internal
        view
        returns (uint256)
    {
        return ERC4626Math.previewDeposit(
            _amount, IERC20(_slashedToken).totalSupply(), IAlephVault(_vault).assetsPerClassOf(_classId, address(this))
        );
    }

    /**
     * @notice Calculates the amount of tokens to redeem based on the amount of slashed tokens to burn
     * @param _classId The share class ID
     * @param _vault The vault address
     * @param _slashedToken The slashed token address
     * @param _amount The amount of slashed tokens to burn
     * @return The amount of tokens to redeem
     */
    function calculateAmountToRedeem(uint8 _classId, address _vault, address _slashedToken, uint256 _amount)
        internal
        view
        returns (uint256)
    {
        return ERC4626Math.previewRedeem(
            _amount, IAlephVault(_vault).assetsPerClassOf(_classId, address(this)), IERC20(_slashedToken).totalSupply()
        );
    }

    /**
     * @notice Redeems tokens from the vault with calculated parameters
     * @param _vault The vault address
     * @param _slashedStrategy The slashed strategy
     * @param _amount The amount of slashed tokens to redeem
     * @param _classId The share class ID
     * @return amount The amount of tokens redeemed
     */
    function redeemFromVault(address _vault, IStrategy _slashedStrategy, uint256 _amount, uint8 _classId)
        internal
        returns (uint256 amount)
    {
        uint256 _estAmountToRedeem =
            calculateAmountToRedeem(_classId, _vault, address(_slashedStrategy.underlyingToken()), _amount);
        IAlephVaultRedeem.RedeemRequestParams memory _redeemParams =
            IAlephVaultRedeem.RedeemRequestParams({classId: _classId, estAmountToRedeem: _estAmountToRedeem});
        return IAlephVaultRedeem(_vault).syncRedeem(_redeemParams);
    }

    /*//////////////////////////////////////////////////////////////
                        SLASHED TOKEN OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validates balance and burns slashed tokens
     * @param _tokenHolder The token holder address
     * @param _slashedStrategy The slashed strategy
     * @param _tokenAmount The amount to burn
     * @param _contractAddress The contract address to transfer tokens to
     */
    function validateAndBurnSlashedTokens(
        address _tokenHolder,
        IStrategy _slashedStrategy,
        uint256 _tokenAmount,
        address _contractAddress
    ) internal {
        IMintableBurnableERC20 _slashedToken = IMintableBurnableERC20(address(_slashedStrategy.underlyingToken()));
        IERC20 _token = IERC20(address(_slashedToken));
        if (_token.balanceOf(_tokenHolder) < _tokenAmount) revert InsufficientBalance();

        _token.safeTransferFrom(_tokenHolder, _contractAddress, _tokenAmount);
        _slashedToken.burn(_contractAddress, _tokenAmount);
    }

    error InsufficientBalance();

    /*//////////////////////////////////////////////////////////////
                        STRATEGY DEPOSIT OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits tokens back into the original strategy on behalf of a staker
     * @param _strategyManager The StrategyManager contract
     * @param _targetStrategy The target strategy to deposit to (from initializeVault)
     * @param _token The token to deposit
     * @param _staker The staker address
     * @param _tokenAmount The token amount to deposit
     * @param _expiry The expiry timestamp for the signature
     * @param _signature The staker's signature
     * @return shares The shares received in the strategy
     */
    function depositToOriginalStrategy(
        IStrategyManager _strategyManager,
        IStrategy _targetStrategy,
        IERC20 _token,
        address _staker,
        uint256 _tokenAmount,
        uint256 _expiry,
        bytes calldata _signature
    ) internal returns (uint256 shares) {
        AlephValidation.validateStrategy(address(_targetStrategy));

        SafeERC20.forceApprove(_token, address(_strategyManager), _tokenAmount);
        shares = _strategyManager.depositIntoStrategyWithSignature(
            _targetStrategy, IERC20Eigen(address(_token)), _tokenAmount, _staker, _expiry, _signature
        );
        SafeERC20.forceApprove(_token, address(_strategyManager), 0);
    }
}

