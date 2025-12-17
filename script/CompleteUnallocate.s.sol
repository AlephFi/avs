// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/AlephAVS.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {StrategyManagerStorage} from "eigenlayer-contracts/src/contracts/core/StrategyManagerStorage.sol";
import {IStrategyFactory} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyFactory.sol";
import {IAlephVault} from "Aleph/src/interfaces/IAlephVault.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20 as IERC20Eigen} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title CompleteUnallocate
 * @notice Script to complete unallocation of funds from an Aleph vault
 * @dev This is the second step of the two-step unallocate flow.
 *      Withdraws redeemable amount from the vault and deposits it back into the original LST strategy.
 *
 * @dev Usage:
 *   1. Set up .env file with:
 *      - PRIVATE_KEY (required - token holder's private key, same as used in RequestUnallocate)
 *      - RPC_URL (or pass via --rpc-url flag)
 *      - ALEPH_AVS_ADDRESS (deployed AlephAVS contract address, or will load from deployments)
 *      - ALEPH_VAULT_ADDRESS (target Aleph vault address, same as used in RequestUnallocate)
 *      - STRATEGY_DEPOSIT_EXPIRY (expiry timestamp for strategy deposit signature, default: max uint256)
 *
 *   2. Run: forge script script/CompleteUnallocate.s.sol:CompleteUnallocate --rpc-url $RPC_URL --broadcast
 *
 * @dev Note: The script will automatically generate the strategy deposit signature using PRIVATE_KEY.
 *      The signature is for depositing tokens back into the original LST strategy on behalf of the token holder.
 */
contract CompleteUnallocate is Script {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    function run() external {
        // Get token holder private key
        uint256 privateKey = getPrivateKey();
        address tokenHolder = vm.addr(privateKey);

        console.log("Token holder address:", tokenHolder);

        // Load configuration
        address alephAVSAddress = getAlephAVSAddress();
        address alephVaultAddress = getAlephVaultAddress();
        uint256 strategyDepositExpiry = getStrategyDepositExpiry();

        console.log("AlephAVS address:", alephAVSAddress);
        console.log("Aleph vault address:", alephVaultAddress);
        console.log("Strategy deposit expiry:", strategyDepositExpiry);

        // Verify vault is initialized
        AlephAVS alephAVS = AlephAVS(alephAVSAddress);
        IStrategy slashedStrategy = alephAVS.vaultToSlashedStrategy(alephVaultAddress);

        if (address(slashedStrategy) == address(0)) {
            revert("Vault has not been initialized. Please initialize the vault first.");
        }

        // Get vault token and original strategy from storage
        IAlephVault vault = IAlephVault(alephVaultAddress);
        IERC20 vaultToken = IERC20(vault.underlyingToken());
        IStrategy originalStrategy = alephAVS.vaultToOriginalStrategy(alephVaultAddress);

        if (address(originalStrategy) == address(0)) {
            revert("Vault has not been initialized. Please initialize the vault first.");
        }

        console.log("Original strategy:", address(originalStrategy));
        console.log("Vault token:", address(vaultToken));

        // Check pending unallocation status using the new view function
        (uint256 userPendingAmount, uint256 totalPendingAmount, uint256 redeemableAmount, bool canComplete) =
            alephAVS.getPendingUnallocateStatus(tokenHolder, alephVaultAddress);

        console.log("\n=== Pending Unallocation Status ===");
        console.log("User pending amount:", userPendingAmount);
        console.log("Total pending amount:", totalPendingAmount);
        console.log("Vault redeemable amount:", redeemableAmount);
        console.log("Can complete unallocation:", canComplete);

        if (!canComplete) {
            if (userPendingAmount == 0) {
                revert("No pending unallocation found. Please call requestUnallocate first.");
            }
            if (redeemableAmount == 0) {
                console.log("\n[WARNING] Vault has no redeemable amount yet.");
                console.log("Please wait for the vault to process the redemption request.");
                revert("Vault has no redeemable amount. Wait for redemption to be processed.");
            }
        }

        // Calculate expected amount that will be withdrawn (for signature generation)
        uint256 expectedAmount = alephAVS.calculateCompleteUnallocateAmount(tokenHolder, alephVaultAddress);
        console.log("\n=== Expected Amount ===");
        console.log("Expected amount to withdraw:", expectedAmount);

        if (expectedAmount == 0) {
            revert("Expected amount is zero. Cannot generate signature.");
        }

        // Use the expected amount for the signature
        uint256 signatureAmount = expectedAmount;

        // Generate strategy deposit signature
        address strategyManagerAddress = address(alephAVS.STRATEGY_MANAGER());
        StrategyManagerStorage strategyManager = StrategyManagerStorage(strategyManagerAddress);
        uint256 nonce = strategyManager.nonces(tokenHolder);

        console.log("\n=== Generating Strategy Deposit Signature ===");
        console.log("Staker (token holder):", tokenHolder);
        console.log("Strategy:", address(originalStrategy));
        console.log("Token:", address(vaultToken));
        console.log("Amount (max for signature):", signatureAmount);
        console.log("Nonce:", nonce);
        console.log("Expiry:", strategyDepositExpiry);

        bytes memory strategyDepositSignature = generateStrategyDepositSignature(
            strategyManager,
            tokenHolder,
            originalStrategy,
            IERC20Eigen(address(vaultToken)),
            signatureAmount,
            nonce,
            strategyDepositExpiry,
            privateKey
        );

        console.log("Signature generated [OK]");

        // Execute complete unallocate
        vm.startBroadcast(privateKey);

        console.log("\n=== Completing Unallocation ===");
        console.log("Calling AlephAVS.completeUnallocate...");

        (uint256 amount, uint256 shares) =
            alephAVS.completeUnallocate(alephVaultAddress, strategyDepositExpiry, strategyDepositSignature);

        vm.stopBroadcast();

        console.log("\n=== Unallocation Complete ===");
        console.log("Amount redeemed and deposited:", amount);
        console.log("Shares received in strategy:", shares);
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

    function getStrategyDepositExpiry() internal view returns (uint256) {
        try vm.envUint("STRATEGY_DEPOSIT_EXPIRY") returns (uint256 expiry) {
            return expiry;
        } catch {
            console.log("STRATEGY_DEPOSIT_EXPIRY not found, using max uint256");
            return type(uint256).max;
        }
    }

    function generateStrategyDepositSignature(
        IStrategyManager strategyManager,
        address staker,
        IStrategy strategy,
        IERC20Eigen token,
        uint256 amount,
        uint256 nonce,
        uint256 expiry,
        uint256 signerPrivateKey
    ) internal view returns (bytes memory) {
        // Calculate the digest hash using StrategyManager's function
        bytes32 digestHash =
            strategyManager.calculateStrategyDepositDigestHash(staker, strategy, token, amount, nonce, expiry);

        // Sign the digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digestHash);

        bytes memory signature = abi.encodePacked(r, s, v);

        console.log("\n=== Signature Details ===");
        console.log("Digest hash:", vm.toString(digestHash));
        console.log("Signature (r, s, v):");
        console.log("  r:", vm.toString(r));
        console.log("  s:", vm.toString(s));
        console.log("  v:", v);

        return signature;
    }
}
