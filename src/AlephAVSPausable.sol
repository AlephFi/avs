// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IAlephAVSPausable} from "./interfaces/IAlephAVSPausable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-upgrades/contracts/access/AccessControlUpgradeable.sol";

contract AlephAVSPausable is IAlephAVSPausable, AccessControlUpgradeable {
    bytes4 public constant ALLOCATE_FLOW = bytes4(keccak256("ALLOCATE_FLOW"));
    bytes4 public constant UNALLOCATE_FLOW = bytes4(keccak256("UNALLOCATE_FLOW"));

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE (ERC-7201)
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:aleph.avs.storage
    struct PausableStorage {
        // Mapping of pausable flow to its pause state
        mapping(bytes4 pausableFlow => bool isPaused) flowsPauseStates;
    }

    // keccak256(abi.encode(uint256(keccak256("pausable.avs.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PAUSABLE_STORAGE_LOCATION =
        0xf8131bc7f7376b7d8d09601d142eed8304a0dce3fa238f43875ec194c35e4400;

    function _getPausableStorage() private pure returns (PausableStorage storage $) {
        assembly {
            $.slot := PAUSABLE_STORAGE_LOCATION
        }
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Modifier to check if a flow is not paused
     * @param _pausableFlow The flow identifier
     */
    modifier whenFlowNotPaused(bytes4 _pausableFlow) {
        _revertIfFlowPaused(_pausableFlow);
        _;
    }

    /**
     * @notice Modifier to check if a flow is paused
     * @param _pausableFlow The flow identifier
     */
    modifier whenFlowPaused(bytes4 _pausableFlow) {
        _revertIfFlowUnpaused(_pausableFlow);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function isFlowPaused(bytes4 _pausableFlow) external view returns (bool _isPaused) {
        return _getPausableStorage().flowsPauseStates[_pausableFlow];
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSING FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function pause(bytes4 _pausableFlow) external onlyRole(_pausableFlow) {
        _pause(_pausableFlow);
    }

    function unpause(bytes4 _pausableFlow) external onlyRole(_pausableFlow) {
        _unpause(_pausableFlow);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev Internal function to pause a flow
     * @param _pausableFlow The flow identifier
     */
    function _pause(bytes4 _pausableFlow) internal {
        PausableStorage storage _sd = _getPausableStorage();
        if (_sd.flowsPauseStates[_pausableFlow]) revert FlowIsCurrentlyPaused();

        _sd.flowsPauseStates[_pausableFlow] = true;
        emit FlowPaused(_pausableFlow, msg.sender);
    }

    /**
     * @dev Internal function to unpause a flow
     * @param _pausableFlow The flow identifier
     */
    function _unpause(bytes4 _pausableFlow) internal {
        PausableStorage storage _sd = _getPausableStorage();
        if (!_sd.flowsPauseStates[_pausableFlow]) revert FlowIsCurrentlyUnpaused();

        _sd.flowsPauseStates[_pausableFlow] = false;
        emit FlowUnpaused(_pausableFlow, msg.sender);
    }

    /**
     * @dev Internal function to revert if a flow is paused
     * @param _pausableFlow The flow identifier
     */
    function _revertIfFlowPaused(bytes4 _pausableFlow) internal view {
        if (_getPausableStorage().flowsPauseStates[_pausableFlow]) revert FlowIsCurrentlyPaused();
    }

    /**
     * @dev Internal function to revert if a flow is unpaused
     * @param _pausableFlow The flow identifier
     */
    function _revertIfFlowUnpaused(bytes4 _pausableFlow) internal view {
        if (!_getPausableStorage().flowsPauseStates[_pausableFlow]) revert FlowIsCurrentlyUnpaused();
    }

    /**
     * @dev Internal function to initialize the pausable storage
     * @param _owner The owner address
     * @param _guardian The guardian address
     */
    function _pausableInit(address _owner, address _guardian) internal {
        _grantRole(ALLOCATE_FLOW, _owner);
        _grantRole(ALLOCATE_FLOW, _guardian);
        _grantRole(UNALLOCATE_FLOW, _owner);
        _grantRole(UNALLOCATE_FLOW, _guardian);
    }
}
