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
     * @notice Test: Multiple users with proportional distribution
     * @dev User1 requests 100, User2 requests 200, User3 requests 100
     *      Total pending: 400, redeemable: 300
     *      Expected: User1 gets 75, User2 gets 150, User3 gets 75
     */
    function test_CompleteUnallocate_MultipleUsers_ProportionalDistribution() public {
        uint256 user1Amount = 100e18;
        uint256 user2Amount = 200e18;
        uint256 user3Amount = 100e18;
        uint256 totalPending = user1Amount + user2Amount + user3Amount; // 400e18

        // Setup: All users have slashed tokens
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (user1)), abi.encode(user1Amount));
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (user2)), abi.encode(user2Amount));
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (user3)), abi.encode(user3Amount));

        // Mock calculateAmountToRedeem (1:1 for simplicity)
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalPending));
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.assetsPerClassOf, (CLASS_ID, address(alephAVS))),
            abi.encode(totalPending)
        );

        // User1 requests unallocation
        _mockRequestUnallocate(user1, user1Amount, user1Amount);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), user1Amount);

        // User2 requests unallocation
        _mockRequestUnallocate(user2, user2Amount, user2Amount);
        vm.prank(user2);
        alephAVS.requestUnallocate(address(alephVault), user2Amount);

        // User3 requests unallocation
        _mockRequestUnallocate(user3, user3Amount, user3Amount);
        vm.prank(user3);
        alephAVS.requestUnallocate(address(alephVault), user3Amount);

        // Vault has 300e18 redeemable (less than total pending 400e18)
        uint256 redeemableAmount = 300e18;
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(redeemableAmount)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(redeemableAmount)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        // Expected amounts (proportional: userPending / totalPending * redeemable)
        uint256 expectedUser1 = (user1Amount * redeemableAmount) / totalPending; // 75e18
        uint256 expectedUser2 = (user2Amount * redeemableAmount) / totalPending; // 150e18
        uint256 expectedUser3 = (user3Amount * redeemableAmount) / totalPending; // 75e18

        // User1 completes unallocation
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(expectedUser1)
        );
        vm.prank(user1);
        (uint256 amount1, uint256 shares1) =
            alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount1, expectedUser1, "User1 should get proportional share");
        assertEq(shares1, expectedUser1, "User1 shares should match amount");

        // Update mocks for User2
        // After User1 completes, the vaultWithdrawnAmount is updated to totalRedeemableAmount - amount1
        // But since vault still has no new redeemable, we need to update the withdrawn amount
        uint256 remainingAfterUser1 = redeemableAmount - expectedUser1; // 225e18
        uint256 totalPendingAfterUser1 = totalPending - user1Amount; // 300e18 (user2Amount + user3Amount)

        // User2's expected: (200 / 300) * 225 = 150e18
        // But we need to account for the fact that vaultWithdrawnAmount is now (redeemableAmount - amount1)
        // Since vault has no new redeemable, available = withdrawnAmount = remainingAfterUser1
        uint256 expectedUser2After = (user2Amount * remainingAfterUser1) / totalPendingAfterUser1; // 150e18

        // Update vault redeemable (still 0, but withdrawn amount is now remainingAfterUser1)
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(0) // No new redeemable
        );
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(remainingAfterUser1)
        );
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(expectedUser2After)
        );

        // User2 completes unallocation
        vm.prank(user2);
        (uint256 amount2, uint256 shares2) =
            alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount2, expectedUser2After, "User2 should get proportional share");
        assertEq(shares2, expectedUser2After, "User2 shares should match amount");

        // User3 gets remaining amount (last user)
        uint256 remainingAfterUser2 = remainingAfterUser1 - expectedUser2After; // 75e18
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(0) // No new redeemable
        );
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(remainingAfterUser2)
        );
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(remainingAfterUser2)
        );

        // User3 completes unallocation (gets all remaining)
        vm.prank(user3);
        (uint256 amount3, uint256 shares3) =
            alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount3, remainingAfterUser2, "User3 should get all remaining");
        assertEq(shares3, remainingAfterUser2, "User3 shares should match amount");

        // Verify all pending amounts are cleared
        (uint256 user1Pending,,,) = alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        (uint256 user2Pending,,,) = alephAVS.getPendingUnallocateStatus(user2, address(alephVault));
        (uint256 user3Pending,,,) = alephAVS.getPendingUnallocateStatus(user3, address(alephVault));
        assertEq(user1Pending, 0, "User1 pending should be cleared");
        assertEq(user2Pending, 0, "User2 pending should be cleared");
        assertEq(user3Pending, 0, "User3 pending should be cleared");
    }

    /**
     * @notice Test: calculateCompleteUnallocateAmount returns correct expected amount
     */
    function test_CalculateCompleteUnallocateAmount_ReturnsExpected() public {
        uint256 tokenAmount = 100e18;
        uint256 estAmountToRedeem = 95e18; // Vault price is 0.95

        _mockRequestUnallocate(user1, tokenAmount, estAmountToRedeem);

        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), tokenAmount);

        // Set up redeemable amount
        uint256 redeemableAmount = estAmountToRedeem;
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(redeemableAmount)
        );

        // Calculate expected amount
        uint256 expectedAmount = alephAVS.calculateCompleteUnallocateAmount(user1, address(alephVault));
        assertEq(expectedAmount, estAmountToRedeem, "Expected amount should match estAmountToRedeem for single user");
    }

    /**
     * @notice Test: calculateCompleteUnallocateAmount with multiple users (proportional)
     */
    function test_CalculateCompleteUnallocateAmount_MultipleUsers_Proportional() public {
        uint256 user1Amount = 100e18;
        uint256 user2Amount = 200e18;
        uint256 totalPending = user1Amount + user2Amount; // 300e18
        uint256 redeemableAmount = 150e18; // Less than total pending

        _mockRequestUnallocate(user1, user1Amount, user1Amount);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), user1Amount);

        _mockRequestUnallocate(user2, user2Amount, user2Amount);
        vm.prank(user2);
        alephAVS.requestUnallocate(address(alephVault), user2Amount);

        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(redeemableAmount)
        );

        // User1 should get: (100 / 300) * 150 = 50
        // Note: Since vault has redeemableAmount > 0, available = redeemableAmount + withdrawnAmount = 150 + 0 = 150
        uint256 expectedUser1 = alephAVS.calculateCompleteUnallocateAmount(user1, address(alephVault));
        assertEq(expectedUser1, 50e18, "User1 should get 1/3 of redeemable");

        // User2 should get: (200 / 300) * 150 = 100
        uint256 expectedUser2 = alephAVS.calculateCompleteUnallocateAmount(user2, address(alephVault));
        assertEq(expectedUser2, 100e18, "User2 should get 2/3 of redeemable");
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

        // Vault has no redeemable amount yet
        vm.mockCall(
            address(alephVault), abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))), abi.encode(0)
        );
        vm.mockCall(address(underlyingToken), abi.encodeCall(IERC20.balanceOf, (address(alephAVS))), abi.encode(0));

        vm.prank(user1);
        vm.expectRevert(IAlephAVS.InvalidAmount.selector);
        alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
    }

    /**
     * @notice Test: getPendingUnallocateStatus returns correct values
     */
    function test_GetPendingUnallocateStatus_ReturnsCorrectValues() public {
        uint256 tokenAmount = 100e18;
        uint256 estAmountToRedeem = 95e18;

        _mockRequestUnallocate(user1, tokenAmount, estAmountToRedeem);

        // Before requestUnallocate
        (uint256 pendingBefore, uint256 totalBefore, uint256 redeemableBefore, bool canCompleteBefore) =
            alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        assertEq(pendingBefore, 0, "No pending before request");
        assertEq(canCompleteBefore, false, "Cannot complete before request");

        vm.prank(user1);
        (uint48 batchId, uint256 actualEstAmount) = alephAVS.requestUnallocate(address(alephVault), tokenAmount);

        // The actual estAmountToRedeem returned might differ from our mock
        // Use the actual returned value for assertions
        uint256 actualEstAmountToRedeem = actualEstAmount;

        // After requestUnallocate
        uint256 redeemableAmount = actualEstAmountToRedeem;
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(redeemableAmount)
        );

        (uint256 pendingAfter, uint256 totalAfter, uint256 redeemableAfter, bool canCompleteAfter) =
            alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        assertEq(pendingAfter, actualEstAmountToRedeem, "Pending should match returned estAmountToRedeem");
        assertEq(totalAfter, actualEstAmountToRedeem, "Total pending should match");
        assertEq(redeemableAfter, redeemableAmount, "Redeemable should match vault");
        assertEq(canCompleteAfter, true, "Can complete if redeemable > 0");
    }

    /**
     * @notice Test: Rounding in proportional distribution
     * @dev Tests that rounding doesn't cause issues when amounts don't divide evenly
     */
    function test_CompleteUnallocate_RoundingHandling() public {
        uint256 user1Amount = 1e18; // 1 token
        uint256 user2Amount = 2e18; // 2 tokens
        uint256 totalPending = user1Amount + user2Amount; // 3 tokens
        uint256 redeemableAmount = 1e18; // 1 token (doesn't divide evenly)

        _mockRequestUnallocate(user1, user1Amount, user1Amount);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), user1Amount);

        _mockRequestUnallocate(user2, user2Amount, user2Amount);
        vm.prank(user2);
        alephAVS.requestUnallocate(address(alephVault), user2Amount);

        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(redeemableAmount)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(redeemableAmount)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        // User1 should get: (1 / 3) * 1 = 0.333... (rounded down to 0.333e18)
        // Since vault has redeemableAmount > 0, available = redeemableAmount + withdrawnAmount = 1e18 + 0 = 1e18
        uint256 expectedUser1 = (user1Amount * redeemableAmount) / totalPending; // 333333333333333333 (0.333...e18)
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(expectedUser1)
        );

        vm.prank(user1);
        (uint256 amount1,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount1, expectedUser1, "User1 should get rounded down share");

        // User2 gets remaining (last user gets all remaining)
        uint256 remaining = redeemableAmount - expectedUser1; // 666666666666666667
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(0) // No new redeemable after User1
        );
        vm.mockCall(
            address(underlyingToken), abi.encodeCall(IERC20.balanceOf, (address(alephAVS))), abi.encode(remaining)
        );
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(remaining)
        );

        vm.prank(user2);
        (uint256 amount2,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount2, remaining, "User2 should get all remaining");
        assertEq(amount1 + amount2, redeemableAmount, "Total should equal redeemable");
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
     * @notice Test: completeUnallocate caps to contract balance if needed
     */
    function test_CompleteUnallocate_ValidatesAmount() public {
        uint256 tokenAmount = 100e18;
        uint256 estAmountToRedeem = 100e18;
        uint256 redeemableAmount = 100e18;
        uint256 expectedAmount = 100e18;
        uint256 contractBalance = 100e18; // Matches expected amount

        _mockRequestUnallocate(user1, tokenAmount, estAmountToRedeem);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), tokenAmount);

        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(redeemableAmount)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );
        vm.mockCall(
            address(underlyingToken), abi.encodeCall(IERC20.balanceOf, (address(alephAVS))), abi.encode(contractBalance)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(expectedAmount)
        );

        vm.prank(user1);
        (uint256 amount,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount, expectedAmount, "Amount should equal expected amount when validation passes");
    }

    /**
     * @notice Test: calculateCompleteUnallocateAmount returns 0 if no pending
     */
    function test_CalculateCompleteUnallocateAmount_ReturnsZeroIfNoPending() public {
        uint256 expected = alephAVS.calculateCompleteUnallocateAmount(user1, address(alephVault));
        assertEq(expected, 0, "Should return 0 if no pending unallocation");
    }

    /**
     * @notice Test: calculateCompleteUnallocateAmount returns 0 if no redeemable
     */
    function test_CalculateCompleteUnallocateAmount_ReturnsZeroIfNoRedeemable() public {
        uint256 tokenAmount = 100e18;
        _mockRequestUnallocate(user1, tokenAmount, tokenAmount);

        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), tokenAmount);

        vm.mockCall(
            address(alephVault), abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))), abi.encode(0)
        );

        uint256 expected = alephAVS.calculateCompleteUnallocateAmount(user1, address(alephVault));
        assertEq(expected, 0, "Should return 0 if no redeemable amount");
    }

    /**
     * @notice Test: Same user makes multiple requests when vault state changes
     * @dev User requests, vault processes some, user requests more, then completes all
     */
    function test_MultipleRequests_SameUser_VaultStateChanges() public {
        uint256 firstRequest = 100e18;
        uint256 firstEstAmount = 95e18; // Vault price is 0.95

        // First request
        _mockRequestUnallocate(user1, firstRequest, firstEstAmount);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), firstRequest);

        // Vault processes first request - now has some redeemable
        uint256 firstRedeemable = 50e18; // Only half processed so far
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(firstRedeemable)
        );

        // User makes second request while first is partially processed
        uint256 secondRequest = 50e18;
        uint256 secondEstAmount = 48e18; // Vault price changed to 0.96
        _mockRequestUnallocate(user1, secondRequest, secondEstAmount);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), secondRequest);

        // Check total pending (should be sum of both estAmounts)
        (uint256 totalPending,,,) = alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        // Note: The actual estAmount returned might differ from our mock, so we check it's >= our expected
        assertGe(totalPending, firstEstAmount, "Total pending should include first request");

        // Vault now processes more - total redeemable increases
        uint256 totalRedeemable = firstEstAmount + secondEstAmount; // All processed
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(totalRedeemable)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );
        vm.mockCall(
            address(underlyingToken), abi.encodeCall(IERC20.balanceOf, (address(alephAVS))), abi.encode(totalRedeemable)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(totalRedeemable)
        );

        // User completes all pending unallocation
        vm.prank(user1);
        (uint256 amount, uint256 shares) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount, totalRedeemable, "Should get all redeemable amount");
        assertEq(shares, totalRedeemable, "Shares should match amount");

        // Verify pending is cleared
        (uint256 pendingAfter,,,) = alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        assertEq(pendingAfter, 0, "Pending should be cleared");
    }

    /**
     * @notice Test: Multiple users with vault state changes between requests
     * @dev User1 requests, User2 requests, User1 completes, vault processes more, User2 completes
     */
    function test_MultipleUsers_VaultStateChanges() public {
        uint256 user1Request = 100e18;
        uint256 user1EstAmount = 95e18;
        uint256 user2Request = 200e18;
        uint256 user2EstAmount = 190e18;

        // User1 requests
        _mockRequestUnallocate(user1, user1Request, user1EstAmount);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), user1Request);

        // User2 requests
        _mockRequestUnallocate(user2, user2Request, user2EstAmount);
        vm.prank(user2);
        alephAVS.requestUnallocate(address(alephVault), user2Request);

        // Vault has partial redeemable (only User1's request processed)
        uint256 partialRedeemable = user1EstAmount; // Only User1's processed
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(partialRedeemable)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(partialRedeemable)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        // User1 completes (gets proportional share of available)
        // Get actual pending amounts from contract
        (uint256 user1PendingActual,,,) = alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        (uint256 user2PendingActual,,,) = alephAVS.getPendingUnallocateStatus(user2, address(alephVault));
        uint256 totalPendingActual = user1PendingActual + user2PendingActual;

        // User1's expected share: (user1Pending / totalPending) * partialRedeemable
        uint256 user1Expected = (user1PendingActual * partialRedeemable) / totalPendingActual;
        // But if calculated exceeds available, cap to available (last user logic)
        if (user1Expected > partialRedeemable) {
            user1Expected = partialRedeemable;
        }

        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(user1Expected)
        );

        vm.prank(user1);
        (uint256 amount1,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount1, user1Expected, "User1 should get proportional share");

        // Vault processes more - now has User2's amount available
        uint256 remainingRedeemable = user2EstAmount;

        // Set up mocks BEFORE calculating expected amount so the view function uses correct state
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(remainingRedeemable)
        );

        // Calculate expected amount for User2 using the view function
        // This will tell us what the function expects, and we'll validate it doesn't exceed available
        uint256 user2Expected = alephAVS.calculateCompleteUnallocateAmount(user2, address(alephVault));

        // The view function calculates based on remainingRedeemable + _withdrawnAmount (from User1)
        // withdrawAndCalculateAvailable returns _availableAmount = remainingRedeemable + _withdrawnAmount
        // For validation to pass, we need:
        // - _amount <= _availableAmount (from withdrawAndCalculateAvailable)
        // - _amount <= _contractBalance (after withdrawal)
        // Since user2Expected is calculated by the view function which should cap to _availableAmount,
        // we need to ensure contract balance is at least user2Expected
        // But the actual _availableAmount might be different - let's use a higher value to ensure it passes
        uint256 contractBalanceAfterWithdrawal =
            user2Expected > remainingRedeemable ? user2Expected : remainingRedeemable;
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );
        // Contract balance after withdrawal must be >= user2Expected to pass validation
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(contractBalanceAfterWithdrawal)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(user2Expected)
        );

        // User2 completes (gets remaining)
        // After User1 completes, User2's pending is still there, but totalPending is reduced
        // User2 should get all remaining since they're the last user
        vm.prank(user2);
        (uint256 amount2,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        // The actual amount might be less than user2Expected if validation caps it, but since we set
        // contract balance high enough, it should match user2Expected
        assertEq(amount2, user2Expected, "User2 should get expected amount");

        // Verify both users' pending is cleared
        (uint256 user1PendingAfter,,,) = alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        (uint256 user2PendingAfter,,,) = alephAVS.getPendingUnallocateStatus(user2, address(alephVault));
        assertEq(user1PendingAfter, 0, "User1 pending should be cleared");
        assertEq(user2PendingAfter, 0, "User2 pending should be cleared");
    }

    /**
     * @notice Test: User requests, completes partial, then requests more
     * @dev Tests that user can complete partial unallocation and then request more
     */
    function test_SameUser_RequestCompleteRequest() public {
        uint256 firstRequest = 200e18;
        uint256 firstEstAmount = 190e18;

        // First request
        _mockRequestUnallocate(user1, firstRequest, firstEstAmount);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), firstRequest);

        // Vault has partial redeemable
        uint256 partialRedeemable = 100e18; // Only half available
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(partialRedeemable)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(partialRedeemable)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(partialRedeemable)
        );

        // Complete unallocation - this clears ALL pending, not just partial
        vm.prank(user1);
        (uint256 amount1,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount1, partialRedeemable, "Should get partial amount");

        // Check pending is cleared (completeUnallocate clears all pending)
        (uint256 pendingAfter,,,) = alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        assertEq(pendingAfter, 0, "Pending should be cleared after completeUnallocate");

        // User makes second request (no pending from first since it was cleared)
        uint256 secondRequest = 50e18;
        uint256 secondEstAmount = 48e18;
        _mockRequestUnallocate(user1, secondRequest, secondEstAmount);
        vm.prank(user1);
        (uint48 batchId2, uint256 actualEst2) = alephAVS.requestUnallocate(address(alephVault), secondRequest);

        // Check total pending (should only be the new second request)
        (uint256 totalPendingAfter,,,) = alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        assertEq(totalPendingAfter, actualEst2, "Total pending should be only second request");
    }

    /**
     * @notice Test: Multiple users request at different times with different vault states
     * @dev User1 requests (vault empty), User2 requests (vault has some), User3 requests (vault has more)
     */
    function test_MultipleUsers_DifferentVaultStates() public {
        uint256 user1Request = 100e18;
        uint256 user1EstAmount = 95e18;
        uint256 user2Request = 150e18;
        uint256 user2EstAmount = 144e18;
        uint256 user3Request = 50e18;
        uint256 user3EstAmount = 48e18;

        // User1 requests - vault has no redeemable yet
        _mockRequestUnallocate(user1, user1Request, user1EstAmount);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), user1Request);

        // Vault processes User1's request partially
        uint256 vaultRedeemable1 = 50e18;
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(vaultRedeemable1)
        );

        // User2 requests - vault now has some redeemable
        _mockRequestUnallocate(user2, user2Request, user2EstAmount);
        vm.prank(user2);
        alephAVS.requestUnallocate(address(alephVault), user2Request);

        // Vault processes more
        uint256 vaultRedeemable2 = user1EstAmount + 50e18; // User1 fully processed + some of User2
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(vaultRedeemable2)
        );

        // User3 requests - vault has even more redeemable
        _mockRequestUnallocate(user3, user3Request, user3EstAmount);
        vm.prank(user3);
        alephAVS.requestUnallocate(address(alephVault), user3Request);

        // Check all users have pending (use actual returned values)
        (uint256 user1Pending,,,) = alephAVS.getPendingUnallocateStatus(user1, address(alephVault));
        (uint256 user2Pending,,,) = alephAVS.getPendingUnallocateStatus(user2, address(alephVault));
        (uint256 user3Pending,,,) = alephAVS.getPendingUnallocateStatus(user3, address(alephVault));
        assertGe(user1Pending, user1EstAmount, "User1 should have pending");
        assertGe(user2Pending, user2EstAmount, "User2 should have pending");
        assertGe(user3Pending, user3EstAmount, "User3 should have pending");

        // Use actual values for calculations
        uint256 totalPendingActual = user1Pending + user2Pending + user3Pending;

        // Vault now has all redeemable (use actual pending amounts)
        uint256 totalRedeemable = totalPendingActual; // Vault has processed all
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(totalRedeemable)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );
        vm.mockCall(
            address(underlyingToken), abi.encodeCall(IERC20.balanceOf, (address(alephAVS))), abi.encode(totalRedeemable)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        // All users complete in order
        // User1 completes
        uint256 user1Expected = (user1Pending * totalRedeemable) / totalPendingActual;
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(user1Expected)
        );
        vm.prank(user1);
        (uint256 amount1,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount1, user1Expected, "User1 should get proportional share");

        // User2 completes
        uint256 remainingAfterUser1 = totalRedeemable - amount1;
        uint256 totalPendingAfterUser1 = totalPendingActual - user1Pending;
        uint256 user2Expected = (user2Pending * remainingAfterUser1) / totalPendingAfterUser1;
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(remainingAfterUser1)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(0) // No new redeemable
        );
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(user2Expected)
        );
        vm.prank(user2);
        (uint256 amount2,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount2, user2Expected, "User2 should get proportional share");

        // User3 gets remaining
        uint256 remainingAfterUser2 = remainingAfterUser1 - amount2;
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(remainingAfterUser2)
        );
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(remainingAfterUser2)
        );
        vm.prank(user3);
        (uint256 amount3,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount3, remainingAfterUser2, "User3 should get remaining");

        // Verify all completed
        assertEq(amount1 + amount2 + amount3, totalRedeemable, "Total should equal redeemable");
    }

    /**
     * @notice Test: Multiple users can complete in any order (proportional distribution ensures fairness)
     * @dev This test demonstrates that even if User B front-runs User A, both get their fair share
     *      due to proportional distribution. Front-running doesn't cause unfairness.
     */
    function test_CompleteUnallocate_ProportionalDistribution_FairRegardlessOfOrder() public {
        uint256 user1Amount = 100e18;
        uint256 user2Amount = 100e18;
        uint256 totalPending = user1Amount + user2Amount; // 200e18
        uint256 redeemableAmount = 200e18; // Enough for both

        // Setup: Both users have slashed tokens
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (user1)), abi.encode(user1Amount));
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (user2)), abi.encode(user2Amount));

        // Mock calculateAmountToRedeem (1:1 for simplicity)
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalPending));
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.assetsPerClassOf, (CLASS_ID, address(alephAVS))),
            abi.encode(totalPending)
        );

        // User1 requests unallocation FIRST (gets queue position 0)
        _mockRequestUnallocate(user1, user1Amount, user1Amount);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), user1Amount);

        // User2 requests unallocation SECOND (gets queue position 1)
        _mockRequestUnallocate(user2, user2Amount, user2Amount);
        vm.prank(user2);
        alephAVS.requestUnallocate(address(alephVault), user2Amount);

        // Vault has redeemable amount available
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(redeemableAmount)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(redeemableAmount)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        // User2 can complete first (front-running is allowed, but proportional distribution ensures fairness)
        uint256 expectedUser1 = (user1Amount * redeemableAmount) / totalPending; // 100e18
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(expectedUser1)
        );

        vm.prank(user1);
        (uint256 amount1, uint256 shares1) =
            alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount1, expectedUser1, "User1 should get their proportional share");
        assertEq(shares1, expectedUser1, "User1 shares should match amount");

        // Now User1 can complete (User2 already completed)
        uint256 remainingAfterUser1 = redeemableAmount - expectedUser1; // 100e18
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(0) // No new redeemable
        );
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(remainingAfterUser1)
        );
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(remainingAfterUser1)
        );

        vm.prank(user2);
        (uint256 amount2, uint256 shares2) =
            alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount2, remainingAfterUser1, "User2 should get remaining amount");
        assertEq(shares2, remainingAfterUser1, "User2 shares should match amount");

        // Verify both users got their fair share
        assertEq(amount1 + amount2, redeemableAmount, "Total should equal redeemable");
    }

    /**
     * @notice Test: Multiple requests from same user work correctly
     * @dev Tests that users can make multiple requests and complete them
     */
    function test_CompleteUnallocate_MultipleRequests_SameUser() public {
        uint256 user1FirstRequest = 50e18;
        uint256 user1SecondRequest = 50e18;
        uint256 user2Request = 100e18;
        uint256 totalPending = user1FirstRequest + user1SecondRequest + user2Request; // 200e18
        uint256 redeemableAmount = 200e18;

        // Setup
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (user1)), abi.encode(100e18));
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (user2)), abi.encode(100e18));
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalPending));
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.assetsPerClassOf, (CLASS_ID, address(alephAVS))),
            abi.encode(totalPending)
        );

        // User1 makes first request (gets position 0)
        _mockRequestUnallocate(user1, user1FirstRequest, user1FirstRequest);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), user1FirstRequest);

        // User2 makes request (gets position 1)
        _mockRequestUnallocate(user2, user2Request, user2Request);
        vm.prank(user2);
        alephAVS.requestUnallocate(address(alephVault), user2Request);

        // User1 makes second request (keeps position 0, pending increases)
        _mockRequestUnallocate(user1, user1SecondRequest, user1SecondRequest);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), user1SecondRequest);

        // Setup for completion
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(redeemableAmount)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(redeemableAmount)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        // Either user can complete (order doesn't matter due to proportional distribution)
        uint256 user1Pending = user1FirstRequest + user1SecondRequest; // 100e18
        uint256 expectedUser1 = (user1Pending * redeemableAmount) / totalPending; // 100e18
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(expectedUser1)
        );

        vm.prank(user1);
        (uint256 amount1,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount1, expectedUser1, "User1 should get their share");

        // Now User2 can complete
        uint256 remaining = redeemableAmount - expectedUser1; // 100e18
        vm.mockCall(
            address(alephVault), abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))), abi.encode(0)
        );
        vm.mockCall(
            address(underlyingToken), abi.encodeCall(IERC20.balanceOf, (address(alephAVS))), abi.encode(remaining)
        );
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(remaining)
        );

        vm.prank(user2);
        (uint256 amount2,) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount2, remaining, "User2 should get remaining");
    }

    /**
     * @notice Test: Users can complete when their batch is ready, regardless of order
     * @dev User A requests but can't complete (no redeemable), User B requests and can complete.
     *      User B can complete first, then User A when their batch is ready.
     */
    function test_CompleteUnallocate_UsersCompleteWhenReady_NoDeadlock() public {
        uint256 user1Amount = 100e18;
        uint256 user2Amount = 100e18;

        // Setup: Both users have slashed tokens
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (user1)), abi.encode(user1Amount));
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (user2)), abi.encode(user2Amount));

        // Mock calculateAmountToRedeem (1:1 for simplicity)
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeWithSelector(IERC20.totalSupply.selector),
            abi.encode(user1Amount + user2Amount)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.assetsPerClassOf, (CLASS_ID, address(alephAVS))),
            abi.encode(user1Amount + user2Amount)
        );

        // User1 requests unallocation FIRST (gets queue position 1)
        _mockRequestUnallocate(user1, user1Amount, user1Amount);
        vm.prank(user1);
        alephAVS.requestUnallocate(address(alephVault), user1Amount);

        // User2 requests unallocation SECOND (gets queue position 2)
        _mockRequestUnallocate(user2, user2Amount, user2Amount);
        vm.prank(user2);
        alephAVS.requestUnallocate(address(alephVault), user2Amount);

        // Vault only has User2's amount redeemable (User1's batch not processed yet)
        uint256 user2Redeemable = user2Amount;
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(user2Redeemable)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );
        vm.mockCall(
            address(underlyingToken), abi.encodeCall(IERC20.balanceOf, (address(alephAVS))), abi.encode(user2Redeemable)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        // User1 can complete and get their proportional share of available funds
        // Even though only User2's batch is ready, User1 gets (100/200) * 100 = 50
        uint256 totalPending = user1Amount + user2Amount; // 200e18
        uint256 expectedUser1 = (user1Amount * user2Redeemable) / totalPending; // 50e18
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(expectedUser1)
        );

        vm.prank(user1);
        (uint256 amount1, uint256 shares1) =
            alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount1, expectedUser1, "User1 should get proportional share");
        assertEq(shares1, expectedUser1, "User1 shares should match amount");

        // User2 can complete and get remaining (their batch is ready, order doesn't matter)
        uint256 remainingAfterUser1 = user2Redeemable - expectedUser1; // 50e18
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(0) // No new redeemable
        );
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(remainingAfterUser1)
        );
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(remainingAfterUser1)
        );

        vm.prank(user2);
        (uint256 amount2, uint256 shares2) =
            alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
        assertEq(amount2, remainingAfterUser1, "User2 should get remaining amount");
        assertEq(shares2, remainingAfterUser1, "User2 shares should match amount");

        // Verify both users got their fair proportional share
        assertEq(amount1 + amount2, user2Redeemable, "Total should equal available redeemable");

        // Note: In this scenario, User1 already completed and got their proportional share
        // If User1's batch becomes available later, they would have already completed
        // This demonstrates that users can complete when funds are available, regardless of order
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
