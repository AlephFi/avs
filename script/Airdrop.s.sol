// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IDisperse {
    function disperseToken(IERC20 token, address[] calldata recipients, uint256[] calldata amounts) external;

    function disperseTokenSimple(IERC20 token, address[] calldata recipients, uint256[] calldata amounts) external;
}

contract Airdrop is Script {
    // Multisender contract on mainnet (disperse.app style)
    address constant DISPERSE_APP = 0xD152f549545093347A162Dce210e7293f1452150;

    // Batch size to avoid gas limits
    uint256 constant BATCH_SIZE = 100;

    function run() external {
        // Load configuration from environment
        address tokenAddress = vm.envAddress("AIRDROP_TOKEN_ADDRESS");
        // CSV must be pre-processed: run `npm run airdrop:prepare <input.csv> <decimals>`
        string memory csvPath = vm.envOr("CSV_PATH", string("airdrop_prepared.csv"));
        bool dryRun = vm.envOr("DRY_RUN", true);
        address disperseAddress = vm.envOr("DISPERSE_ADDRESS", DISPERSE_APP);

        console.log("==============================================");
        console.log("           TOKEN AIRDROP SCRIPT");
        console.log("==============================================");
        console.log("");
        // Get token info
        IERC20Metadata tokenMeta = IERC20Metadata(tokenAddress);
        uint8 decimals = tokenMeta.decimals();
        string memory symbol = tokenMeta.symbol();

        console.log("Token:", tokenAddress);
        console.log("Symbol:", symbol);
        console.log("Decimals:", decimals);
        console.log("CSV:", csvPath);
        console.log("Disperse:", disperseAddress);
        console.log("Dry Run:", dryRun);
        console.log("");

        // Load CSV data (pre-processed with scaled integer amounts)
        (address[] memory recipients, uint256[] memory amounts) = loadCSV(csvPath);

        console.log("Loaded", recipients.length, "recipients");

        // Calculate total amount
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }
        console.log("Total amount:", totalAmount);

        if (dryRun) {
            console.log("");
            console.log("==============================================");
            console.log("  DRY RUN - No transactions will be sent");
            console.log("  Set DRY_RUN=false to execute");
            console.log("==============================================");

            // Show sample
            console.log("");
            console.log("Sample recipients (first 5):");
            for (uint256 i = 0; i < 5 && i < recipients.length; i++) {
                console.log("  ", recipients[i], amounts[i]);
            }

            // Estimate batches
            uint256 estimatedBatches = (recipients.length + BATCH_SIZE - 1) / BATCH_SIZE;
            console.log("");
            console.log("Will create batches:", estimatedBatches);

            return;
        }

        // Execute airdrop
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        IERC20 token = IERC20(tokenAddress);

        // Approve disperse contract
        uint256 currentAllowance = token.allowance(msg.sender, disperseAddress);
        if (currentAllowance < totalAmount) {
            console.log("Approving token...");
            token.approve(disperseAddress, totalAmount);
        }

        // Send in batches
        IDisperse disperse = IDisperse(disperseAddress);
        uint256 numBatches = (recipients.length + BATCH_SIZE - 1) / BATCH_SIZE;

        for (uint256 batch = 0; batch < numBatches; batch++) {
            uint256 start = batch * BATCH_SIZE;
            uint256 end = start + BATCH_SIZE;
            if (end > recipients.length) {
                end = recipients.length;
            }

            uint256 batchSize = end - start;
            address[] memory batchRecipients = new address[](batchSize);
            uint256[] memory batchAmounts = new uint256[](batchSize);

            for (uint256 i = 0; i < batchSize; i++) {
                batchRecipients[i] = recipients[start + i];
                batchAmounts[i] = amounts[start + i];
            }

            console.log("Sending batch", batch + 1, "/", numBatches);
            disperse.disperseTokenSimple(token, batchRecipients, batchAmounts);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("Airdrop complete!");
    }

    /// @notice Load CSV with pre-processed integer amounts
    /// @dev CSV format: address,amount (amount is pre-scaled integer)
    /// @dev Use scripts/prepare_airdrop_csv.py to prepare the CSV
    function loadCSV(string memory path) internal view returns (address[] memory, uint256[] memory) {
        string memory csv = vm.readFile(path);
        string[] memory lines = vm.split(csv, "\n");

        // Count valid lines
        uint256 count = 0;
        for (uint256 i = 0; i < lines.length; i++) {
            if (bytes(lines[i]).length > 0) {
                count++;
            }
        }

        address[] memory recipients = new address[](count);
        uint256[] memory amounts = new uint256[](count);

        uint256 idx = 0;
        for (uint256 i = 0; i < lines.length; i++) {
            if (bytes(lines[i]).length == 0) continue;

            string[] memory parts = vm.split(lines[i], ",");
            if (parts.length >= 2) {
                uint256 amount = vm.parseUint(parts[1]);
                if (amount > 0) {
                    recipients[idx] = vm.parseAddress(parts[0]);
                    amounts[idx] = amount;
                    idx++;
                }
            }
        }

        // Trim arrays to actual size
        assembly {
            mstore(recipients, idx)
            mstore(amounts, idx)
        }

        return (recipients, amounts);
    }
}
