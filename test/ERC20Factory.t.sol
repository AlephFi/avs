// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ERC20Factory} from "../src/ERC20Factory.sol";
import {ERC20Token} from "../src/ERC20Token.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract ERC20FactoryTest is Test {
    ERC20Factory public factory;
    address public user = address(0x1);
    address public owner = address(0x2);

    event TokenCreated(address indexed token, string name, string symbol, address indexed creator);

    function setUp() public {
        factory = new ERC20Factory(owner);
    }

    function test_CreateToken() public {
        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint8 decimals = 18;

        vm.prank(owner);
        address token = factory.createToken(name, symbol, decimals);

        // Verify return value is used (covers return statement)
        assertTrue(token != address(0), "Token address should not be zero");
        assertTrue(factory.isToken(token));
        assertEq(factory.getTokenCount(), 1);
        assertEq(factory.getToken(0), token);

        ERC20Token tokenContract = ERC20Token(token);
        assertEq(tokenContract.name(), name);
        assertEq(tokenContract.symbol(), symbol);
        assertEq(tokenContract.decimals(), decimals);
        assertEq(tokenContract.totalSupply(), 0); // No initial supply
    }

    function test_CreateTokenWithCustomDecimals() public {
        vm.prank(owner);
        address token = factory.createToken("Custom Decimals", "CUSTOM", 6);

        ERC20Token tokenContract = ERC20Token(token);
        assertEq(tokenContract.decimals(), 6);
        assertEq(tokenContract.totalSupply(), 0);
    }

    function test_CreateMultipleTokens() public {
        vm.startPrank(owner);
        address token1 = factory.createToken("Token 1", "T1", 18);
        address token2 = factory.createToken("Token 2", "T2", 18);
        address token3 = factory.createToken("Token 3", "T3", 18);
        vm.stopPrank();

        assertEq(factory.getTokenCount(), 3);
        assertEq(factory.getToken(0), token1);
        assertEq(factory.getToken(1), token2);
        assertEq(factory.getToken(2), token3);

        address[] memory allTokens = factory.getAllTokens();
        assertEq(allTokens.length, 3);
        assertEq(allTokens[0], token1);
        assertEq(allTokens[1], token2);
        assertEq(allTokens[2], token3);
    }

    function test_IsTokenReturnsFalseForNonFactoryToken() public {
        // Deploy a token directly (not through factory)
        ERC20Token directToken = new ERC20Token("Token", "TKN", 18, owner);

        assertFalse(factory.isToken(address(directToken)));
    }

    function test_CreateTokenFailsWithEmptyName() public {
        vm.expectRevert(ERC20Factory.EmptyString.selector);
        vm.prank(owner);
        factory.createToken("", "SYMBOL", 18);
    }

    function test_CreateTokenFailsWithEmptySymbol() public {
        vm.expectRevert(ERC20Factory.EmptyString.selector);
        vm.prank(owner);
        factory.createToken("Name", "", 18);
    }

    function test_TokenMintAndBurn() public {
        vm.startPrank(owner);
        address token = factory.createToken("Mintable Token", "MINT", 18);

        ERC20Token tokenContract = ERC20Token(token);

        // Owner can mint
        tokenContract.mint(user, 500 ether);
        assertEq(tokenContract.balanceOf(user), 500 ether);
        assertEq(tokenContract.totalSupply(), 500 ether);

        // Owner can burn
        tokenContract.burn(user, 200 ether);
        assertEq(tokenContract.balanceOf(user), 300 ether);
        assertEq(tokenContract.totalSupply(), 300 ether);
        vm.stopPrank();
    }

    function test_TokenMintFailsIfNotOwner() public {
        // Set chain ID to mainnet (1) to test owner-only restriction
        vm.chainId(1);

        vm.prank(owner);
        address token = factory.createToken("Mintable Token", "MINT", 18);

        ERC20Token tokenContract = ERC20Token(token);

        // Non-owner cannot mint on mainnet
        vm.prank(user);
        vm.expectRevert();
        tokenContract.mint(user, 500 ether);
    }

    function test_TokenMintSucceedsForAnyoneOnTestnet() public {
        // Use a testnet chain ID (not 1) to test open minting
        vm.chainId(11155111); // Sepolia

        vm.prank(owner);
        address token = factory.createToken("Mintable Token", "MINT", 18);

        ERC20Token tokenContract = ERC20Token(token);

        // Anyone can mint on testnets
        vm.prank(user);
        tokenContract.mint(user, 500 ether);
        assertEq(tokenContract.balanceOf(user), 500 ether);
        assertEq(tokenContract.totalSupply(), 500 ether);
    }

    function test_GetTokenFailsWithInvalidIndex() public {
        vm.prank(owner);
        factory.createToken("Token", "TKN", 18);

        vm.expectRevert(ERC20Factory.IndexOutOfBounds.selector);
        factory.getToken(1);
    }

    function test_GetTokenCount() public {
        assertEq(factory.getTokenCount(), 0);

        vm.startPrank(owner);
        factory.createToken("Token 1", "T1", 18);
        assertEq(factory.getTokenCount(), 1);

        factory.createToken("Token 2", "T2", 18);
        assertEq(factory.getTokenCount(), 2);
        vm.stopPrank();
    }

    function test_GetAllTokens_Empty() public {
        address[] memory tokens = factory.getAllTokens();
        assertEq(tokens.length, 0);
    }

    function test_GetToken_SuccessPath() public {
        vm.startPrank(owner);
        address token1 = factory.createToken("Token 1", "T1", 18);
        address token2 = factory.createToken("Token 2", "T2", 18);
        vm.stopPrank();

        // Test all valid indices
        assertEq(factory.getToken(0), token1);
        assertEq(factory.getToken(1), token2);

        // Test getAllTokens returns same addresses
        address[] memory allTokens = factory.getAllTokens();
        assertEq(allTokens[0], token1);
        assertEq(allTokens[1], token2);
    }

    function test_GetToken_EdgeCase_LastIndex() public {
        vm.prank(owner);
        address token = factory.createToken("Token", "TKN", 18);

        // Test getting the last (and only) token
        assertEq(factory.getToken(0), token);
    }
}
