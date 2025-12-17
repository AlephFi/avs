// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20 as IERC20Eigen} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IRewardsCoordinatorTypes} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {AlephUtils} from "./AlephUtils.sol";

/**
 * @title RewardsManagement
 * @notice Library for managing rewards submissions to EigenLayer's RewardsCoordinator
 * @dev Handles operator-directed rewards for vault allocations
 */
library RewardsManagement {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Number of intervals to look back for retroactive rewards (EigenLayer requirement)
    uint256 private constant RETROACTIVE_INTERVALS = 2;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OperatorSplitNotZero();

    /**
     * @notice Submits operator-directed rewards to RewardsCoordinator
     * @param _rewardsCoordinator The RewardsCoordinator contract
     * @param _avsAddress The AVS address submitting rewards
     * @param _operator The operator receiving rewards
     * @param _stakerStrategy The strategy used for reward calculation
     * @param _rewardToken The token to distribute as rewards
     * @param _rewardAmount The amount of rewards to distribute
     * @param _rewardsDescription The description for the rewards submission
     * @dev Creates a retroactive rewards submission that covers the previous calculation interval
     */
    function submitOperatorDirectedRewards(
        IRewardsCoordinator _rewardsCoordinator,
        address _avsAddress,
        address _operator,
        IStrategy _stakerStrategy,
        IERC20Eigen _rewardToken,
        uint256 _rewardAmount,
        string memory _rewardsDescription
    ) internal {
        IRewardsCoordinatorTypes.StrategyAndMultiplier[] memory strategiesAndMultipliers =
            createStrategyAndMultiplierArray(_stakerStrategy);
        IRewardsCoordinatorTypes.OperatorReward[] memory operatorRewards =
            createOperatorRewardArray(_operator, _rewardAmount);
        (uint32 _startTimestamp, uint32 _duration) = calculateRetroactiveRewardsWindow(_rewardsCoordinator);

        IRewardsCoordinatorTypes.OperatorDirectedRewardsSubmission[] memory rewardsSubmissions =
            createRewardsSubmissionArray(
                strategiesAndMultipliers, _rewardToken, operatorRewards, _startTimestamp, _duration, _rewardsDescription
            );

        // Approve RewardsCoordinator to spend tokens using SafeERC20
        SafeERC20.forceApprove(IERC20(address(_rewardToken)), address(_rewardsCoordinator), _rewardAmount);
        _rewardsCoordinator.createOperatorDirectedAVSRewardsSubmission(_avsAddress, rewardsSubmissions);
        // Reset approval to 0 after use
        SafeERC20.forceApprove(IERC20(address(_rewardToken)), address(_rewardsCoordinator), 0);
    }

    /**
     * @notice Creates a single-element StrategyAndMultiplier array
     * @param _strategy The strategy
     * @return Array containing the strategy with default multiplier
     */
    function createStrategyAndMultiplierArray(IStrategy _strategy)
        internal
        pure
        returns (IRewardsCoordinatorTypes.StrategyAndMultiplier[] memory)
    {
        IRewardsCoordinatorTypes.StrategyAndMultiplier[] memory arr =
            new IRewardsCoordinatorTypes.StrategyAndMultiplier[](1);
        arr[0] = IRewardsCoordinatorTypes.StrategyAndMultiplier({
            strategy: _strategy, multiplier: AlephUtils.REWARD_MULTIPLIER
        });
        return arr;
    }

    /**
     * @notice Creates a single-element OperatorReward array
     * @param _operator The operator
     * @param _amount The reward amount
     * @return Array containing the operator reward
     */
    function createOperatorRewardArray(address _operator, uint256 _amount)
        internal
        pure
        returns (IRewardsCoordinatorTypes.OperatorReward[] memory)
    {
        IRewardsCoordinatorTypes.OperatorReward[] memory arr = new IRewardsCoordinatorTypes.OperatorReward[](1);
        arr[0] = IRewardsCoordinatorTypes.OperatorReward({operator: _operator, amount: _amount});
        return arr;
    }

    /**
     * @notice Creates a single-element OperatorDirectedRewardsSubmission array
     * @param _strategiesAndMultipliers The strategies and multipliers
     * @param _token The reward token
     * @param _operatorRewards The operator rewards
     * @param _startTimestamp The start timestamp
     * @param _duration The duration
     * @param _description The description
     * @return Array containing the rewards submission
     */
    function createRewardsSubmissionArray(
        IRewardsCoordinatorTypes.StrategyAndMultiplier[] memory _strategiesAndMultipliers,
        IERC20Eigen _token,
        IRewardsCoordinatorTypes.OperatorReward[] memory _operatorRewards,
        uint32 _startTimestamp,
        uint32 _duration,
        string memory _description
    ) internal pure returns (IRewardsCoordinatorTypes.OperatorDirectedRewardsSubmission[] memory) {
        IRewardsCoordinatorTypes.OperatorDirectedRewardsSubmission[] memory arr =
            new IRewardsCoordinatorTypes.OperatorDirectedRewardsSubmission[](1);
        arr[0] = IRewardsCoordinatorTypes.OperatorDirectedRewardsSubmission({
            strategiesAndMultipliers: _strategiesAndMultipliers,
            token: _token,
            operatorRewards: _operatorRewards,
            startTimestamp: _startTimestamp,
            duration: _duration,
            description: _description
        });
        return arr;
    }

    /**
     * @notice Calculates retroactive rewards window for EigenLayer submission
     * @param _rewardsCoordinator The RewardsCoordinator contract
     * @return startTimestamp The start timestamp for the rewards window
     * @return duration The duration of the rewards window (one interval)
     * @dev Uses RETROACTIVE_INTERVALS to ensure rewards are based on pre-slash share amounts
     */
    function calculateRetroactiveRewardsWindow(IRewardsCoordinator _rewardsCoordinator)
        internal
        view
        returns (uint32 startTimestamp, uint32 duration)
    {
        uint32 interval = _rewardsCoordinator.CALCULATION_INTERVAL_SECONDS();
        startTimestamp = uint32(((block.timestamp / interval) - RETROACTIVE_INTERVALS) * interval);
        duration = interval;
    }

    /**
     * @notice Validates that operator's AVS split is 0 (100% to stakers)
     * @param _rewardsCoordinator The RewardsCoordinator contract
     * @param _operator The operator address
     * @param _avsAddress The AVS address
     * @dev getOperatorAVSSplit returns a uint16 value in basis points (bips):
     *      - Range: 0 to 10,000 (inclusive)
     *      - 0 = 0% to operator, 100% to stakers (required)
     *      - 10,000 = 100% to operator, 0% to stakers
     *      - If operator hasn't set a custom split, returns defaultOperatorSplitBips (typically 1000 = 10%)
     *      - Reverts if the split is not 0, ensuring all rewards go to stakers
     */
    function validateOperatorSplit(IRewardsCoordinator _rewardsCoordinator, address _operator, address _avsAddress)
        internal
        view
    {
        uint16 operatorSplit = _rewardsCoordinator.getOperatorAVSSplit(_operator, _avsAddress);
        if (operatorSplit != 0) {
            revert OperatorSplitNotZero();
        }
    }
}
