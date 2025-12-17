// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/AlephAVS.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IStrategyFactory} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyFactory.sol";
import {IAlephVault} from "Aleph/src/interfaces/IAlephVault.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20 as IERC20Eigen} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";

/**
 * @title InitializeVault
 * @notice Script for the AlephAVS owner to initialize a vault
 * @dev Usage:
 *   1. Set up .env file with:
 *      - PRIVATE_KEY (required - owner's private key)
 *      - RPC_URL (or pass via --rpc-url flag)
 *      - ALEPH_AVS_ADDRESS (deployed AlephAVS contract address, or will load from deployments)
 *      - ALEPH_VAULT_ADDRESS (target Aleph vault address to initialize)
 *      - ALEPH_CLASS_ID (class id of the vault to initialize)
 *      - LST_STRATEGY_ADDRESS (optional - original LST strategy address, or will load from config/deployment.json)
 *
 *   2. Run: forge script script/InitializeVault.s.sol:InitializeVault --rpc-url $RPC_URL --broadcast
 */
contract InitializeVault is Script {
    function run() external {
        // Get owner private key
        uint256 ownerPrivateKey = getOwnerPrivateKey();
        address owner = vm.addr(ownerPrivateKey);

        console.log("Owner address:", owner);

        // Load configuration
        address alephAVSAddress = getAlephAVSAddress();
        address vaultAddress = getVaultAddress();
        uint8 classId = uint8(getClassId());

        console.log("AlephAVS address:", alephAVSAddress);
        console.log("Vault address:", vaultAddress);

        AlephAVS alephAVS = AlephAVS(alephAVSAddress);

        // Get vault info before initialization
        IAlephVault vault = IAlephVault(vaultAddress);
        IERC20 underlyingToken = IERC20(vault.underlyingToken());
        console.log("Vault underlying token:", address(underlyingToken));

        // Get LST strategy address
        IStrategy lstStrategy = getLstStrategy(alephAVS, address(underlyingToken));
        console.log("LST strategy:", address(lstStrategy));

        // Check if vault is already initialized
        IStrategy existingSlashedStrategy = alephAVS.vaultToSlashedStrategy(vaultAddress);
        if (address(existingSlashedStrategy) != address(0)) {
            console.log("INFO: Vault is already initialized.");
            console.log("Existing slashed strategy:", address(existingSlashedStrategy));
            console.log("Skipping initialization - vault is ready to use.");

            // If already initialized, just return the existing strategy
            console.log("\n=== Vault Already Initialized ===");
            console.log("Vault address:", vaultAddress);
            console.log("Underlying token:", address(underlyingToken));
            console.log("LST strategy:", address(lstStrategy));
            console.log("Slashed strategy:", address(existingSlashedStrategy));
            console.log("Vault is ready to use!");
            return;
        }

        // Execute initializeVault
        vm.startBroadcast(ownerPrivateKey);

        console.log("\n=== Initializing Vault ===");
        console.log("Calling initializeVault with classId:", classId);
        console.log("LST strategy (looked up):", address(lstStrategy));

        IStrategy slashedStrategy = alephAVS.initializeVault(classId, vaultAddress, lstStrategy);

        vm.stopBroadcast();

        console.log("\n=== Vault Initialization Complete ===");
        console.log("Vault address:", vaultAddress);
        console.log("Underlying token:", address(underlyingToken));
        console.log("LST strategy:", address(lstStrategy));
        console.log("Slashed strategy:", address(slashedStrategy));
        console.log("Successfully initialized vault!");
    }

    function getLstStrategy(AlephAVS alephAVS, address underlyingToken) internal view returns (IStrategy) {
        // Try to get from env var first
        try vm.envAddress("LST_STRATEGY_ADDRESS") returns (address addr) {
            console.log("Using LST_STRATEGY_ADDRESS from .env file");
            return IStrategy(addr);
        } catch {
            // Fall back to config/deployment.json
            uint256 chainId = block.chainid;
            string memory deploymentPath = string.concat(vm.projectRoot(), "/config/deployment.json");

            try vm.readFile(deploymentPath) returns (string memory json) {
                string memory chainIdStr = vm.toString(chainId);
                string memory jsonPath = string.concat(".", chainIdStr, ".strategy");

                // Check if the chain ID exists in the JSON first
                try vm.parseJson(json, string.concat(".", chainIdStr)) returns (bytes memory) {
                    // Chain ID exists, try to get strategy
                    try vm.parseJsonAddress(json, jsonPath) returns (address addr) {
                        if (addr == address(0)) {
                            revert(
                                string.concat(
                                    "Strategy address is zero in deployment.json for chain ID ",
                                    chainIdStr,
                                    ". Please set LST_STRATEGY_ADDRESS in .env or update config/deployment.json"
                                )
                            );
                        }
                        console.log("Loaded LST strategy address from config/deployment.json");
                        return IStrategy(addr);
                    } catch {
                        // Strategy field doesn't exist or is invalid
                        revert(
                            string.concat(
                                "LST_STRATEGY_ADDRESS not found. Please set LST_STRATEGY_ADDRESS in .env file, or add 'strategy' field to config/deployment.json for chain ID ",
                                chainIdStr
                            )
                        );
                    }
                } catch {
                    revert(
                        string.concat(
                            "Chain ID ",
                            chainIdStr,
                            " not found in deployment.json. Please set LST_STRATEGY_ADDRESS in .env or add chain configuration to config/deployment.json"
                        )
                    );
                }
            } catch {
                revert(
                    "LST_STRATEGY_ADDRESS not found. Please set LST_STRATEGY_ADDRESS in .env file or add it to config/deployment.json"
                );
            }
        }
    }

    function getOwnerPrivateKey() internal view returns (uint256) {
        try vm.envString("PRIVATE_KEY") returns (string memory privateKeyStr) {
            uint256 privateKey = vm.parseUint(privateKeyStr);
            console.log("Using PRIVATE_KEY from .env file");
            return privateKey;
        } catch {
            revert("PRIVATE_KEY not found in .env file. Please set PRIVATE_KEY to the owner's private key.");
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

    function getVaultAddress() internal view returns (address) {
        try vm.envAddress("ALEPH_VAULT_ADDRESS") returns (address addr) {
            return addr;
        } catch {
            revert("ALEPH_VAULT_ADDRESS not found. Please set ALEPH_VAULT_ADDRESS in .env file.");
        }
    }

    function getClassId() internal view returns (uint256) {
        try vm.envUint("ALEPH_CLASS_ID") returns (uint256 classId) {
            return classId;
        } catch {
            revert("CLASS_ID not found. Please set CLASS_ID in .env file.");
        }
    }
}

