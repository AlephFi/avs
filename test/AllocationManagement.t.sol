// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {AllocationManagement} from "../src/libraries/AllocationManagement.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IAllocationManagerTypes} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";
import {AlephUtils} from "../src/libraries/AlephUtils.sol";

contract AllocationManagementTest is Test {
    using AllocationManagement for IStrategy[];

    IAllocationManager public mockAllocationManager;
    IStrategy public strategy1;
    IStrategy public strategy2;
    IStrategy public strategy3;
    address public avsAddress;
    address public operator;

    IStrategy[] public lstStrategies;
    IStrategy[] public slashedStrategies;

    function setUp() public {
        mockAllocationManager = IAllocationManager(address(0x100));
        strategy1 = IStrategy(address(0x200));
        strategy2 = IStrategy(address(0x300));
        strategy3 = IStrategy(address(0x400));
        avsAddress = address(0x500);
        operator = address(0x600);
    }

    function test_AddStrategy_EmptyArray() public {
        AllocationManagement.addStrategy(lstStrategies, strategy1);
        assertEq(lstStrategies.length, 1);
        assertEq(address(lstStrategies[0]), address(strategy1));
    }

    function test_AddStrategy_AppendAtEnd() public {
        AllocationManagement.addStrategy(lstStrategies, strategy1);
        AllocationManagement.addStrategy(lstStrategies, strategy2);
        AllocationManagement.addStrategy(lstStrategies, strategy3);

        assertEq(lstStrategies.length, 3);
        assertEq(address(lstStrategies[0]), address(strategy1));
        assertEq(address(lstStrategies[1]), address(strategy2));
        assertEq(address(lstStrategies[2]), address(strategy3));
    }

    function test_AddStrategy_InsertInMiddle() public {
        // Add strategies in non-sorted order
        AllocationManagement.addStrategy(lstStrategies, strategy3); // 0x400
        AllocationManagement.addStrategy(lstStrategies, strategy1); // 0x200
        AllocationManagement.addStrategy(lstStrategies, strategy2); // 0x300

        // Should be sorted: 0x200, 0x300, 0x400
        assertEq(lstStrategies.length, 3);
        assertEq(address(lstStrategies[0]), address(strategy1));
        assertEq(address(lstStrategies[1]), address(strategy2));
        assertEq(address(lstStrategies[2]), address(strategy3));
    }

    function test_AddStrategy_DuplicateIgnored() public {
        AllocationManagement.addStrategy(lstStrategies, strategy1);
        AllocationManagement.addStrategy(lstStrategies, strategy1);

        assertEq(lstStrategies.length, 1);
        assertEq(address(lstStrategies[0]), address(strategy1));
    }

    function test_AddStrategy_InsertAtBeginning() public {
        AllocationManagement.addStrategy(lstStrategies, strategy2);
        AllocationManagement.addStrategy(lstStrategies, strategy1);

        assertEq(lstStrategies.length, 2);
        assertEq(address(lstStrategies[0]), address(strategy1));
        assertEq(address(lstStrategies[1]), address(strategy2));
    }

    function test_BuildParams_EmptyArray() public {
        (IStrategy[] memory strategies, uint64[] memory magnitudes) = AllocationManagement.buildParams(lstStrategies);

        assertEq(strategies.length, 0);
        assertEq(magnitudes.length, 0);
    }

    function test_BuildParams_SingleStrategy() public {
        AllocationManagement.addStrategy(lstStrategies, strategy1);

        (IStrategy[] memory strategies, uint64[] memory magnitudes) = AllocationManagement.buildParams(lstStrategies);

        assertEq(strategies.length, 1);
        assertEq(magnitudes.length, 1);
        assertEq(address(strategies[0]), address(strategy1));
        assertEq(magnitudes[0], AlephUtils.OPERATOR_SET_MAGNITUDE);
    }

    function test_BuildParams_MultipleStrategies() public {
        AllocationManagement.addStrategy(lstStrategies, strategy1);
        AllocationManagement.addStrategy(lstStrategies, strategy2);
        AllocationManagement.addStrategy(lstStrategies, strategy3);

        (IStrategy[] memory strategies, uint64[] memory magnitudes) = AllocationManagement.buildParams(lstStrategies);

        assertEq(strategies.length, 3);
        assertEq(magnitudes.length, 3);
        assertEq(address(strategies[0]), address(strategy1));
        assertEq(address(strategies[1]), address(strategy2));
        assertEq(address(strategies[2]), address(strategy3));
        assertEq(magnitudes[0], AlephUtils.OPERATOR_SET_MAGNITUDE);
        assertEq(magnitudes[1], AlephUtils.OPERATOR_SET_MAGNITUDE);
        assertEq(magnitudes[2], AlephUtils.OPERATOR_SET_MAGNITUDE);
    }

    function test_PrepareAllocationParams_ViewFunction() public {
        AllocationManagement.addStrategy(lstStrategies, strategy1);

        IAllocationManagerTypes.AllocateParams memory params = AllocationManagement.prepareAllocationParams(
            avsAddress, AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID, lstStrategies
        );

        assertEq(address(params.operatorSet.avs), avsAddress);
        assertEq(params.operatorSet.id, AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID);
        assertEq(params.strategies.length, 1);
        assertEq(params.newMagnitudes.length, 1);
        assertEq(address(params.strategies[0]), address(strategy1));
        assertEq(params.newMagnitudes[0], AlephUtils.OPERATOR_SET_MAGNITUDE);
    }

    function test_AllocateStakeForVaultStrategies() public {
        vm.mockCall(
            address(mockAllocationManager),
            abi.encodeWithSelector(IAllocationManager.modifyAllocations.selector),
            abi.encode()
        );

        AllocationManagement.allocateStakeForVaultStrategies(
            mockAllocationManager, operator, avsAddress, strategy1, strategy2, lstStrategies, slashedStrategies
        );

        // Verify strategies were added
        assertEq(lstStrategies.length, 1);
        assertEq(slashedStrategies.length, 1);
        assertEq(address(lstStrategies[0]), address(strategy1));
        assertEq(address(slashedStrategies[0]), address(strategy2));
    }

    function test_AllocateStakeForVaultStrategies_WithExistingStrategies() public {
        // Add existing strategies
        AllocationManagement.addStrategy(lstStrategies, strategy3);
        AllocationManagement.addStrategy(slashedStrategies, strategy3);

        vm.mockCall(
            address(mockAllocationManager),
            abi.encodeWithSelector(IAllocationManager.modifyAllocations.selector),
            abi.encode()
        );

        AllocationManagement.allocateStakeForVaultStrategies(
            mockAllocationManager, operator, avsAddress, strategy1, strategy2, lstStrategies, slashedStrategies
        );

        // Verify new strategies were added and arrays are sorted
        assertEq(lstStrategies.length, 2);
        assertEq(slashedStrategies.length, 2);
        assertEq(address(lstStrategies[0]), address(strategy1));
        assertEq(address(lstStrategies[1]), address(strategy3));
        assertEq(address(slashedStrategies[0]), address(strategy2));
        assertEq(address(slashedStrategies[1]), address(strategy3));
    }
}

