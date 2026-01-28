// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {AlephAVS} from "../src/AlephAVS.sol";
import {IAlephAVS} from "../src/IAlephAVS.sol";
import {IMintableBurnableERC20} from "../src/interfaces/IMintableBurnableERC20.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IAlephVault} from "Aleph/src/interfaces/IAlephVault.sol";
import {IAlephVaultRedeem} from "Aleph/src/interfaces/IAlephVaultRedeem.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20 as IERC20Eigen} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626Math} from "Aleph/src/libraries/ERC4626Math.sol";
import "./AlephAVS.t.sol";

/**
 * @title UnallocateEdgeCasesTest
 * @notice Comprehensive tests for edge cases in the two-step unallocate flow
 * @dev Tests proportional distribution, rounding, multiple users, and error conditions
 */
contract UnallocateEdgeCasesTest is AlephAVSTest {
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    /**
     * @notice Test: Multiple users complete unallocations with sync flow
     * @dev Each user gets exactly their pending amount via syncRedeem
     */
    function test_CompleteUnallocate_MultipleUsers_SyncFlow() public {
        uint256 user1Amount = 100e18;
        uint256 user2Amount = 200e18;
        uint256 user3Amount = 100e18;
        uint256 totalPending = user1Amount + user2Amount + user3Amount;

        // Setup mocks
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (user1)), abi.encode(user1Amount));
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (user2)), abi.encode(user2Amount));
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (user3)), abi.encode(user3Amount));
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalPending));
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.assetsPerClassOf, (CLASS_ID, address(alephAVS))),
            abi.encode(totalPending)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        // All users request unallocation
        _mockRequestUnallocate(user1, user1Amount, user1Amount);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), user1Amount);

        _mockRequestUnallocate(user2, user2Amount, user2Amount);
        vm.prank(user2);
        alephAVS.requestUnallocate(address(alephVault), user2Amount);

        _mockRequestUnallocate(user3, user3Amount, user3Amount);
        vm.prank(user3);
        alephAVS.requestUnallocate(address(alephVault), user3Amount);

        // User1 completes - gets exact pending via syncRedeem
        underlyingToken.transfer(address(alephVault), user1Amount);
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(user1Amount)
        );
        vm.prank(user1);
        (uint256 amount1,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount1, user1Amount, "User1 should get exact pending amount");

        // User2 completes - gets exact pending via syncRedeem
        underlyingToken.transfer(address(alephVault), user2Amount);
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(user2Amount)
        );
        vm.prank(user2);
        (uint256 amount2,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount2, user2Amount, "User2 should get exact pending amount");

        // User3 completes - gets exact pending via syncRedeem
        underlyingToken.transfer(address(alephVault), user3Amount);
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(user3Amount)
        );
        vm.prank(user3);
        (uint256 amount3,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount3, user3Amount, "User3 should get exact pending amount");

        // Verify all pending amounts are cleared
        (uint256 user1Pending,,,) = alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        (uint256 user2Pending,,,) = alephAVS.getPendingUnallocateStatus(user2, address(alephVault));
        (uint256 user3Pending,,,) = alephAVS.getPendingUnallocateStatus(user3, address(alephVault));
        assertEq(user1Pending, 0, "User1 pending should be cleared");
        assertEq(user2Pending, 0, "User2 pending should be cleared");
        assertEq(user3Pending, 0, "User3 pending should be cleared");
    }

    /**
     * @notice Test: calculateCompleteUnallocateAmount returns user's pending amount
     * @dev With sync flow, user gets exactly their pending amount
     */
    function test_CalculateCompleteUnallocateAmount_ReturnsUserPending() public {
        uint256 tokenAmount = 100e18;

        // Use standard mock which gives 1:1 price
        _mockRequestUnallocate(user1, tokenAmount, tokenAmount);

        vm.prank(user1);
        (uint48 batchId, uint256 actualEstAmount) = alephAVS.requestUnallocate(address(alephVault), tokenAmount);

        // Calculate expected amount - should be exactly user's pending
        uint256 expectedAmount = alephAVS.calculateCompleteUnallocateAmount(user1, address(alephVault));
        assertEq(expectedAmount, actualEstAmount, "Expected amount should match user's pending amount");
    }

    /**
     * @notice Test: calculateCompleteUnallocateAmount with multiple users returns each user's pending
     * @dev With sync flow, no proportional distribution - each user gets their exact pending
     */
    function test_CalculateCompleteUnallocateAmount_MultipleUsers() public {
        uint256 user1Amount = 100e18;
        uint256 user2Amount = 200e18;

        _mockRequestUnallocate(user1, user1Amount, user1Amount);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), user1Amount);

        _mockRequestUnallocate(user2, user2Amount, user2Amount);
        vm.prank(user2);
        alephAVS.requestUnallocate(address(alephVault), user2Amount);

        // Each user gets exactly their pending amount
        uint256 expectedUser1 = alephAVS.calculateCompleteUnallocateAmount(user1, address(alephVault));
        assertEq(expectedUser1, user1Amount, "User1 should get their exact pending");

        uint256 expectedUser2 = alephAVS.calculateCompleteUnallocateAmount(user2, address(alephVault));
        assertEq(expectedUser2, user2Amount, "User2 should get their exact pending");
    }

    /**
     * @notice Test: completeUnallocate reverts if no pending unallocation
     */
    function test_CompleteUnallocate_RevertsIfNoPending() public {
        vm.prank(user1);
        vm.expectRevert(IAlephAVS.NoPendingUnallocation.selector);
        alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
    }

    /**
     * @notice Test: completeUnallocate reverts if no redeemable amount
     */
    function test_CompleteUnallocate_RevertsIfNoRedeemable() public {
        uint256 tokenAmount = 100e18;
        _mockRequestUnallocate(user1, tokenAmount, tokenAmount);

        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), tokenAmount);

        // Vault has no funds for syncRedeem - it will revert
        // classId is 1 (set in setUp via initializeVault)
        vm.mockCallRevert(
            address(alephVault),
            abi.encodeCall(IAlephVaultRedeem.syncRedeem, (IAlephVaultRedeem.RedeemRequestParams(1, tokenAmount))),
            "Insufficient funds"
        );

        vm.prank(user1);
        vm.expectRevert("Insufficient funds");
        alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
    }

    /**
     * @notice Test: getPendingUnallocateStatus returns correct values
     */
    function test_GetPendingUnallocateStatus_ReturnsCorrectValues() public {
        uint256 tokenAmount = 100e18;
        uint256 estAmountToRedeem = 95e18;

        _mockRequestUnallocate(user1, tokenAmount, estAmountToRedeem);

        // Before requestUnallocate - mock vault balance as 0
        vm.mockCall(address(underlyingToken), abi.encodeCall(IERC20.balanceOf, (address(alephVault))), abi.encode(0));

        (uint256 pendingBefore, uint256 totalBefore, uint256 vaultBalanceBefore, bool canCompleteBefore) =
            alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        assertEq(pendingBefore, 0, "No pending before request");
        assertEq(canCompleteBefore, false, "Cannot complete before request");

        vm.prank(user1);
        (uint48 batchId, uint256 actualEstAmount) = alephAVS.requestUnallocate(address(alephVault), tokenAmount);

        // The actual estAmountToRedeem returned might differ from our mock
        // Use the actual returned value for assertions
        uint256 actualEstAmountToRedeem = actualEstAmount;

        // After requestUnallocate - mock vault has enough balance for syncRedeem
        uint256 vaultBalance = actualEstAmountToRedeem;
        vm.mockCall(
            address(underlyingToken), abi.encodeCall(IERC20.balanceOf, (address(alephVault))), abi.encode(vaultBalance)
        );

        (uint256 pendingAfter, uint256 totalAfter, uint256 vaultBalanceAfter, bool canCompleteAfter) =
            alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        assertEq(pendingAfter, actualEstAmountToRedeem, "Pending should match returned estAmountToRedeem");
        assertEq(totalAfter, actualEstAmountToRedeem, "Total pending should match");
        assertEq(vaultBalanceAfter, vaultBalance, "Vault balance should match");
        assertEq(canCompleteAfter, true, "Can complete if vault has enough balance");
    }

    /**
     * @notice Test: User can request multiple unallocations and complete them separately
     */
    function test_RequestUnallocate_MultipleRequests_SameUser() public {
        uint256 firstAmount = 50e18;
        uint256 secondAmount = 50e18;

        // First request
        _mockRequestUnallocate(user1, firstAmount, firstAmount);
        vm.prank(user1);
        (uint48 batchId1, uint256 est1) = alephAVS.requestUnallocate(address(alephVault), firstAmount);
        assertEq(uint256(batchId1), 0, "Batch ID should be set");
        assertEq(est1, firstAmount, "Est amount should match");

        // Check pending status
        (uint256 pending1,,,) = alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        assertEq(pending1, firstAmount, "Pending should be first amount");

        // Second request (adds to pending)
        _mockRequestUnallocate(user1, secondAmount, secondAmount);
        vm.prank(user1);
        (uint48 batchId2, uint256 est2) = alephAVS.requestUnallocate(address(alephVault), secondAmount);
        assertEq(uint256(batchId2), 0, "Batch ID should be set");
        assertEq(est2, secondAmount, "Est amount should match");

        // Check pending status (should be sum)
        (uint256 pending2,,,) = alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        assertEq(pending2, firstAmount + secondAmount, "Pending should be sum of both requests");
    }

    /**
     * @notice Test: calculateCompleteUnallocateAmount returns 0 if no pending
     */
    function test_CalculateCompleteUnallocateAmount_ReturnsZeroIfNoPending() public {
        uint256 expected = alephAVS.calculateCompleteUnallocateAmount(user1, address(alephVault));
        assertEq(expected, 0, "Should return 0 if no pending unallocation");
    }

    // Helper function to mock requestUnallocate setup
    function _mockRequestUnallocate(address user, uint256 tokenAmount, uint256 estAmountToRedeem) internal {
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (user)), abi.encode(tokenAmount));
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.transferFrom, (user, address(alephAVS), tokenAmount)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.burn, (address(alephAVS), tokenAmount)),
            abi.encode()
        );
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(tokenAmount));
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.assetsPerClassOf, (CLASS_ID, address(alephAVS))),
            abi.encode(tokenAmount)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(
                IAlephVaultRedeem.requestRedeem, (IAlephVaultRedeem.RedeemRequestParams(CLASS_ID, estAmountToRedeem))
            ),
            abi.encode(uint48(0))
        );
    }
}
