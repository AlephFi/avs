// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IAllocationManagerTypes} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";
import {AlephUtils} from "./AlephUtils.sol";

/**
 * @title AllocationManagement
 * @notice Library for managing operator allocations to EigenLayer operator sets
 */
library AllocationManagement {
    /**
     * @notice Allocates stake to both LST and slashed strategies for a vault
     * @param _allocationManager The AllocationManager contract
     * @param _operator The operator address (must be msg.sender when called from contract)
     * @param _avsAddress The AVS address
     * @param _lstStrategy The LST strategy to allocate to
     * @param _slashedStrategy The slashed strategy to allocate to
     * @param _lstStrategies Storage array for LST strategies (maintained in sorted order)
     * @param _slashedStrategies Storage array for slashed strategies (maintained in sorted order)
     * @dev Updates stored state and calls modifyAllocations with current strategies.
     *      IMPORTANT: _operator must equal msg.sender when this is called, as modifyAllocations
     *      requires the caller to be the operator or an authorized appointee.
     */
    function allocateStakeForVaultStrategies(
        IAllocationManager _allocationManager,
        address _operator,
        address _avsAddress,
        IStrategy _lstStrategy,
        IStrategy _slashedStrategy,
        IStrategy[] storage _lstStrategies,
        IStrategy[] storage _slashedStrategies
    ) internal {
        // Prepare allocation params for both operator sets
        IAllocationManagerTypes.AllocateParams memory _lstParams = _prepareAllocationParams(
            _avsAddress, AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID, _lstStrategy, _lstStrategies
        );
        IAllocationManagerTypes.AllocateParams memory _slashedParams = _prepareAllocationParams(
            _avsAddress, AlephUtils.SLASHED_STRATEGIES_OPERATOR_SET_ID, _slashedStrategy, _slashedStrategies
        );

        // Execute allocations - _operator must be msg.sender for authorization to pass
        IAllocationManagerTypes.AllocateParams[] memory _params = new IAllocationManagerTypes.AllocateParams[](2);
        _params[0] = _lstParams;
        _params[1] = _slashedParams;
        _allocationManager.modifyAllocations(_operator, _params);
    }

    /**
     * @notice Prepares allocation params for a single operator set (view function)
     * @param _avsAddress The AVS address
     * @param _operatorSetId The operator set ID
     * @param _strategies Storage array for strategies (maintained in sorted order)
     * @return params The prepared AllocateParams
     * @dev This is a view function that prepares params without modifying storage.
     */
    function prepareAllocationParams(address _avsAddress, uint32 _operatorSetId, IStrategy[] storage _strategies)
        internal
        view
        returns (IAllocationManagerTypes.AllocateParams memory params)
    {
        return _buildAllocateParams(_avsAddress, _operatorSetId, _strategies);
    }

    /**
     * @notice Prepares allocation params for a single operator set (internal function that modifies storage)
     * @param _avsAddress The AVS address
     * @param _operatorSetId The operator set ID
     * @param _strategy The strategy to add
     * @param _strategies Storage array for strategies (maintained in sorted order)
     * @return params The prepared AllocateParams
     */
    function _prepareAllocationParams(
        address _avsAddress,
        uint32 _operatorSetId,
        IStrategy _strategy,
        IStrategy[] storage _strategies
    ) private returns (IAllocationManagerTypes.AllocateParams memory params) {
        // Add strategy if new
        addStrategy(_strategies, _strategy);

        // Build params from storage
        return _buildAllocateParams(_avsAddress, _operatorSetId, _strategies);
    }

    /**
     * @notice Builds AllocateParams from strategies array
     * @param _avsAddress The AVS address
     * @param _operatorSetId The operator set ID
     * @param _strategies Storage array for strategies (maintained in sorted order)
     * @return params The prepared AllocateParams
     */
    function _buildAllocateParams(address _avsAddress, uint32 _operatorSetId, IStrategy[] storage _strategies)
        private
        view
        returns (IAllocationManagerTypes.AllocateParams memory params)
    {
        OperatorSet memory _operatorSet = AlephUtils.getOperatorSet(_avsAddress, _operatorSetId);
        (IStrategy[] memory _strategiesArray, uint64[] memory _magnitudesArray) = buildParams(_strategies);

        params = IAllocationManagerTypes.AllocateParams({
            operatorSet: _operatorSet, strategies: _strategiesArray, newMagnitudes: _magnitudesArray
        });
    }

    /**
     * @notice Adds strategy to array if it doesn't exist, maintaining sorted order
     */
    function addStrategy(IStrategy[] storage _strategies, IStrategy _strategy) internal {
        address _addr = address(_strategy);
        uint256 _count = _strategies.length;

        // Check if exists and find insertion point in one pass
        for (uint256 i = 0; i < _count; i++) {
            address _existing = address(_strategies[i]);
            if (_existing == _addr) return; // Already exists
            if (_existing > _addr) {
                // Found insertion point - shift and insert
                _strategies.push();
                for (uint256 j = _count; j > i; j--) {
                    _strategies[j] = _strategies[j - 1];
                }
                _strategies[i] = _strategy;
                return;
            }
        }

        // Append at end (largest address)
        _strategies.push(_strategy);
    }

    /**
     * @notice Builds allocation params from storage (strategies already sorted)
     * @dev All strategies use the same magnitude constant
     */
    function buildParams(IStrategy[] storage _strategies)
        internal
        view
        returns (IStrategy[] memory strategies, uint64[] memory magnitudes)
    {
        uint256 _count = _strategies.length;
        strategies = new IStrategy[](_count);
        magnitudes = new uint64[](_count);

        for (uint256 i = 0; i < _count; i++) {
            strategies[i] = _strategies[i];
            magnitudes[i] = AlephUtils.OPERATOR_SET_MAGNITUDE;
        }
    }
}

