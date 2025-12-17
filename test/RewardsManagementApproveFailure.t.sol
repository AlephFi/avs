// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {RewardsManagement} from "../src/libraries/RewardsManagement.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IRewardsCoordinatorTypes} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract RewardsManagementApproveFailureTest is Test {
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

    function test_SubmitOperatorDirectedRewards_ApproveFails() public {
        // Mock calculation interval
        vm.mockCall(
            address(mockRewardsCoordinator),
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );

        // Mock approve to return false
        vm.mockCall(
            address(mockRewardToken),
            abi.encodeWithSelector(IERC20.approve.selector, address(mockRewardsCoordinator), 1000e18),
            abi.encode(false)
        );

        vm.warp(1000000);

        // Expect SafeERC20FailedOperation error (thrown by forceApprove when approve returns false)
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(mockRewardToken)));
        this._submitOperatorDirectedRewards();
    }

    function _submitOperatorDirectedRewards() external {
        RewardsManagement.submitOperatorDirectedRewards(
            mockRewardsCoordinator,
            avsAddress,
            operator,
            mockStrategy,
            IERC20(address(mockRewardToken)),
            1000e18,
            "Test rewards"
        );
    }
}

