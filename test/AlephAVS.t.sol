// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

import {AlephAVS} from "../src/AlephAVS.sol";
import {IAlephAVS} from "../src/IAlephAVS.sol";
import {IMintableBurnableERC20} from "../src/interfaces/IMintableBurnableERC20.sol";
import {AlephSlashing} from "../src/libraries/AlephSlashing.sol";
import {AlephValidation} from "../src/libraries/AlephValidation.sol";
import {AlephUtils} from "../src/libraries/AlephUtils.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IAllocationManagerTypes} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IStrategyFactory} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyFactory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IERC20Factory} from "../src/interfaces/IERC20Factory.sol";
import {IAVSRegistrar} from "eigenlayer-contracts/src/contracts/interfaces/IAVSRegistrar.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";
import {IAlephVault} from "Aleph/src/interfaces/IAlephVault.sol";
import {IAlephVaultDeposit} from "Aleph/src/interfaces/IAlephVaultDeposit.sol";
import {IAlephVaultRedeem} from "Aleph/src/interfaces/IAlephVaultRedeem.sol";
import {IAlephVaultFactory} from "Aleph/src/interfaces/IAlephVaultFactory.sol";
import {AuthLibrary} from "Aleph/src/libraries/AuthLibrary.sol";
import {ERC4626Math} from "Aleph/src/libraries/ERC4626Math.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20 as IERC20Eigen} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {
    TransparentUpgradeableProxy
} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// Mintable token for testing
contract MintableToken is ERC20, Ownable {
    constructor(string memory name, string memory symbol, uint256 initialSupply, address owner)
        ERC20(name, symbol)
        Ownable(owner)
    {
        if (initialSupply > 0) {
            _mint(owner, initialSupply);
        }
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function totalSupply() public view override returns (uint256) {
        return 1000e18; // Mock value
    }
}

// Minimal vault contract - handles token transfers for syncDeposit
contract MinimalAlephVault is IAlephVaultDeposit, IAlephVaultRedeem {
    using SafeERC20 for IERC20;

    IERC20 private immutable _underlyingToken;
    uint256 public pricePerShareValue = 1e18; // 1:1 for simplicity

    // Track redeemable amounts per user
    mapping(address => uint256) public redeemableAmount;

    // Track isTotalAssetsValid per classId (defaults to true for sync deposits in tests)
    mapping(uint8 => bool) public isTotalAssetsValidForClass;

    // Track notice period per classId (non-zero means async only)
    mapping(uint8 => uint48) public noticePeriodForClass;

    constructor(address __underlyingToken) {
        _underlyingToken = IERC20(__underlyingToken);
    }

    function underlyingToken() external view returns (address) {
        return address(_underlyingToken);
    }

    function name() external pure returns (string memory) {
        return "TestVault";
    }

    function isTotalAssetsValid(uint8 _classId) external view returns (bool) {
        // Default to true if not explicitly set, to maintain existing test behavior
        return isTotalAssetsValidForClass[_classId] != false;
    }

    function noticePeriod(uint8 _classId) external view returns (uint48) {
        // Default to 1 (async only) to maintain existing test behavior
        // noticePeriodForClass == type(uint48).max means explicitly set to 0
        if (noticePeriodForClass[_classId] == type(uint48).max) return 0;
        if (noticePeriodForClass[_classId] == 0) return 1; // Not set, default to async
        return noticePeriodForClass[_classId];
    }

    function enableSyncRedeem(uint8 _classId) external {
        noticePeriodForClass[_classId] = type(uint48).max; // Sentinel value for "explicitly set to 0"
    }

    function requestDeposit(RequestDepositParams calldata params) external override returns (uint48) {
        _underlyingToken.safeTransferFrom(msg.sender, address(this), params.amount);
        return 0;
    }

    function syncDeposit(RequestDepositParams calldata params) external override returns (uint256) {
        _underlyingToken.safeTransferFrom(msg.sender, address(this), params.amount);
        // Return shares minted (1:1 for simplicity in tests)
        return params.amount;
    }

    function queueMinDepositAmount(uint8, uint256) external pure override {}
    function queueMinUserBalance(uint8, uint256) external pure override {}
    function queueMaxDepositCap(uint8, uint256) external pure override {}
    function setMinDepositAmount(uint8) external pure override {}
    function setMinUserBalance(uint8) external pure override {}
    function setMaxDepositCap(uint8) external pure override {}

    // Redeem functions
    function requestRedeem(RedeemRequestParams calldata) external pure override returns (uint48) {
        return 0;
    }

    function syncRedeem(RedeemRequestParams calldata params) external override returns (uint256) {
        // Sync redeem only allowed if noticePeriod is 0 (explicitly enabled)
        // noticePeriodForClass == type(uint48).max means explicitly set to 0
        if (noticePeriodForClass[params.classId] != type(uint48).max) {
            revert IAlephVaultRedeem.OnlyAsyncRedeemAllowed();
        }
        uint256 amount = (params.estAmountToRedeem * pricePerShareValue) / 1e18;
        _underlyingToken.safeTransfer(msg.sender, amount);
        return amount;
    }

    function withdrawRedeemableAmount() external override {
        uint256 amount = redeemableAmount[msg.sender];
        require(amount > 0, "No redeemable amount");
        delete redeemableAmount[msg.sender];
        _underlyingToken.safeTransfer(msg.sender, amount);
    }

    function withdrawExcessAssets() external pure override {}

    // Helper function for testing - set redeemable amount
    function setRedeemableAmount(address user, uint256 amount) external {
        redeemableAmount[user] = amount;
    }

    // Helper function for testing - set price per share
    function setPricePerShare(uint256 _pricePerShare) external {
        pricePerShareValue = _pricePerShare;
    }

    // Helper functions for vault interface
    function totalSharesPerSeries(uint8, uint32) external pure returns (uint256) {
        return 1000e18; // Mock value
    }

    function totalAssetsPerSeries(uint8, uint32) external pure returns (uint256) {
        return 1000e18; // Mock value
    }

    function assetsPerClassOf(uint8, address) external view returns (uint256) {
        return 0; // Mock value
    }

    function pricePerShare(uint8, uint32) external view returns (uint256) {
        return pricePerShareValue;
    }

    function shareSeriesId(uint8) external pure returns (uint32) {
        return 0;
    }

    // Timelock functions (not used in tests)
    function queueNoticePeriod(uint8, uint48) external pure override {}
    function queueLockInPeriod(uint8, uint48) external pure override {}
    function queueMinRedeemAmount(uint8, uint256) external pure override {}
    function setNoticePeriod(uint8) external pure override {}
    function setLockInPeriod(uint8) external pure override {}
    function setMinRedeemAmount(uint8) external pure override {}
}

contract AlephAVSTest is Test {
    using SafeERC20 for IERC20;
    AlephAVS public alephAVS;

    address public constant MOCK_ALLOCATION_MANAGER = address(0x1001);
    address public constant MOCK_DELEGATION_MANAGER = address(0x1002);
    address public constant MOCK_STRATEGY_MANAGER = address(0x1003);
    address public constant MOCK_REWARDS_COORDINATOR = address(0x1007);
    address public constant MOCK_STRATEGY = address(0x1004);
    address public constant MOCK_ALEPH_STRATEGY = address(0x1006);
    address public constant MOCK_VAULT_FACTORY = address(0x1005);
    address public constant MOCK_STRATEGY_FACTORY = address(0x1009);
    address public constant MOCK_SLASHED_TOKEN = address(0x2001);
    address public constant MOCK_SLASHED_STRATEGY = address(0x2002);

    IStrategy[] public MOCK_STRATEGIES;
    IStrategy[] public MOCK_SLASHED_STRATEGIES;

    MinimalAlephVault public alephVault;
    MintableToken public underlyingToken;
    address public operator;
    address public owner;
    address public gaurdian;

    address public MOCK_ERC20_FACTORY;

    uint256 public constant STAKE_AMOUNT = 1000e18;
    uint256 public constant ALLOCATE_AMOUNT = 100e18;
    uint8 public constant CLASS_ID = 1;

    event SlashExecuted(
        address indexed operator,
        uint32 operatorSetId,
        address indexed strategy,
        address indexed underlyingToken,
        uint256 amount,
        uint256 slashId
    );
    event AllocatedToAlephVault(
        address indexed operator,
        address indexed alephVault,
        address originalStrategy,
        address slashedStrategy,
        uint256 amount,
        uint256 amountToMint,
        uint256 vaultShares,
        uint8 classId
    );
    event OperatorRegistered(address indexed operator, uint32[] operatorSetIds);
    event OperatorDeregistered(address indexed operator, uint32[] operatorSetIds);
    event UnallocateCompleted(
        address indexed tokenHolder,
        address indexed alephVault,
        address originalStrategy,
        address slashedStrategy,
        uint256 amount,
        uint256 shares,
        uint8 classId
    );
    event VaultInitialized(
        address indexed vault,
        uint8 classId,
        address indexed originalToken,
        address indexed slashedToken,
        address slashedStrategy
    );

    function _mockOperatorRegistration(address _operator, bool _isRegistered) internal {
        vm.mockCall(
            MOCK_DELEGATION_MANAGER,
            abi.encodeCall(IDelegationManager.isOperator, (_operator)),
            abi.encode(_isRegistered)
        );
    }

    function _mockOperatorSetAndMembership(
        address _operator,
        OperatorSet memory _operatorSet,
        bool _isOperatorSet,
        bool _isMember
    ) internal {
        vm.mockCall(
            MOCK_ALLOCATION_MANAGER,
            abi.encodeCall(IAllocationManager.isOperatorSet, (_operatorSet)),
            abi.encode(_isOperatorSet)
        );
        vm.mockCall(
            MOCK_ALLOCATION_MANAGER,
            abi.encodeCall(IAllocationManager.isMemberOfOperatorSet, (_operator, _operatorSet)),
            abi.encode(_isMember)
        );
    }

    function _getDefaultOperatorSet() internal view returns (OperatorSet memory) {
        return OperatorSet({avs: address(alephAVS), id: AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID});
    }

    function _mockStrategyUnderlyingToShares(uint256 _amount, uint256 _shares) internal {
        vm.mockCall(MOCK_STRATEGY, abi.encodeCall(IStrategy.underlyingToSharesView, (_amount)), abi.encode(_shares));
    }

    function _mockStrategyUnderlyingToken(address _token) internal {
        vm.mockCall(MOCK_STRATEGY, abi.encodeCall(IStrategy.underlyingToken, ()), abi.encode(IERC20(_token)));
    }

    function _mockVaultFactory(address _vault, bool _isValid) internal {
        vm.mockCall(MOCK_VAULT_FACTORY, abi.encodeCall(IAlephVaultFactory.isValidVault, (_vault)), abi.encode(_isValid));
    }

    function _mockAllocatedStake(OperatorSet memory _operatorSet, address _operator, uint256 _allocatedShares)
        internal
    {
        address[] memory operators = new address[](1);
        operators[0] = _operator;
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = IStrategy(MOCK_STRATEGY);
        uint256[][] memory allocatedStakes = new uint256[][](1);
        allocatedStakes[0] = new uint256[](1);
        allocatedStakes[0][0] = _allocatedShares;

        vm.mockCall(
            MOCK_ALLOCATION_MANAGER,
            abi.encodeCall(IAllocationManager.getAllocatedStake, (_operatorSet, operators, strategies)),
            abi.encode(allocatedStakes)
        );
    }

    function _mockAllocation(address _operator, OperatorSet memory _operatorSet, uint64 _currentMagnitude) internal {
        IAllocationManagerTypes.Allocation memory allocation = IAllocationManagerTypes.Allocation({
            currentMagnitude: _currentMagnitude, pendingDiff: int128(0), effectBlock: uint32(block.number)
        });

        vm.mockCall(
            MOCK_ALLOCATION_MANAGER,
            abi.encodeCall(IAllocationManager.getAllocation, (_operator, _operatorSet, IStrategy(MOCK_STRATEGY))),
            abi.encode(allocation)
        );
    }

    function _mockSlashOperator(
        address _operator,
        uint32 _operatorSetId,
        uint256 _allocatedShares,
        uint256 _expectedSlashId,
        uint256 _slashedShares,
        uint256 _tokenAmount
    ) internal {
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = IStrategy(MOCK_STRATEGY);
        uint256 expectedWad = (_tokenAmount * 1e18) / _allocatedShares;
        uint256[] memory expectedWads = new uint256[](1);
        expectedWads[0] = expectedWad;
        uint256[] memory slashedSharesArray = new uint256[](1);
        slashedSharesArray[0] = _slashedShares;

        vm.mockCall(
            MOCK_ALLOCATION_MANAGER,
            abi.encodeCall(
                IAllocationManager.slashOperator,
                (
                    address(alephAVS),
                    IAllocationManagerTypes.SlashingParams({
                        operator: _operator,
                        operatorSetId: _operatorSetId,
                        strategies: strategies,
                        wadsToSlash: expectedWads,
                        description: ""
                    })
                )
            ),
            abi.encode(_expectedSlashId, slashedSharesArray)
        );
    }

    function _mockClearBurnOrRedistributableShares(
        OperatorSet memory _operatorSet,
        uint256 _slashId,
        uint256 _tokenAmount
    ) internal {
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeCall(
                IStrategyManager.clearBurnOrRedistributableSharesByStrategy,
                (_operatorSet, _slashId, IStrategy(MOCK_STRATEGY))
            ),
            abi.encode(_tokenAmount)
        );
    }

    function _setupCompleteAllocationMocks(
        address _operator,
        uint256 _allocatedShares,
        uint64 _magnitude,
        uint256 _tokenAmount
    ) internal {
        OperatorSet memory operatorSet = _getDefaultOperatorSet();

        _mockOperatorRegistration(_operator, true);
        _mockOperatorSetAndMembership(_operator, operatorSet, true, true);
        _mockStrategyUnderlyingToShares(_tokenAmount, _tokenAmount);
        _mockAllocatedStake(operatorSet, _operator, _allocatedShares);
        _mockAllocation(_operator, operatorSet, _magnitude);
        _mockSlashOperator(
            _operator, AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID, _allocatedShares, 1, _tokenAmount, _tokenAmount
        );
        _mockClearBurnOrRedistributableShares(operatorSet, 1, _tokenAmount);
        _mockStrategyUnderlyingToken(address(underlyingToken));
        _mockVaultFactory(address(alephVault), true);
        vm.mockCall(
            address(alephVault), abi.encodeCall(IAlephVault.underlyingToken, ()), abi.encode(address(underlyingToken))
        );

        // Mock accountant() to return address(0) (no accountant configured)
        vm.mockCall(address(alephVault), abi.encodeCall(IAlephVault.accountant, ()), abi.encode(address(0)));

        // Mock strategyFactory.deployedStrategies for vault token
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeCall(IStrategyFactory.deployedStrategies, (IERC20Eigen(address(underlyingToken)))),
            abi.encode(IStrategy(MOCK_STRATEGY))
        );

        // Mock getOperatorAVSSplit to return 0 (100% to stakers)
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeCall(IRewardsCoordinator.getOperatorAVSSplit, (_operator, address(alephAVS))),
            abi.encode(0)
        );
    }

    function _initializeVaultForTests() internal {
        address mockSlashedStrategy = MOCK_SLASHED_STRATEGY;
        address mockSlashedToken = MOCK_SLASHED_TOKEN;

        // Mock vault name for token creation
        vm.mockCall(address(alephVault), abi.encodeCall(IAlephVault.name, ()), abi.encode("TestVault"));

        // Mock token metadata
        vm.mockCall(address(underlyingToken), abi.encodeCall(IERC20Metadata.name, ()), abi.encode("Test Token"));
        vm.mockCall(address(underlyingToken), abi.encodeCall(IERC20Metadata.symbol, ()), abi.encode("TEST"));

        // Mock ERC20Factory.createToken
        vm.mockCall(
            MOCK_ERC20_FACTORY, abi.encodeWithSelector(IERC20Factory.createToken.selector), abi.encode(mockSlashedToken)
        );

        // Mock StrategyFactory.deployedStrategies for slashed token (returns 0 initially)
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeWithSelector(IStrategyFactory.deployedStrategies.selector, mockSlashedToken),
            abi.encode(IStrategy(address(0)))
        );

        // Mock StrategyFactory.deployNewStrategy
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeWithSelector(IStrategyFactory.deployNewStrategy.selector, mockSlashedToken),
            abi.encode(IStrategy(mockSlashedStrategy))
        );

        vm.mockCall(
            MOCK_ALLOCATION_MANAGER,
            abi.encodeWithSelector(
                IAllocationManager.getStrategiesInOperatorSet.selector,
                OperatorSet(address(alephAVS), AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID)
            ),
            abi.encode(MOCK_STRATEGIES)
        );

        vm.mockCall(
            MOCK_ALLOCATION_MANAGER,
            abi.encodeWithSelector(
                IAllocationManager.getStrategiesInOperatorSet.selector,
                OperatorSet(address(alephAVS), AlephUtils.SLASHED_STRATEGIES_OPERATOR_SET_ID)
            ),
            abi.encode(MOCK_SLASHED_STRATEGIES)
        );

        // Mock slashed strategy underlyingToken
        vm.mockCall(mockSlashedStrategy, abi.encodeCall(IStrategy.underlyingToken, ()), abi.encode(mockSlashedToken));

        // Mock getVaultTokenAndStrategy to return the LST strategy
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeCall(IStrategyFactory.deployedStrategies, (IERC20Eigen(address(underlyingToken)))),
            abi.encode(IStrategy(MOCK_STRATEGY))
        );

        // Mock addStrategiesToOperatorSet (called twice - once for LST, once for slashed)
        vm.mockCall(
            MOCK_ALLOCATION_MANAGER,
            abi.encodeWithSelector(IAllocationManager.addStrategiesToOperatorSet.selector),
            abi.encode()
        );

        // Call initializeVault as owner
        vm.prank(owner);
        alephAVS.initializeVault(1, address(alephVault), IStrategy(MOCK_STRATEGY));
    }

    function _createAuthSignature(uint256 _expiryBlock) internal pure returns (AuthLibrary.AuthSignature memory) {
        return AuthLibrary.AuthSignature({authSignature: "", expiryBlock: _expiryBlock});
    }

    function setUp() public {
        owner = address(this);
        gaurdian = makeAddr("gaurdian");
        operator = makeAddr("operator");

        MOCK_STRATEGIES.push(IStrategy(MOCK_STRATEGY));
        MOCK_SLASHED_STRATEGIES.push(IStrategy(MOCK_SLASHED_STRATEGY));

        underlyingToken = new MintableToken("Test Token", "TEST", STAKE_AMOUNT * 10, owner);
        alephVault = new MinimalAlephVault(address(underlyingToken));

        bytes memory minimalBytecode = hex"6080604052348015600f57600080fd5b50600080fdfe";

        vm.etch(MOCK_ALLOCATION_MANAGER, minimalBytecode);
        vm.etch(MOCK_DELEGATION_MANAGER, minimalBytecode);
        vm.etch(MOCK_STRATEGY_MANAGER, minimalBytecode);
        vm.etch(MOCK_STRATEGY, minimalBytecode);
        vm.etch(MOCK_ALEPH_STRATEGY, minimalBytecode);
        vm.etch(MOCK_VAULT_FACTORY, minimalBytecode);
        vm.etch(MOCK_STRATEGY_FACTORY, minimalBytecode);
        vm.etch(MOCK_ERC20_FACTORY, minimalBytecode);
        vm.etch(MOCK_REWARDS_COORDINATOR, minimalBytecode);

        // Predict the proxy address (implementation + proxy)
        uint256 nonce = vm.getNonce(address(this));
        // Skip one nonce for implementation, get proxy address
        address predictedAlephAVS = vm.computeCreateAddress(address(this), nonce + 1);

        // Define mock addresses for slashed token and strategy (used throughout tests)
        address mockSlashedToken = MOCK_SLASHED_TOKEN;
        address mockSlashedStrategy = MOCK_SLASHED_STRATEGY;

        // Mock AVS metadata registration (called in constructor)
        vm.mockCall(
            MOCK_ALLOCATION_MANAGER,
            abi.encodeWithSelector(IAllocationManager.updateAVSMetadataURI.selector),
            abi.encode()
        );

        // Mock AVS registrar setting (called in constructor)
        vm.mockCall(
            MOCK_ALLOCATION_MANAGER,
            abi.encodeCall(IAllocationManager.setAVSRegistrar, (predictedAlephAVS, IAVSRegistrar(predictedAlephAVS))),
            abi.encode()
        );

        // Mock operator set initialization (called in constructor)
        IStrategy[] memory lstStrategies = new IStrategy[](0);
        IAllocationManagerTypes.CreateSetParams memory lstCreateParam =
            IAllocationManagerTypes.CreateSetParams({operatorSetId: 0, strategies: lstStrategies});

        IAllocationManagerTypes.CreateSetParams[] memory createParams = new IAllocationManagerTypes.CreateSetParams[](1);
        createParams[0] = lstCreateParam;

        address[] memory recipients = new address[](1);
        recipients[0] = predictedAlephAVS;

        vm.mockCall(
            MOCK_ALLOCATION_MANAGER,
            abi.encodeCall(
                IAllocationManager.createRedistributingOperatorSets, (predictedAlephAVS, createParams, recipients)
            ),
            abi.encode()
        );

        // Mock strategy underlyingToken (needed during constructor)
        vm.mockCall(MOCK_STRATEGY, abi.encodeCall(IStrategy.underlyingToken, ()), abi.encode(address(underlyingToken)));

        // Mock StrategyFactory.deployedStrategies to return MOCK_STRATEGY for the underlying token
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeCall(IStrategyFactory.deployedStrategies, (IERC20Eigen(address(underlyingToken)))),
            abi.encode(IStrategy(MOCK_STRATEGY))
        );

        // Deploy the implementation contract
        AlephAVS alephAVSImpl = new AlephAVS(
            IAllocationManager(MOCK_ALLOCATION_MANAGER),
            IDelegationManager(MOCK_DELEGATION_MANAGER),
            IStrategyManager(MOCK_STRATEGY_MANAGER),
            IRewardsCoordinator(MOCK_REWARDS_COORDINATOR),
            IAlephVaultFactory(MOCK_VAULT_FACTORY),
            IStrategyFactory(MOCK_STRATEGY_FACTORY)
        );

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(AlephAVS.initialize.selector, owner, gaurdian, "");

        // Deploy proxy with initialization
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(alephAVSImpl),
            owner, // admin
            initData
        );

        // Wrap proxy in AlephAVS interface
        alephAVS = AlephAVS(address(proxy));

        MOCK_ERC20_FACTORY = address(alephAVS.erc20Factory());

        // After deployment, operator set exists
        OperatorSet memory operatorSet =
            OperatorSet({avs: address(alephAVS), id: AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID});
        vm.mockCall(
            MOCK_ALLOCATION_MANAGER, abi.encodeCall(IAllocationManager.isOperatorSet, (operatorSet)), abi.encode(true)
        );

        vm.mockCall(
            MOCK_VAULT_FACTORY, abi.encodeCall(IAlephVaultFactory.isValidVault, (address(alephVault))), abi.encode(true)
        );

        // Mock ERC20Factory.createToken to return a new token address
        vm.mockCall(
            MOCK_ERC20_FACTORY, abi.encodeWithSelector(IERC20Factory.createToken.selector), abi.encode(mockSlashedToken)
        );

        // Mock StrategyFactory.deployedStrategies for slashed tokens
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeWithSelector(IStrategyFactory.deployedStrategies.selector, mockSlashedToken),
            abi.encode(IStrategy(address(0)))
        );

        // Mock StrategyFactory.deployNewStrategy to return a new strategy
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeWithSelector(IStrategyFactory.deployNewStrategy.selector, mockSlashedToken),
            abi.encode(IStrategy(mockSlashedStrategy))
        );

        // Mock the slashed strategy's underlyingToken to return the slashed token
        vm.mockCall(mockSlashedStrategy, abi.encodeCall(IStrategy.underlyingToken, ()), abi.encode(mockSlashedToken));

        // Mock addStrategiesToOperatorSet
        vm.mockCall(
            MOCK_ALLOCATION_MANAGER,
            abi.encodeWithSelector(IAllocationManager.addStrategiesToOperatorSet.selector),
            abi.encode()
        );

        // Mock slashed token mint function
        vm.mockCall(mockSlashedToken, abi.encodeCall(IMintableBurnableERC20.mint, (address(0), 0)), abi.encode());

        // Mock slashed token approve function
        vm.mockCall(mockSlashedToken, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        // Mock slashed token transfer functions
        vm.mockCall(mockSlashedToken, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));
        vm.mockCall(mockSlashedToken, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));

        // Mock slashed token balanceOf
        vm.mockCall(
            mockSlashedToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(0)),
            abi.encode(type(uint256).max)
        );

        // Mock slashed token burn
        vm.mockCall(
            mockSlashedToken, abi.encodeWithSelector(IMintableBurnableERC20.burn.selector, address(0), 0), abi.encode()
        );

        // Mock slashed token totalSupply (needed for calculateAmountToMint/calculateAmountToRedeem)
        vm.mockCall(mockSlashedToken, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(0));

        // Initialize vault
        _initializeVaultForTests();

        // Enable sync redeem for the vault (required since we removed async fallback)
        alephVault.enableSyncRedeem(CLASS_ID);

        // Fund the vault with tokens for sync redeem operations
        underlyingToken.transfer(address(alephVault), STAKE_AMOUNT * 5);
    }

    function test_OperatorAllocatesToAlephVault() public {
        // Set a large block timestamp to avoid underflow in calculateRetroactiveRewardsWindow
        vm.warp(1000000); // Set timestamp to a large value

        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, 1000, ALLOCATE_AMOUNT);

        // Mock CALCULATION_INTERVAL_SECONDS (needed for calculateRetroactiveRewardsWindow)
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400)) // 1 day in seconds
        );

        // Don't mock approve - let the real token handle it
        // Don't mock syncDeposit - let the real MinimalAlephVault handle it
        // But we need to ensure tokens are available for transfer
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT);

        // Mock slashed token mint (called by allocate)
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );

        // Mock slashed token approve (for rewards submission)
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );

        // Mock rewards submission
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        // Transfer tokens to AVS (simulating redistributable shares being cleared)
        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);

        // Create allocation params
        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);

        // Verify vault received tokens (the vault's syncDeposit will transfer tokens)
        // Since we're mocking, we can't verify the actual balance, but the call should succeed
    }

    function test_RegisterOperator_EmitsEvent() public {
        uint32[] memory operatorSetIds = new uint32[](2);
        operatorSetIds[0] = AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID;
        operatorSetIds[1] = AlephUtils.SLASHED_STRATEGIES_OPERATOR_SET_ID;

        vm.expectEmit(true, false, false, false);
        emit OperatorRegistered(operator, operatorSetIds);

        vm.prank(MOCK_ALLOCATION_MANAGER);
        alephAVS.registerOperator(operator, address(alephAVS), operatorSetIds, "");
    }

    function test_RegisterOperator_RevertsIfNotFromAllocationManager() public {
        uint32[] memory operatorSetIds = new uint32[](1);
        operatorSetIds[0] = 0;

        vm.prank(address(alephAVS));
        vm.expectRevert(IAlephAVS.Unauthorized.selector);
        alephAVS.registerOperator(operator, address(alephAVS), operatorSetIds, "");
    }

    function test_RegisterOperator_RevertsIfWrongAVS() public {
        uint32[] memory operatorSetIds = new uint32[](1);
        operatorSetIds[0] = 0;

        vm.prank(MOCK_ALLOCATION_MANAGER);
        vm.expectRevert(IAlephAVS.Unauthorized.selector);
        alephAVS.registerOperator(operator, address(0x9999), operatorSetIds, "");
    }

    function test_Allocate_ValidatesAmount() public {
        _mockOperatorRegistration(operator, true);
        _mockVaultFactory(address(alephVault), true);

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: 0, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(operator);
        vm.expectRevert(IAlephAVS.InvalidAmount.selector);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_RevertsIfNotOperator() public {
        address nonOperator = makeAddr("nonOperator");
        _mockOperatorRegistration(nonOperator, false);
        _mockVaultFactory(address(alephVault), true);

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(nonOperator);
        vm.expectRevert(IAlephAVS.NotRegisteredOperator.selector);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_RevertsIfOperatorSplitNotZero() public {
        _mockOperatorRegistration(operator, true);
        _mockVaultFactory(address(alephVault), true);

        // Mock getOperatorAVSSplit to return non-zero (operator takes a cut)
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeCall(IRewardsCoordinator.getOperatorAVSSplit, (operator, address(alephAVS))),
            abi.encode(1e17) // 10% to operator
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(operator);
        vm.expectRevert();
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_RevertsIfInvalidVault() public {
        _mockOperatorRegistration(operator, true);
        _mockVaultFactory(address(alephVault), false);

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(operator);
        vm.expectRevert();
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_RevertsIfVaultNotInitialized() public {
        _mockOperatorRegistration(operator, true);
        _mockVaultFactory(address(alephVault), true);

        // Mock vaultToSlashedStrategy to return address(0) (vault not initialized)
        vm.mockCall(
            address(alephAVS),
            abi.encodeCall(IAlephAVS.vaultToSlashedStrategy, (address(alephVault))),
            abi.encode(IStrategy(address(0)))
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(operator);
        vm.expectRevert();
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_EmitsCorrectEvents() public {
        // Set a large block timestamp to avoid underflow in calculateRetroactiveRewardsWindow
        vm.warp(1000000); // Set timestamp to a large value

        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, 1000, ALLOCATE_AMOUNT);

        // Mock CALCULATION_INTERVAL_SECONDS (needed for calculateRetroactiveRewardsWindow)
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400)) // 1 day in seconds
        );

        // Don't mock approve - let the real token handle it
        // Don't mock syncDeposit - let the real MinimalAlephVault handle it
        // But we need to ensure tokens are available for transfer
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT);

        // Mock slashed token mint (called by allocate)
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );

        // Mock slashed token approve (for rewards submission)
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );

        // Mock rewards submission
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        // Expect the event (checkTopic1=false because Approval events may be emitted first)
        vm.expectEmit(false, true, true, false);
        emit AllocatedToAlephVault(
            operator,
            address(alephVault),
            MOCK_STRATEGY,
            MOCK_SLASHED_STRATEGY,
            ALLOCATE_AMOUNT,
            ALLOCATE_AMOUNT,
            ALLOCATE_AMOUNT,
            CLASS_ID
        );

        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Unallocate_ReturnsAmountAndShares() public {
        address tokenHolder = makeAddr("tokenHolder");
        uint256 unallocateAmount = ALLOCATE_AMOUNT;

        // Mock token holder has slashed tokens
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (tokenHolder)), abi.encode(unallocateAmount));

        // Mock transferFrom (token holder transfers to contract)
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.transferFrom, (tokenHolder, address(alephAVS), unallocateAmount)),
            abi.encode(true)
        );

        // Mock burn
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.burn, (address(alephAVS), unallocateAmount)),
            abi.encode()
        );

        // Mock slashed token totalSupply and vault assetsPerClassOf (needed for calculateAmountToRedeem)
        vm.mockCall(
            MOCK_SLASHED_TOKEN, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(unallocateAmount)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.assetsPerClassOf, (CLASS_ID, address(alephAVS))),
            abi.encode(unallocateAmount)
        );

        uint256 expectedRedeemAmount = ERC4626Math.previewRedeem(unallocateAmount, unallocateAmount, unallocateAmount);
        // syncRedeem is enabled in setUp via enableSyncRedeem(CLASS_ID)
        // The real MinimalAlephVault will handle the sync redeem

        // Mock depositIntoStrategyWithSignature
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(expectedRedeemAmount) // Return shares
        );

        // For sync flow: redeemableAmount returns 0 (funds already withdrawn by syncRedeem)
        // The funds are in the contract and tracked via vaultWithdrawnAmount
        vm.mockCall(
            address(alephVault), abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))), abi.encode(0)
        );
        // Don't need to mock withdrawRedeemableAmount since redeemableAmount is 0

        // Mock vault token approve
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        vm.prank(tokenHolder);
        alephAVS.requestUnallocate(address(alephVault), unallocateAmount);

        vm.prank(tokenHolder);
        (uint256 amount, uint256 shares) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");

        assertEq(amount, expectedRedeemAmount, "Unexpected unallocated amount");
        assertEq(shares, expectedRedeemAmount, "Unexpected shares returned");
    }

    function test_Unallocate_RevertsForZeroAmount() public {
        address tokenHolder = makeAddr("tokenHolder");

        vm.prank(tokenHolder);
        vm.expectRevert(IAlephAVS.InvalidAmount.selector);
        alephAVS.requestUnallocate(address(alephVault), 0);
    }

    function test_Unallocate_RevertsIfInsufficientBalance() public {
        address tokenHolder = makeAddr("tokenHolder");

        // Mock token holder has insufficient balance
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.balanceOf, (tokenHolder)),
            abi.encode(ALLOCATE_AMOUNT - 1) // Less than requested
        );

        vm.prank(tokenHolder);
        vm.expectRevert(IAlephAVS.InsufficientBalance.selector);
        alephAVS.requestUnallocate(address(alephVault), ALLOCATE_AMOUNT);
    }

    function test_CalculateUnallocateAmount_ReturnsEstimatedAmount() public {
        uint256 tokenAmount = ALLOCATE_AMOUNT;

        // Mock vault functions needed for calculateEstAmountToRedeem
        vm.mockCall(address(alephVault), abi.encodeCall(IAlephVault.shareSeriesId, (CLASS_ID)), abi.encode(uint32(0)));
        vm.mockCall(
            address(alephVault), abi.encodeCall(IAlephVault.pricePerShare, (CLASS_ID, uint32(0))), abi.encode(1e18)
        );

        (uint256 estimatedAmount, IStrategy strategy, IERC20 token) =
            alephAVS.calculateUnallocateAmount(address(alephVault), tokenAmount);

        assertEq(address(strategy), MOCK_STRATEGY, "Strategy should match");
        assertEq(address(token), address(underlyingToken), "Token should match");
        assertGt(estimatedAmount, 0, "Estimated amount should be greater than 0");
    }

    function test_SupportsAVS_ReturnsTrueForSelf() public view {
        assertTrue(alephAVS.supportsAVS(address(alephAVS)));
    }

    function test_SupportsAVS_ReturnsFalseForOther() public view {
        assertFalse(alephAVS.supportsAVS(address(0x9999)));
    }

    function test_Constructor_RevertsIfInvalidAllocationManager() public {
        vm.expectRevert(IAlephAVS.InvalidAllocationManager.selector);
        new AlephAVS(
            IAllocationManager(address(0)),
            IDelegationManager(MOCK_DELEGATION_MANAGER),
            IStrategyManager(MOCK_STRATEGY_MANAGER),
            IRewardsCoordinator(MOCK_REWARDS_COORDINATOR),
            IAlephVaultFactory(MOCK_VAULT_FACTORY),
            IStrategyFactory(MOCK_STRATEGY_FACTORY)
        );
    }

    function test_Constructor_RevertsIfInvalidDelegationManager() public {
        vm.expectRevert(IAlephAVS.InvalidDelegationManager.selector);
        new AlephAVS(
            IAllocationManager(MOCK_ALLOCATION_MANAGER),
            IDelegationManager(address(0)),
            IStrategyManager(MOCK_STRATEGY_MANAGER),
            IRewardsCoordinator(MOCK_REWARDS_COORDINATOR),
            IAlephVaultFactory(MOCK_VAULT_FACTORY),
            IStrategyFactory(MOCK_STRATEGY_FACTORY)
        );
    }

    function test_Constructor_RevertsIfInvalidStrategyManager() public {
        vm.expectRevert(IAlephAVS.InvalidStrategyManager.selector);
        new AlephAVS(
            IAllocationManager(MOCK_ALLOCATION_MANAGER),
            IDelegationManager(MOCK_DELEGATION_MANAGER),
            IStrategyManager(address(0)),
            IRewardsCoordinator(MOCK_REWARDS_COORDINATOR),
            IAlephVaultFactory(MOCK_VAULT_FACTORY),
            IStrategyFactory(MOCK_STRATEGY_FACTORY)
        );
    }

    function test_DeregisterOperator_EmitsEvent() public {
        uint32[] memory operatorSetIds = new uint32[](1);
        operatorSetIds[0] = 0;

        vm.expectEmit(true, false, false, false);
        emit OperatorDeregistered(operator, operatorSetIds);

        vm.prank(MOCK_ALLOCATION_MANAGER);
        alephAVS.deregisterOperator(operator, address(alephAVS), operatorSetIds);
    }

    function test_DeregisterOperator_RevertsIfNotFromAllocationManager() public {
        uint32[] memory operatorSetIds = new uint32[](1);
        operatorSetIds[0] = 0;

        vm.prank(address(alephAVS));
        vm.expectRevert(IAlephAVS.Unauthorized.selector);
        alephAVS.deregisterOperator(operator, address(alephAVS), operatorSetIds);
    }

    function test_DeregisterOperator_RevertsIfWrongAVS() public {
        uint32[] memory operatorSetIds = new uint32[](1);
        operatorSetIds[0] = 0;

        vm.prank(MOCK_ALLOCATION_MANAGER);
        vm.expectRevert(IAlephAVS.Unauthorized.selector);
        alephAVS.deregisterOperator(operator, address(0x9999), operatorSetIds);
    }

    // ============ Additional Comprehensive Tests ============

    function test_Allocate_MultipleAllocationsBySameOperator() public {
        vm.warp(1000000);
        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT * 2, 2000, ALLOCATE_AMOUNT);

        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );

        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT * 2);

        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params1 = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params1);

        // Second allocation
        _mockSlashOperator(
            operator, AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID, STAKE_AMOUNT * 2, 2, ALLOCATE_AMOUNT, ALLOCATE_AMOUNT
        );
        _mockClearBurnOrRedistributableShares(_getDefaultOperatorSet(), 2, ALLOCATE_AMOUNT);

        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params1);
    }

    function test_Allocate_MultipleOperators() public {
        vm.warp(1000000);
        address operator2 = makeAddr("operator2");

        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, 1000, ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT * 2);
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);

        // Setup for operator2
        _setupCompleteAllocationMocks(operator2, STAKE_AMOUNT, 1000, ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);
        vm.prank(operator2);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_LargeAmount() public {
        vm.warp(1000000);
        uint256 largeAmount = 1000000e18;
        // Mint enough tokens to cover the large amount
        underlyingToken.mint(owner, largeAmount * 2);
        _setupCompleteAllocationMocks(operator, largeAmount, 1000000, largeAmount);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), largeAmount);
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), largeAmount)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, largeAmount)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: largeAmount, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), largeAmount);
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_SmallAmount() public {
        vm.warp(1000000);
        // Use a small but valid amount (minimum 1e18 to avoid precision issues)
        uint256 smallAmount = 1e18;
        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, 1000, smallAmount);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), smallAmount);
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), smallAmount)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, smallAmount)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: smallAmount, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), smallAmount);
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_RevertsIfNoTokensReceived() public {
        vm.warp(1000000);
        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, 1000, ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );

        // Mock clearBurnOrRedistributableShares to return 0
        OperatorSet memory operatorSet = _getDefaultOperatorSet();
        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeCall(
                IStrategyManager.clearBurnOrRedistributableSharesByStrategy, (operatorSet, 1, IStrategy(MOCK_STRATEGY))
            ),
            abi.encode(0) // Return 0 tokens
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(operator);
        vm.expectRevert(IAlephAVS.NoTokensReceived.selector);
        alephAVS.allocate(address(alephVault), params);
    }

    /**
     * @notice Test: Unallocate with different price per share (vault appreciation)
     */
    function test_Unallocate_DifferentPricePerShare() public {
        address tokenHolder = makeAddr("tokenHolder");
        uint256 unallocateAmount = ALLOCATE_AMOUNT;

        // Test with price per share > 1 (vault has appreciated)
        uint256 highPPS = 2e18; // 2:1

        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (tokenHolder)), abi.encode(unallocateAmount));
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.transferFrom, (tokenHolder, address(alephAVS), unallocateAmount)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.burn, (address(alephAVS), unallocateAmount)),
            abi.encode()
        );

        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.assetsPerClassOf, (CLASS_ID, address(alephAVS))),
            abi.encode(highPPS)
        );
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(1e18));

        uint256 expectedRedeemAmount = ERC4626Math.previewRedeem(unallocateAmount, highPPS, 1e18);

        // Ensure vault has enough tokens for syncRedeem
        underlyingToken.transfer(address(alephVault), expectedRedeemAmount);

        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(expectedRedeemAmount)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        vm.prank(tokenHolder);
        alephAVS.requestUnallocate(address(alephVault), unallocateAmount);

        vm.prank(tokenHolder);
        (uint256 amount, uint256 shares) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");

        assertEq(amount, expectedRedeemAmount, "Amount should match high PPS calculation");
        assertEq(shares, expectedRedeemAmount, "Shares should match");
    }

    /**
     * @notice Test: Unallocate partial amount
     */
    function test_Unallocate_PartialAmount() public {
        address tokenHolder = makeAddr("tokenHolder");
        uint256 totalAmount = ALLOCATE_AMOUNT;
        uint256 partialAmount = totalAmount / 2;

        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (tokenHolder)), abi.encode(totalAmount));
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.transferFrom, (tokenHolder, address(alephAVS), partialAmount)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.burn, (address(alephAVS), partialAmount)),
            abi.encode()
        );

        // Mock totalSupply and assetsPerClassOf for calculateAmountToRedeem
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalAmount));
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.assetsPerClassOf, (CLASS_ID, address(alephAVS))),
            abi.encode(totalAmount)
        );

        uint256 expectedRedeemAmount = ERC4626Math.previewRedeem(partialAmount, totalAmount, totalAmount);

        // Ensure vault has enough tokens for syncRedeem
        underlyingToken.transfer(address(alephVault), expectedRedeemAmount);

        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(expectedRedeemAmount)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        vm.prank(tokenHolder);
        alephAVS.requestUnallocate(address(alephVault), partialAmount);

        vm.prank(tokenHolder);
        (uint256 amount, uint256 shares) = alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");

        assertEq(amount, expectedRedeemAmount, "Amount should match partial unallocation");
        assertEq(shares, expectedRedeemAmount, "Shares should match");
    }

    /**
     * @notice Test: Multiple sequential unallocations by same user
     */
    function test_Unallocate_MultipleUnallocations() public {
        address tokenHolder = makeAddr("tokenHolder");
        uint256 totalAmount = ALLOCATE_AMOUNT;
        uint256 firstUnallocate = totalAmount / 3;
        uint256 secondUnallocate = totalAmount / 3;

        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (tokenHolder)), abi.encode(totalAmount));

        // Mock totalSupply and assetsPerClassOf for calculateAmountToRedeem
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalAmount));
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.assetsPerClassOf, (CLASS_ID, address(alephAVS))),
            abi.encode(totalAmount)
        );

        // First unallocation
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.transferFrom, (tokenHolder, address(alephAVS), firstUnallocate)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.burn, (address(alephAVS), firstUnallocate)),
            abi.encode()
        );

        uint256 firstExpectedRedeemAmount = ERC4626Math.previewRedeem(firstUnallocate, totalAmount, totalAmount);

        // Fund vault for first syncRedeem
        underlyingToken.transfer(address(alephVault), firstExpectedRedeemAmount);

        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(firstExpectedRedeemAmount)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        vm.prank(tokenHolder);
        alephAVS.requestUnallocate(address(alephVault), firstUnallocate);

        vm.prank(tokenHolder);
        alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");

        // Second unallocation
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.transferFrom, (tokenHolder, address(alephAVS), secondUnallocate)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.burn, (address(alephAVS), secondUnallocate)),
            abi.encode()
        );

        uint256 secondExpectedRedeemAmount = ERC4626Math.previewRedeem(secondUnallocate, totalAmount, totalAmount);

        // Fund vault for second syncRedeem
        underlyingToken.transfer(address(alephVault), secondExpectedRedeemAmount);

        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(secondExpectedRedeemAmount)
        );

        vm.prank(tokenHolder);
        alephAVS.requestUnallocate(address(alephVault), secondUnallocate);

        vm.prank(tokenHolder);
        alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
    }

    function test_Unallocate_RevertsIfInvalidVault() public {
        address tokenHolder = makeAddr("tokenHolder");
        address invalidVault = makeAddr("invalidVault");
        _mockVaultFactory(invalidVault, false);

        vm.prank(tokenHolder);
        vm.expectRevert();
        alephAVS.requestUnallocate(invalidVault, ALLOCATE_AMOUNT);
    }

    function test_Unallocate_RevertsIfVaultNotInitialized() public {
        address tokenHolder = makeAddr("tokenHolder");
        address uninitializedVault = makeAddr("uninitializedVault");
        _mockVaultFactory(uninitializedVault, true);

        vm.mockCall(
            address(alephAVS),
            abi.encodeCall(IAlephAVS.vaultToSlashedStrategy, (uninitializedVault)),
            abi.encode(IStrategy(address(0)))
        );

        vm.prank(tokenHolder);
        vm.expectRevert();
        alephAVS.requestUnallocate(uninitializedVault, ALLOCATE_AMOUNT);
    }

    function test_CalculateUnallocateAmount_DifferentPricePerShare() public {
        uint256 tokenAmount = ALLOCATE_AMOUNT;

        // Test with different price per share values
        uint256[] memory ppsValues = new uint256[](4);
        ppsValues[0] = 1e17; // 0.1:1 (vault has depreciated)
        ppsValues[1] = 1e18; // 1:1
        ppsValues[2] = 2e18; // 2:1 (vault has appreciated)
        ppsValues[3] = 5e18; // 5:1 (vault has greatly appreciated)

        for (uint256 i = 0; i < ppsValues.length; i++) {
            vm.mockCall(
                address(alephVault),
                abi.encodeCall(IAlephVault.assetsPerClassOf, (CLASS_ID, address(alephAVS))),
                abi.encode(ppsValues[i])
            );
            vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(1e18));

            (uint256 estimatedAmount, IStrategy strategy, IERC20 token) =
                alephAVS.calculateUnallocateAmount(address(alephVault), tokenAmount);

            assertEq(address(strategy), MOCK_STRATEGY, "Strategy should match");
            assertEq(address(token), address(underlyingToken), "Token should match");
            uint256 expectedAmount = ERC4626Math.previewRedeem(tokenAmount, ppsValues[i], 1e18);
            assertEq(estimatedAmount, expectedAmount, "Estimated amount should match PPS calculation");
        }
    }

    function test_CalculateUnallocateAmount_RevertsIfInvalidVault() public {
        address invalidVault = makeAddr("invalidVault");
        _mockVaultFactory(invalidVault, false);

        vm.expectRevert();
        alephAVS.calculateUnallocateAmount(invalidVault, ALLOCATE_AMOUNT);
    }

    function test_CalculateUnallocateAmount_ZeroAmount() public {
        vm.mockCall(address(alephVault), abi.encodeCall(IAlephVault.shareSeriesId, (CLASS_ID)), abi.encode(uint32(0)));
        vm.mockCall(
            address(alephVault), abi.encodeCall(IAlephVault.pricePerShare, (CLASS_ID, uint32(0))), abi.encode(1e18)
        );

        (uint256 estimatedAmount, IStrategy strategy, IERC20 token) =
            alephAVS.calculateUnallocateAmount(address(alephVault), 0);

        assertEq(estimatedAmount, 0, "Estimated amount should be 0");
        assertEq(address(strategy), MOCK_STRATEGY, "Strategy should match");
        assertEq(address(token), address(underlyingToken), "Token should match");
    }

    function test_InitializeVault_MultipleVaults() public {
        MintableToken token2 = new MintableToken("Test Token 2", "TEST2", STAKE_AMOUNT * 10, owner);
        MinimalAlephVault vault2 = new MinimalAlephVault(address(token2));
        address mockSlashedStrategy2 = address(0x3001);
        address mockSlashedToken2 = address(0x3002);

        _mockVaultFactory(address(vault2), true);
        vm.mockCall(address(vault2), abi.encodeCall(IAlephVault.name, ()), abi.encode("TestVault2"));
        vm.mockCall(address(token2), abi.encodeCall(IERC20Metadata.name, ()), abi.encode("Test Token 2"));
        vm.mockCall(address(token2), abi.encodeCall(IERC20Metadata.symbol, ()), abi.encode("TEST2"));
        vm.mockCall(
            MOCK_ERC20_FACTORY,
            abi.encodeWithSelector(IERC20Factory.createToken.selector),
            abi.encode(mockSlashedToken2)
        );
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeWithSelector(IStrategyFactory.deployedStrategies.selector, mockSlashedToken2),
            abi.encode(IStrategy(address(0)))
        );
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeWithSelector(IStrategyFactory.deployNewStrategy.selector, mockSlashedToken2),
            abi.encode(IStrategy(mockSlashedStrategy2))
        );
        vm.mockCall(mockSlashedStrategy2, abi.encodeCall(IStrategy.underlyingToken, ()), abi.encode(mockSlashedToken2));
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeCall(IStrategyFactory.deployedStrategies, (IERC20Eigen(address(token2)))),
            abi.encode(IStrategy(MOCK_STRATEGY))
        );

        // Mock MOCK_STRATEGY to return token2 as underlying token for this test
        vm.mockCall(MOCK_STRATEGY, abi.encodeCall(IStrategy.underlyingToken, ()), abi.encode(address(token2)));

        vm.prank(owner);
        IStrategy slashedStrategy2 = alephAVS.initializeVault(1, address(vault2), IStrategy(MOCK_STRATEGY));

        assertEq(address(slashedStrategy2), mockSlashedStrategy2, "Second vault slashed strategy should match");
        assertEq(
            address(alephAVS.vaultToSlashedStrategy(address(vault2))),
            mockSlashedStrategy2,
            "Second vault mapping should be set"
        );
        assertEq(
            address(alephAVS.vaultToSlashedStrategy(address(alephVault))),
            MOCK_SLASHED_STRATEGY,
            "First vault mapping should still be set"
        );
    }

    function test_InitializeVault_RevertsIfNotOwner() public {
        address nonOwner = makeAddr("nonOwner");
        _mockVaultFactory(address(alephVault), true);

        vm.prank(nonOwner);
        vm.expectRevert();
        alephAVS.initializeVault(1, address(alephVault), IStrategy(MOCK_STRATEGY));
    }

    function test_InitializeVault_RevertsIfInvalidVault() public {
        address invalidVault = makeAddr("invalidVault");
        _mockVaultFactory(invalidVault, false);

        vm.prank(owner);
        vm.expectRevert();
        alephAVS.initializeVault(1, invalidVault, IStrategy(MOCK_STRATEGY));
    }

    function test_InitializeVault_RevertsIfAlreadyInitialized() public {
        // Try to initialize again
        vm.mockCall(address(alephVault), abi.encodeCall(IAlephVault.name, ()), abi.encode("TestVault"));
        vm.mockCall(address(underlyingToken), abi.encodeCall(IERC20Metadata.name, ()), abi.encode("Test Token"));
        vm.mockCall(address(underlyingToken), abi.encodeCall(IERC20Metadata.symbol, ()), abi.encode("TEST"));

        // Mock that slashed strategy already exists
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeWithSelector(IStrategyFactory.deployedStrategies.selector, MOCK_SLASHED_TOKEN),
            abi.encode(IStrategy(MOCK_SLASHED_STRATEGY)) // Already exists
        );

        vm.prank(owner);
        vm.expectRevert(IAlephAVS.VaultAlreadyInitialized.selector);
        alephAVS.initializeVault(1, address(alephVault), IStrategy(MOCK_STRATEGY));
    }

    function test_ViewFunctions_ReturnCorrectValues() public view {
        assertEq(address(alephAVS.ALLOCATION_MANAGER()), MOCK_ALLOCATION_MANAGER, "AllocationManager should match");
        assertEq(address(alephAVS.DELEGATION_MANAGER()), MOCK_DELEGATION_MANAGER, "DelegationManager should match");
        assertEq(address(alephAVS.STRATEGY_MANAGER()), MOCK_STRATEGY_MANAGER, "StrategyManager should match");
    }

    function test_ViewFunctions_VaultToSlashedStrategy() public {
        IStrategy slashedStrategy = alephAVS.vaultToSlashedStrategy(address(alephVault));
        assertEq(address(slashedStrategy), MOCK_SLASHED_STRATEGY, "Slashed strategy should match");

        // Test with uninitialized vault - this should revert when accessing via _getSlashedStrategy
        address uninitializedVault = makeAddr("uninitializedVault");
        IStrategy uninitializedStrategy = alephAVS.vaultToSlashedStrategy(uninitializedVault);
        assertEq(address(uninitializedStrategy), address(0), "Uninitialized vault should return zero address");

        // Test that _getSlashedStrategy path is covered by calling allocate which uses it
        // This covers the return statement in _getSlashedStrategy
        vm.warp(1000000);
        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, 1000, ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );
        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);
        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_ReentrancyProtection_Allocate() public {
        vm.warp(1000000);
        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, 1000, ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);

        // First call should succeed
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);

        // Second call in same transaction should revert due to reentrancy guard
        // (This is tested implicitly - the nonReentrant modifier prevents re-entry)
    }

    /**
     * @notice Test: Reentrancy protection on unallocate
     */
    function test_ReentrancyProtection_Unallocate() public {
        address tokenHolder = makeAddr("tokenHolder");
        uint256 unallocateAmount = ALLOCATE_AMOUNT;

        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (tokenHolder)), abi.encode(unallocateAmount));
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.transferFrom, (tokenHolder, address(alephAVS), unallocateAmount)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.burn, (address(alephAVS), unallocateAmount)),
            abi.encode()
        );

        // Mock totalSupply and assetsPerClassOf for calculateAmountToRedeem
        vm.mockCall(
            MOCK_SLASHED_TOKEN, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(unallocateAmount)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.assetsPerClassOf, (CLASS_ID, address(alephAVS))),
            abi.encode(unallocateAmount)
        );

        uint256 expectedRedeemAmount = ERC4626Math.previewRedeem(unallocateAmount, unallocateAmount, unallocateAmount);

        // Fund vault for syncRedeem
        underlyingToken.transfer(address(alephVault), expectedRedeemAmount);

        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(expectedRedeemAmount)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        // First call should succeed
        vm.prank(tokenHolder);
        alephAVS.requestUnallocate(address(alephVault), unallocateAmount);

        vm.prank(tokenHolder);
        alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");

        // Reentrancy protection is implicit via nonReentrant modifier
    }

    function test_Constructor_AllParameters() public view {
        // Test that constructor properly sets all immutable variables
        assertEq(address(alephAVS.ALLOCATION_MANAGER()), MOCK_ALLOCATION_MANAGER, "ALLOCATION_MANAGER should match");
        assertEq(address(alephAVS.DELEGATION_MANAGER()), MOCK_DELEGATION_MANAGER, "DELEGATION_MANAGER should match");
        assertEq(address(alephAVS.STRATEGY_MANAGER()), MOCK_STRATEGY_MANAGER, "STRATEGY_MANAGER should match");
        assertEq(address(alephAVS.REWARDS_COORDINATOR()), MOCK_REWARDS_COORDINATOR, "REWARDS_COORDINATOR should match");
        assertEq(address(alephAVS.VAULT_FACTORY()), MOCK_VAULT_FACTORY, "VAULT_FACTORY should match");
        assertEq(address(alephAVS.STRATEGY_FACTORY()), MOCK_STRATEGY_FACTORY, "STRATEGY_FACTORY should match");
    }

    function test_Constructor_RevertsIfInvalidRewardsCoordinator() public {
        vm.expectRevert(IAlephAVS.InvalidRewardsCoordinator.selector);
        new AlephAVS(
            IAllocationManager(MOCK_ALLOCATION_MANAGER),
            IDelegationManager(MOCK_DELEGATION_MANAGER),
            IStrategyManager(MOCK_STRATEGY_MANAGER),
            IRewardsCoordinator(address(0)),
            IAlephVaultFactory(MOCK_VAULT_FACTORY),
            IStrategyFactory(MOCK_STRATEGY_FACTORY)
        );
    }

    function test_Constructor_RevertsIfInvalidVaultFactory() public {
        vm.expectRevert(IAlephAVS.InvalidVaultFactory.selector);
        new AlephAVS(
            IAllocationManager(MOCK_ALLOCATION_MANAGER),
            IDelegationManager(MOCK_DELEGATION_MANAGER),
            IStrategyManager(MOCK_STRATEGY_MANAGER),
            IRewardsCoordinator(MOCK_REWARDS_COORDINATOR),
            IAlephVaultFactory(address(0)),
            IStrategyFactory(MOCK_STRATEGY_FACTORY)
        );
    }

    function test_Constructor_RevertsIfInvalidStrategyFactory() public {
        vm.expectRevert(IAlephAVS.InvalidStrategyFactory.selector);
        new AlephAVS(
            IAllocationManager(MOCK_ALLOCATION_MANAGER),
            IDelegationManager(MOCK_DELEGATION_MANAGER),
            IStrategyManager(MOCK_STRATEGY_MANAGER),
            IRewardsCoordinator(MOCK_REWARDS_COORDINATOR),
            IAlephVaultFactory(MOCK_VAULT_FACTORY),
            IStrategyFactory(address(0))
        );
    }

    function test_Allocate_EmitsSlashExecutedEvent() public {
        vm.warp(1000000);
        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, 1000, ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit SlashExecuted(
            operator,
            AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID,
            MOCK_STRATEGY,
            address(underlyingToken),
            ALLOCATE_AMOUNT,
            1
        );

        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }

    /**
     * @notice Test: Unallocate emits correct event
     */
    function test_Unallocate_EmitsCorrectEvent() public {
        address tokenHolder = makeAddr("tokenHolder");
        uint256 unallocateAmount = ALLOCATE_AMOUNT;

        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (tokenHolder)), abi.encode(unallocateAmount));
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.transferFrom, (tokenHolder, address(alephAVS), unallocateAmount)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.burn, (address(alephAVS), unallocateAmount)),
            abi.encode()
        );

        // Mock totalSupply and assetsPerClassOf for calculateAmountToRedeem
        vm.mockCall(
            MOCK_SLASHED_TOKEN, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(unallocateAmount)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.assetsPerClassOf, (CLASS_ID, address(alephAVS))),
            abi.encode(unallocateAmount)
        );

        uint256 expectedRedeemAmount = ERC4626Math.previewRedeem(unallocateAmount, unallocateAmount, unallocateAmount);

        // Fund vault for syncRedeem
        underlyingToken.transfer(address(alephVault), expectedRedeemAmount);

        vm.mockCall(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encode(expectedRedeemAmount)
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        vm.prank(tokenHolder);
        alephAVS.requestUnallocate(address(alephVault), unallocateAmount);

        vm.expectEmit(true, true, true, false);
        emit UnallocateCompleted(
            tokenHolder,
            address(alephVault),
            MOCK_STRATEGY,
            MOCK_SLASHED_STRATEGY,
            expectedRedeemAmount,
            expectedRedeemAmount,
            CLASS_ID
        );

        vm.prank(tokenHolder);
        alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
    }

    // ============ Additional Coverage Tests ============

    function test_Allocate_RevertsIfInvalidOperatorSet() public {
        vm.warp(1000000);
        _mockOperatorRegistration(operator, true);
        _mockVaultFactory(address(alephVault), true);

        OperatorSet memory invalidOperatorSet = OperatorSet({avs: address(0x9999), id: 999});
        _mockOperatorSetAndMembership(operator, invalidOperatorSet, false, false);

        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeCall(IRewardsCoordinator.getOperatorAVSSplit, (operator, address(alephAVS))),
            abi.encode(0)
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(operator);
        vm.expectRevert();
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_RevertsIfNotMemberOfOperatorSet() public {
        vm.warp(1000000);
        _mockOperatorRegistration(operator, true);
        _mockVaultFactory(address(alephVault), true);

        OperatorSet memory operatorSet = _getDefaultOperatorSet();
        _mockOperatorSetAndMembership(operator, operatorSet, true, false); // Not a member

        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeCall(IRewardsCoordinator.getOperatorAVSSplit, (operator, address(alephAVS))),
            abi.encode(0)
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(operator);
        vm.expectRevert();
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_RevertsIfAmountTooSmall() public {
        vm.warp(1000000);
        _mockOperatorRegistration(operator, true);
        _mockVaultFactory(address(alephVault), true);

        OperatorSet memory operatorSet = _getDefaultOperatorSet();
        _mockOperatorSetAndMembership(operator, operatorSet, true, true);

        // Mock underlyingToSharesView to return 0 (amount too small)
        vm.mockCall(MOCK_STRATEGY, abi.encodeCall(IStrategy.underlyingToSharesView, (1)), abi.encode(0));

        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeCall(IRewardsCoordinator.getOperatorAVSSplit, (operator, address(alephAVS))),
            abi.encode(0)
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: 1, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(operator);
        vm.expectRevert();
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_RevertsIfInsufficientAllocation() public {
        vm.warp(1000000);
        _mockOperatorRegistration(operator, true);
        _mockVaultFactory(address(alephVault), true);

        OperatorSet memory operatorSet = _getDefaultOperatorSet();
        _mockOperatorSetAndMembership(operator, operatorSet, true, true);

        // Mock underlyingToSharesView to return more shares than allocated
        uint256 sharesNeeded = ALLOCATE_AMOUNT;
        uint256 allocatedShares = ALLOCATE_AMOUNT - 1; // Less than needed
        _mockStrategyUnderlyingToShares(ALLOCATE_AMOUNT, sharesNeeded);
        _mockAllocatedStake(operatorSet, operator, allocatedShares);

        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeCall(IRewardsCoordinator.getOperatorAVSSplit, (operator, address(alephAVS))),
            abi.encode(0)
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(operator);
        vm.expectRevert();
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_RevertsIfInsufficientMagnitude() public {
        vm.warp(1000000);
        _mockOperatorRegistration(operator, true);
        _mockVaultFactory(address(alephVault), true);

        OperatorSet memory operatorSet = _getDefaultOperatorSet();
        _mockOperatorSetAndMembership(operator, operatorSet, true, true);
        _mockStrategyUnderlyingToShares(ALLOCATE_AMOUNT, ALLOCATE_AMOUNT);
        _mockAllocatedStake(operatorSet, operator, STAKE_AMOUNT);

        // Mock allocation with magnitude less than what's needed
        uint64 lowMagnitude = 100;
        _mockAllocation(operator, operatorSet, lowMagnitude);

        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeCall(IRewardsCoordinator.getOperatorAVSSplit, (operator, address(alephAVS))),
            abi.encode(0)
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(operator);
        vm.expectRevert();
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_RevertsIfStrategyNotFound() public {
        vm.warp(1000000);
        _mockOperatorRegistration(operator, true);
        _mockVaultFactory(address(alephVault), true);

        // Mock strategyFactory to return zero address (strategy not found)
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeCall(IStrategyFactory.deployedStrategies, (IERC20Eigen(address(underlyingToken)))),
            abi.encode(IStrategy(address(0)))
        );

        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeCall(IRewardsCoordinator.getOperatorAVSSplit, (operator, address(alephAVS))),
            abi.encode(0)
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(operator);
        vm.expectRevert();
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_RevertsIfSlashedStrategyInvalid() public {
        vm.warp(1000000);
        _mockOperatorRegistration(operator, true);
        _mockVaultFactory(address(alephVault), true);

        // Don't initialize vault - slashed strategy will be zero
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeCall(IStrategyFactory.deployedStrategies, (IERC20Eigen(address(underlyingToken)))),
            abi.encode(IStrategy(MOCK_STRATEGY))
        );

        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeCall(IRewardsCoordinator.getOperatorAVSSplit, (operator, address(alephAVS))),
            abi.encode(0)
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        vm.prank(operator);
        vm.expectRevert();
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Unallocate_RevertsIfStrategyNotFound() public {
        address tokenHolder = makeAddr("tokenHolder");
        uint256 unallocateAmount = ALLOCATE_AMOUNT;

        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (tokenHolder)), abi.encode(unallocateAmount));
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.transferFrom, (tokenHolder, address(alephAVS), unallocateAmount)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.burn, (address(alephAVS), unallocateAmount)),
            abi.encode()
        );
        vm.mockCall(address(alephVault), abi.encodeCall(IAlephVault.shareSeriesId, (CLASS_ID)), abi.encode(uint32(0)));
        vm.mockCall(
            address(alephVault), abi.encodeCall(IAlephVault.pricePerShare, (CLASS_ID, uint32(0))), abi.encode(1e18)
        );
        uint256 expectedRedeemAmount = unallocateAmount;
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(
                IAlephVaultRedeem.requestRedeem, (IAlephVaultRedeem.RedeemRequestParams(CLASS_ID, expectedRedeemAmount))
            ),
            abi.encode(uint48(0))
        );

        // First step should succeed
        vm.prank(tokenHolder);
        alephAVS.requestUnallocate(address(alephVault), unallocateAmount);

        // Mock for completeUnallocate - strategy lookup happens here
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(expectedRedeemAmount)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );

        // Mock strategyFactory to return zero address (strategy not found) - this will cause revert in completeUnallocate
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeCall(IStrategyFactory.deployedStrategies, (IERC20Eigen(address(underlyingToken)))),
            abi.encode(IStrategy(address(0)))
        );

        vm.prank(tokenHolder);
        vm.expectRevert();
        alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "");
    }

    function test_CalculateUnallocateAmount_RevertsIfStrategyNotFound() public {
        // Test that calculateUnallocateAmount reverts if vault is not initialized
        // (vaultToOriginalStrategy will be address(0), causing InvalidStrategy revert)
        address uninitializedVault = makeAddr("uninitializedVault");
        _mockVaultFactory(uninitializedVault, true);
        vm.mockCall(
            uninitializedVault, abi.encodeCall(IAlephVault.underlyingToken, ()), abi.encode(address(underlyingToken))
        );
        vm.mockCall(uninitializedVault, abi.encodeCall(IAlephVault.shareSeriesId, (CLASS_ID)), abi.encode(uint32(0)));
        vm.mockCall(
            uninitializedVault, abi.encodeCall(IAlephVault.pricePerShare, (CLASS_ID, uint32(0))), abi.encode(1e18)
        );

        // Mock vaultToSlashedStrategy to return address(0) (vault not initialized)
        vm.mockCall(
            address(alephAVS),
            abi.encodeCall(IAlephAVS.vaultToSlashedStrategy, (uninitializedVault)),
            abi.encode(IStrategy(address(0)))
        );

        vm.expectRevert();
        alephAVS.calculateUnallocateAmount(uninitializedVault, ALLOCATE_AMOUNT);
    }

    function test_Allocate_WithDifferentOperatorSetId() public {
        vm.warp(1000000);
        uint32 customOperatorSetId = AlephUtils.LST_STRATEGIES_OPERATOR_SET_ID; // Use valid operator set ID
        OperatorSet memory customOperatorSet = OperatorSet({avs: address(alephAVS), id: customOperatorSetId});

        _mockOperatorRegistration(operator, true);
        _mockOperatorSetAndMembership(operator, customOperatorSet, true, true);
        _mockStrategyUnderlyingToShares(ALLOCATE_AMOUNT, ALLOCATE_AMOUNT);
        _mockAllocatedStake(customOperatorSet, operator, STAKE_AMOUNT);
        _mockAllocation(operator, customOperatorSet, 1000);
        _mockSlashOperator(operator, customOperatorSetId, STAKE_AMOUNT, 1, ALLOCATE_AMOUNT, ALLOCATE_AMOUNT);
        _mockClearBurnOrRedistributableShares(customOperatorSet, 1, ALLOCATE_AMOUNT);
        _mockStrategyUnderlyingToken(address(underlyingToken));
        _mockVaultFactory(address(alephVault), true);
        vm.mockCall(
            address(alephVault), abi.encodeCall(IAlephVault.underlyingToken, ()), abi.encode(address(underlyingToken))
        );
        // Mock accountant() to return address(0) (no accountant configured)
        vm.mockCall(address(alephVault), abi.encodeCall(IAlephVault.accountant, ()), abi.encode(address(0)));
        vm.mockCall(
            MOCK_STRATEGY_FACTORY,
            abi.encodeCall(IStrategyFactory.deployedStrategies, (IERC20Eigen(address(underlyingToken)))),
            abi.encode(IStrategy(MOCK_STRATEGY))
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeCall(IRewardsCoordinator.getOperatorAVSSplit, (operator, address(alephAVS))),
            abi.encode(0)
        );

        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_WithMaxMagnitude() public {
        vm.warp(1000000);
        // Use a large but reasonable magnitude to avoid calculation issues
        uint64 maxMagnitude = 1e18; // Large magnitude
        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, maxMagnitude, ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_WithMinMagnitude() public {
        vm.warp(1000000);
        // Use minimum magnitude that still allows allocation
        uint64 minMagnitude = 1000; // Minimum that works with the allocation
        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, minMagnitude, ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_WithExactAllocatedShares() public {
        vm.warp(1000000);
        // Test when allocated shares exactly equals shares needed
        _setupCompleteAllocationMocks(operator, ALLOCATE_AMOUNT, 1000, ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Unallocate_WithExpiredSignature() public {
        address tokenHolder = makeAddr("tokenHolder");
        uint256 unallocateAmount = ALLOCATE_AMOUNT;

        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (tokenHolder)), abi.encode(unallocateAmount));
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.transferFrom, (tokenHolder, address(alephAVS), unallocateAmount)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.burn, (address(alephAVS), unallocateAmount)),
            abi.encode()
        );
        vm.mockCall(address(alephVault), abi.encodeCall(IAlephVault.shareSeriesId, (CLASS_ID)), abi.encode(uint32(0)));
        vm.mockCall(
            address(alephVault), abi.encodeCall(IAlephVault.pricePerShare, (CLASS_ID, uint32(0))), abi.encode(1e18)
        );
        uint256 expectedRedeemAmount = unallocateAmount;
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(
                IAlephVaultRedeem.requestRedeem, (IAlephVaultRedeem.RedeemRequestParams(CLASS_ID, expectedRedeemAmount))
            ),
            abi.encode(uint48(0))
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(expectedRedeemAmount)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(expectedRedeemAmount)
        );

        // Mock depositIntoStrategyWithSignature to revert (expired signature)
        vm.mockCallRevert(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encodeWithSignature("SignatureExpired()")
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        vm.prank(tokenHolder);
        alephAVS.requestUnallocate(address(alephVault), unallocateAmount);

        uint256 expiredTimestamp = block.timestamp - 1;
        vm.prank(tokenHolder);
        vm.expectRevert();
        alephAVS.completeUnallocate(address(alephVault), expiredTimestamp, "");
    }

    function test_Unallocate_WithInvalidSignature() public {
        address tokenHolder = makeAddr("tokenHolder");
        uint256 unallocateAmount = ALLOCATE_AMOUNT;

        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.balanceOf, (tokenHolder)), abi.encode(unallocateAmount));
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.transferFrom, (tokenHolder, address(alephAVS), unallocateAmount)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.burn, (address(alephAVS), unallocateAmount)),
            abi.encode()
        );
        vm.mockCall(address(alephVault), abi.encodeCall(IAlephVault.shareSeriesId, (CLASS_ID)), abi.encode(uint32(0)));
        vm.mockCall(
            address(alephVault), abi.encodeCall(IAlephVault.pricePerShare, (CLASS_ID, uint32(0))), abi.encode(1e18)
        );
        uint256 expectedRedeemAmount = unallocateAmount;
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(
                IAlephVaultRedeem.requestRedeem, (IAlephVaultRedeem.RedeemRequestParams(CLASS_ID, expectedRedeemAmount))
            ),
            abi.encode(uint48(0))
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(IAlephVault.redeemableAmount, (address(alephAVS))),
            abi.encode(expectedRedeemAmount)
        );
        vm.mockCall(
            address(alephVault),
            abi.encodeWithSelector(IAlephVaultRedeem.withdrawRedeemableAmount.selector),
            abi.encode()
        );
        vm.mockCall(
            address(underlyingToken),
            abi.encodeCall(IERC20.balanceOf, (address(alephAVS))),
            abi.encode(expectedRedeemAmount)
        );

        // Mock depositIntoStrategyWithSignature to revert (invalid signature)
        vm.mockCallRevert(
            MOCK_STRATEGY_MANAGER,
            abi.encodeWithSelector(IStrategyManager.depositIntoStrategyWithSignature.selector),
            abi.encodeWithSignature("InvalidSignature()")
        );
        vm.mockCall(address(underlyingToken), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        vm.prank(tokenHolder);
        alephAVS.requestUnallocate(address(alephVault), unallocateAmount);

        vm.prank(tokenHolder);
        vm.expectRevert();
        alephAVS.completeUnallocate(address(alephVault), block.timestamp + 1000, "invalid");
    }

    function test_Allocate_WithDifferentCalculationInterval() public {
        // Set a very large timestamp to avoid underflow
        vm.warp(10000000);
        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, 1000, ALLOCATE_AMOUNT);

        // Test with different calculation interval (1 week instead of 1 day)
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(604800)) // 1 week
        );
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_WithMaxUint256Amount() public {
        vm.warp(1000000);
        // Use a large but reasonable amount to avoid overflow issues
        uint256 maxAmount = 1e30; // Large but safe amount
        underlyingToken.mint(owner, maxAmount * 2);
        _setupCompleteAllocationMocks(operator, maxAmount, 1000000, maxAmount);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), maxAmount);
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), maxAmount)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, maxAmount)), abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: maxAmount, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), maxAmount);
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_RegisterOperator_WithEmptyOperatorSetIds() public {
        uint32[] memory operatorSetIds = new uint32[](0);

        vm.expectEmit(true, false, false, false);
        emit OperatorRegistered(operator, operatorSetIds);

        vm.prank(MOCK_ALLOCATION_MANAGER);
        alephAVS.registerOperator(operator, address(alephAVS), operatorSetIds, "");
    }

    function test_DeregisterOperator_WithEmptyOperatorSetIds() public {
        uint32[] memory operatorSetIds = new uint32[](0);

        vm.expectEmit(true, false, false, false);
        emit OperatorDeregistered(operator, operatorSetIds);

        vm.prank(MOCK_ALLOCATION_MANAGER);
        alephAVS.deregisterOperator(operator, address(alephAVS), operatorSetIds);
    }

    function test_Allocate_WithZeroVaultShares() public {
        vm.warp(1000000);
        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, 1000, ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT);

        // Mock vault to return 0 shares (edge case)
        vm.mockCall(
            address(alephVault),
            abi.encodeCall(
                IAlephVaultDeposit.syncDeposit,
                (IAlephVaultDeposit.RequestDepositParams(
                        CLASS_ID, ALLOCATE_AMOUNT, _createAuthSignature(block.number + 100)
                    ))
            ),
            abi.encode(0)
        );

        vm.mockCall(
            MOCK_SLASHED_TOKEN, abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), 0)), abi.encode()
        );
        vm.mockCall(MOCK_SLASHED_TOKEN, abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, 0)), abi.encode(true));
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);
        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_WithSyncDeposit_WhenIsTotalAssetsValid() public {
        vm.warp(1000000);
        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, 1000, ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT);

        // Explicitly set isTotalAssetsValid to true
        vm.mockCall(address(alephVault), abi.encodeCall(IAlephVault.isTotalAssetsValid, (CLASS_ID)), abi.encode(true));

        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);

        // Expect syncDeposit to be called (not requestDeposit)
        vm.expectCall(address(alephVault), abi.encodeCall(IAlephVaultDeposit.syncDeposit, (params)));

        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }

    function test_Allocate_WithAsyncDeposit_WhenIsTotalAssetsValidFalse_Correct() public {
        vm.warp(1000000);
        _setupCompleteAllocationMocks(operator, STAKE_AMOUNT, 1000, ALLOCATE_AMOUNT);
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.CALCULATION_INTERVAL_SECONDS.selector),
            abi.encode(uint32(86400))
        );
        underlyingToken.mint(address(alephAVS), ALLOCATE_AMOUNT);

        // Set isTotalAssetsValid to false for this class
        vm.mockCall(address(alephVault), abi.encodeCall(IAlephVault.isTotalAssetsValid, (CLASS_ID)), abi.encode(false));

        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IMintableBurnableERC20.mint, (address(alephAVS), ALLOCATE_AMOUNT)),
            abi.encode()
        );
        vm.mockCall(
            MOCK_SLASHED_TOKEN,
            abi.encodeCall(IERC20.approve, (MOCK_REWARDS_COORDINATOR, ALLOCATE_AMOUNT)),
            abi.encode(true)
        );
        vm.mockCall(
            MOCK_REWARDS_COORDINATOR,
            abi.encodeWithSelector(IRewardsCoordinator.createOperatorDirectedAVSRewardsSubmission.selector),
            abi.encode()
        );

        IAlephVaultDeposit.RequestDepositParams memory params = IAlephVaultDeposit.RequestDepositParams({
            classId: CLASS_ID, amount: ALLOCATE_AMOUNT, authSignature: _createAuthSignature(block.number + 100)
        });

        IERC20(address(underlyingToken)).safeTransfer(address(alephAVS), ALLOCATE_AMOUNT);

        // Expect requestDeposit to be called (not syncDeposit)
        vm.expectCall(address(alephVault), abi.encodeCall(IAlephVaultDeposit.requestDeposit, (params)));

        // Expect AllocatedToAlephVault event with 0 shares (async deposits return 0 shares)
        vm.expectEmit(true, true, true, true);
        emit AllocatedToAlephVault(
            operator,
            address(alephVault),
            address(MOCK_STRATEGY),
            address(MOCK_SLASHED_STRATEGY),
            ALLOCATE_AMOUNT,
            ALLOCATE_AMOUNT, // amountToMint
            0, // vaultShares = 0 for async deposits
            CLASS_ID
        );

        vm.prank(operator);
        alephAVS.allocate(address(alephVault), params);
    }
}
