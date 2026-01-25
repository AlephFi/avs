// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/AlephAVS.sol";
import {IMintableBurnableERC20} from "../src/interfaces/IMintableBurnableERC20.sol";
import {IERC20Factory} from "../src/interfaces/IERC20Factory.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title MintToken
 * @notice Script for minting ERC20 tokens created by the ERC20Factory
 * @dev This script can be run by anyone, but only the owner of the token (AlephAVS) can successfully mint.
 *      Tokens are created via the ERC20Factory and owned by AlephAVS.
 *
 * @dev Usage:
 *   1. Set up .env file with:
 *      - PRIVATE_KEY (required - any private key, but minting will only succeed if it's the owner of AlephAVS)
 *      - RPC_URL (or pass via --rpc-url flag)
 *      - ALEPH_AVS_ADDRESS (deployed AlephAVS contract address, or will load from deployments)
 *      - TOKEN_ADDRESS (required - address of the token to mint)
 *      - MINT_TO_ADDRESS (optional - address to receive the minted tokens, defaults to msg.sender)
 *      - MINT_AMOUNT (required - amount in wei to mint, e.g., "100000000000000000000" for 100 tokens)
 *
 *   2. Run: forge script script/MintToken.s.sol:MintToken --rpc-url $RPC_URL --broadcast
 *
 *   Note: Anyone can run this script, but only the owner of the token (AlephAVS) can successfully mint.
 *         If AlephAVS is owned by a Safe, you'll need to submit this transaction through the Safe.
 */
contract MintToken is Script {
    function run() external {
        // Get operator private key
        uint256 privateKey = getPrivateKey();
        address caller = vm.addr(privateKey);

        console.log("=== Mint ERC20 Token ===");
        console.log("Caller address:", caller);

        // Load configuration
        address tokenAddress = getTokenAddress();
        address mintToAddress = getMintToAddress(caller);
        uint256 mintAmount = getMintAmount();

        console.log("Token address:", tokenAddress);
        console.log("Mint to address:", mintToAddress);
        console.log("Mint amount (wei):", mintAmount);

        // Get AlephAVS contract

        // Get token contract
        IMintableBurnableERC20 token = IMintableBurnableERC20(tokenAddress);
        IERC20 tokenERC20 = IERC20(tokenAddress);

        // Check current balance
        uint256 balanceBefore = tokenERC20.balanceOf(mintToAddress);
        console.log("Balance before mint:", balanceBefore);

        // Anyone can run this script, but only the token owner (AlephAVS) can successfully mint
        // ERC20Token uses Ownable with onlyOwner modifier on mint function
        console.log("\n[INFO] Token owner is AlephAVS");
        console.log("[INFO] Attempting to mint tokens...");
        console.log(
            "[INFO] Note: Anyone can run this script, but minting will only succeed if the caller is the token owner (AlephAVS)."
        );
        console.log("[INFO] Note: If AlephAVS is owned by a Safe, this transaction must be submitted through the Safe.");

        vm.startBroadcast(privateKey);

        // Mint tokens
        // The token's mint function requires the owner (AlephAVS) to call it
        // We call it directly - if AlephAVS is owned by a Safe and caller is not the Safe owner,
        // this will revert and the user should submit through Safe
        token.mint(mintToAddress, mintAmount);

        vm.stopBroadcast();

        // Check balance after
        uint256 balanceAfter = tokenERC20.balanceOf(mintToAddress);
        console.log("Balance after mint:", balanceAfter);
        console.log("\n[OK] Tokens minted successfully!");
        console.log("  Minted:", mintAmount, "wei");
        console.log("  To:", mintToAddress);
    }

    /**
     * @notice Get private key from .env file
     * @return privateKey The private key as uint256
     */
    function getPrivateKey() internal view returns (uint256) {
        string memory privateKeyStr = vm.envString("PRIVATE_KEY");
        return vm.parseUint(privateKeyStr);
    }

    /**
     * @notice Get AlephAVS address from .env or deployments file
     * @return alephAVSAddress The AlephAVS contract address
     */
    function getAlephAVSAddress() internal view returns (address) {
        try vm.envAddress("ALEPH_AVS_ADDRESS") returns (address envAddress) {
            return envAddress;
        } catch {
            // Try to load from deployments file
            uint256 chainId = getChainId();
            string memory deploymentsDir = string.concat(vm.projectRoot(), "/deployments");
            string memory filename = string.concat(vm.toString(chainId), ".json");
            string memory deploymentPath = string.concat(deploymentsDir, "/", filename);

            try vm.readFile(deploymentPath) returns (string memory jsonContent) {
                return vm.parseJsonAddress(jsonContent, ".alephAVSProxyAddress");
            } catch {
                revert("ALEPH_AVS_ADDRESS not found in .env or deployments file");
            }
        }
    }

    /**
     * @notice Get chain ID from .env or block.chainid
     * @return chainId The chain ID
     */
    function getChainId() internal view returns (uint256) {
        try vm.envUint("CHAIN_ID") returns (uint256 envChainId) {
            return envChainId;
        } catch {
            return block.chainid;
        }
    }

    /**
     * @notice Get token address from .env file
     * @return tokenAddress The token contract address
     */
    function getTokenAddress() internal view returns (address) {
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        require(tokenAddress != address(0), "TOKEN_ADDRESS must be set in .env file");
        return tokenAddress;
    }

    /**
     * @notice Get mint to address from .env file or default to caller
     * @param defaultAddress The default address to use if MINT_TO_ADDRESS is not set
     * @return mintToAddress The address to receive minted tokens
     */
    function getMintToAddress(address defaultAddress) internal view returns (address) {
        try vm.envAddress("MINT_TO_ADDRESS") returns (address envAddress) {
            return envAddress;
        } catch {
            // If not set, use the caller's address (msg.sender)
            return defaultAddress;
        }
    }

    /**
     * @notice Get mint amount from .env file
     * @return mintAmount The amount to mint in wei
     */
    function getMintAmount() internal view returns (uint256) {
        string memory amountStr = vm.envString("MINT_AMOUNT");
        require(bytes(amountStr).length > 0, "MINT_AMOUNT must be set in .env file");
        return vm.parseUint(amountStr);
    }
}

