// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";
import {IAlephVaultFactory} from "Aleph/src/interfaces/IAlephVaultFactory.sol";
import {AlephUtils} from "./AlephUtils.sol";

/**
 * @title AlephValidation
 * @notice Library for validation logic across Aleph contracts
 * @dev Provides validation functions for operator sets, vaults, and strategies
 */
library AlephValidation {
    /*//////////////////////////////////////////////////////////////
                                   ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidOperatorSet();
    error NotMemberOfOperatorSet();
    error InvalidAlephVault();
    error InvalidStrategy();

    /**
     * @notice Validates operator set and membership
     * @param _allocationManager The AllocationManager contract
     * @param _operator The operator address
     * @param _operatorSet The operator set
     */
    function validateOperatorSetAndMembership(
        IAllocationManager _allocationManager,
        address _operator,
        OperatorSet memory _operatorSet
    ) internal view {
        if (!_allocationManager.isOperatorSet(_operatorSet)) revert InvalidOperatorSet();
        if (!_allocationManager.isMemberOfOperatorSet(_operator, _operatorSet)) revert NotMemberOfOperatorSet();
    }

    /*//////////////////////////////////////////////////////////////
                          VAULT VALIDATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validates that an address is a valid Aleph vault
     * @param _vaultFactory The Aleph Vault Factory contract
     * @param _alephVault The vault address to validate
     */
    function validateVault(IAlephVaultFactory _vaultFactory, address _alephVault) internal view {
        if (!_vaultFactory.isValidVault(_alephVault)) {
            revert InvalidAlephVault();
        }
    }

    /*//////////////////////////////////////////////////////////////
                          STRATEGY VALIDATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validates that a strategy address is not zero
     * @param _strategy The strategy address
     */
    function validateStrategy(address _strategy) internal pure {
        if (_strategy == address(0)) {
            revert InvalidStrategy();
        }
    }
}

