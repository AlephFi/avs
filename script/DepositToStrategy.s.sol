// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/AlephAVS.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IStrategyFactory} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyFactory.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20 as IERC20Eigen} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAlephVault} from "Aleph/src/interfaces/IAlephVault.sol";

/**
 * @title DepositToStrategy
 * @notice Script for restakers to deposit tokens into EigenLayer strategies
 * @dev This script allows restakers to deposit ERC20 tokens into an EigenLayer strategy
 *      to receive deposit shares. These shares can then be delegated to operators.
 *
 * @dev Usage:
 *   1. Set up .env file with:
 *      - PRIVATE_KEY (required - restaker's private key)
 *      - RPC_URL (or pass via --rpc-url flag)
 *      - ALEPH_AVS_ADDRESS (deployed AlephAVS contract address, or will load from deployments)
 *      - STRATEGY_ADDRESS (optional - address of the strategy to deposit into)
 *      - ALEPH_VAULT_ADDRESS (optional - if STRATEGY_ADDRESS is not set, will get strategy from vault via AlephAVS)
 *      - DEPOSIT_AMOUNT (optional - amount in wei to deposit, e.g., "100000000000000000000" for 100 tokens.
 *                        If not set, will deposit the full wallet balance)
 *
 *      Note: Token address is automatically retrieved from the strategy's underlyingToken() function.
 *
 *   2. Run: forge script script/DepositToStrategy.s.sol:DepositToStrategy --rpc-url $RPC_URL --broadcast
 *
 *   Note: If STRATEGY_ADDRESS is not set, the script will try to get it from ALEPH_VAULT_ADDRESS
 *         by querying the AlephAVS contract to find the strategy associated with the vault.
 */
contract DepositToStrategy is Script {
    using SafeERC20 for IERC20;

    function run() external {
        // Get restaker private key
        uint256 restakerPrivateKey = getRestakerPrivateKey();
        address restaker = vm.addr(restakerPrivateKey);

        console.log("=== Deposit to EigenLayer Strategy ===");
        console.log("Restaker address:", restaker);

        // Load configuration
        address alephAVSAddress = getAlephAVSAddress();
        address strategyAddress = getStrategyAddress();

        console.log("AlephAVS address:", alephAVSAddress);
        console.log("Strategy address:", strategyAddress);

        // Get StrategyManager from AlephAVS
        AlephAVS alephAVS = AlephAVS(alephAVSAddress);
        IStrategyManager strategyManager = IStrategyManager(alephAVS.STRATEGY_MANAGER());

        console.log("StrategyManager address:", address(strategyManager));

        // Get strategy and token from strategy
        IStrategy strategy = IStrategy(strategyAddress);
        address tokenAddress = address(strategy.underlyingToken());
        console.log("Token address (from strategy):", tokenAddress);

        // Verify token and strategy
        IERC20 token = IERC20(tokenAddress);
        IERC20Eigen tokenEigen = IERC20Eigen(tokenAddress);

        // Check token balance
        uint256 balance = token.balanceOf(restaker);
        console.log("Restaker token balance:", balance);

        // Get deposit amount (use env var if set, otherwise use full balance)
        uint256 amount = getDepositAmount(balance);
        console.log("Deposit amount (wei):", amount);

        if (balance < amount) {
            revert("Insufficient token balance. Please ensure you have enough tokens to deposit.");
        }

        if (amount == 0) {
            revert("Deposit amount is zero. Please ensure you have tokens to deposit or set DEPOSIT_AMOUNT in .env");
        }

        // Check token allowance
        uint256 allowance = token.allowance(restaker, address(strategyManager));
        console.log("Current allowance:", allowance);

        vm.startBroadcast(restakerPrivateKey);

        // Approve StrategyManager to spend tokens if needed
        if (allowance < amount) {
            console.log("\n=== Approving StrategyManager ===");
            console.log("Approving", amount, "tokens...");
            // Use forceApprove to set allowance (works even if current allowance > 0)
            SafeERC20.forceApprove(token, address(strategyManager), amount);
            console.log("[OK] Approval successful");
        } else {
            console.log("\n=== Token allowance sufficient [OK] ===");
        }

        // Deposit tokens into strategy
        console.log("\n=== Depositing to Strategy ===");
        console.log("Depositing", amount, "tokens into strategy...");

        uint256 shares = strategyManager.depositIntoStrategy(strategy, tokenEigen, amount);

        vm.stopBroadcast();

        console.log("\n=== Deposit Complete ===");
        console.log("Successfully deposited", amount, "tokens");
        console.log("Received", shares, "strategy shares");
        console.log("\nNext steps:");
        console.log("  1. Delegate your shares to an operator using DelegationManager.delegateTo()");
        console.log("  2. Or use the EigenLayer frontend/CLI tools to delegate");
    }

    function getRestakerPrivateKey() internal view returns (uint256) {
        // Try STRATEGY_DEPOSIT_SIGNER_PRIVATE_KEY first if available
        try vm.envString("STRATEGY_DEPOSIT_SIGNER_PRIVATE_KEY") returns (string memory privateKeyStr) {
            uint256 privateKey = vm.parseUint(privateKeyStr);
            console.log("Using STRATEGY_DEPOSIT_SIGNER_PRIVATE_KEY from .env file");
            return privateKey;
        } catch {
            // Fall back to PRIVATE_KEY
            try vm.envString("PRIVATE_KEY") returns (string memory privateKeyStr) {
                uint256 privateKey = vm.parseUint(privateKeyStr);
                console.log("Using PRIVATE_KEY from .env file");
                return privateKey;
            } catch {
                revert(
                    "PRIVATE_KEY or STRATEGY_DEPOSIT_SIGNER_PRIVATE_KEY not found in .env file. Please set one of them to the restaker's private key."
                );
            }
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
                address addr = vm.parseJsonAddress(json, ".alephAVSAddress");
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

    function getStrategyAddress() internal view returns (address) {
        // Try to get from env var first
        try vm.envAddress("STRATEGY_ADDRESS") returns (address addr) {
            return addr;
        } catch {
            // Try to get from vault address via AlephAVS
            bool strategyFound = false;
            address strategyAddress;

            try vm.envAddress("ALEPH_VAULT_ADDRESS") returns (address vaultAddress) {
                address alephAVSAddress = getAlephAVSAddress();
                AlephAVS alephAVS = AlephAVS(alephAVSAddress);

                // Get vault and underlying token
                // Check if vault is a contract first - if not, skip this option
                if (vaultAddress.code.length > 0) {
                    try IAlephVault(vaultAddress).underlyingToken() returns (address underlyingToken) {
                        if (underlyingToken != address(0)) {
                            // Get strategy from AlephAVS using vaultToOriginalStrategy
                            IStrategy strategy = alephAVS.vaultToOriginalStrategy(vaultAddress);

                            if (address(strategy) != address(0)) {
                                console.log("Loaded strategy address from vault via AlephAVS");
                                console.log("Vault address:", vaultAddress);
                                console.log("Underlying token:", underlyingToken);
                                strategyFound = true;
                                strategyAddress = address(strategy);
                            } else {
                                console.log(
                                    "Vault has not been initialized. Please initialize the vault first using InitializeVault.s.sol"
                                );
                            }
                        }
                    } catch {}
                }
            } catch {}

            if (strategyFound) {
                return strategyAddress;
            }

            // Fall through to deployment.json option
            // Try to load from deployments file
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
                                    ". Please set STRATEGY_ADDRESS in .env or update config/deployment.json"
                                )
                            );
                        }
                        console.log("Loaded strategy address from deployment.json");
                        return addr;
                    } catch {
                        // Strategy field doesn't exist or is invalid
                        revert(
                            string.concat(
                                "Strategy address not found in deployment.json for chain ID ",
                                chainIdStr,
                                ". Please set STRATEGY_ADDRESS or ALEPH_VAULT_ADDRESS in .env, or add 'strategy' field to config/deployment.json for this chain ID"
                            )
                        );
                    }
                } catch {
                    revert(
                        string.concat(
                            "Chain ID ",
                            chainIdStr,
                            " not found in deployment.json. Please set STRATEGY_ADDRESS or ALEPH_VAULT_ADDRESS in .env, or add chain configuration to config/deployment.json"
                        )
                    );
                }
            } catch {
                revert(
                    "STRATEGY_ADDRESS not found. Please set STRATEGY_ADDRESS or ALEPH_VAULT_ADDRESS in .env, or add it to config/deployment.json"
                );
            }
        }
    }

    function getDepositAmount(uint256 walletBalance) internal view returns (uint256) {
        try vm.envUint("DEPOSIT_AMOUNT") returns (uint256 amount) {
            return amount;
        } catch {
            // If DEPOSIT_AMOUNT not set, use full wallet balance
            console.log("DEPOSIT_AMOUNT not found, using full wallet balance");
            return walletBalance;
        }
    }
}

