// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AuthLibrary} from "Aleph/src/libraries/AuthLibrary.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title GenerateAuthSignature
 * @notice Script to generate auth signature for Aleph vault deposits
 * @dev Usage:
 *   1. Set up .env file with:
 *      - AUTH_SIGNER_PRIVATE_KEY (required - auth signer's private key)
 *      - ALEPH_AVS_ADDRESS (deployed AlephAVS contract address)
 *      - ALEPH_VAULT_ADDRESS (target Aleph vault address)
 *      - CLASS_ID (share class ID, default: 0)
 *      - EXPIRY_BLOCK (expiry block for auth signature, default: max uint256)
 *      - CHAIN_ID (chain ID, optional - will use block.chainid if not set)
 *
 *   2. Run: forge script script/GenerateAuthSignature.s.sol:GenerateAuthSignature --rpc-url $RPC_URL
 *
 *   3. Copy the generated AUTH_SIGNER_SIG and set it in your .env file for use with AllocateToAlephVault.s.sol
 */
contract GenerateAuthSignature is Script {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    function run() external view {
        // Get auth signer private key
        uint256 signerPrivateKey = getAuthSignerPrivateKey();
        address signerAddress = vm.addr(signerPrivateKey);

        console.log("Auth Signer Address:", signerAddress);

        // Load configuration
        address alephAVSAddress = getAlephAVSAddress();
        address alephVaultAddress = getAlephVaultAddress();
        uint8 classId = getClassId();
        uint256 expiryBlock = getExpiryBlock();
        uint256 chainId = getChainId();

        console.log("\n=== Configuration ===");
        console.log("AlephAVS address:", alephAVSAddress);
        console.log("Aleph vault address:", alephVaultAddress);
        console.log("Class ID:", classId);
        console.log("Expiry block:", expiryBlock);
        console.log("Chain ID:", chainId);

        // Generate signature
        AuthLibrary.AuthSignature memory authSig =
            generateAuthSignature(alephAVSAddress, alephVaultAddress, classId, expiryBlock, chainId, signerPrivateKey);

        // Output the signature in hex format
        console.log("\n=== Generated Auth Signature ===");
        console.log("AUTH_SIGNER_SIG:", vm.toString(authSig.authSignature));
        console.log("EXPIRY_BLOCK:", expiryBlock);
        console.log("\n=== Add to .env file ===");
        console.log("AUTH_SIGNER_SIG=", vm.toString(authSig.authSignature));
        console.log("EXPIRY_BLOCK=", expiryBlock);
    }

    function getAuthSignerPrivateKey() internal view returns (uint256) {
        try vm.envString("AUTH_SIGNER_PRIVATE_KEY") returns (string memory privateKeyStr) {
            uint256 privateKey = vm.parseUint(privateKeyStr);
            console.log("Using AUTH_SIGNER_PRIVATE_KEY from .env file");
            return privateKey;
        } catch {
            revert("AUTH_SIGNER_PRIVATE_KEY not found in .env file. Please set AUTH_SIGNER_PRIVATE_KEY.");
        }
    }

    function getAlephAVSAddress() internal view returns (address) {
        // Try to get from env var first
        try vm.envAddress("ALEPH_AVS_ADDRESS") returns (address addr) {
            return addr;
        } catch {
            // Try to load from deployments file
            uint256 chainId = getChainId();
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

    function getChainId() internal view returns (uint256) {
        try vm.envUint("CHAIN_ID") returns (uint256 chainId) {
            return chainId;
        } catch {
            // Fallback to block.chainid if CHAIN_ID is not set
            return block.chainid;
        }
    }

    function generateAuthSignature(
        address msgSenderAddress,
        address alephVaultAddress,
        uint8 classId,
        uint256 expiryBlock,
        uint256 chainId,
        uint256 signerPrivateKey
    ) internal view returns (AuthLibrary.AuthSignature memory) {
        // The auth signature is verified by the vault using verifyDepositRequestAuthSignature:
        // keccak256(abi.encode(msg.sender, address(this), block.chainid, _classId, _authSignature.expiryBlock))
        // where msg.sender is the AlephAVS contract (since it calls syncDeposit directly)
        // and address(this) is the vault address

        bytes32 messageHash = keccak256(abi.encode(msgSenderAddress, alephVaultAddress, chainId, classId, expiryBlock));

        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedMessageHash);

        bytes memory signature = abi.encodePacked(r, s, v);

        console.log("\n=== Signature Details ===");
        console.log("Message hash:", vm.toString(messageHash));
        console.log("Eth signed message hash:", vm.toString(ethSignedMessageHash));
        console.log("Signature (r, s, v):");
        console.log("  r:", vm.toString(r));
        console.log("  s:", vm.toString(s));
        console.log("  v:", v);

        return AuthLibrary.AuthSignature({authSignature: signature, expiryBlock: expiryBlock});
    }
}

