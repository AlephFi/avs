// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {RewardsManagement} from "../src/libraries/RewardsManagement.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IRewardsCoordinatorTypes} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AlephUtils} from "../src/libraries/AlephUtils.sol";

contract RewardsManagementTest is Test {
    IRewardsCoordinator public mockRewardsCoordinator;
    IStrategy public mockStrategy;
    IERC20 public mockRewardToken;
    address public avsAddress;
    address public operator;

    function setUp() public {
        mockRewardsCoordinator = IRewardsCoordinator(address(0x100));
        mockStrategy = IStrategy(address(0x200));
        mockRewardToken = IERC20(address(0x300));
        avsAddress = address(0x400);
        operator = address(0x500);
    }

    function test_CreateStrategyAndMultiplierArray() public pure {
        IRewardsCoordinatorTypes.StrategyAndMultiplier[] memory arr =
            RewardsManagement.createStrategyAndMultiplierArray(IStrategy(address(0x200)));

        assertEq(arr.length, 1);
        assertEq(address(arr[0].strategy), address(0x200));
        assertEq(arr[0].multiplier, AlephUtils.REWARD_MULTIPLIER);

        // Use return value to ensure return statement is covered
        IRewardsCoordinatorTypes.StrategyAndMultiplier[] memory arr2 = arr;
        assertEq(arr2.length, 1);
    }

    function test_CreateOperatorRewardArray() public pure {
        IRewardsCoordinatorTypes.OperatorReward[] memory arr =
            RewardsManagement.createOperatorRewardArray(address(0x500), 1000e18);

        assertEq(arr.length, 1);
        assertEq(arr[0].operator, address(0x500));
        assertEq(arr[0].amount, 1000e18);

        // Use return value to ensure return statement is covered
        IRewardsCoordinatorTypes.OperatorReward[] memory arr2 = arr;
        assertEq(arr2.length, 1);
    }

    function test_CreateRewardsSubmissionArray() public pure {
        IRewardsCoordinatorTypes.StrategyAndMultiplier[] memory strategies =
            new IRewardsCoordinatorTypes.StrategyAndMultiplier[](1);
        strategies[0] = IRewardsCoordinatorTypes.StrategyAndMultiplier({
            strategy: IStrategy(address(0x200)), multiplier: AlephUtils.REWARD_MULTIPLIER
        });

        IRewardsCoordinatorTypes.OperatorReward[] memory operatorRewards =
            new IRewardsCoordinatorTypes.OperatorReward[](1);
        operatorRewards[0] = IRewardsCoordinatorTypes.OperatorReward({operator: address(0x500), amount: 1000e18});

        IRewardsCoordinatorTypes.OperatorDirectedRewardsSubmission[] memory arr =
            RewardsManagement.createRewardsSubmissionArray(
                strategies, IERC20(address(0x300)), operatorRewards, 1000, 86400, "Test rewards"
            );

        assertEq(arr.length, 1);
        assertEq(arr[0].strategiesAndMultipliers.length, 1);
        assertEq(address(arr[0].token), address(0x300));
        assertEq(arr[0].operatorRewards.length, 1);
        assertEq(arr[0].startTimestamp, 1000);
        assertEq(arr[0].duration, 86400);

        // Use return value to ensure return statement is covered
        IRewardsCoordinatorTypes.OperatorDirectedRewardsSubmission[] memory arr2 = arr;
        assertEq(arr2.length, 1);
    }

    function test_CalculateRetroactiveRewardsWindow() public {
        uint32 calculationInterval = 86400; // 1 day
        vm.mockCall(
            address(mockRewardsCoordinator),
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(calculationInterval)
        );

        vm.warp(172800 * 3); // 3 days in the future

        (uint32 startTimestamp, uint32 duration) =
            RewardsManagement.calculateRetroactiveRewardsWindow(mockRewardsCoordinator);

        // Should be 2 intervals ago
        uint32 expectedStart = uint32(((block.timestamp / calculationInterval) - 2) * calculationInterval);
        assertEq(startTimestamp, expectedStart);
        assertEq(duration, calculationInterval);
    }

    function test_ValidateOperatorSplit_Zero() public {
        vm.mockCall(
            address(mockRewardsCoordinator),
            abi.encodeWithSelector(IRewardsCoordinator.getOperatorAVSSplit.selector, operator, avsAddress),
            abi.encode(uint16(0))
        );

        // Should not revert
        RewardsManagement.validateOperatorSplit(mockRewardsCoordinator, operator, avsAddress);
    }

    function test_ValidateOperatorSplit_NonZero() public {
        vm.mockCall(
            address(mockRewardsCoordinator),
            abi.encodeWithSelector(IRewardsCoordinator.getOperatorAVSSplit.selector, operator, avsAddress),
            abi.encode(uint16(1000)) // 10%
        );

        vm.expectRevert(RewardsManagement.OperatorSplitNotZero.selector);
        this._validateOperatorSplit();
    }

    function test_ValidateOperatorSplit_MaxValue() public {
        vm.mockCall(
            address(mockRewardsCoordinator),
            abi.encodeWithSelector(IRewardsCoordinator.getOperatorAVSSplit.selector, operator, avsAddress),
            abi.encode(uint16(10000)) // 100%
        );

        vm.expectRevert(RewardsManagement.OperatorSplitNotZero.selector);
        this._validateOperatorSplit();
    }

    // Helper function to wrap library call for revert testing
    function _validateOperatorSplit() external {
        RewardsManagement.validateOperatorSplit(mockRewardsCoordinator, operator, avsAddress);
    }
}

