// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/AlephAVS.sol";
import {AuthLibrary} from "Aleph/src/libraries/AuthLibrary.sol";
import {IAlephVaultDeposit} from "Aleph/src/interfaces/IAlephVaultDeposit.sol";
import {IAlephVault} from "Aleph/src/interfaces/IAlephVault.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";
import {AlephUtils} from "../src/libraries/AlephUtils.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20 as IERC20Eigen} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title AllocateToAlephVault
 * @notice Script for operators to allocate their delegated stake to Aleph vaults
 * @dev Usage:
 *   1. Set up .env file with:
 *      - PRIVATE_KEY (required - operator's private key, must be a registered EigenLayer operator)
 *      - RPC_URL (or pass via --rpc-url flag)
 *      - ALEPH_AVS_ADDRESS (deployed AlephAVS contract address)
 *      - ALEPH_VAULT_ADDRESS (target Aleph vault address that has been initialized)
 *      - ALLOCATE_AMOUNT (amount in underlying tokens, e.g., "100000000000000000000" for 100 tokens)
 *      - CLASS_ID (share class ID, default: 0)
 *      - EXPIRY_BLOCK (expiry block for auth signature, default: max uint256)
 *      - AUTH_SIGNER_SIG (required - pre-generated auth signature, use GenerateAuthSignature.s.sol to generate)
 *
 *   2. Run: forge script script/AllocateToAlephVault.s.sol:AllocateToAlephVault --rpc-url $RPC_URL --broadcast
 */
contract AllocateToAlephVault is Script {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    function run() external {
        // Get operator private key
        uint256 operatorPrivateKey = getOperatorPrivateKey();
        address operator = vm.addr(operatorPrivateKey);

        console.log("Operator address:", operator);

        // Load configuration
        address alephAVSAddress = getAlephAVSAddress();
        address alephVaultAddress = getAlephVaultAddress();
        uint256 amount = getAmount();
        uint8 classId = getClassId();
        uint256 expiryBlock = getExpiryBlock();

        console.log("AlephAVS address:", alephAVSAddress);
        console.log("Aleph vault address:", alephVaultAddress);
        console.log("Amount (wei):", amount);
        console.log("Class ID:", classId);
        console.log("Expiry block:", expiryBlock);

        // Verify operator is registered
        AlephAVS alephAVS = AlephAVS(alephAVSAddress);
        IDelegationManager delegationManager = IDelegationManager(alephAVS.DELEGATION_MANAGER());
        IAllocationManager allocationManager = IAllocationManager(alephAVS.ALLOCATION_MANAGER());
        IRewardsCoordinator rewardsCoordinator = IRewardsCoordinator(alephAVS.REWARDS_COORDINATOR());

        if (!delegationManager.isOperator(operator)) {
            revert("Address is not a registered EigenLayer operator. Please register as an operator first.");
        }
        console.log("Operator is registered [OK]");

        // Check if operator has allocated stake to the operator set
        IAlephVault vault = IAlephVault(alephVaultAddress);
        IERC20 underlyingToken = IERC20(vault.underlyingToken());
        IStrategy lstStrategy = alephAVS.vaultToOriginalStrategy(alephVaultAddress);

        if (address(lstStrategy) == address(0)) {
            revert("Vault has not been initialized. Please initialize the vault first using InitializeVault.s.sol");
        }

        OperatorSet memory lstOperatorSet =
            OperatorSet({avs: alephAVSAddress, id: AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID});

        // Check allocated stake
        address[] memory operators = new address[](1);
        operators[0] = operator;
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = lstStrategy;
        uint256[][] memory allocatedStakes = allocationManager.getAllocatedStake(lstOperatorSet, operators, strategies);
        uint256 allocatedShares = allocatedStakes[0][0];

        // Check allocation magnitude
        IAllocationManagerTypes.Allocation memory allocation =
            allocationManager.getAllocation(operator, lstOperatorSet, lstStrategy);
        uint64 currentMagnitude = allocation.currentMagnitude;
        uint32 effectBlock = allocation.effectBlock;

        // The allocate() function requires allocatedShares > 0, not just currentMagnitude > 0
        // allocatedShares can be 0 even if currentMagnitude > 0 if the allocation delay hasn't passed
        if (allocatedShares == 0) {
            console.log("\n[ERROR] Operator has no allocated shares to AlephAVS operator sets.");
            console.log("  Current allocated shares:", allocatedShares);
            console.log("  Current magnitude:", currentMagnitude);
            console.log("  Effect block:", effectBlock);
            console.log("  Current block:", block.number);

            if (currentMagnitude > 0 && effectBlock > block.number) {
                console.log("\n[INFO] Operator has a pending allocation that hasn't taken effect yet.");
                console.log("  Blocks remaining:", effectBlock - block.number);
                console.log("\nPlease wait for the allocation delay to pass before running this script.");
                revert("Allocation delay has not passed. Wait for the allocation to take effect.");
            } else if (currentMagnitude == 0) {
                console.log("\nPlease run OnboardOperator.s.sol first to allocate stake to operator sets.");
                revert("Operator has not allocated stake to AlephAVS operator sets. Run OnboardOperator.s.sol first.");
            } else {
                console.log("\n[WARNING] Allocation may have been set but shares are not yet available.");
                console.log("Please wait a few blocks and try again, or run OnboardOperator.s.sol to re-allocate.");
                revert("Operator has no allocated shares available. Wait for allocation to take effect.");
            }
        }

        console.log("Operator has allocated stake [OK]");
        console.log("  Allocated shares:", allocatedShares);
        console.log("  Current magnitude:", currentMagnitude);

        // Get or generate auth signature
        // Note: msg.sender in the vault will be AlephAVS, not the operator
        AuthLibrary.AuthSignature memory authSig =
            getAuthSignature(alephAVSAddress, alephVaultAddress, classId, expiryBlock);

        // Prepare RequestDepositParams
        IAlephVaultDeposit.RequestDepositParams memory requestDepositParams =
            IAlephVaultDeposit.RequestDepositParams({classId: classId, amount: amount, authSignature: authSig});

        // Execute allocation
        vm.startBroadcast(operatorPrivateKey);

        console.log("\n=== Allocating to Aleph Vault ===");
        console.log("Calling AlephAVS.allocate...");

        alephAVS.allocate(alephVaultAddress, requestDepositParams);

        vm.stopBroadcast();

        console.log("\n=== Allocation Complete ===");
        console.log("Successfully allocated", amount, "tokens to Aleph vault");
    }

    function getOperatorPrivateKey() internal view returns (uint256) {
        try vm.envString("PRIVATE_KEY") returns (string memory privateKeyStr) {
            uint256 privateKey = vm.parseUint(privateKeyStr);
            console.log("Using PRIVATE_KEY from .env file");
            return privateKey;
        } catch {
            revert("PRIVATE_KEY not found in .env file. Please set PRIVATE_KEY to the operator's private key.");
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

    function getAmount() internal view returns (uint256) {
        try vm.envUint("ALLOCATE_AMOUNT") returns (uint256 amount) {
            return amount;
        } catch {
            revert("ALLOCATE_AMOUNT not found in .env file. Please set ALLOCATE_AMOUNT (in wei).");
        }
    }

    function getClassId() internal view returns (uint8) {
        try vm.envUint("CLASS_ID") returns (uint256 classId) {
            require(classId <= type(uint8).max, "CLASS_ID too large");
            // casting to 'uint8' is safe because we check classId <= type(uint8).max above
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint8(classId);
        } catch {
            console.log("CLASS_ID not found, using default: 0");
            return 0;
        }
    }

    function getExpiryBlock() internal view returns (uint256) {
        try vm.envUint("EXPIRY_BLOCK") returns (uint256 expiry) {
            return expiry;
        } catch {
            console.log("EXPIRY_BLOCK not found, using max uint256");
            return type(uint256).max;
        }
    }

    function getAuthSignature(address alephAVSAddress, address alephVaultAddress, uint8 classId, uint256 expiryBlock)
        internal
        view
        returns (AuthLibrary.AuthSignature memory)
    {
        // First try to get pre-generated signature from AUTH_SIGNER_SIG
        try vm.envString("AUTH_SIGNER_SIG") returns (string memory sigHex) {
            console.log("Using pre-generated AUTH_SIGNER_SIG from .env file");
            bytes memory signature = vm.parseBytes(sigHex);

            // Get expiry block (use from env or parameter)
            uint256 sigExpiryBlock = expiryBlock;
            try vm.envUint("EXPIRY_BLOCK") returns (uint256 envExpiry) {
                sigExpiryBlock = envExpiry;
            } catch {}

            return AuthLibrary.AuthSignature({authSignature: signature, expiryBlock: sigExpiryBlock});
        } catch {
            // Fallback to generating from private key (for backward compatibility)
            try vm.envString("AUTH_SIGNER_PRIVATE_KEY") returns (string memory signerKeyStr) {
                uint256 signerPrivateKey = vm.parseUint(signerKeyStr);
                console.log("Generating auth signature from AUTH_SIGNER_PRIVATE_KEY (fallback)");
                return generateAuthSignature(alephAVSAddress, alephVaultAddress, classId, expiryBlock, signerPrivateKey);
            } catch {
                revert(
                    "AUTH_SIGNER_SIG is required. Please set AUTH_SIGNER_SIG in your .env file. "
                    "Use GenerateAuthSignature.s.sol to generate the signature."
                );
            }
        }
    }

    function generateAuthSignature(
        address msgSenderAddress,
        address alephVaultAddress,
        uint8 classId,
        uint256 expiryBlock,
        uint256 signerPrivateKey
    ) internal view returns (AuthLibrary.AuthSignature memory) {
        // The auth signature is verified by the vault using verifyDepositRequestAuthSignature:
        // keccak256(abi.encode(msg.sender, address(this), block.chainid, _classId, _authSignature.expiryBlock))
        // where msg.sender is the AlephAVS contract (since it calls syncDeposit directly)
        // and address(this) is the vault address

        bytes32 messageHash =
            keccak256(abi.encode(msgSenderAddress, alephVaultAddress, block.chainid, classId, expiryBlock));

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedMessageHash);

        bytes memory signature = abi.encodePacked(r, s, v);

        console.log("Generated auth signature for:");
        console.log("  msg.sender (AlephAVS):", msgSenderAddress);
        console.log("  Vault:", alephVaultAddress);
        console.log("  Chain ID:", block.chainid);
        console.log("  Class ID:", classId);
        console.log("  Expiry Block:", expiryBlock);

        return AuthLibrary.AuthSignature({authSignature: signature, expiryBlock: expiryBlock});
    }
}

