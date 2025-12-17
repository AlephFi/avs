// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {AlephUtils} from "../src/libraries/AlephUtils.sol";
import {AlephValidation} from "../src/libraries/AlephValidation.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IAlephVaultFactory} from "Aleph/src/interfaces/IAlephVaultFactory.sol";

contract LibraryUtilsTest is Test {
    using AlephUtils for address;

    function test_Constants() public pure {
        assertEq(AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID, 0);
        assertEq(AlephUtils.SLASHED_STRATEGIES_OPERATOR_SET_ID, 1);
        assertEq(AlephUtils.OPERATOR_SET_MAGNITUDE, 1e18);
        assertEq(AlephUtils.WAD, 1e18);
        assertEq(AlephUtils.REWARD_MULTIPLIER, uint96(1e18));
    }

    function test_ValidateAddress_RevertsOnZeroAddress() public {
        vm.expectRevert(AlephUtils.InvalidAddress.selector);
        this._validateAddress(address(0));
    }

    function _validateAddress(address _addr) external pure {
        AlephUtils.validateAddress(_addr);
    }

    function test_ValidateAddress_SucceedsOnNonZeroAddress() public pure {
        AlephUtils.validateAddress(address(0x1));
        AlephUtils.validateAddress(address(0x2));
    }

    function test_ValidateAddressWithSelector_RevertsOnZeroAddress() public {
        bytes4 customSelector = bytes4(keccak256("CustomError()"));
        vm.expectRevert(customSelector);
        this._validateAddressWithSelector(address(0), customSelector);
    }

    function _validateAddressWithSelector(address _addr, bytes4 _selector) external pure {
        AlephUtils.validateAddressWithSelector(_addr, _selector);
    }

    function test_ValidateAddressWithSelector_SucceedsOnNonZeroAddress() public pure {
        bytes4 customSelector = bytes4(keccak256("CustomError()"));
        AlephUtils.validateAddressWithSelector(address(0x1), customSelector);
    }

    function test_AsStrategyArray() public pure {
        IStrategy mockStrategy = IStrategy(address(0x123));
        IStrategy[] memory arr = AlephUtils.asStrategyArray(mockStrategy);

        assertEq(arr.length, 1);
        assertEq(address(arr[0]), address(mockStrategy));

        // Use the return value to ensure return statement is covered
        IStrategy[] memory arr2 = arr;
        assertEq(arr2.length, 1);
    }

    function test_CreateStrategyAllocationParams() public pure {
        IStrategy mockStrategy = IStrategy(address(0x456));
        uint64 magnitude = 1e18;

        (IStrategy[] memory strategies, uint64[] memory magnitudes) =
            AlephUtils.createStrategyAllocationParams(mockStrategy, magnitude);

        assertEq(strategies.length, 1);
        assertEq(magnitudes.length, 1);
        assertEq(address(strategies[0]), address(mockStrategy));
        assertEq(magnitudes[0], magnitude);
    }

    function test_GetOperatorSet() public pure {
        address avsAddress = address(0x789);
        uint32 operatorSetId = 42;

        OperatorSet memory operatorSet = AlephUtils.getOperatorSet(avsAddress, operatorSetId);

        assertEq(operatorSet.avs, avsAddress);
        assertEq(operatorSet.id, operatorSetId);
    }
}

contract AlephValidationTest is Test {
    function test_ValidateStrategy_RevertsOnZeroAddress() public {
        vm.expectRevert(AlephValidation.InvalidStrategy.selector);
        this._validateStrategy(address(0));
    }

    function _validateStrategy(address _strategy) external pure {
        AlephValidation.validateStrategy(_strategy);
    }

    function test_ValidateStrategy_SucceedsOnNonZeroAddress() public pure {
        AlephValidation.validateStrategy(address(0x1));
        AlephValidation.validateStrategy(address(0x2));
    }

    function test_ValidateOperatorSetAndMembership_RevertsOnInvalidOperatorSet() public {
        IAllocationManager mockAllocationManager = IAllocationManager(address(0x100));
        address operator = address(0x200);
        OperatorSet memory operatorSet = OperatorSet(address(0x300), 1);

        vm.mockCall(
            address(mockAllocationManager),
            abi.encodeWithSelector(IAllocationManager.isOperatorSet.selector, operatorSet),
            abi.encode(false)
        );

        vm.expectRevert(AlephValidation.InvalidOperatorSet.selector);
        this._validateOperatorSetAndMembership(mockAllocationManager, operator, operatorSet);
    }

    function _validateOperatorSetAndMembership(
        IAllocationManager _allocationManager,
        address _operator,
        OperatorSet memory _operatorSet
    ) external view {
        AlephValidation.validateOperatorSetAndMembership(_allocationManager, _operator, _operatorSet);
    }

    function test_ValidateOperatorSetAndMembership_RevertsOnNotMember() public {
        IAllocationManager mockAllocationManager = IAllocationManager(address(0x100));
        address operator = address(0x200);
        OperatorSet memory operatorSet = OperatorSet(address(0x300), 1);

        vm.mockCall(
            address(mockAllocationManager),
            abi.encodeWithSelector(IAllocationManager.isOperatorSet.selector, operatorSet),
            abi.encode(true)
        );
        vm.mockCall(
            address(mockAllocationManager),
            abi.encodeWithSelector(IAllocationManager.isMemberOfOperatorSet.selector, operator, operatorSet),
            abi.encode(false)
        );

        vm.expectRevert(AlephValidation.NotMemberOfOperatorSet.selector);
        this._validateOperatorSetAndMembership(mockAllocationManager, operator, operatorSet);
    }

    function test_ValidateOperatorSetAndMembership_Succeeds() public {
        IAllocationManager mockAllocationManager = IAllocationManager(address(0x100));
        address operator = address(0x200);
        OperatorSet memory operatorSet = OperatorSet(address(0x300), 1);

        vm.mockCall(
            address(mockAllocationManager),
            abi.encodeWithSelector(IAllocationManager.isOperatorSet.selector, operatorSet),
            abi.encode(true)
        );
        vm.mockCall(
            address(mockAllocationManager),
            abi.encodeWithSelector(IAllocationManager.isMemberOfOperatorSet.selector, operator, operatorSet),
            abi.encode(true)
        );

        AlephValidation.validateOperatorSetAndMembership(mockAllocationManager, operator, operatorSet);
    }

    function test_ValidateVault_RevertsOnInvalidVault() public {
        IAlephVaultFactory mockVaultFactory = IAlephVaultFactory(address(0x400));
        address vault = address(0x500);

        vm.mockCall(
            address(mockVaultFactory),
            abi.encodeWithSelector(IAlephVaultFactory.isValidVault.selector, vault),
            abi.encode(false)
        );

        vm.expectRevert(AlephValidation.InvalidAlephVault.selector);
        this._validateVault(mockVaultFactory, vault);
    }

    function _validateVault(IAlephVaultFactory _vaultFactory, address _vault) external view {
        AlephValidation.validateVault(_vaultFactory, _vault);
    }

    function test_ValidateVault_Succeeds() public {
        IAlephVaultFactory mockVaultFactory = IAlephVaultFactory(address(0x400));
        address vault = address(0x500);

        vm.mockCall(
            address(mockVaultFactory),
            abi.encodeWithSelector(IAlephVaultFactory.isValidVault.selector, vault),
            abi.encode(true)
        );

        AlephValidation.validateVault(mockVaultFactory, vault);
    }
}

