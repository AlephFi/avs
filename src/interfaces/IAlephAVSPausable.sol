// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

/**
 * @author Othentic Labs LTD.
 * @notice Terms of Service: https://aleph.finance/terms-of-service
 */
interface IAlephAVSPausable {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Emitted when a flow is paused
     * @param _pausableFlow The flow identifier
     * @param _pauser The address that paused the flow
     */
    event FlowPaused(bytes4 _pausableFlow, address _pauser);

    /**
     * @notice Emitted when a flow is unpaused
     * @param _pausableFlow The flow identifier
     * @param _unpauser The address that unpaused the flow
     */
    event FlowUnpaused(bytes4 _pausableFlow, address _unpauser);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Emitted when a flow is currently paused
     */
    error FlowIsCurrentlyPaused();

    /**
     * @notice Emitted when a flow is currently unpaused
     */
    error FlowIsCurrentlyUnpaused();

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Checks if a specific flow is currently paused
     * @param _pausableFlow The flow identifier to check
     * @return True if the flow is paused, false otherwise
     */
    function isFlowPaused(bytes4 _pausableFlow) external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                            PAUSING FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Pauses a specific flow to prevent its execution
     * @param _pausableFlow The flow identifier to pause
     * @dev Only callable by users with the flow-specific role. Reverts if flow is already paused.
     */
    function pause(bytes4 _pausableFlow) external;

    /**
     * @notice Unpauses a specific flow to allow its execution
     * @param _pausableFlow The flow identifier to unpause
     * @dev Only callable by users with the flow-specific role. Reverts if flow is not paused.
     */
    function unpause(bytes4 _pausableFlow) external;
}
