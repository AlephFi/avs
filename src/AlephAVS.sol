// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IAlephAVS} from "./IAlephAVS.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IAllocationManagerTypes} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IStrategyFactory} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyFactory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20 as IERC20Eigen} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import {IAlephVaultDeposit} from "Aleph/src/interfaces/IAlephVaultDeposit.sol";
import {IAlephVaultFactory} from "Aleph/src/interfaces/IAlephVaultFactory.sol";
import {IAlephVault} from "Aleph/src/interfaces/IAlephVault.sol";
import {IAlephVaultRedeem} from "Aleph/src/interfaces/IAlephVaultRedeem.sol";
import {IAccountant} from "Aleph/src/interfaces/IAccountant.sol";
import {IERC20Factory} from "./interfaces/IERC20Factory.sol";
import {ERC20Factory} from "./ERC20Factory.sol";
import {AlephAVSPausable} from "./AlephAVSPausable.sol";
import {IMintableBurnableERC20} from "./interfaces/IMintableBurnableERC20.sol";
import {AlephSlashing} from "./libraries/AlephSlashing.sol";
import {AlephVaultManagement} from "./libraries/AlephVaultManagement.sol";
import {RewardsManagement} from "./libraries/RewardsManagement.sol";
import {AlephValidation} from "./libraries/AlephValidation.sol";

contract AlephAVS is IAlephAVS, AlephAVSPausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OWNER = keccak256("OWNER");

    uint32 private constant LST_STRATEGIES_OPERATOR_SET_ID = 0;

    IAllocationManager public immutable ALLOCATION_MANAGER;
    IDelegationManager public immutable DELEGATION_MANAGER;
    IStrategyManager public immutable STRATEGY_MANAGER;
    IRewardsCoordinator public immutable REWARDS_COORDINATOR;
    IAlephVaultFactory public immutable VAULT_FACTORY;
    IStrategyFactory public immutable STRATEGY_FACTORY;

    struct AVSStorage {
        IERC20Factory erc20Factory;
        mapping(address vault => IStrategy slashedStrategy) vaultToSlashedStrategy;
        mapping(address vault => IStrategy originalStrategy) vaultToOriginalStrategy;
        mapping(address vault => uint8 classId) vaultToClassId;
        mapping(uint32 operatorSetId => mapping(address strategy => bool exists)) strategyExists;
        mapping(address user => mapping(address vault => uint256 estAmountToRedeem)) pendingUnallocate;
        mapping(address vault => uint256 totalEstAmount) totalPendingUnallocate;
        mapping(address vault => uint256 withdrawnAmount) vaultWithdrawnAmount;
    }

    bytes32 private constant AVS_STORAGE_LOCATION = 0x032f19bc7820640f5c22e33241af744bedc756ef7c75496e1c948383db604100;

    function _getAVSStorage() private pure returns (AVSStorage storage $) {
        assembly {
            $.slot := AVS_STORAGE_LOCATION
        }
    }

    string private constant SLASH_DESCRIPTION = "";
    string private constant REWARDS_DESCRIPTION = "";

    function _validVault(address _vault) private view {
        if (_getAVSStorage().vaultToSlashedStrategy[_vault] == IStrategy(address(0))) {
            revert VaultNotInitialized(_vault);
        }
    }

    modifier validVault(address _vault) {
        _validVault(_vault);
        _;
    }

    function _onlyOperator() private view {
        if (!DELEGATION_MANAGER.isOperator(msg.sender)) revert NotRegisteredOperator();
    }

    modifier onlyOperator() {
        _onlyOperator();
        _;
    }

    function _validAmount(uint256 _amount) private pure {
        if (_amount == 0) revert InvalidAmount();
    }

    modifier validAmount(uint256 _amount) {
        _validAmount(_amount);
        _;
    }

    constructor(
        IAllocationManager _allocationManager,
        IDelegationManager _delegationManager,
        IStrategyManager _strategyManager,
        IRewardsCoordinator _rewardsCoordinator,
        IAlephVaultFactory _vaultFactory,
        IStrategyFactory _strategyFactory
    ) {
        if (address(_allocationManager) == address(0)) {
            revert InvalidAllocationManager();
        }
        if (address(_delegationManager) == address(0)) revert InvalidDelegationManager();
        if (address(_strategyManager) == address(0)) revert InvalidStrategyManager();
        if (address(_rewardsCoordinator) == address(0)) revert InvalidRewardsCoordinator();
        if (address(_vaultFactory) == address(0)) revert InvalidVaultFactory();
        if (address(_strategyFactory) == address(0)) revert InvalidStrategyFactory();

        ALLOCATION_MANAGER = _allocationManager;
        DELEGATION_MANAGER = _delegationManager;
        STRATEGY_MANAGER = _strategyManager;
        REWARDS_COORDINATOR = _rewardsCoordinator;
        VAULT_FACTORY = _vaultFactory;
        STRATEGY_FACTORY = _strategyFactory;

        _disableInitializers();
    }

    function initialize(address _owner, address _guardian, string memory _metadataURI) external initializer {
        _initialize(_owner, _guardian, _metadataURI);
    }

    function _initialize(address _owner, address _guardian, string memory _metadataURI) internal onlyInitializing {
        if (_owner == address(0) || _guardian == address(0)) revert InvalidAmount();

        __AccessControl_init();
        _pausableInit(_owner, _guardian);
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(OWNER, _owner);

        ALLOCATION_MANAGER.updateAVSMetadataURI(address(this), _metadataURI);

        _initializeOperatorSet();

        ERC20Factory _erc20Factory = new ERC20Factory(address(this));
        _getAVSStorage().erc20Factory = IERC20Factory(address(_erc20Factory));
    }

    function erc20Factory() external view returns (IERC20Factory) {
        return _getAVSStorage().erc20Factory;
    }

    function vaultToSlashedStrategy(address _vault) external view returns (IStrategy _slashedStrategy) {
        _slashedStrategy = _getAVSStorage().vaultToSlashedStrategy[_vault];
    }

    function vaultToOriginalStrategy(address _vault) external view returns (IStrategy _originalStrategy) {
        _originalStrategy = _getAVSStorage().vaultToOriginalStrategy[_vault];
    }

    /**
     * @notice Returns the pending unallocation status for a user and vault
     * @dev This view function allows users to check if they can call completeUnallocate
     * @param _user The user address to check
     * @param _alephVault The Aleph vault address
     * @return userPendingAmount The user's pending unallocation amount
     * @return totalPendingAmount The total pending unallocation amount for the vault
     * @return vaultBalance The vault's underlying token balance (indicates if syncRedeem will work)
     * @return canComplete Whether the user can complete (has pending and vault has sufficient balance)
     */
    function getPendingUnallocateStatus(address _user, address _alephVault)
        external
        view
        returns (uint256 userPendingAmount, uint256 totalPendingAmount, uint256 vaultBalance, bool canComplete)
    {
        AVSStorage storage $ = _getAVSStorage();
        userPendingAmount = $.pendingUnallocate[_user][_alephVault];
        totalPendingAmount = $.totalPendingUnallocate[_alephVault];

        // Check vault's underlying token balance to see if syncRedeem will work
        address _underlyingToken = IAlephVault(_alephVault).underlyingToken();
        vaultBalance = IERC20(_underlyingToken).balanceOf(_alephVault);

        // User can complete if they have pending amount and vault has enough balance
        canComplete = userPendingAmount > 0 && vaultBalance >= userPendingAmount;
    }

    /**
     * @notice Calculates the expected amount that will be withdrawn in completeUnallocate
     * @dev View function to get expected amount for signature generation.
     *      With the new sync flow, user receives their full pending amount.
     *
     * @param _user The user address to calculate for
     * @param _alephVault The Aleph vault address
     * @return expectedAmount The expected amount (equals user's pending amount)
     */
    function calculateCompleteUnallocateAmount(address _user, address _alephVault)
        external
        view
        returns (uint256 expectedAmount)
    {
        // User receives their full pending amount via syncRedeem
        expectedAmount = _getAVSStorage().pendingUnallocate[_user][_alephVault];
    }

    function registerOperator(
        address _operator,
        address _avs,
        uint32[] calldata _operatorSetIds,
        bytes calldata /* data */
    )
        external
    {
        _validateAVSRegistrarCall(_avs);
        emit OperatorRegistered(_operator, _operatorSetIds);
    }

    function deregisterOperator(address _operator, address _avs, uint32[] calldata _operatorSetIds) external {
        _validateAVSRegistrarCall(_avs);
        emit OperatorDeregistered(_operator, _operatorSetIds);
    }

    function supportsAVS(address _avs) external view returns (bool) {
        return _avs == address(this);
    }

    function initializeVault(uint8 _classId, address _vault, IStrategy _lstStrategy)
        external
        onlyRole(OWNER)
        returns (IStrategy _slashedStrategy)
    {
        AVSStorage storage $ = _getAVSStorage();

        if (!VAULT_FACTORY.isValidVault(_vault)) revert InvalidVault();
        if ($.vaultToSlashedStrategy[_vault] != IStrategy(address(0))) revert VaultAlreadyInitialized();

        // Validate the provided strategy
        AlephValidation.validateStrategy(address(_lstStrategy));

        // Get the original token from the LST strategy's underlying token
        // This is the token that will be used to create the slashed token
        // Note: underlyingToken() returns IERC20Eigen, so we use that type
        IERC20Eigen _originalTokenEigen = _lstStrategy.underlyingToken();
        IERC20 _originalToken = IERC20(address(_originalTokenEigen));

        // Validate that the vault's underlying token matches the LST strategy's underlying token
        if (address(IAlephVault(_vault).underlyingToken()) != address(_originalToken)) {
            revert InvalidStrategy();
        }

        IERC20 _slashedToken;
        (_slashedToken, _slashedStrategy) = AlephVaultManagement.createSlashedStrategyForVault(
            STRATEGY_FACTORY, _vault, _originalToken, $.vaultToSlashedStrategy, $.erc20Factory
        );
        $.vaultToClassId[_vault] = _classId;
        $.vaultToOriginalStrategy[_vault] = _lstStrategy;

        _addStrategyIfNotExists(LST_STRATEGIES_OPERATOR_SET_ID, _lstStrategy);

        emit VaultInitialized(
            _vault, _classId, address(_originalToken), address(_slashedToken), address(_slashedStrategy)
        );
    }

    /// @notice Rescues tokens stuck in the contract
    /// @param _token The token address to rescue
    /// @param _to The recipient address
    /// @param _amount The amount to rescue
    function rescueTokens(address _token, address _to, uint256 _amount) external onlyRole(OWNER) {
        IERC20(_token).transfer(_to, _amount);
    }

    function allocate(address _alephVault, IAlephVaultDeposit.RequestDepositParams calldata _requestDepositParams)
        external
        nonReentrant
        onlyOperator
        whenFlowNotPaused(ALLOCATE_FLOW)
        validVault(_alephVault)
        validAmount(_requestDepositParams.amount)
    {
        RewardsManagement.validateOperatorSplit(REWARDS_COORDINATOR, msg.sender, address(this));

        AVSStorage storage $ = _getAVSStorage();

        if ($.vaultToClassId[_alephVault] != _requestDepositParams.classId) revert InvalidClassId();

        (, IStrategy _stakerStrategy) = _getVaultTokenAndStrategy(_alephVault);
        IStrategy _stakerSlashedStrategy = _getSlashedStrategy(_alephVault);

        uint256 _tokenAmount = _slashAndTransferInternal(
            msg.sender, _requestDepositParams.amount, _stakerStrategy, LST_STRATEGIES_OPERATOR_SET_ID, address(this)
        );

        IERC20Eigen _slashedToken = IERC20Eigen(_stakerSlashedStrategy.underlyingToken());
        uint256 _amountToMint = AlephVaultManagement.calculateAmountToMint(
            _requestDepositParams.classId, _alephVault, address(_slashedToken), _tokenAmount
        );

        uint256 _vaultShares =
            AlephVaultManagement.depositToAlephVault(_alephVault, _requestDepositParams, _tokenAmount);
        IMintableBurnableERC20(address(_slashedToken)).mint(address(this), _amountToMint);

        // Update operator allocations in Accountant for fee distribution
        address _accountant = IAlephVault(_alephVault).accountant();
        if (_accountant != address(0)) {
            IAccountant(_accountant).setOperatorAllocations(_alephVault, msg.sender, _tokenAmount);
        }

        RewardsManagement.submitOperatorDirectedRewards(
            REWARDS_COORDINATOR,
            address(this),
            msg.sender,
            _stakerStrategy,
            _slashedToken,
            _amountToMint,
            REWARDS_DESCRIPTION
        );

        emit AllocatedToAlephVault(
            msg.sender,
            _alephVault,
            address(_stakerStrategy),
            address(_stakerSlashedStrategy),
            _tokenAmount,
            _amountToMint,
            _vaultShares,
            _requestDepositParams.classId
        );
    }

    /**
     * @notice Requests to unallocate funds by burning slashed tokens
     * @dev First step of two-step unallocate flow. Emits UnallocateRequested event for manager notification.
     *      Manager should ensure vault has liquidity before user calls completeUnallocate.
     *
     * @param _alephVault The Aleph vault address to unallocate from
     * @param _tokenAmount The amount of slashed strategy tokens to unallocate
     * @return batchId Always 0 (sync flow)
     * @return estAmountToRedeem The estimated amount that will be redeemed from the vault
     */
    function requestUnallocate(address _alephVault, uint256 _tokenAmount)
        external
        nonReentrant
        whenFlowNotPaused(UNALLOCATE_FLOW)
        validAmount(_tokenAmount)
        validVault(_alephVault)
        returns (uint48 batchId, uint256 estAmountToRedeem)
    {
        AVSStorage storage $ = _getAVSStorage();
        uint8 _classId = $.vaultToClassId[_alephVault];
        IStrategy _slashedStrategy = _getSlashedStrategy(_alephVault);

        estAmountToRedeem = AlephVaultManagement.calculateAmountToRedeem(
            _classId, _alephVault, address(_slashedStrategy.underlyingToken()), _tokenAmount
        );

        if (estAmountToRedeem == 0) revert InvalidAmount();

        AlephVaultManagement.validateAndBurnSlashedTokens(msg.sender, _slashedStrategy, _tokenAmount, address(this));

        // Record pending amount - syncRedeem will be called in completeUnallocate
        batchId = 0;
        $.pendingUnallocate[msg.sender][_alephVault] += estAmountToRedeem;
        $.totalPendingUnallocate[_alephVault] += estAmountToRedeem;

        emit UnallocateRequested(
            msg.sender, _alephVault, address(_slashedStrategy), _tokenAmount, estAmountToRedeem, batchId, _classId
        );

        return (batchId, estAmountToRedeem);
    }

    /**
     * @notice Completes the unallocation by calling syncRedeem and depositing back to strategy
     * @dev Second step of two-step unallocate flow. Manager must ensure vault has liquidity first.
     *
     * @param _alephVault The Aleph vault address to complete unallocation from
     * @param _strategyDepositExpiry The expiry timestamp for the strategy deposit signature
     * @param _strategyDepositSignature The caller's signature for depositing back into the original LST strategy
     * @return _amount The amount of tokens redeemed from the vault and deposited to the strategy
     * @return _shares The shares received in the original LST strategy
     */
    function completeUnallocate(
        address _alephVault,
        uint256 _strategyDepositExpiry,
        bytes calldata _strategyDepositSignature
    )
        external
        nonReentrant
        whenFlowNotPaused(UNALLOCATE_FLOW)
        validVault(_alephVault)
        returns (uint256 _amount, uint256 _shares)
    {
        AVSStorage storage $ = _getAVSStorage();
        uint8 _classId = $.vaultToClassId[_alephVault];
        IStrategy _slashedStrategy = _getSlashedStrategy(_alephVault);
        (IERC20 _vaultToken, IStrategy _originalStrategy) = _getVaultTokenAndStrategy(_alephVault);

        uint256 _userPendingAmount = $.pendingUnallocate[msg.sender][_alephVault];
        if (_userPendingAmount == 0) revert NoPendingUnallocation();

        // Call syncRedeem to get funds from vault
        IAlephVaultRedeem.RedeemRequestParams memory _p =
            IAlephVaultRedeem.RedeemRequestParams({classId: _classId, estAmountToRedeem: _userPendingAmount});
        IAlephVaultRedeem(_alephVault).syncRedeem(_p);

        // User receives their full pending amount
        _amount = _userPendingAmount;

        // Update storage
        $.pendingUnallocate[msg.sender][_alephVault] = 0;
        $.totalPendingUnallocate[_alephVault] -= _userPendingAmount;

        // Deposit to strategy
        _shares = AlephVaultManagement.depositToOriginalStrategy(
            STRATEGY_MANAGER,
            _originalStrategy,
            _vaultToken,
            msg.sender,
            _amount,
            _strategyDepositExpiry,
            _strategyDepositSignature
        );
        emit UnallocateCompleted(
            msg.sender, _alephVault, address(_originalStrategy), address(_slashedStrategy), _amount, _shares, _classId
        );
    }

    function calculateUnallocateAmount(address _alephVault, uint256 _tokenAmount)
        external
        view
        validVault(_alephVault)
        returns (uint256 _estimatedAmount, IStrategy _strategy, IERC20 _token)
    {
        IStrategy _slashedStrategy = _getSlashedStrategy(_alephVault);
        _estimatedAmount = AlephVaultManagement.calculateAmountToRedeem(
            _getAVSStorage().vaultToClassId[_alephVault],
            _alephVault,
            address(_slashedStrategy.underlyingToken()),
            _tokenAmount
        );
        (_token, _strategy) = _getVaultTokenAndStrategy(_alephVault);
    }

    function _addStrategyIfNotExists(uint32 _operatorSetId, IStrategy _strategy) private {
        AVSStorage storage $ = _getAVSStorage();

        if ($.strategyExists[_operatorSetId][address(_strategy)]) return;

        IStrategy[] memory arr = new IStrategy[](1);
        arr[0] = _strategy;
        ALLOCATION_MANAGER.addStrategiesToOperatorSet(address(this), _operatorSetId, arr);

        $.strategyExists[_operatorSetId][address(_strategy)] = true;
    }

    function _slashAndTransferInternal(
        address _operator,
        uint256 _amount,
        IStrategy _strategy,
        uint32 _operatorSetId,
        address _recipient
    ) private returns (uint256 _tokenAmount) {
        OperatorSet memory _operatorSet = OperatorSet(address(this), _operatorSetId);
        if (!ALLOCATION_MANAGER.isOperatorSet(_operatorSet)) revert InvalidOperatorSet();
        if (!ALLOCATION_MANAGER.isMemberOfOperatorSet(_operator, _operatorSet)) revert NotMemberOfOperatorSet();

        uint64 _magnitudeToSlash =
            AlephSlashing.calculateMagnitudeFromAmount(ALLOCATION_MANAGER, _operator, _operatorSet, _amount, _strategy);
        AlephSlashing.verifyOperatorAllocation(
            ALLOCATION_MANAGER, _operator, _operatorSet, _magnitudeToSlash, _strategy
        );

        uint256 _slashId = AlephSlashing.executeSlashAndGetId(
            ALLOCATION_MANAGER,
            address(this),
            _operator,
            _operatorSetId,
            _magnitudeToSlash,
            _strategy,
            SLASH_DESCRIPTION
        );

        _tokenAmount = AlephSlashing.clearRedistributableShares(
            STRATEGY_MANAGER, address(this), _operatorSetId, _slashId, _strategy
        );
        if (_tokenAmount == 0) revert NoTokensReceived();

        IERC20 _underlyingToken = IERC20(address(_strategy.underlyingToken()));
        _underlyingToken.safeTransfer(_recipient, _tokenAmount);

        emit SlashExecuted(
            _operator, _operatorSetId, address(_strategy), address(_underlyingToken), _tokenAmount, _slashId
        );
    }

    function _getSlashedStrategy(address _vault) internal view returns (IStrategy _slashedStrategy) {
        _slashedStrategy = _getAVSStorage().vaultToSlashedStrategy[_vault];
        if (address(_slashedStrategy) == address(0)) revert InvalidStrategy();
    }

    function _getVaultTokenAndStrategy(address _vault) internal view returns (IERC20 _vaultToken, IStrategy _strategy) {
        AVSStorage storage $ = _getAVSStorage();
        _strategy = $.vaultToOriginalStrategy[_vault];
        if (address(_strategy) == address(0)) revert InvalidStrategy();
        _vaultToken = IERC20(IAlephVault(_vault).underlyingToken());
    }

    function _validateAVSRegistrarCall(address _avs) private view {
        if (msg.sender != address(ALLOCATION_MANAGER) || _avs != address(this)) {
            revert Unauthorized();
        }
    }

    function _initializeOperatorSet() private {
        IStrategy[] memory _lstStrategies = new IStrategy[](0);

        IAllocationManagerTypes.CreateSetParams memory lstCreateParams = IAllocationManagerTypes.CreateSetParams({
            operatorSetId: LST_STRATEGIES_OPERATOR_SET_ID, strategies: _lstStrategies
        });

        IAllocationManagerTypes.CreateSetParams[] memory _params = new IAllocationManagerTypes.CreateSetParams[](1);
        _params[0] = lstCreateParams;

        address[] memory recipients = new address[](1);
        recipients[0] = address(this);

        ALLOCATION_MANAGER.createRedistributingOperatorSets(address(this), _params, recipients);
    }
}
