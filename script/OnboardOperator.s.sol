// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/AlephAVS.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IAllocationManagerTypes} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";
import {AlephUtils} from "../src/libraries/AlephUtils.sol";

/**
 * @title OnboardOperator
 * @notice Comprehensive script for onboarding an operator to AlephAVS
 * @dev This script performs all necessary steps to onboard an operator:
 *      1. Ensure allocation delay is set to 0 (required for allocations)
 *         - IMPORTANT: If allocation delay is not yet initialized, the script will set it
 *           and STOP. You must wait for ALLOCATION_CONFIGURATION_DELAY (~17.5 days / 126,000 blocks
 *           on mainnet) before re-running the script to continue.
 *      2. Register as EigenLayer operator (if not already registered)
 *      3. Register for AlephAVS operator sets (if not already registered)
 *      4. Allocate stake to vault strategies (if strategies exist in operator sets)
 *      5. Set operator AVS split to 0 (100% to stakers, if not already set)
 *         - If activation delay is required, the script will STOP here
 *         - You must wait for the activation delay, then re-run the script
 *
 *      The script skips steps that have already been completed.
 *      If the operator AVS split needs activation delay, the script stops
 *      and must be re-run after the delay period.
 *
 * @dev NEW OPERATOR ONBOARDING TIMELINE:
 *      For operators who have never set an allocation delay before:
 *      - First run: Sets allocation delay, script stops
 *      - Wait ~17.5 days (ALLOCATION_CONFIGURATION_DELAY)
 *      - Second run: Completes registration and allocation
 *
 * @dev Allocation Behavior:
 *      - If operator has available (unallocated) magnitude: allocates directly to AlephAVS
 *      - If all magnitude is encumbered to other operator sets:
 *        * If operator is NOT slashable by those sets: deallocates immediately and allocates to AlephAVS in same transaction
 *        * If operator IS slashable by those sets: deallocates (queued with DEALLOCATION_DELAY) but skips allocation
 *          - Magnitude remains slashable for DEALLOCATION_DELAY blocks (typically 50 blocks = ~10 minutes on Sepolia)
 *          - After delay passes, run this script again to allocate to AlephAVS
 *          - Alternative: Deregister from the other AVS first to allow immediate deallocation
 *
 * @dev Usage:
 *   1. Set up .env file with:
 *      - PRIVATE_KEY (required - operator's private key)
 *      - RPC_URL (or pass via --rpc-url flag)
 *      - ALEPH_AVS_ADDRESS (deployed AlephAVS contract address, or will load from deployments)
 *      - METADATA_URI (optional - operator metadata URI)
 *      - DELEGATION_APPROVER (optional - delegation approver address, default: address(0))
 *
 *   2. Run: forge script script/OnboardOperator.s.sol:OnboardOperator --rpc-url $RPC_URL --broadcast
 *
 *   3. If deallocation is queued (operator is slashable by other AVS):
 *      - Wait for DEALLOCATION_DELAY blocks to pass (check logs for delay duration)
 *      - Re-run the script to complete allocation to AlephAVS
 *      - Or deregister from the other AVS first to allow immediate deallocation
 */
contract OnboardOperator is Script {
    function run() external {
        // Get operator private key
        uint256 operatorPrivateKey = getOperatorPrivateKey();
        address operator = vm.addr(operatorPrivateKey);

        console.log("=== AlephAVS Operator Onboarding ===");
        console.log("Operator address:", operator);

        // Load configuration
        address alephAVSAddress = getAlephAVSAddress();
        AlephAVS alephAVS = AlephAVS(alephAVSAddress);
        IDelegationManager delegationManager = IDelegationManager(alephAVS.DELEGATION_MANAGER());
        IAllocationManager allocationManager = IAllocationManager(alephAVS.ALLOCATION_MANAGER());
        IRewardsCoordinator rewardsCoordinator = IRewardsCoordinator(alephAVS.REWARDS_COORDINATOR());

        console.log("AlephAVS address:", alephAVSAddress);
        console.log("DelegationManager:", address(delegationManager));
        console.log("AllocationManager:", address(allocationManager));
        console.log("RewardsCoordinator:", address(rewardsCoordinator));

        vm.startBroadcast(operatorPrivateKey);

        // Track if we have queued deallocations (needed to stop script after Step 4)
        bool hasQueuedDeallocations = false;
        // Track if allocation delay was just set (need to skip Step 4 but continue to Step 5)
        bool allocationDelayJustSet = false;

        // Step 1: Ensure allocation delay is set to 0
        console.log("\n=== Step 1: Checking Allocation Delay ===");
        (bool isDelaySet, uint32 currentDelay) = allocationManager.getAllocationDelay(operator);
        console.log("Allocation delay is set:", isDelaySet);
        console.log("Current allocation delay:", currentDelay, "blocks");

        if (!isDelaySet || currentDelay != 0) {
            console.log("Setting allocation delay to 0...");
            allocationManager.setAllocationDelay(operator, 0);

            uint32 configDelay = allocationManager.ALLOCATION_CONFIGURATION_DELAY();
            uint256 effectBlock = block.number + configDelay;
            uint256 estimatedDays = (configDelay * 12) / 86400; // ~12 sec per block

            console.log("[OK] Allocation delay set to 0");
            console.log("\n=== IMPORTANT: Allocation Delay Configuration Delay ===");
            console.log("ALLOCATION_CONFIGURATION_DELAY:", configDelay, "blocks");
            console.log("Current block:", block.number);
            console.log("Effect block:", effectBlock);
            console.log("Estimated wait time:", estimatedDays, "days");
            console.log("\n[INFO] Step 4 (allocations) will be skipped - requires waiting for configuration delay.");
            console.log("After", configDelay, "blocks, re-run this script to complete allocations.");

            allocationDelayJustSet = true;
        } else {
            console.log("[OK] Allocation delay is already set to 0");
        }

        // Step 2: Register as EigenLayer operator (if not already registered)
        if (!delegationManager.isOperator(operator)) {
            console.log("\n=== Step 2: Registering as EigenLayer Operator ===");
            address delegationApprover = getDelegationApprover();
            string memory metadataURI = getMetadataURI();

            console.log("Delegation approver:", delegationApprover);
            console.log("Metadata URI:", metadataURI);

            delegationManager.registerAsOperator(delegationApprover, 0, metadataURI);
            console.log("[OK] Successfully registered as EigenLayer operator");
        } else {
            console.log("\n=== Step 2: Already registered as EigenLayer operator [OK] ===");
        }

        // Step 3: Register for AlephAVS operator sets (if not already registered)
        OperatorSet memory lstOperatorSet = OperatorSet(alephAVSAddress, AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID);

        bool isRegisteredForLST = allocationManager.isOperatorSlashable(operator, lstOperatorSet);

        if (!isRegisteredForLST) {
            console.log("\n=== Step 3: Registering for AlephAVS Operator Sets ===");

            uint32[] memory operatorSetIds = new uint32[](1);
            operatorSetIds[0] = AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID;

            IAllocationManagerTypes.RegisterParams memory registerParams = IAllocationManagerTypes.RegisterParams({
                avs: alephAVSAddress, operatorSetIds: operatorSetIds, data: ""
            });

            console.log("Registering for operator sets:");
            console.log("  - LST Strategies (ID:", AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID, ")");

            allocationManager.registerForOperatorSets(operator, registerParams);
            console.log("[OK] Successfully registered for AlephAVS operator sets");
        } else {
            console.log("\n=== Step 3: Already registered for AlephAVS operator sets [OK] ===");
        }

        // Step 4: Allocate stake to vault strategies
        // This step allocates stake to all strategies in the operator sets (LST and Slashed)
        // It doesn't require a specific vault - it allocates to all strategies in the sets
        console.log("\n=== Step 4: Allocating Stake to Vault Strategies ===");

        // Get current strategies in operator sets from AllocationManager
        // Reuse the operator sets from Step 2

        IStrategy[] memory lstStrategies = allocationManager.getStrategiesInOperatorSet(lstOperatorSet);
        bool hasPendingAllocations = false;

        if (allocationDelayJustSet) {
            console.log("[SKIP] Allocation delay was just set. Skipping allocations until configuration delay passes.");
            console.log("  Re-run this script after the delay to complete Step 4.");
        } else if (lstStrategies.length == 0) {
            console.log("[WARNING] No strategies found in operator sets. Skipping stake allocation.");
            console.log("  Strategies will be added when vaults are initialized via initializeVault().");
        } else {
            console.log("LST strategies in operator set:", lstStrategies.length);
            for (uint256 i = 0; i < lstStrategies.length; i++) {
                console.log("  LST Strategy", i, ":", address(lstStrategies[i]));
            }

            // Build allocation params, checking current allocations and available magnitude
            (IAllocationManagerTypes.AllocateParams[] memory params, bool _hasQueuedDeallocations) =
                _buildAllocationParamsWithChecks(allocationManager, operator, lstOperatorSet, lstStrategies);
            hasQueuedDeallocations = _hasQueuedDeallocations;

            if (hasQueuedDeallocations) {
                // Deallocations are queued (operator is slashable by other AVS)
                // Only perform deallocations, skip allocations (they will fail)
                // Filter params to only include deallocations (magnitude = 0)
                IAllocationManagerTypes.AllocateParams[] memory deallocationParams =
                    new IAllocationManagerTypes.AllocateParams[](params.length);
                uint256 deallocationCount = 0;

                for (uint256 i = 0; i < params.length; i++) {
                    // Check if this is a deallocation (all magnitudes are 0)
                    bool isDeallocation = true;
                    for (uint256 j = 0; j < params[i].newMagnitudes.length; j++) {
                        if (params[i].newMagnitudes[j] != 0) {
                            isDeallocation = false;
                            break;
                        }
                    }
                    if (isDeallocation) {
                        deallocationParams[deallocationCount] = params[i];
                        deallocationCount++;
                    }
                }

                // Resize array
                IAllocationManagerTypes.AllocateParams[] memory finalDeallocationParams =
                    new IAllocationManagerTypes.AllocateParams[](deallocationCount);
                for (uint256 i = 0; i < deallocationCount; i++) {
                    finalDeallocationParams[i] = deallocationParams[i];
                }

                if (finalDeallocationParams.length > 0) {
                    // Check if there's already a pending modification before trying to queue
                    bool hasPendingModification = false;
                    for (uint256 i = 0; i < finalDeallocationParams.length; i++) {
                        for (uint256 j = 0; j < finalDeallocationParams[i].strategies.length; j++) {
                            IAllocationManagerTypes.Allocation memory alloc = allocationManager.getAllocation(
                                operator,
                                finalDeallocationParams[i].operatorSet,
                                finalDeallocationParams[i].strategies[j]
                            );
                            if (alloc.effectBlock > block.number) {
                                hasPendingModification = true;
                                console.log(
                                    "\n[INFO] Deallocation already pending for strategy:",
                                    address(finalDeallocationParams[i].strategies[j])
                                );
                                console.log("  Effect block:", alloc.effectBlock);
                                console.log("  Current block:", block.number);
                                console.log("  Blocks remaining:", alloc.effectBlock - block.number);
                                break;
                            }
                        }
                        if (hasPendingModification) {
                            break;
                        }
                    }

                    if (!hasPendingModification) {
                        console.log("\n=== Queuing Deallocations (Operator is Slashable) ===");
                        console.log("Deallocation params count:", finalDeallocationParams.length);
                        console.log("\nCalling AllocationManager.modifyAllocations (deallocations only)...");
                        allocationManager.modifyAllocations(operator, finalDeallocationParams);
                        console.log("[OK] Deallocations queued successfully");
                    } else {
                        console.log("\n[INFO] Deallocation already queued from previous transaction");
                        console.log("Skipping modifyAllocations call (ModificationAlreadyPending would occur)");
                    }

                    uint32 deallocationDelay = allocationManager.DEALLOCATION_DELAY();
                    console.log("\n[WARNING] Deallocations are queued (operator is slashable by source AVS)");
                    console.log("DEALLOCATION_DELAY:", deallocationDelay, "blocks");
                    console.log("Magnitude will be freed after the delay passes.");

                    // Continue to Step 4 (setOperatorAVSSplit) before stopping
                    // Setting AVS split is independent of allocations and can be done now
                } else {
                    console.log(
                        "\n[WARNING] No deallocations to queue. Operator may need to deregister from other AVS first."
                    );
                }
            }

            // Only process allocations if we don't have queued deallocations
            // (queued deallocations are handled above and we skip allocations)
            // Note: When hasQueuedDeallocations is true, params only contains deallocation params
            // which we've already handled above, so we skip the allocation logic here
            if (!hasQueuedDeallocations) {
                if (params.length == 0) {
                    // Check if allocations have actually taken effect (allocated shares > 0)
                    bool allAllocationsActive = true;

                    console.log("\n=== Verifying Allocation Status ===");
                    address[] memory operators = new address[](1);
                    operators[0] = operator;

                    // Check LST strategies
                    for (uint256 i = 0; i < lstStrategies.length; i++) {
                        IStrategy strategy = lstStrategies[i];
                        IAllocationManagerTypes.Allocation memory alloc =
                            allocationManager.getAllocation(operator, lstOperatorSet, strategy);

                        IStrategy[] memory strategyArray = new IStrategy[](1);
                        strategyArray[0] = strategy;
                        uint256[][] memory allocatedStakes =
                            allocationManager.getAllocatedStake(lstOperatorSet, operators, strategyArray);
                        uint256 allocatedShares = allocatedStakes[0][0];

                        // Get operator's actual shares in the strategy
                        uint256[][] memory operatorSharesArray =
                            delegationManager.getOperatorsShares(operators, strategyArray);
                        uint256 operatorShares = operatorSharesArray[0][0];
                        uint64 maxMagnitude = allocationManager.getMaxMagnitude(operator, strategy);

                        console.log("  LST Strategy:", address(strategy));
                        console.log("    Current magnitude:", alloc.currentMagnitude);
                        console.log("    Max magnitude:", maxMagnitude);
                        console.log("    Operator shares:", operatorShares);
                        console.log("    Allocated shares:", allocatedShares);
                        console.log("    Effect block:", alloc.effectBlock);
                        console.log("    Current block:", block.number);

                        if (allocatedShares == 0) {
                            allAllocationsActive = false;
                            if (
                                alloc.currentMagnitude >= AlephUtils.OPERATOR_SET_MAGNITUDE
                                    && alloc.effectBlock > block.number
                            ) {
                                hasPendingAllocations = true;
                                console.log("    [WARNING] Allocation pending - waiting for delay to pass");
                                console.log("    Blocks remaining:", alloc.effectBlock - block.number);
                            }
                        }
                    }

                    if (allAllocationsActive) {
                        console.log("\n[OK] All strategies have sufficient allocation and allocated shares are active.");
                    } else if (hasPendingAllocations) {
                        console.log("\n[INFO] Allocations are set but waiting for allocation delay to pass.");
                        console.log(
                            "Please wait for the effect blocks shown above before running AllocateToAlephVault.s.sol"
                        );
                    } else {
                        console.log("\n[WARNING] Some allocations may not be active. Check the status above.");
                    }
                } else {
                    console.log("\n=== Allocation Parameters ===");
                    for (uint256 i = 0; i < params.length; i++) {
                        console.log("  Operator Set ID:", params[i].operatorSet.id);
                        console.log("  Strategies count:", params[i].strategies.length);
                        for (uint256 j = 0; j < params[i].strategies.length; j++) {
                            IAllocationManagerTypes.Allocation memory currentAlloc = allocationManager.getAllocation(
                                operator, params[i].operatorSet, params[i].strategies[j]
                            );
                            console.log("    Strategy", j, ":", address(params[i].strategies[j]));
                            console.log("      Current magnitude:", currentAlloc.currentMagnitude);
                            console.log("      New magnitude:", params[i].newMagnitudes[j]);
                        }
                    }

                    console.log("\nCalling AllocationManager.modifyAllocations...");
                    allocationManager.modifyAllocations(operator, params);
                    console.log("[OK] Successfully allocated stake to vault strategies");

                    // Check effect blocks for the allocations
                    console.log("\n=== Allocation Effect Blocks ===");
                    for (uint256 i = 0; i < params.length; i++) {
                        for (uint256 j = 0; j < params[i].strategies.length; j++) {
                            IAllocationManagerTypes.Allocation memory alloc = allocationManager.getAllocation(
                                operator, params[i].operatorSet, params[i].strategies[j]
                            );
                            console.log("  Strategy:", address(params[i].strategies[j]));
                            console.log("    Effect block:", alloc.effectBlock);
                            console.log("    Current block:", block.number);
                            if (alloc.effectBlock > block.number) {
                                hasPendingAllocations = true;
                                console.log("    Blocks remaining:", alloc.effectBlock - block.number);
                            } else {
                                console.log("    [OK] Allocation is active");
                            }
                        }
                    }
                }
            }
        }

        // Step 5: Set operator AVS split to 0 (100% to stakers)
        uint16 currentSplit = rewardsCoordinator.getOperatorAVSSplit(operator, alephAVSAddress);
        if (currentSplit != 0) {
            console.log("\n=== Step 5: Setting Operator AVS Split to 0 ===");
            console.log("Current split (bips):", uint256(currentSplit));
            console.log("Setting split to 0 (100% to stakers)...");

            // Get activation delay to inform the operator
            uint32 activationDelay = rewardsCoordinator.activationDelay();
            console.log("Activation delay:", uint256(activationDelay), "seconds");

            rewardsCoordinator.setOperatorAVSSplit(operator, alephAVSAddress, 0);
            console.log("[OK] Operator AVS split set to 0");

            if (activationDelay > 0) {
                uint256 activationTime = block.timestamp + activationDelay;
                uint256 activationDays = activationDelay / 1 days;
                console.log("\n[WARNING] Split will be activated at timestamp:", activationTime);
                console.log("         Activation delay:", uint256(activationDelay), "seconds");
                console.log("         (~", uint256(activationDays), "days)");
                console.log("\n=== Script Stopped ===");
                console.log("You must wait for the activation delay before continuing.");
                console.log("After the delay, re-run this script to complete the onboarding process.");
                console.log("The script will skip steps that are already completed.");
                vm.stopBroadcast();
                return;
            } else {
                console.log("[OK] Split is immediately active (activation delay is 0)");
            }
        } else {
            console.log("\n=== Step 5: Operator AVS split already set to 0 [OK] ===");
        }

        // If we had queued deallocations, stop here and inform user to wait
        if (hasQueuedDeallocations) {
            uint32 deallocationDelay = allocationManager.DEALLOCATION_DELAY();
            console.log("\n=== Script Stopped ===");
            console.log("You must wait for DEALLOCATION_DELAY (", deallocationDelay, "blocks) before continuing.");
            console.log("After the delay, re-run this script to complete allocation to AlephAVS.");
            console.log("The script will skip steps that are already completed.");
            vm.stopBroadcast();
            return;
        }

        // If allocation delay was just set, inform user to wait before allocations can be done
        if (allocationDelayJustSet) {
            uint32 configDelay = allocationManager.ALLOCATION_CONFIGURATION_DELAY();
            uint256 estimatedDays = (configDelay * 12) / 86400;
            console.log("\n=== Partial Onboarding Complete ===");
            console.log("Operator:", operator);
            console.log("AlephAVS:", alephAVSAddress);
            console.log("\nCompleted steps:");
            console.log("  [OK] Step 1: Allocation delay set to 0");
            console.log("  [OK] Step 2: EigenLayer operator registration");
            console.log("  [OK] Step 3: AlephAVS operator set registration");
            console.log("  [SKIP] Step 4: Stake allocation (requires waiting for configuration delay)");
            console.log("  [OK] Step 5: Operator AVS split set to 0");
            console.log("\nNext steps:");
            console.log("  1. Wait for ALLOCATION_CONFIGURATION_DELAY (~", estimatedDays, "days /", configDelay, "blocks)");
            console.log("  2. Re-run this script to complete Step 4 (stake allocation)");
            vm.stopBroadcast();
            return;
        }

        vm.stopBroadcast();

        console.log("\n=== Onboarding Complete ===");
        console.log("Operator:", operator);
        console.log("AlephAVS:", alephAVSAddress);
        console.log("\nNext steps:");
        if (hasPendingAllocations) {
            console.log("  1. Wait for allocation delay to take effect (check effect blocks above)");
            console.log("  2. Verify allocated shares are > 0 using getAllocatedStake()");
            console.log("  3. Run AllocateToAlephVault.s.sol to allocate stake to specific vaults");
        } else {
            console.log("  1. Verify allocated shares are > 0 using getAllocatedStake()");
            console.log("  2. Run AllocateToAlephVault.s.sol to allocate stake to specific vaults");
        }
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

    function getDelegationApprover() internal view returns (address) {
        try vm.envAddress("DELEGATION_APPROVER") returns (address addr) {
            return addr;
        } catch {
            console.log("DELEGATION_APPROVER not found, using default: address(0)");
            return address(0);
        }
    }

    function getMetadataURI() internal view returns (string memory) {
        try vm.envString("METADATA_URI") returns (string memory uri) {
            return uri;
        } catch {
            console.log("METADATA_URI not found, using default: empty string");
            return "";
        }
    }

    /**
     * @notice Builds AllocateParams with checks for current allocations and available magnitude
     * @param _allocationManager The AllocationManager contract
     * @param _operator The operator address
     * @param _lstOperatorSet The LST operator set
     * @param _lstStrategies The LST strategies
     * @return params Array of AllocateParams that need to be updated
     * @return hasQueuedDeallocations Whether any deallocations will be queued (operator is slashable)
     */
    function _buildAllocationParamsWithChecks(
        IAllocationManager _allocationManager,
        address _operator,
        OperatorSet memory _lstOperatorSet,
        IStrategy[] memory _lstStrategies
    ) internal view returns (IAllocationManagerTypes.AllocateParams[] memory params, bool hasQueuedDeallocations) {
        // Collect all allocation params (both allocations and deallocations)
        bool _hasQueuedDeallocations = false;
        // We use a larger array to accommodate potential deallocations from other sets
        // when reallocating magnitude from other AVSs to AlephAVS
        IStrategy[] memory allStrategies = new IStrategy[](_lstStrategies.length * 10);
        OperatorSet[] memory allOperatorSets = new OperatorSet[](_lstStrategies.length * 10);
        uint64[] memory allMagnitudes = new uint64[](_lstStrategies.length * 10);
        uint256 totalCount = 0;

        // Check LST strategies
        for (uint256 i = 0; i < _lstStrategies.length; i++) {
            IStrategy strategy = _lstStrategies[i];
            IAllocationManagerTypes.Allocation memory currentAlloc =
                _allocationManager.getAllocation(_operator, _lstOperatorSet, strategy);
            uint64 allocatableMagnitude = _allocationManager.getAllocatableMagnitude(_operator, strategy);
            uint64 targetMagnitude = AlephUtils.OPERATOR_SET_MAGNITUDE;

            uint64 maxMagnitude = _allocationManager.getMaxMagnitude(_operator, strategy);
            uint64 encumberedMagnitude = _allocationManager.getEncumberedMagnitude(_operator, strategy);

            // Check which operator sets are using the magnitude
            (OperatorSet[] memory allocatedSets, IAllocationManagerTypes.Allocation[] memory allocations) =
                _allocationManager.getStrategyAllocations(_operator, strategy);

            console.log("  LST Strategy:", address(strategy));
            console.log("    Current magnitude (AlephAVS):", currentAlloc.currentMagnitude);
            console.log("    Max magnitude:", maxMagnitude);
            console.log("    Encumbered magnitude:", encumberedMagnitude);
            console.log("    Allocatable magnitude:", allocatableMagnitude);
            console.log("    Target magnitude:", targetMagnitude);
            console.log("    Operator sets using magnitude:", allocatedSets.length);
            for (uint256 j = 0; j < allocatedSets.length; j++) {
                console.log("      Set", j);
                console.log("        AVS:", uint160(allocatedSets[j].avs));
                console.log("        ID:", allocatedSets[j].id);
                console.log("        Magnitude:", allocations[j].currentMagnitude);
            }

            // Only allocate if current is less than target
            if (currentAlloc.currentMagnitude < targetMagnitude) {
                uint64 newMagnitude = targetMagnitude;
                bool shouldAddAllocation = true;

                // If we have allocatable magnitude, use it (normal case)
                if (allocatableMagnitude > 0) {
                    // Cap by available magnitude
                    if (newMagnitude > currentAlloc.currentMagnitude + allocatableMagnitude) {
                        newMagnitude = currentAlloc.currentMagnitude + allocatableMagnitude;
                    }
                    console.log("    [OK] Will allocate to magnitude:", newMagnitude, "(using allocatable magnitude)");
                } else if (encumberedMagnitude > 0) {
                    // All magnitude is encumbered to other sets - need to deallocate from them first
                    // This handles reallocation scenarios where operator wants to move stake from other AVSs to AlephAVS
                    // Always allow deallocation if magnitude is encumbered - operator should be able to reallocate existing stake
                    console.log(
                        "    [INFO] All magnitude encumbered to other sets. Will deallocate from other sets and allocate to AlephAVS."
                    );

                    // Check if any deallocations will be queued (operator is slashable)
                    // If operator is slashable, deallocation goes into a queue and magnitude remains slashable
                    // for DEALLOCATION_DELAY blocks before being freed
                    bool strategyHasQueuedDeallocations = false;
                    uint32 deallocationDelay = _allocationManager.DEALLOCATION_DELAY();

                    // Find and deallocate from other operator sets that have magnitude
                    for (uint256 j = 0; j < allocatedSets.length; j++) {
                        // Skip AlephAVS operator sets (we want to allocate TO these, not deallocate FROM them)
                        if (allocatedSets[j].avs == _lstOperatorSet.avs && allocatedSets[j].id == _lstOperatorSet.id) {
                            continue;
                        }

                        // If this set has magnitude allocated, deallocate it (set to 0)
                        if (allocations[j].currentMagnitude > 0) {
                            // Check if operator is slashable by this set
                            // This determines whether deallocation is immediate or queued
                            bool isSlashableBySet = _allocationManager.isOperatorSlashable(_operator, allocatedSets[j]);

                            console.log("      Will deallocate magnitude:", allocations[j].currentMagnitude);
                            console.log("        From AVS:", uint160(allocatedSets[j].avs));
                            console.log("        Set ID:", allocatedSets[j].id);
                            console.log("        Operator slashable by this set:", isSlashableBySet);

                            if (isSlashableBySet) {
                                strategyHasQueuedDeallocations = true;
                                _hasQueuedDeallocations = true;
                                console.log("        [WARNING] Deallocation will be queued");
                                console.log("        DEALLOCATION_DELAY:", deallocationDelay, "blocks");
                                console.log("        Magnitude will NOT be freed immediately");
                            } else {
                                console.log("        [INFO] Deallocation will free magnitude immediately");
                            }

                            // Add deallocation params (set magnitude to 0)
                            allStrategies[totalCount] = strategy;
                            allOperatorSets[totalCount] = allocatedSets[j];
                            allMagnitudes[totalCount] = 0; // Deallocate
                            totalCount++;
                        }
                    }

                    if (strategyHasQueuedDeallocations) {
                        // If operator is slashable, deallocation will be queued
                        // AllocationManager processes params sequentially, but queued deallocations don't free magnitude immediately
                        // So we should NOT attempt allocation - it will fail
                        // Only queue deallocations, then stop and tell user to re-run after delay
                        console.log("    [WARNING] Operator is slashable by source AVS - deallocation will be queued");
                        console.log("    [WARNING] Allocation will be skipped (magnitude still encumbered)");
                        console.log("    [WARNING] This will require 2 transactions:");
                        console.log("      1. Current transaction: Deallocation queued (magnitude remains encumbered)");
                        console.log("      2. After delay: Re-run script to allocate (magnitude will be freed)");
                        console.log("    [INFO] DEALLOCATION_DELAY:", deallocationDelay, "blocks");
                        console.log(
                            "    [INFO] Alternative: Deregister from the other AVS first (allows 1-transaction reallocation)"
                        );
                        // Skip allocation - don't add it to params since it will fail
                        console.log("    [SKIP] Skipping allocation (will fail - magnitude still encumbered)");
                        shouldAddAllocation = false;
                    } else {
                        // Operator is not slashable, so deallocation is immediate
                        // We can do both deallocation and allocation in 1 transaction
                        // Deallocations are processed first (via grouping), then allocations
                        // Cap newMagnitude to maxMagnitude since that's the maximum available
                        if (newMagnitude > maxMagnitude) {
                            newMagnitude = maxMagnitude;
                        }
                        console.log(
                            "    [OK] Will allocate to magnitude:",
                            newMagnitude,
                            "(1 transaction: deallocation + allocation)"
                        );
                    }
                } else {
                    // No magnitude at all - operator needs to deposit into strategy first
                    console.log("    [SKIP] No magnitude available. Operator needs to deposit into strategy first.");
                    continue;
                }

                if (shouldAddAllocation && newMagnitude > currentAlloc.currentMagnitude) {
                    allStrategies[totalCount] = strategy;
                    allOperatorSets[totalCount] = _lstOperatorSet;
                    allMagnitudes[totalCount] = newMagnitude;
                    totalCount++;
                } else if (!shouldAddAllocation) {
                    // Already logged skip message above
                } else {
                    console.log("    [SKIP] New magnitude not greater than current");
                }
            } else {
                console.log("    [SKIP] Already at target magnitude");
            }
        }

        if (totalCount == 0) {
            return (new IAllocationManagerTypes.AllocateParams[](0), _hasQueuedDeallocations);
        }

        // If there are queued deallocations, remove allocation params (they will fail)
        // Only keep deallocation params (magnitude = 0)
        if (_hasQueuedDeallocations) {
            // Filter out allocations, keep only deallocations
            IStrategy[] memory deallocationStrategies = new IStrategy[](totalCount);
            OperatorSet[] memory deallocationOperatorSets = new OperatorSet[](totalCount);
            uint64[] memory deallocationMagnitudes = new uint64[](totalCount);
            uint256 deallocationCount = 0;

            for (uint256 i = 0; i < totalCount; i++) {
                if (allMagnitudes[i] == 0) {
                    // This is a deallocation
                    deallocationStrategies[deallocationCount] = allStrategies[i];
                    deallocationOperatorSets[deallocationCount] = allOperatorSets[i];
                    deallocationMagnitudes[deallocationCount] = allMagnitudes[i];
                    deallocationCount++;
                }
            }

            if (deallocationCount == 0) {
                return (new IAllocationManagerTypes.AllocateParams[](0), _hasQueuedDeallocations);
            }

            return (
                _groupByOperatorSetWithPriority(
                    deallocationStrategies,
                    deallocationOperatorSets,
                    deallocationMagnitudes,
                    deallocationCount,
                    _lstOperatorSet
                ),
                _hasQueuedDeallocations
            );
        }

        // Group by operator set, with AlephAVS sets processed first
        // This allows us to attempt allocation before deallocation in the same transaction
        // Note: If operator is slashable, deallocation will be queued and allocation params are excluded
        return (
            _groupByOperatorSetWithPriority(allStrategies, allOperatorSets, allMagnitudes, totalCount, _lstOperatorSet),
            _hasQueuedDeallocations
        );
    }

    /**
     * @notice Groups strategies by operator set for allocation params, with deallocations processed first
     * @dev This processes deallocations from other sets first, then AlephAVS allocations.
     *      This order allows magnitude to be freed before allocation, enabling single-transaction reallocation.
     *      If the operator is slashable by other AVSs, deallocation will be queued and allocation may fail.
     */
    function _groupByOperatorSetWithPriority(
        IStrategy[] memory _strategies,
        OperatorSet[] memory _operatorSets,
        uint64[] memory _magnitudes,
        uint256 _count,
        OperatorSet memory _lstOperatorSet
    ) internal pure returns (IAllocationManagerTypes.AllocateParams[] memory) {
        // Count unique operator sets
        uint256 uniqueSets = 0;
        OperatorSet[] memory uniqueOperatorSets = new OperatorSet[](_count);

        for (uint256 i = 0; i < _count; i++) {
            bool found = false;
            for (uint256 j = 0; j < uniqueSets; j++) {
                if (
                    _operatorSets[i].avs == uniqueOperatorSets[j].avs && _operatorSets[i].id == uniqueOperatorSets[j].id
                ) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                uniqueOperatorSets[uniqueSets] = _operatorSets[i];
                uniqueSets++;
            }
        }

        // Build params grouped by operator set, with AlephAVS sets first
        IAllocationManagerTypes.AllocateParams[] memory params =
            new IAllocationManagerTypes.AllocateParams[](uniqueSets);

        // Separate AlephAVS sets from other sets
        OperatorSet[] memory alephSets = new OperatorSet[](uniqueSets);
        OperatorSet[] memory otherSets = new OperatorSet[](uniqueSets);
        uint256 alephCount = 0;
        uint256 otherCount = 0;

        for (uint256 i = 0; i < uniqueSets; i++) {
            OperatorSet memory opSet = uniqueOperatorSets[i];
            // Check if this is an AlephAVS operator set
            bool isAlephSet = (opSet.avs == _lstOperatorSet.avs && opSet.id == _lstOperatorSet.id);

            if (isAlephSet) {
                alephSets[alephCount] = opSet;
                alephCount++;
            } else {
                otherSets[otherCount] = opSet;
                otherCount++;
            }
        }

        uint256 paramIdx = 0;

        // Process other sets first (deallocations) - this frees magnitude before allocation
        for (uint256 i = 0; i < otherCount; i++) {
            OperatorSet memory opSet = otherSets[i];
            uint256 strategyCount = 0;

            // Count strategies for this operator set
            for (uint256 j = 0; j < _count; j++) {
                if (_operatorSets[j].avs == opSet.avs && _operatorSets[j].id == opSet.id) {
                    strategyCount++;
                }
            }

            IStrategy[] memory setStrategies = new IStrategy[](strategyCount);
            uint64[] memory setMagnitudes = new uint64[](strategyCount);
            uint256 strategyIdx = 0;

            // Collect strategies and magnitudes for this operator set
            for (uint256 j = 0; j < _count; j++) {
                if (_operatorSets[j].avs == opSet.avs && _operatorSets[j].id == opSet.id) {
                    setStrategies[strategyIdx] = _strategies[j];
                    setMagnitudes[strategyIdx] = _magnitudes[j];
                    strategyIdx++;
                }
            }

            params[paramIdx] = IAllocationManagerTypes.AllocateParams({
                operatorSet: opSet, strategies: setStrategies, newMagnitudes: setMagnitudes
            });
            paramIdx++;
        }

        // Process AlephAVS sets second (allocations) - after deallocations free magnitude
        for (uint256 i = 0; i < alephCount; i++) {
            OperatorSet memory opSet = alephSets[i];
            uint256 strategyCount = 0;

            // Count strategies for this operator set
            for (uint256 j = 0; j < _count; j++) {
                if (_operatorSets[j].avs == opSet.avs && _operatorSets[j].id == opSet.id) {
                    strategyCount++;
                }
            }

            IStrategy[] memory setStrategies = new IStrategy[](strategyCount);
            uint64[] memory setMagnitudes = new uint64[](strategyCount);
            uint256 strategyIdx = 0;

            // Collect strategies and magnitudes for this operator set
            for (uint256 j = 0; j < _count; j++) {
                if (_operatorSets[j].avs == opSet.avs && _operatorSets[j].id == opSet.id) {
                    setStrategies[strategyIdx] = _strategies[j];
                    setMagnitudes[strategyIdx] = _magnitudes[j];
                    strategyIdx++;
                }
            }

            params[paramIdx] = IAllocationManagerTypes.AllocateParams({
                operatorSet: opSet, strategies: setStrategies, newMagnitudes: setMagnitudes
            });
            paramIdx++;
        }

        return params;
    }
}

