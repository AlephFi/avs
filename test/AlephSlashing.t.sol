// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {AlephSlashing} from "../src/libraries/AlephSlashing.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IAllocationManagerTypes} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";
import {AlephUtils} from "../src/libraries/AlephUtils.sol";

contract AlephSlashingTest is Test {
    IAllocationManager public mockAllocationManager;
    IStrategyManager public mockStrategyManager;
    IStrategy public mockStrategy;
    address public operator;
    address public avsAddress;
    OperatorSet public operatorSet;
    uint32 public operatorSetId = 0;

    function setUp() public {
        mockAllocationManager = IAllocationManager(address(0x100));
        mockStrategyManager = IStrategyManager(address(0x200));
        mockStrategy = IStrategy(address(0x300));
        operator = address(0x400);
        avsAddress = address(0x500);
        operatorSet = OperatorSet(avsAddress, operatorSetId);
    }

    function test_CalculateWadToSlash_ZeroMagnitude() public pure {
        uint256 wad = AlephSlashing.calculateWadToSlash(0, 100);
        assertEq(wad, 0);
    }

    function test_CalculateWadToSlash_ZeroCurrentMagnitude() public pure {
        uint256 wad = AlephSlashing.calculateWadToSlash(50, 0);
        assertEq(wad, 0);
    }

    function test_CalculateWadToSlash_HalfMagnitude() public pure {
        uint256 wad = AlephSlashing.calculateWadToSlash(50, 100);
        assertEq(wad, AlephUtils.WAD / 2);
    }

    function test_CalculateWadToSlash_FullMagnitude() public pure {
        uint256 wad = AlephSlashing.calculateWadToSlash(100, 100);
        assertEq(wad, AlephUtils.WAD);
    }

    function test_CalculateWadToSlash_ExceedsCurrentMagnitude() public pure {
        // Should cap at current magnitude
        uint256 wad = AlephSlashing.calculateWadToSlash(150, 100);
        assertEq(wad, AlephUtils.WAD);
    }

    function test_CalculateWadToSlash_SmallProportion() public pure {
        uint256 wad = AlephSlashing.calculateWadToSlash(1, 1000);
        // Should be 1/1000 of WAD
        assertEq(wad, AlephUtils.WAD / 1000);
    }

    function test_GetAllocatedShares() public {
        address[] memory operators = new address[](1);
        operators[0] = operator;
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = mockStrategy;

        uint256[][] memory allocatedStakes = new uint256[][](1);
        allocatedStakes[0] = new uint256[](1);
        allocatedStakes[0][0] = 1000e18;

        vm.mockCall(
            address(mockAllocationManager),
            abi.encodeWithSelector(IAllocationManager.getAllocatedStake.selector, operatorSet, operators, strategies),
            abi.encode(allocatedStakes)
        );

        uint256 shares = AlephSlashing.getAllocatedShares(mockAllocationManager, operator, operatorSet, mockStrategy);
        assertEq(shares, 1000e18);
    }

    function test_VerifyOperatorAllocation_Sufficient() public {
        IAllocationManagerTypes.Allocation memory allocation =
            IAllocationManagerTypes.Allocation({currentMagnitude: 100, pendingDiff: 0, effectBlock: 0});

        vm.mockCall(
            address(mockAllocationManager),
            abi.encodeWithSelector(IAllocationManager.getAllocation.selector, operator, operatorSet, mockStrategy),
            abi.encode(allocation)
        );

        // Should not revert
        AlephSlashing.verifyOperatorAllocation(mockAllocationManager, operator, operatorSet, 50, mockStrategy);
    }

    function test_VerifyOperatorAllocation_Insufficient() public {
        IAllocationManagerTypes.Allocation memory allocation =
            IAllocationManagerTypes.Allocation({currentMagnitude: 50, pendingDiff: 0, effectBlock: 0});

        vm.mockCall(
            address(mockAllocationManager),
            abi.encodeWithSelector(IAllocationManager.getAllocation.selector, operator, operatorSet, mockStrategy),
            abi.encode(allocation)
        );

        vm.expectRevert(AlephSlashing.InsufficientAllocation.selector);
        this._verifyOperatorAllocation(100);
    }

    function test_CalculateMagnitudeFromAmount_ZeroShares() public {
        vm.mockCall(
            address(mockStrategy), abi.encodeWithSelector(IStrategy.underlyingToSharesView.selector, 100), abi.encode(0)
        );

        vm.expectRevert(AlephSlashing.AmountTooSmall.selector);
        this._calculateMagnitudeFromAmount();
    }

    // Helper functions to wrap library calls for revert testing
    function _verifyOperatorAllocation(uint64 _requiredMagnitude) external {
        AlephSlashing.verifyOperatorAllocation(
            mockAllocationManager, operator, operatorSet, _requiredMagnitude, mockStrategy
        );
    }

    function _calculateMagnitudeFromAmount() external {
        AlephSlashing.calculateMagnitudeFromAmount(mockAllocationManager, operator, operatorSet, 100, mockStrategy);
    }

    function test_ClearRedistributableShares() public {
        uint256 expectedAmount = 500e18;

        vm.mockCall(
            address(mockStrategyManager),
            abi.encodeWithSelector(
                IStrategyManager.clearBurnOrRedistributableSharesByStrategy.selector, operatorSet, 1, mockStrategy
            ),
            abi.encode(expectedAmount)
        );

        uint256 amount =
            AlephSlashing.clearRedistributableShares(mockStrategyManager, avsAddress, operatorSetId, 1, mockStrategy);

        assertEq(amount, expectedAmount);
    }

    function test_CalculateMagnitudeFromAmount_NormalCase() public {
        // Test normal case where magnitude calculation works correctly
        // Note: Line 57 (magnitudeUint > currentMagnitude capping) is defensive code
        // that's mathematically unreachable when allocatedShares >= sharesNeeded
        vm.mockCall(
            address(mockStrategy),
            abi.encodeWithSelector(IStrategy.underlyingToSharesView.selector, 100),
            abi.encode(1000e18)
        );

        // Mock allocation with currentMagnitude = 100
        IAllocationManagerTypes.Allocation memory allocation =
            IAllocationManagerTypes.Allocation({currentMagnitude: 100, pendingDiff: 0, effectBlock: 0});

        vm.mockCall(
            address(mockAllocationManager),
            abi.encodeWithSelector(IAllocationManager.getAllocation.selector, operator, operatorSet, mockStrategy),
            abi.encode(allocation)
        );

        // Mock getAllocatedStake to return shares >= sharesNeeded
        address[] memory operators = new address[](1);
        operators[0] = operator;
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = mockStrategy;
        uint256[][] memory allocatedStakes = new uint256[][](1);
        allocatedStakes[0] = new uint256[](1);
        allocatedStakes[0][0] = 1000e18; // Equal to sharesNeeded

        vm.mockCall(
            address(mockAllocationManager),
            abi.encodeWithSelector(IAllocationManager.getAllocatedStake.selector, operatorSet, operators, strategies),
            abi.encode(allocatedStakes)
        );

        // Should succeed
        uint64 magnitude =
            AlephSlashing.calculateMagnitudeFromAmount(mockAllocationManager, operator, operatorSet, 100, mockStrategy);
        assertEq(magnitude, 100);
    }
}

