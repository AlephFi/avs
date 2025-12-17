// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/AlephAVS.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IAlephVault} from "Aleph/src/interfaces/IAlephVault.sol";

/**
 * @title RequestUnallocate
 * @notice Script to request unallocation of funds from an Aleph vault
 * @dev This is the first step of the two-step unallocate flow.
 *      Burns slashed tokens and requests redemption from the vault.
 *
 * @dev Usage:
 *   1. Set up .env file with:
 *      - PRIVATE_KEY (required - token holder's private key)
 *      - RPC_URL (or pass via --rpc-url flag)
 *      - ALEPH_AVS_ADDRESS (deployed AlephAVS contract address, or will load from deployments)
 *      - ALEPH_VAULT_ADDRESS (target Aleph vault address)
 *      - UNALLOCATE_TOKEN_AMOUNT (amount of slashed strategy tokens to unallocate, in wei)
 *
 *   2. Run: forge script script/RequestUnallocate.s.sol:RequestUnallocate --rpc-url $RPC_URL --broadcast
 *
 *   3. After the vault processes the redemption request, run CompleteUnallocate.s.sol to complete the unallocation
 */
contract RequestUnallocate is Script {
    function run() external {
        // Get token holder private key
        uint256 privateKey = getPrivateKey();
        address tokenHolder = vm.addr(privateKey);

        console.log("Token holder address:", tokenHolder);

        // Load configuration
        address alephAVSAddress = getAlephAVSAddress();
        address alephVaultAddress = getAlephVaultAddress();
        uint256 tokenAmount = getTokenAmount();

        console.log("AlephAVS address:", alephAVSAddress);
        console.log("Aleph vault address:", alephVaultAddress);
        console.log("Token amount (wei):", tokenAmount);

        // Get slashed strategy and token
        AlephAVS alephAVS = AlephAVS(alephAVSAddress);
        IStrategy slashedStrategy = alephAVS.vaultToSlashedStrategy(alephVaultAddress);

        if (address(slashedStrategy) == address(0)) {
            revert("Vault has not been initialized. Please initialize the vault first.");
        }

        IERC20 slashedToken = IERC20(address(slashedStrategy.underlyingToken()));
        uint256 balance = slashedToken.balanceOf(tokenHolder);

        console.log("Slashed strategy:", address(slashedStrategy));
        console.log("Slashed token:", address(slashedToken));
        console.log("Token holder balance:", balance);

        if (balance < tokenAmount) {
            revert("Insufficient slashed token balance. Token holder needs more tokens.");
        }

        // Calculate estimated amount to redeem
        (uint256 estAmountToRedeem, IStrategy originalStrategy, IERC20 vaultToken) =
            alephAVS.calculateUnallocateAmount(alephVaultAddress, tokenAmount);

        // Check minimum redeem amount
        // Note: Class ID is typically 1 for AlephAVS vaults. If your vault uses a different class ID,
        // you may need to adjust this or add a getter function to AlephAVS contract.
        uint8 classId = 1;
        uint256 minRedeemAmount = IAlephVault(alephVaultAddress).minRedeemAmount(classId);

        console.log("\n=== Unallocation Preview ===");
        console.log("Estimated amount to redeem:", estAmountToRedeem);
        console.log("Vault minimum redeem amount:", minRedeemAmount);
        console.log("Original strategy:", address(originalStrategy));
        console.log("Vault token:", address(vaultToken));

        // Check if estimated amount is 0 (no assets allocated to vault)
        if (estAmountToRedeem == 0) {
            console.log("\n[ERROR] Cannot unallocate: No assets allocated to vault!");
            console.log("  The vault has no assets allocated for this class.");
            console.log("  You must allocate funds to the vault first before unallocating.");
            console.log("  Run AllocateToAlephVault.s.sol to allocate funds.");
            revert("Cannot unallocate: estAmountToRedeem is 0. No assets allocated to vault.");
        }

        // Check if estimated amount meets minimum requirement
        // Note: The vault only checks minRedeemAmount if not redeeming all (remaining balance > 0)
        // So we warn but don't revert - the actual check happens in the vault
        if (estAmountToRedeem < minRedeemAmount) {
            console.log("\n[WARNING] Estimated amount to redeem is below vault minimum!");
            console.log("  Estimated:", estAmountToRedeem);
            console.log("  Minimum:", minRedeemAmount);
            console.log("  This will fail unless you are redeeming all remaining balance.");
            console.log("  Consider increasing UNALLOCATE_TOKEN_AMOUNT to at least:", minRedeemAmount);
        }

        // Execute request unallocate
        vm.startBroadcast(privateKey);

        // Check and approve if needed
        uint256 currentAllowance = slashedToken.allowance(tokenHolder, alephAVSAddress);
        if (currentAllowance < tokenAmount) {
            console.log("\n=== Approving Tokens ===");
            console.log("Current allowance:", currentAllowance);
            console.log("Required allowance:", tokenAmount);
            console.log("Approving AlephAVS to spend slashed tokens...");

            slashedToken.approve(alephAVSAddress, tokenAmount);

            console.log("Approval complete. New allowance:", slashedToken.allowance(tokenHolder, alephAVSAddress));
        } else {
            console.log("\n=== Token Approval ===");
            console.log("Sufficient allowance already exists:", currentAllowance);
        }

        console.log("\n=== Requesting Unallocation ===");
        console.log("Calling AlephAVS.requestUnallocate...");

        (uint48 batchId, uint256 actualEstAmount) = alephAVS.requestUnallocate(alephVaultAddress, tokenAmount);

        vm.stopBroadcast();

        console.log("\n=== Unallocation Request Complete ===");
        console.log("Batch ID:", uint256(batchId));
        console.log("Estimated amount to redeem:", actualEstAmount);
        console.log("\nNext steps:");
        console.log("  1. Wait for the vault to process the redemption request");
        console.log("  2. Run CompleteUnallocate.s.sol to complete the unallocation");
    }

    function getPrivateKey() internal view returns (uint256) {
        try vm.envString("PRIVATE_KEY") returns (string memory privateKeyStr) {
            uint256 privateKey = vm.parseUint(privateKeyStr);
            console.log("Using PRIVATE_KEY from .env file");
            return privateKey;
        } catch {
            revert("PRIVATE_KEY not found in .env file. Please set PRIVATE_KEY to the token holder's private key.");
        }
    }

    function getAlephAVSAddress() internal view returns (address) {
        // Try to get from env var first
        try vm.envAddress("ALEPH_AVS_ADDRESS") returns (address addr) {
            return addr;
        } catch {
            // Try to load from deployments file
            uint256 chainId = block.chainid;
            string memory deploymentPath =
                string.concat(vm.projectRoot(), "/deployments/", vm.toString(chainId), ".json");

            try vm.readFile(deploymentPath) returns (string memory json) {
                address addr = vm.parseJsonAddress(json, ".alephAVSProxyAddress");
                if (addr == address(0)) {
                    addr = vm.parseJsonAddress(json, ".contractAddress");
                }
                console.log("Loaded AlephAVS address from deployments file");
                return addr;
            } catch {
                revert(
                    "ALEPH_AVS_ADDRESS not found. Please set ALEPH_AVS_ADDRESS in .env or deploy the contract first."
                );
            }
        }
    }

    function getAlephVaultAddress() internal view returns (address) {
        try vm.envAddress("ALEPH_VAULT_ADDRESS") returns (address addr) {
            return addr;
        } catch {
            revert("ALEPH_VAULT_ADDRESS not found. Please set ALEPH_VAULT_ADDRESS in .env file.");
        }
    }

    function getTokenAmount() internal view returns (uint256) {
        try vm.envUint("UNALLOCATE_TOKEN_AMOUNT") returns (uint256 amount) {
            return amount;
        } catch {
            revert("UNALLOCATE_TOKEN_AMOUNT not found in .env file. Please set UNALLOCATE_TOKEN_AMOUNT (in wei).");
        }
    }
}
