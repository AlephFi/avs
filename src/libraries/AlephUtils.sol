// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";

/**
 * @title AlephUtils
 * @notice Utility library for common functions used across Aleph contracts
 * @dev This library provides reusable utility functions to reduce code duplication
 */
library AlephUtils {
    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint32 public constant LST_STRATEGIES_OPERATOR_SET_ID = 0;
    uint32 public constant SLASHED_STRATEGIES_OPERATOR_SET_ID = 1;
    uint64 public constant OPERATOR_SET_MAGNITUDE = 1e18;
    uint256 public constant WAD = 1e18;
    uint96 public constant REWARD_MULTIPLIER = uint96(1e18);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidAddress();

    /*//////////////////////////////////////////////////////////////
                          VALIDATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validates that an address is not the zero address
     * @param _address The address to validate
     * @dev Reverts with InvalidAddress if the address is zero
     */
    function validateAddress(address _address) internal pure {
        if (_address == address(0)) {
            revert InvalidAddress();
        }
    }

    /**
     * @notice Validates that an address is not the zero address with custom error selector
     * @param _address The address to validate
     * @param _errorSelector The error selector to use if validation fails
     * @dev Uses assembly to revert with the provided error selector
     */
    function validateAddressWithSelector(address _address, bytes4 _errorSelector) internal pure {
        if (_address == address(0)) {
            assembly {
                mstore(0x00, _errorSelector)
                revert(0x00, 0x04)
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          STRATEGY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Converts a single strategy to an array
     * @param _strategy The strategy to convert
     * @return An array containing the single strategy
     */
    function asStrategyArray(IStrategy _strategy) internal pure returns (IStrategy[] memory) {
        IStrategy[] memory arr = new IStrategy[](1);
        arr[0] = _strategy;
        return arr;
    }

    /**
     * @notice Creates a single-element strategy array with magnitude
     * @param _strategy The strategy
     * @param _magnitude The magnitude
     * @return strategies Array of strategies
     * @return magnitudes Array of magnitudes
     */
    function createStrategyAllocationParams(IStrategy _strategy, uint64 _magnitude)
        internal
        pure
        returns (IStrategy[] memory strategies, uint64[] memory magnitudes)
    {
        strategies = new IStrategy[](1);
        strategies[0] = _strategy;
        magnitudes = new uint64[](1);
        magnitudes[0] = _magnitude;
    }

    /*//////////////////////////////////////////////////////////////
                          OPERATOR SET FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets an operator set for a given AVS address
     * @param _avsAddress The AVS contract address
     * @param _operatorSetId The operator set ID
     * @return The operator set
     */
    function getOperatorSet(address _avsAddress, uint32 _operatorSetId) internal pure returns (OperatorSet memory) {
        return OperatorSet(_avsAddress, _operatorSetId);
    }
}

