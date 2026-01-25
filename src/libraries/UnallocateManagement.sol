// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IAlephVaultRedeem} from "Aleph/src/interfaces/IAlephVaultRedeem.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title UnallocateManagement
 * @notice Library for managing unallocate operations
 * @dev Handles calculation logic for unallocate operations to reduce contract size
 */
library UnallocateManagement {
    /**
     * @notice Calculates the user's proportional share for complete unallocate
     * @dev Calculates share based on proportional distribution. If user is the last one or calculated
     *      share exceeds available, they receive all remaining withdrawn amount.
     * @param _userPendingAmount The user's pending unallocation amount
     * @param _totalPending The total pending unallocation amount across all users
     * @param _totalRedeemableAmount The total redeemable amount (vault redeemable + previously withdrawn)
     * @param _withdrawnAmount The currently withdrawn amount stored in contract
     * @return _userShare The user's calculated share amount
     */
    function calculateUserShare(
        uint256 _userPendingAmount,
        uint256 _totalPending,
        uint256 _totalRedeemableAmount,
        uint256 _withdrawnAmount
    ) internal pure returns (uint256 _userShare) {
        if (_totalPending == 0 || _userPendingAmount == 0) {
            return 0;
        }

        // Calculate user's share: (userPending / totalPending) * totalRedeemable
        _userShare = (_userPendingAmount * _totalRedeemableAmount) / _totalPending;

        // If this is the last user (or only user), they get all remaining withdrawn amount
        if (_totalPending == _userPendingAmount || _userShare > _withdrawnAmount) {
            _userShare = _withdrawnAmount > 0 ? _withdrawnAmount : _totalRedeemableAmount;
        }
    }

    /**
     * @notice Calculates the expected amount for complete unallocate (pure view function)
     * @dev This is a pure function that calculates the expected amount before any state changes.
     *      Used for signature generation. Handles proportional distribution and edge cases.
     * @param _userPendingAmount The user's pending unallocation amount
     * @param _totalPending The total pending unallocation amount across all users
     * @param _vaultRedeemableAmount The current redeemable amount available in the vault
     * @param _withdrawnAmount The amount previously withdrawn and stored in contract
     * @return _expectedAmount The expected amount the user will receive (0 if no pending or no redeemable)
     */
    function calculateCompleteUnallocateAmountView(
        uint256 _userPendingAmount,
        uint256 _totalPending,
        uint256 _vaultRedeemableAmount,
        uint256 _withdrawnAmount
    ) internal pure returns (uint256 _expectedAmount) {
        if (_userPendingAmount == 0) {
            return 0;
        }

        uint256 _totalRedeemableAmount = _vaultRedeemableAmount + _withdrawnAmount;
        if (_totalRedeemableAmount == 0 || _totalPending == 0) {
            return 0;
        }

        // Calculate expected share: (userPending / totalPending) * totalRedeemable
        _expectedAmount = (_userPendingAmount * _totalRedeemableAmount) / _totalPending;

        // Available amount is what can actually be withdrawn:
        // - If vault has new redeemable: available = vaultRedeemable + withdrawn (will be withdrawn in completeUnallocate)
        // - If vault has no new redeemable: available = withdrawn (already withdrawn)
        uint256 _availableAmount = _vaultRedeemableAmount > 0 ? _totalRedeemableAmount : _withdrawnAmount;

        // If this is the last user (or only user), they get all remaining available amount
        // Also if calculated share exceeds available, cap to available (last user gets remainder)
        if (_totalPending == _userPendingAmount) {
            // Last user gets all available
            _expectedAmount = _availableAmount;
        } else if (_expectedAmount > _availableAmount) {
            // Calculated share exceeds available, cap to available
            _expectedAmount = _availableAmount;
        }
    }

    /**
     * @notice Withdraws redeemable amount from vault and calculates total available
     * @dev Withdraws new redeemable funds if available, otherwise uses previously withdrawn amount.
     *      Verifies actual contract balance when using previously withdrawn funds.
     * @param _alephVault The vault address to withdraw from
     * @param _vaultToken The vault token contract
     * @param _vaultRedeemableAmount The current redeemable amount available in the vault
     * @param _withdrawnAmount The amount previously withdrawn and stored in contract state
     * @return _totalRedeemableAmount The total amount available (newly withdrawn + previously withdrawn)
     * @custom:reverts If no funds are available (should be checked before calling)
     */
    function withdrawAndCalculateAvailable(
        address _alephVault,
        IERC20 _vaultToken,
        uint256 _vaultRedeemableAmount,
        uint256 _withdrawnAmount
    ) internal returns (uint256 _totalRedeemableAmount) {
        if (_vaultRedeemableAmount > 0) {
            // Withdraw new redeemable amount from vault
            IAlephVaultRedeem(_alephVault).withdrawRedeemableAmount();
            _totalRedeemableAmount = _vaultRedeemableAmount + _withdrawnAmount;
        } else if (_withdrawnAmount > 0) {
            // Use previously withdrawn amount, but check actual contract balance
            uint256 _contractBalance = _vaultToken.balanceOf(address(this));
            _totalRedeemableAmount = _contractBalance < _withdrawnAmount ? _contractBalance : _withdrawnAmount;
        } else {
            // No funds available - this should be caught before calling this function
            revert();
        }
    }

    /**
     * @notice Calculates the final amount to withdraw, capping to available balances
     * @dev Caps the calculated share to both available amount and contract balance to ensure
     *      we never attempt to withdraw more than what's actually available.
     * @param _calculatedShare The user's calculated proportional share
     * @param _availableAmount The amount available for withdrawal (vault-specific)
     * @param _contractBalance The contract's current token balance (global safety check)
     * @return _finalAmount The final amount to withdraw (capped to minimum of share, available, and balance)
     * @custom:reverts If final amount is zero after capping
     */
    function calculateFinalAmount(uint256 _calculatedShare, uint256 _availableAmount, uint256 _contractBalance)
        internal
        pure
        returns (uint256 _finalAmount)
    {
        _finalAmount = _calculatedShare;

        // Cap to available amount
        if (_finalAmount > _availableAmount) {
            _finalAmount = _availableAmount;
        }

        // Cap to contract balance
        if (_finalAmount > _contractBalance) {
            _finalAmount = _contractBalance;
        }

        if (_finalAmount == 0) {
            revert();
        }
    }

    /**
     * @notice Calculates new storage values after processing unallocation
     * @dev Pure function that calculates what storage values should be after completing an unallocation.
     *      Reduces withdrawn amount by the amount used, reduces total pending by user's pending amount.
     *      Clears withdrawn amount if no more pending unallocations remain.
     * @param _currentVaultWithdrawnAmount Current total withdrawn amount stored for this vault
     * @param _amount The amount being withdrawn and used in this unallocation
     * @param _userPendingAmount The user's pending unallocation amount being processed
     * @param _totalPending The total pending unallocation amount across all users
     * @return _newVaultWithdrawnAmount New vault withdrawn amount (current - amount used, or 0 if no pending left)
     * @return _newTotalPending New total pending amount (total - user's pending, or 0 if invalid)
     */
    function calculateUnallocationStorageUpdates(
        uint256 _currentVaultWithdrawnAmount,
        uint256 _amount,
        uint256 _userPendingAmount,
        uint256 _totalPending
    ) internal pure returns (uint256 _newVaultWithdrawnAmount, uint256 _newTotalPending) {
        // Update vault withdrawn amount: subtract the amount being used
        _newVaultWithdrawnAmount = _currentVaultWithdrawnAmount - _amount;

        // Update total pending: subtract user's pending amount
        if (_userPendingAmount > _totalPending) {
            _newTotalPending = 0;
        } else {
            _newTotalPending = _totalPending - _userPendingAmount;
        }

        // If no more pending unallocations, clear withdrawn amount
        if (_newTotalPending == 0 && _newVaultWithdrawnAmount > 0) {
            _newVaultWithdrawnAmount = 0;
        }
    }
}
