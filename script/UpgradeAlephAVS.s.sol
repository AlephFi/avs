// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/AlephAVS.sol";
import "../src/ERC20Factory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {AlephUtils} from "../src/libraries/AlephUtils.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IAlephVaultFactory} from "Aleph/src/interfaces/IAlephVaultFactory.sol";
import {IStrategyFactory} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyFactory.sol";
import {IERC20Factory} from "../src/interfaces/IERC20Factory.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {StorageSlot} from "openzeppelin-contracts/contracts/utils/StorageSlot.sol";

/**
 * @title UpgradeAlephAVS
 * @notice Deployment script for AlephAVS that reads configuration from JSON file and .env
 * @dev Usage:
 *   1. Set up .env file with:
 *      - PRIVATE_KEY (required for --broadcast)
 *      - RPC_URL (or pass via --rpc-url flag)
 *      - CHAIN_ID (optional - will use block.chainid if not set)
 *      - ETHERSCAN_API_KEY (optional - for contract verification)
 *   2. Run: forge script script/UpgradeAlephAVS.s.sol:UpgradeAlephAVS --rpc-url $RPC_URL --broadcast --verify
 *
 *   The script will read CHAIN_ID from .env file and match it with the corresponding configuration
 *   from config/deployment.json. If CHAIN_ID is not set in .env, it will use block.chainid.
 */
contract UpgradeAlephAVS is Script {
    struct DeploymentConfig {
        string name;
        address allocationManager;
        address delegationManager;
        address strategyManager;
        address rewardsCoordinator;
        address vaultFactory;
        address strategyFactory;
        string metadataURI;
    }

    function run() external {
        // Validate environment variables
        validateEnvVars();

        // Get chain ID from .env file or fallback to block.chainid
        uint256 chainId = getChainId();

        console.log("Using chain ID from .env or network:", chainId);
        console.log("Deploying AlephAVS to chain ID:", chainId);

        // Load configuration from JSON file
        DeploymentConfig memory config = loadConfig(chainId);

        // Log and validate configuration
        logConfig(config);
        validateConfig(config);

        // Deploy - use PRIVATE_KEY from .env if available, otherwise fall back to default behavior
        (bool hasPrivateKey, uint256 privateKey) = tryGetPrivateKey();
        if (hasPrivateKey) {
            vm.startBroadcast(privateKey);
        } else {
            // Fall back to default behavior (will use --private-key flag or other methods)
            vm.startBroadcast();
        }

        IStrategyManager strategyManager = IStrategyManager(config.strategyManager);
        IStrategyFactory strategyFactory = IStrategyFactory(config.strategyFactory);
        IRewardsCoordinator rewardsCoordinator = IRewardsCoordinator(config.rewardsCoordinator);

        // Check if implementation address is provided via environment variable
        // This allows reusing an already-deployed implementation
        address providedImplAddress;
        try vm.envAddress("ALEPH_AVS_IMPL_ADDRESS") returns (address implAddr) {
            providedImplAddress = implAddr;
            console.log("Using provided implementation address:", providedImplAddress);
        } catch {
            providedImplAddress = address(0);
        }

        // Deploy AlephAVS (only if not provided)
        AlephAVS alephAVSImpl;
        address implAddress;
        if (providedImplAddress != address(0)) {
            // Use provided implementation address
            implAddress = providedImplAddress;
            alephAVSImpl = AlephAVS(implAddress);
            console.log("Using existing implementation at:", implAddress);
        } else {
            // Deploy new implementation
            alephAVSImpl = new AlephAVS(
                IAllocationManager(config.allocationManager),
                IDelegationManager(config.delegationManager),
                strategyManager,
                rewardsCoordinator,
                IAlephVaultFactory(config.vaultFactory),
                strategyFactory
            );
            implAddress = address(alephAVSImpl);
        }

        address _proxy = getAlephAVSProxy(chainId);
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(payable(_proxy));

        // Get the ProxyAdmin address from the proxy's storage slot
        // ERC1967 admin slot: 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
        bytes32 ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        address _proxyAdmin = StorageSlot.getAddressSlot(ADMIN_SLOT).value;

        // If reading from script storage returns 0, read directly from proxy storage
        if (_proxyAdmin == address(0)) {
            bytes32 adminValue = vm.load(_proxy, ADMIN_SLOT);
            _proxyAdmin = address(uint160(uint256(adminValue)));
        }

        require(_proxyAdmin != address(0), "ProxyAdmin address is zero");

        // Get the owner of the ProxyAdmin
        ProxyAdmin proxyAdmin = ProxyAdmin(_proxyAdmin);
        address proxyAdminOwner = proxyAdmin.owner();
        address currentAccount = msg.sender;

        console.log("Proxy address:", _proxy);
        console.log("ProxyAdmin address:", _proxyAdmin);
        console.log("ProxyAdmin owner:", proxyAdminOwner);
        console.log("Current account:", currentAccount);

        // Check if owner is a Safe contract (has code)
        uint256 ownerCodeSize;
        assembly {
            ownerCodeSize := extcodesize(proxyAdminOwner)
        }
        bool isSafeContract = ownerCodeSize > 0;

        if (isSafeContract) {
            console.log("\n[INFO] ProxyAdmin owner is a Safe contract");
            console.log("  Preparing transaction data for Safe submission...");

            // Encode the upgradeAndCall transaction
            bytes memory upgradeData =
                abi.encodeWithSelector(ProxyAdmin.upgradeAndCall.selector, proxy, implAddress, "");

            console.log("\n=== Safe Transaction Data ===");
            console.log("To (ProxyAdmin):", _proxyAdmin);
            console.log("Value: 0");
            console.log("Data:", vm.toString(upgradeData));
            console.log("\n[INFO] To submit this transaction to Safe:");
            console.log("  1. Use the bash script: pnpm run upgrade");
            console.log("  2. Or manually submit via Safe UI with the data above");
            console.log("  3. The transaction will be executed by the Safe contract");

            // For Safe contracts, we need to prepare the transaction data but not execute it
            // The bash script will extract this from console logs and submit it to Safe
            // We do NOT attempt execution here to avoid simulation errors with --verify flag
            // The implementation contract is already deployed above and can be verified
            console.log("\n[INFO] Transaction data prepared. The bash script will submit this to Safe.");
            console.log("[INFO] Skipping upgrade execution (Safe contract requires multisig approval).");
            console.log("[INFO] Implementation contract deployed and ready for verification.");

            vm.stopBroadcast();
            logDeploymentInfo(alephAVSImpl);
            // Save deployment info (only if we deployed a new implementation)
            if (providedImplAddress == address(0)) {
                saveDeploymentInfo(chainId, implAddress);
            }
            return;
        }

        // If not a Safe, check ownership and proceed directly
        if (currentAccount != proxyAdminOwner) {
            console.log("\n[ERROR] Current account is not the ProxyAdmin owner!");
            console.log("  Required owner:", proxyAdminOwner);
            console.log("  Current account:", currentAccount);
            console.log("  Please use the owner's private key to execute this upgrade.");
            revert("OwnableUnauthorizedAccount: Current account is not the ProxyAdmin owner");
        }

        console.log("\n[INFO] Executing upgrade directly...");
        proxyAdmin.upgradeAndCall(proxy, implAddress, "");

        vm.stopBroadcast();

        // Log deployment information
        logDeploymentInfo(alephAVSImpl);

        // Save deployment info (only if we deployed a new implementation)
        if (providedImplAddress == address(0)) {
            saveDeploymentInfo(chainId, implAddress);
        }
    }

    /**
     * @notice Log configuration details
     * @param config The deployment configuration to log
     */
    function logConfig(DeploymentConfig memory config) internal view {
        console.log("Chain name:", config.name);
        console.log("AllocationManager:", config.allocationManager);
        console.log("DelegationManager:", config.delegationManager);
        console.log("StrategyManager:", config.strategyManager);
        console.log("RewardsCoordinator:", config.rewardsCoordinator);
        console.log("VaultFactory:", config.vaultFactory);
        console.log("StrategyFactory:", config.strategyFactory);
        console.log("Note: ERC20Factory will be deployed as part of this script");
        console.log("MetadataURI:", config.metadataURI);
    }

    /**
     * @notice Validate that all configuration addresses are non-zero
     * @param config The deployment configuration to validate
     */
    function validateConfig(DeploymentConfig memory config) internal pure {
        validateAddress(config.allocationManager, "AllocationManager");
        validateAddress(config.delegationManager, "DelegationManager");
        validateAddress(config.strategyManager, "StrategyManager");
        validateAddress(config.rewardsCoordinator, "RewardsCoordinator");
        validateAddress(config.vaultFactory, "VaultFactory");
        validateAddress(config.strategyFactory, "StrategyFactory");
    }

    /**
     * @notice Validate that an address is non-zero
     * @param addr The address to validate
     * @param name The name of the address field for error messages
     */
    function validateAddress(address addr, string memory name) internal pure {
        require(addr != address(0), string.concat(name, " address is zero"));
    }

    /**
     * @notice Log deployment information
     * @param alephAVS The deployed AlephAVS contract
     */
    function logDeploymentInfo(AlephAVS alephAVS) internal view {
        console.log("AlephAVS Implementation deployed at:", address(alephAVS));
        console.log("AllocationManager:", address(alephAVS.ALLOCATION_MANAGER()));
        console.log("DelegationManager:", address(alephAVS.DELEGATION_MANAGER()));
        console.log("StrategyManager:", address(alephAVS.STRATEGY_MANAGER()));
        console.log("RewardsCoordinator:", address(alephAVS.REWARDS_COORDINATOR()));
        console.log("VaultFactory:", address(alephAVS.VAULT_FACTORY()));
        console.log("StrategyFactory:", address(alephAVS.STRATEGY_FACTORY()));
    }

    /**
     * @notice Validate that required environment variables are set
     */
    function validateEnvVars() internal view {
        bool hasPrivateKey = envStringExists("PRIVATE_KEY");
        if (!hasPrivateKey) {
            if (!envAddressExists("DEPLOYER_ADDRESS")) {
                revert("Missing PRIVATE_KEY. Provide PRIVATE_KEY in .env or set DEPLOYER_ADDRESS.");
            }
            console.log(
                "PRIVATE_KEY not found in .env. Using DEPLOYER_ADDRESS for address prediction. Ensure forge receives the correct signer when broadcasting."
            );
        } else {
            console.log("PRIVATE_KEY found in .env file");
        }
        checkEnvVar("RPC_URL", "NOTE: RPC_URL not found in .env file. Make sure to pass --rpc-url flag");
        checkEnvVar(
            "ETHERSCAN_API_KEY",
            "NOTE: ETHERSCAN_API_KEY not found in .env file. Contract verification will require --etherscan-api-key flag"
        );
    }

    /**
     * @notice Check if an environment variable is set and log accordingly
     * @param varName The name of the environment variable to check
     * @param notFoundMessage The message to log if the variable is not found
     */
    function checkEnvVar(string memory varName, string memory notFoundMessage) internal view {
        try vm.envString(varName) returns (string memory) {
            console.log(string.concat(varName, " found in .env file"));
        } catch {
            console.log(notFoundMessage);
        }
    }

    /**
     * @notice Get private key from .env file or return 0 if not set
     * @return hasKey Whether the private key was found
     * @return privateKey The private key as uint256, or 0 if not found
     */
    function tryGetPrivateKey() internal view returns (bool hasKey, uint256 privateKey) {
        try vm.envString("PRIVATE_KEY") returns (string memory privateKeyStr) {
            privateKey = vm.parseUint(privateKeyStr);
            hasKey = true;
        } catch {
            hasKey = false;
            privateKey = 0;
        }
    }

    function getDeployerAddress(uint256 privateKey) internal view returns (address) {
        if (privateKey != 0) {
            return vm.addr(privateKey);
        }

        try vm.envAddress("DEPLOYER_ADDRESS") returns (address envAddress) {
            return envAddress;
        } catch {
            revert("Set PRIVATE_KEY or DEPLOYER_ADDRESS to determine the deployer address");
        }
    }

    function getOwnerAddress(address defaultOwner) internal view returns (address owner) {
        try vm.envAddress("ALEPH_OWNER_ADDRESS") returns (address envOwner) {
            owner = envOwner;
        } catch {
            owner = defaultOwner;
        }
    }

    /**
     * @notice Get chain ID from .env file or fallback to block.chainid
     * @return chainId The chain ID to use for deployment
     */
    function getChainId() internal view returns (uint256 chainId) {
        // Try to read CHAIN_ID from .env file
        try vm.envUint("CHAIN_ID") returns (uint256 envChainId) {
            chainId = envChainId;
            console.log("CHAIN_ID read from .env file:", chainId);
        } catch {
            // Fallback to block.chainid if CHAIN_ID is not set in .env
            chainId = block.chainid;
            console.log("CHAIN_ID not found in .env, using block.chainid:", chainId);
        }
    }

    /**
     * @notice Load deployment configuration from JSON file
     * @param chainId The chain ID to get configuration for
     * @return config The deployment configuration
     */
    function loadConfig(uint256 chainId) internal view returns (DeploymentConfig memory config) {
        string memory configPath = string.concat(vm.projectRoot(), "/config/deployment.json");
        string memory jsonContent = vm.readFile(configPath);

        string memory chainIdStr = vm.toString(chainId);
        string memory jsonPath = string.concat(".", chainIdStr);

        // Check if chain ID exists in config
        if (!vm.keyExists(jsonContent, jsonPath)) {
            revert(string.concat("Configuration not found for chain ID: ", chainIdStr));
        }

        // Parse JSON - parseJson returns bytes, need to extract values directly
        config.name = vm.parseJsonString(jsonContent, string.concat(jsonPath, ".name"));
        config.allocationManager = vm.parseJsonAddress(jsonContent, string.concat(jsonPath, ".allocationManager"));
        config.delegationManager = vm.parseJsonAddress(jsonContent, string.concat(jsonPath, ".delegationManager"));
        config.strategyManager = vm.parseJsonAddress(jsonContent, string.concat(jsonPath, ".strategyManager"));
        config.rewardsCoordinator = loadAddressWithFallback(
            jsonContent, string.concat(jsonPath, ".rewardsCoordinator"), "REWARDS_COORDINATOR", "rewardsCoordinator"
        );
        config.vaultFactory = vm.parseJsonAddress(jsonContent, string.concat(jsonPath, ".vaultFactory"));
        config.strategyFactory = loadAddressWithFallback(
            jsonContent, string.concat(jsonPath, ".strategyFactory"), "STRATEGY_FACTORY", "strategyFactory"
        );
        config.metadataURI =
            loadStringWithFallback(jsonContent, string.concat(jsonPath, ".metadataURI"), "METADATA_URI", "");
    }

    /**
     * @notice Save deployment information to a file
     * @param chainId The chain ID where the contracts were deployed
     * @param alephAVSImplAddress The deployed AlephAVS implementation contract address
     */
    function saveDeploymentInfo(uint256 chainId, address alephAVSImplAddress) internal {
        string memory deploymentsDir = string.concat(vm.projectRoot(), "/deployments");
        string memory filename = string.concat(vm.toString(chainId), ".json");
        string memory deploymentPath = string.concat(deploymentsDir, "/", filename);

        // Read existing file (assuming it exists)
        string memory existingJson = vm.readFile(deploymentPath);

        // Parse existing values to preserve them
        uint256 existingChainId = vm.parseJsonUint(existingJson, ".chainId");
        address existingProxyAddress = vm.parseJsonAddress(existingJson, ".alephAVSProxyAddress");
        uint256 existingDeployedAt = vm.parseJsonUint(existingJson, ".deployedAt");
        uint256 existingDeployedBlock = vm.parseJsonUint(existingJson, ".deployedBlock");
        address existingOwner = vm.parseJsonAddress(existingJson, ".owner");

        // Create JSON with updated implementation address only
        string memory json = string.concat(
            "{\n",
            '  "chainId": ',
            vm.toString(existingChainId),
            ",\n",
            '  "alephAVSImplAddress": "',
            vm.toString(alephAVSImplAddress), // Only this field is updated
            '",\n',
            '  "alephAVSProxyAddress": "',
            vm.toString(existingProxyAddress),
            '",\n',
            '  "deployedAt": ',
            vm.toString(existingDeployedAt),
            ",\n",
            '  "deployedBlock": ',
            vm.toString(existingDeployedBlock),
            ",\n",
            '  "owner": "',
            vm.toString(existingOwner),
            "\"\n",
            "}"
        );

        vm.writeFile(deploymentPath, json);

        console.log("Updated alephAVSImplAddress in:", deploymentPath);
    }

    function getAlephAVSProxy(uint256 chainId) internal view returns (address) {
        string memory deploymentsDir = string.concat(vm.projectRoot(), "/deployments");
        string memory filename = string.concat(vm.toString(chainId), ".json");
        string memory deploymentPath = string.concat(deploymentsDir, "/", filename);
        string memory existingJson = vm.readFile(deploymentPath);
        return vm.parseJsonAddress(existingJson, ".alephAVSProxyAddress");
    }

    function loadAddressWithFallback(
        string memory jsonContent,
        string memory jsonPath,
        string memory envVar,
        string memory fieldName
    ) internal view returns (address) {
        if (vm.keyExists(jsonContent, jsonPath)) {
            return vm.parseJsonAddress(jsonContent, jsonPath);
        }

        try vm.envAddress(envVar) returns (address envValue) {
            console.log(string.concat("Using ", envVar, " from environment for ", fieldName));
            return envValue;
        } catch {
            revert(
                string.concat(
                    "Missing ",
                    fieldName,
                    " configuration. Add ",
                    jsonPath,
                    " to config/deployment.json or set ",
                    envVar,
                    " in your environment."
                )
            );
        }
    }

    function loadUintWithFallback(
        string memory jsonContent,
        string memory jsonPath,
        string memory envVar,
        uint256 defaultValue,
        bool allowDefault
    ) internal view returns (uint256) {
        if (vm.keyExists(jsonContent, jsonPath)) {
            return vm.parseJsonUint(jsonContent, jsonPath);
        }

        try vm.envUint(envVar) returns (uint256 envValue) {
            console.log(string.concat("Using ", envVar, " from environment for ", jsonPath));
            return envValue;
        } catch {
            if (allowDefault) {
                console.log(string.concat("Using default value for ", jsonPath));
                return defaultValue;
            }
            revert(
                string.concat(
                    "Missing numeric configuration for ",
                    jsonPath,
                    ". Add it to config/deployment.json or set ",
                    envVar,
                    " in your environment."
                )
            );
        }
    }

    function loadStringWithFallback(
        string memory jsonContent,
        string memory jsonPath,
        string memory envVar,
        string memory defaultValue
    ) internal view returns (string memory) {
        if (vm.keyExists(jsonContent, jsonPath)) {
            return vm.parseJsonString(jsonContent, jsonPath);
        }

        try vm.envString(envVar) returns (string memory envValue) {
            console.log(string.concat("Using ", envVar, " from environment for ", jsonPath));
            return envValue;
        } catch {
            return defaultValue;
        }
    }

    function envStringExists(string memory varName) internal view returns (bool) {
        try vm.envString(varName) returns (string memory) {
            return true;
        } catch {
            return false;
        }
    }

    function envAddressExists(string memory varName) internal view returns (bool) {
        try vm.envAddress(varName) returns (address) {
            return true;
        } catch {
            return false;
        }
    }
}

