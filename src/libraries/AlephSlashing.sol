// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IAllocationManagerTypes} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {AlephUtils} from "./AlephUtils.sol";

/**
 * @title AlephSlashing
 * @notice Library for slashing-related calculations and operations
 * @dev Provides functions for calculating magnitudes, wads, and executing slashes
 */
library AlephSlashing {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error AmountTooSmall();
    error InsufficientAllocation();
    error MagnitudeOverflow();

    /*//////////////////////////////////////////////////////////////
                    MAGNITUDE CALCULATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate magnitude to slash from underlying token amount
     * @param _allocationManager The AllocationManager contract
     * @param _operator The operator address
     * @param _operatorSet The operator set
     * @param _amount The underlying token amount
     * @param _strategy The strategy
     * @return magnitudeToSlash The magnitude to slash
     */
    function calculateMagnitudeFromAmount(
        IAllocationManager _allocationManager,
        address _operator,
        OperatorSet memory _operatorSet,
        uint256 _amount,
        IStrategy _strategy
    ) internal view returns (uint64 magnitudeToSlash) {
        uint256 sharesNeeded = _strategy.underlyingToSharesView(_amount);
        if (sharesNeeded == 0) revert AmountTooSmall();

        uint256 allocatedShares = getAllocatedShares(_allocationManager, _operator, _operatorSet, _strategy);
        if (allocatedShares < sharesNeeded) revert InsufficientAllocation();

        IAllocationManagerTypes.Allocation memory allocation =
            _allocationManager.getAllocation(_operator, _operatorSet, _strategy);
        uint256 magnitudeUint = Math.mulDiv(uint256(allocation.currentMagnitude), sharesNeeded, allocatedShares);

        if (magnitudeUint > uint256(allocation.currentMagnitude)) {
            magnitudeUint = uint256(allocation.currentMagnitude);
        }
        if (magnitudeUint > type(uint64).max) revert MagnitudeOverflow();

        // casting to 'uint64' is safe because we check magnitudeUint <= type(uint64).max above
        // forge-lint: disable-next-line(unsafe-typecast)
        magnitudeToSlash = uint64(magnitudeUint);
    }

    /**
     * @notice Get allocated shares for an operator in an operator set
     * @param _allocationManager The AllocationManager contract
     * @param _operator The operator address
     * @param _operatorSet The operator set
     * @param _strategy The strategy
     * @return The allocated shares
     */
    function getAllocatedShares(
        IAllocationManager _allocationManager,
        address _operator,
        OperatorSet memory _operatorSet,
        IStrategy _strategy
    ) internal view returns (uint256) {
        address[] memory operators = new address[](1);
        operators[0] = _operator;
        IStrategy[] memory strategyArray = AlephUtils.asStrategyArray(_strategy);
        uint256[][] memory allocatedStakes =
            _allocationManager.getAllocatedStake(_operatorSet, operators, strategyArray);
        return allocatedStakes[0][0];
    }

    /**
     * @notice Verify operator has allocated magnitude to the operator set
     * @param _allocationManager The AllocationManager contract
     * @param _operator The operator address
     * @param _operatorSet The operator set
     * @param _magnitudeToSlash The magnitude to slash
     * @param _strategy The strategy
     */
    function verifyOperatorAllocation(
        IAllocationManager _allocationManager,
        address _operator,
        OperatorSet memory _operatorSet,
        uint64 _magnitudeToSlash,
        IStrategy _strategy
    ) internal view {
        IAllocationManagerTypes.Allocation memory allocation =
            _allocationManager.getAllocation(_operator, _operatorSet, _strategy);
        if (allocation.currentMagnitude < _magnitudeToSlash) revert InsufficientAllocation();
    }

    /*//////////////////////////////////////////////////////////////
                        SLASHING EXECUTION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute slash of operator to redistribute shares
     * @param _allocationManager The AllocationManager contract
     * @param _avsAddress The AVS address (slash caller)
     * @param _operator The operator to slash
     * @param _operatorSetId The operator set ID
     * @param _magnitudeToSlash The magnitude to slash
     * @param _strategy The strategy being slashed
     * @param _slashDescription The description for the slash
     * @return slashId The ID of the slash
     */
    function executeSlashAndGetId(
        IAllocationManager _allocationManager,
        address _avsAddress,
        address _operator,
        uint32 _operatorSetId,
        uint64 _magnitudeToSlash,
        IStrategy _strategy,
        string memory _slashDescription
    ) internal returns (uint256 slashId) {
        OperatorSet memory operatorSet = AlephUtils.getOperatorSet(_avsAddress, _operatorSetId);
        IAllocationManagerTypes.Allocation memory allocation =
            _allocationManager.getAllocation(_operator, operatorSet, _strategy);
        uint256 wadToSlash = calculateWadToSlash(_magnitudeToSlash, allocation.currentMagnitude);

        IStrategy[] memory strategyArray = AlephUtils.asStrategyArray(_strategy);
        uint256[] memory wadsToSlash = new uint256[](1);
        wadsToSlash[0] = wadToSlash;

        IAllocationManagerTypes.SlashingParams memory slashingParams = IAllocationManagerTypes.SlashingParams({
            operator: _operator,
            operatorSetId: _operatorSetId,
            strategies: strategyArray,
            wadsToSlash: wadsToSlash,
            description: _slashDescription
        });

        (slashId,) = _allocationManager.slashOperator(_avsAddress, slashingParams);
        return slashId;
    }

    /**
     * @notice Calculate wad to slash from magnitude and current magnitude
     * @param _magnitudeToSlash The magnitude to slash
     * @param _currentMagnitude The current magnitude of the allocation
     * @return The wad (proportion) to slash, capped at 1e18 (100%)
     */
    function calculateWadToSlash(uint64 _magnitudeToSlash, uint64 _currentMagnitude) internal pure returns (uint256) {
        if (_currentMagnitude == 0 || _magnitudeToSlash == 0) return 0;

        uint64 _magnitudeToSlashAdjusted = _magnitudeToSlash > _currentMagnitude ? _currentMagnitude : _magnitudeToSlash;

        uint256 _wad = Math.mulDiv(uint256(_magnitudeToSlashAdjusted), AlephUtils.WAD, uint256(_currentMagnitude));

        return _wad > AlephUtils.WAD ? AlephUtils.WAD : _wad;
    }

    /**
     * @notice Clear redistributable shares and receive tokens
     * @param _strategyManager The StrategyManager contract
     * @param _avsAddress The AVS address
     * @param _operatorSetId The operator set ID
     * @param _slashId The slash ID
     * @param _strategy The strategy
     * @return The token amount received
     */
    function clearRedistributableShares(
        IStrategyManager _strategyManager,
        address _avsAddress,
        uint32 _operatorSetId,
        uint256 _slashId,
        IStrategy _strategy
    ) internal returns (uint256) {
        OperatorSet memory operatorSet = AlephUtils.getOperatorSet(_avsAddress, _operatorSetId);
        return _strategyManager.clearBurnOrRedistributableSharesByStrategy(operatorSet, _slashId, _strategy);
    }
}

