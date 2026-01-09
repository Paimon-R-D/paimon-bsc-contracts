// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PPTTypes} from "./PPTTypes.sol";
import {IPPT, IRedemptionManager,  IAssetController, IRedemptionVoucher} from "./IPPTContracts.sol";


/// @title RedemptionManager
/// @author Paimon Yield Protocol
/// @notice Redemption manager contract - User directly calls for redemption operations (UUPS Upgradeable)
/// @dev Redemption channel description:
///      1. Standard channel (T+7): Base fee (default 1%, configurable)
///         - Approval condition: >=100K or exceeds dynamic quota
///      2. Emergency channel (T+1): Base fee + penalty fee (default 2%, configurable)
///         - Approval condition: >30K or >10% of Layer1
contract RedemptionManager is
    IRedemptionManager,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    
    // =============================================================================
    // Roles
    // =============================================================================
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // =============================================================================
    // External Contracts
    // =============================================================================

    /// @notice Vault contract address (immutable, preserved during upgrade)
    IPPT public vault;
    IAssetController public assetController;

    // =============================================================================
    // Fee Configuration (Admin Configurable)
    // =============================================================================

    /// @notice Base redemption fee (default 1% = 100 bps)
    uint256 public baseRedemptionFeeBps;

    /// @notice Emergency redemption penalty fee (default 1% = 100 bps)
    uint256 public emergencyPenaltyFeeBps;

    // =============================================================================
    // Approval Threshold Configuration (Admin Configurable)
    // =============================================================================

    /// @notice Standard channel approval amount threshold (default 50K = 50_000e18)
    uint256 public standardApprovalAmount;

    /// @notice Standard channel approval quota ratio threshold (default 20% = 2000 bps)
    uint256 public standardApprovalQuotaRatio;

    /// @notice Emergency channel approval amount threshold (default 30K = 30_000e18)
    uint256 public emergencyApprovalAmount;

    /// @notice Emergency channel approval quota ratio threshold (default 20% = 2000 bps)
    uint256 public emergencyApprovalQuotaRatio;

    // =============================================================================
    // State Variables
    // =============================================================================

    mapping(uint256 => PPTTypes.RedemptionRequest) private _requests;
    mapping(address => uint256[]) private _userRequests;
    uint256 private _requestIdCounter;

    uint256[] private _pendingApprovals;
    mapping(uint256 => uint256) private _pendingApprovalIndex;
    uint256 public  totalPendingApprovalAmount;

    uint256 private _lastLiquidityAlertTime;

    // =============================================================================
    // Liability Tracking State Variables
    // =============================================================================

    /// @notice Liability amount mapped by settlement date (dayIndex => amount)
    mapping(uint256 => uint256) public dailyLiability;

    /// @notice Total overdue but unsettled liability (must be reserved immediately)
    uint256 public overdueLiability;

    // =============================================================================
    // NFT Voucher State Variables
    // =============================================================================

    /// @notice Redemption voucher NFT contract
    IRedemptionVoucher public redemptionVoucher;

    /// @notice Minimum delay threshold for NFT generation (default 7 days)
    uint256 public voucherThreshold;

    // =============================================================================
    // Events
    // =============================================================================
    
    event RedemptionRequested(
        uint256 indexed requestId,
        address indexed owner,
        address receiver,
        uint256 shares,
        uint256 lockedAmount,
        uint256 estimatedFee,
        PPTTypes.RedemptionChannel channel,
        bool requiresApproval,
        uint256 settlementTime,
        uint256 windowId
    );
    
    event RedemptionSettled(
        uint256 indexed requestId,
        address indexed owner,
        address receiver,
        uint256 grossAmount,
        uint256 fee,
        uint256 netAmount,
        PPTTypes.RedemptionChannel channel
    );
    
    event RedemptionApproved(uint256 indexed requestId, address indexed approver, uint256 settlementTime);
    event RedemptionRejected(uint256 indexed requestId, address indexed rejector, string reason);
  //  event LowLiquidityAlert(uint256 currentRatio, uint256 threshold, uint256 available, uint256 total);
  //  event CriticalLiquidityAlert(uint256 currentRatio, uint256 threshold, uint256 available);
    event AssetControllerUpdated(address indexed oldController, address indexed newController);
    event DailyLiabilityAdded(uint256 indexed dayIndex, uint256 amount);
    event LiabilityRemoved(uint256 indexed dayIndex, uint256 amount, bool wasOverdue);
    event BaseRedemptionFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event EmergencyPenaltyFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event SettlementWaterfallTriggered(uint256 indexed requestId, uint256 deficit, uint256 funded);
    event SettlementLiquidityInsufficient(uint256 indexed requestId, uint256 availableCash, uint256 payoutAmount);
    //event RedemptionVoucherUpdated(address indexed oldVoucher, address indexed newVoucher);
    event VoucherThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event VoucherMinted(uint256 indexed requestId, uint256 indexed tokenId, address indexed owner);
    event StandardApprovalAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event StandardApprovalQuotaRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event EmergencyApprovalAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event EmergencyApprovalQuotaRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event AdjustOverdueLiability(uint256 amount);
    event AdjustDailyLiability(uint256 dayIndex, uint256 amount);
     event PPTUpgraded(address indexed newImplementation, uint256 timestamp, uint256 blockNumber);

    // =============================================================================
    // Errors
    // =============================================================================
    
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientShares(uint256 available, uint256 required);
    error InsufficientLiquidity(uint256 available, uint256 required);
    error RequestNotFound(uint256 requestId);
    error InvalidRequestStatus(uint256 requestId);
    error SettlementTimeNotReached(uint256 settlementTime, uint256 currentTime);
    error NotPendingApproval(uint256 requestId);
    // error EmergencyModeNotActive();
    error EmergencyQuotaExceeded(uint256 available, uint256 requested);
    error InvalidSettlementTime(uint256 provided, uint256 minimum);
    error NotVoucherOwner(address caller, address owner);
    error CancellationDisabled();

    // =============================================================================
    // Constructor & Initializer
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize function (replaces constructor in proxy pattern)
    /// @param vault_ Vault contract address
    /// @param adminSig_ Admin address
    function initialize(address vault_, address adminSig_, address timerlock,address redemptionVoucher_) external initializer {
        if (vault_ == address(0) || adminSig_ == address(0)||timerlock==address(0)) revert ZeroAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        // __Ownable_init(msg.sender);
        // __Ownable2Step_init();
        __UUPSUpgradeable_init();

        vault = IPPT(vault_);
        redemptionVoucher = IRedemptionVoucher(redemptionVoucher_);

        // Initialize fee configuration
        baseRedemptionFeeBps = 100; // 1%
        emergencyPenaltyFeeBps = 100; // 1%

        // Initialize approval threshold configuration
        standardApprovalAmount = 50_000e18;    // 50K
        standardApprovalQuotaRatio = 2000;     // 20%
        emergencyApprovalAmount = 30_000e18;   // 30K
        emergencyApprovalQuotaRatio = 2000;    // 20%

        // Initialize NFT voucher threshold (default 7 days)
        voucherThreshold = 7 days;

        _grantRole(DEFAULT_ADMIN_ROLE, adminSig_);
        _grantRole(ADMIN_ROLE, adminSig_);
        _grantRole(KEEPER_ROLE, adminSig_);
        _grantRole(UPGRADER_ROLE, timerlock);
    }

    // =============================================================================
    // UUPS Upgrade Authorization
    // =============================================================================

    /// @notice Authorize upgrade (only ADMIN can call)
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit PPTUpgraded(newImplementation, block.timestamp, block.number);
    }

    // =============================================================================
    // User Functions - User Direct Calls
    // =============================================================================

    /// @notice Request redemption (user direct call) - Standard channel T+7
    /// @param shares Shares to redeem
    /// @param receiver Address to receive USDT
    /// @return requestId Redemption request ID
    function requestRedemption(
        uint256 shares,
        address receiver
    ) external override nonReentrant whenNotPaused returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        address owner = msg.sender;
        // Since pending approval and locked shares are transferred to vault, user balanceOf is available balance
        uint256 availableShares = IERC20(address(vault)).balanceOf(owner);

        if (availableShares < shares) revert InsufficientShares(availableShares, shares);

        uint256 nav = vault.sharePrice();
        uint256 grossAmount = (shares * nav) / PPTTypes.PRECISION;

        return _processStandardRedemption(owner, shares, receiver, grossAmount, nav);
    }

    /// @notice Request emergency redemption (user direct call)
    /// @param shares Shares to redeem
    /// @param receiver Address to receive USDT
    /// @return requestId Redemption request ID
    function requestEmergencyRedemption(
        uint256 shares,
        address receiver
    ) external override nonReentrant returns (uint256 requestId) {
        // if (!vault.emergencyMode()) revert EmergencyModeNotActive();
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        address owner = msg.sender;
        // Since pending approval and locked shares are transferred to vault, user balanceOf is available balance
        uint256 availableShares = IERC20(address(vault)).balanceOf(owner);

        if (availableShares < shares) revert InsufficientShares(availableShares, shares);

        uint256 nav = vault.sharePrice();
        uint256 grossAmount = (shares * nav) / PPTTypes.PRECISION;

        return _processEmergencyRedemption(owner, shares, receiver, grossAmount, nav);
    }
    
    /// @notice Settle redemption (by requestId)
    /// @dev Without NFT voucher: Anyone can call, assets sent to receiver
    ///      With NFT voucher: Only NFT holder can call, assets sent to NFT holder
    function settleRedemption(uint256 requestId) external override whenNotPaused nonReentrant {
        _settleRedemptionCore(requestId);
    }

    /// @notice Settlement method for NFT voucher holders (by tokenId)
    /// @dev Settle by tokenId, convenient when NFT holder doesn't know requestId
    /// @param tokenId NFT voucher's tokenId
    function settleWithVoucher(uint256 tokenId) external whenNotPaused nonReentrant {
        // Verify caller is NFT holder
        // address voucherOwner = redemptionVoucher.ownerOf(tokenId);
        // if (msg.sender != voucherOwner) {
        //     revert NotVoucherOwner(msg.sender, voucherOwner);
        // }

        // Get associated requestId, call core settlement logic
        (uint256 requestId, , , ) = redemptionVoucher.voucherInfo(tokenId);
        if (requestId == 0) revert RequestNotFound(0);

        _settleRedemptionCore(requestId);
    }

    /// @dev Core settlement logic (shared by settleRedemption and settleWithVoucher)
    function _settleRedemptionCore(uint256 requestId) internal {
        PPTTypes.RedemptionRequest storage request = _requests[requestId];

        if (request.requestId == 0) revert RequestNotFound(requestId);
        if (request.status != PPTTypes.RedemptionStatus.PENDING &&
            request.status != PPTTypes.RedemptionStatus.APPROVED) {
            revert InvalidRequestStatus(requestId);
        }
        if (block.timestamp < request.settlementTime) {
            revert SettlementTimeNotReached(request.settlementTime, block.timestamp);
        }

        // NFT voucher verification
        address payoutReceiver = request.receiver;
        if (request.hasVoucher) {
            uint256 tokenId = redemptionVoucher.requestToToken(requestId);
            address voucherOwner = redemptionVoucher.ownerOf(tokenId);

            // Must be called by NFT holder
            if (msg.sender != voucherOwner) {
                revert NotVoucherOwner(msg.sender, voucherOwner);
            }

            // Send assets to NFT holder
            payoutReceiver = voucherOwner;

            // Burn NFT
            redemptionVoucher.burn(tokenId);
        }

        _executeSettlement(request, payoutReceiver);
    }

    /// @notice User cancel unsettled redemption request (disabled)
    /// @dev Once redemption application is submitted it cannot be cancelled, can only wait for settlement or rejection
    function cancelRedemption(uint256 requestId) external override nonReentrant {
        // Redemption cancellation is disabled
        revert CancellationDisabled();
    }

    // =============================================================================
    // Preview Functions - User Direct Calls
    // =============================================================================

    /// @notice Preview redemption (user direct call)
    /// @dev Anyone can call, checks caller's (msg.sender) available shares
    function previewRedemption(uint256 shares) external view override returns (PPTTypes.RedemptionPreview memory preview) {
        // Check if contract is paused
        if (paused()) {
            preview.canProcess = false;
            preview.channelReason = "Contract is paused";
            return preview;
        }

        if (shares == 0) {
            preview.canProcess = false;
            preview.channelReason = "Shares cannot be zero";
            return preview;
        }

        // uint256 userBalance = _balanceOf(msg.sender);
        // uint256 lockedShares = vault.lockedSharesOf(msg.sender);
        // uint256 availableShares = userBalance > lockedShares ? userBalance - lockedShares : 0;

        // if (availableShares < shares) {
        //     preview.canProcess = false;
        //     preview.channelReason = "Insufficient available shares";
        //     return preview;
        // }

        uint256 nav = vault.sharePrice();
        preview.grossAmount = (shares * nav) / PPTTypes.PRECISION;
        preview.fee = _calculateRedemptionFee(preview.grossAmount, false);
        preview.netAmount = preview.grossAmount - preview.fee;

        preview.channel = PPTTypes.RedemptionChannel.STANDARD;
        preview.requiresApproval = _requiresStandardApproval(preview.grossAmount);
        preview.settlementDelay = PPTTypes.STANDARD_REDEMPTION_DELAY;
        // Note: If approval required, actual settlement time starts from approval time
        preview.estimatedSettlementTime = block.timestamp + PPTTypes.STANDARD_REDEMPTION_DELAY;

        // T+7 settlement, do not use current liquidity to determine if can apply
        // Liquidity is checked at settlement time
        preview.canProcess = true;
        preview.channelReason = preview.requiresApproval
            ? "Standard channel (T+7): Requires approval "
            : "Standard channel (T+7): No approval required";
    }
    
    /// @notice Preview emergency redemption
    function previewEmergencyRedemption(uint256 shares) external view override returns (PPTTypes.RedemptionPreview memory preview) {
        // if (!vault.emergencyMode()) {
        //     preview.canProcess = false;
        //     preview.channelReason = "Emergency mode not active";
        //  }

        //address owner = msg.sender;
        if (shares == 0) {
            preview.canProcess = false;
            preview.channelReason = "Shares cannot be zero";
            return preview;
        }

        // uint256 userBalance = _balanceOf(owner);
        // uint256 lockedShares = vault.lockedSharesOf(owner);
        // uint256 availableShares = userBalance > lockedShares ? userBalance - lockedShares : 0;

        // if (availableShares < shares) {
        //     preview.canProcess = false;
        //     preview.channelReason = "Insufficient available shares";
        //     return preview;
        // }

        uint256 nav = vault.sharePrice();
        preview.grossAmount = (shares * nav) / PPTTypes.PRECISION;
        preview.fee = _calculateRedemptionFee(preview.grossAmount, true);
        preview.netAmount = preview.grossAmount - preview.fee;
        preview.channel = PPTTypes.RedemptionChannel.EMERGENCY;
        preview.requiresApproval = _requiresEmergencyApproval(preview.grossAmount);
        preview.settlementDelay = PPTTypes.EMERGENCY_REDEMPTION_DELAY;
        preview.estimatedSettlementTime = block.timestamp + PPTTypes.EMERGENCY_REDEMPTION_DELAY;

        // Check emergency application quota (hard limit, deducted at application)
        uint256 quota = vault.emergencyQuota();
        if (preview.grossAmount > quota) {
            preview.canProcess = false;
            preview.channelReason = "Emergency channel: Quota exceeded";
            return preview;
        }

        // T+1 settlement, do not use current liquidity to determine if can apply
        // Liquidity is checked at settlement time
        preview.canProcess = true;
        preview.channelReason = preview.requiresApproval
            ? "Emergency channel (T+1): Requires approval (>30K or >20% of emergency quota), +1% fee"
            : "Emergency channel (T+1): No approval required, +1% fee";
    }

    // =============================================================================
    // Approval Functions - VIP Approver Calls
    // =============================================================================

    /// @notice Approve redemption (using default settlement time)
    /// @dev Standard channel +7 days, emergency channel +1 day
    function approveRedemption(uint256 requestId) external override onlyRole(KEEPER_ROLE) {
        _approveRedemptionCore(requestId, 0);
    }

    /// @notice Approve redemption with custom settlement date
    /// @dev customSettlementTime=0 uses default delay; delay > voucherThreshold generates NFT
    /// @param requestId Redemption request ID
    /// @param customSettlementTime Custom settlement timestamp (0 means use default)
    function approveRedemptionWithDate(
        uint256 requestId,
        uint256 customSettlementTime
    ) external onlyRole(KEEPER_ROLE) {
        _approveRedemptionCore(requestId, customSettlementTime);
    }

    /// @dev Core approval logic (shared by approveRedemption and approveRedemptionWithDate)
    /// @param requestId Redemption request ID
    /// @param customSettlementTime Custom settlement time (0 means use default delay)
    function _approveRedemptionCore(uint256 requestId, uint256 customSettlementTime) internal {
        PPTTypes.RedemptionRequest storage request = _requests[requestId];

        if (request.requestId == 0) revert RequestNotFound(requestId);
        if (!request.requiresApproval) revert NotPendingApproval(requestId);
        if (request.status != PPTTypes.RedemptionStatus.PENDING_APPROVAL) {
            revert NotPendingApproval(requestId);
        }

        // Calculate minimum delay
        uint256 minDelay = request.channel == PPTTypes.RedemptionChannel.EMERGENCY
            ? PPTTypes.EMERGENCY_REDEMPTION_DELAY
            : PPTTypes.STANDARD_REDEMPTION_DELAY;

        // Determine settlement time
        uint256 settlementTime;
        if (customSettlementTime == 0) {
            // Use default delay
            settlementTime = block.timestamp + minDelay;
        } else {
            // Validate custom time >= minimum delay
            if (customSettlementTime < block.timestamp + minDelay) {
                revert InvalidSettlementTime(customSettlementTime, block.timestamp + minDelay);
            }
            settlementTime = customSettlementTime;
        }

        request.settlementTime = settlementTime;
        request.status = PPTTypes.RedemptionStatus.APPROVED;

        // Calculate delay, decide whether to generate NFT
        uint256 delay = settlementTime - block.timestamp;
        uint256 threshold = voucherThreshold > 0 ? voucherThreshold : 7 days;

        if (delay > threshold && address(redemptionVoucher) != address(0)) {
            // Calculate net amount (netAmount = grossAmount - fee)
            bool isEmergency = request.channel == PPTTypes.RedemptionChannel.EMERGENCY;
            uint256 fee = _calculateRedemptionFee(request.grossAmount, isEmergency);
            uint256 netAmount = request.grossAmount - fee;

            // Generate NFT voucher (using net amount)
            uint256 tokenId = redemptionVoucher.mint(
                request.owner,
                requestId,
                netAmount,  // Net amount, not grossAmount
                settlementTime
            );
            request.hasVoucher = true;

            emit VoucherMinted(requestId, tokenId, request.owner);
        }

        // After approval:
        // 1. Convert pending approval shares to locked shares (affects effectiveSupply)
        vault.convertPendingToLocked(request.owner, request.shares);
        // 2. Add liability (affects totalAssets)
        vault.addRedemptionLiability(request.grossAmount);
        // 3. Record daily liability (for quota calculation)
        _addDailyLiability(settlementTime, request.grossAmount);

        _removeFromPendingApprovals(requestId);
        totalPendingApprovalAmount -= request.grossAmount;

        emit RedemptionApproved(requestId, msg.sender, settlementTime);
    }

    function rejectRedemption(uint256 requestId, string calldata reason) external override onlyRole(KEEPER_ROLE) {
        PPTTypes.RedemptionRequest storage request = _requests[requestId];

        if (request.requestId == 0) revert RequestNotFound(requestId);
        if (!request.requiresApproval) revert NotPendingApproval(requestId);
        if (request.status != PPTTypes.RedemptionStatus.PENDING_APPROVAL) {
            revert NotPendingApproval(requestId);
        }

        request.status = PPTTypes.RedemptionStatus.CANCELLED;

        // PENDING_APPROVAL state: only pending approval shares were added at application (does not affect NAV)
        // On rejection: remove pending approval shares marker, user can transfer freely
        // No need for removeRedemptionLiability (never added)
        // No need for removeLiability (settlementTime=0, no daily liability recorded)
        vault.removePendingApprovalShares(request.owner, request.shares);

        // If emergency channel, refund quota
        if (request.channel == PPTTypes.RedemptionChannel.EMERGENCY) {
            vault.restoreEmergencyQuota(request.grossAmount);
        }

        _removeFromPendingApprovals(requestId);
        totalPendingApprovalAmount -= request.grossAmount;

        emit RedemptionRejected(requestId, msg.sender, reason);
    }

    // =============================================================================
    // Internal Processing
    // =============================================================================
    
    function _processStandardRedemption(
        address owner,
        uint256 shares,
        address receiver,
        uint256 grossAmount,
        uint256 nav
    ) internal returns (uint256 requestId) {
        bool requiresApproval = _requiresStandardApproval(grossAmount);
        uint256 estimatedFee = _calculateRedemptionFee(grossAmount, false);

        // Note: T+7 settlement, do not check liquidity at application
        // Liquidity check is done at _executeSettlement

        requestId = ++_requestIdCounter;

        PPTTypes.RedemptionStatus status = requiresApproval
            ? PPTTypes.RedemptionStatus.PENDING_APPROVAL
            : PPTTypes.RedemptionStatus.PENDING;
        uint256 settlementTime = requiresApproval ? 0 : block.timestamp + PPTTypes.STANDARD_REDEMPTION_DELAY;

        _requests[requestId] = PPTTypes.RedemptionRequest({
            requestId: requestId,
            owner: owner,
            receiver: receiver,
            shares: shares,
            grossAmount: grossAmount,
            lockedNav: nav,
            estimatedFee: estimatedFee,
            requestTime: block.timestamp,
            settlementTime: settlementTime,
            status: status,
            channel: PPTTypes.RedemptionChannel.STANDARD,
            requiresApproval: requiresApproval,
            windowId: 0,
            hasVoucher: false
        });

        _userRequests[owner].push(requestId);

        if (requiresApproval) {
            // Requires approval: only mark pending approval shares, no locking, no liability
            // Does not affect NAV, but restricts transfer
            vault.addPendingApprovalShares(owner, shares);
             // _pendingApprovals.push(requestId);
            _addToPendingApprovals(requestId);
            totalPendingApprovalAmount += grossAmount;
        } else {
            // No approval needed: lock shares + add liability + daily liability
            vault.lockShares(owner, shares);
            vault.addRedemptionLiability(grossAmount);
            _addDailyLiability(settlementTime, grossAmount);
        }

        emit RedemptionRequested(
            requestId, owner, receiver, shares, grossAmount, estimatedFee,
            PPTTypes.RedemptionChannel.STANDARD, requiresApproval, settlementTime, 0
        );

       // _checkLiquidityAndAlert();
    }
    
    function _processEmergencyRedemption(
        address owner,
        uint256 shares,
        address receiver,
        uint256 grossAmount,
        uint256 nav
    ) internal returns (uint256 requestId) {
        // Check emergency application quota
        uint256 quota = vault.emergencyQuota();
        if (grossAmount > quota) {
            revert EmergencyQuotaExceeded(quota, grossAmount);
        }

        bool requiresApproval = _requiresEmergencyApproval(grossAmount);
        uint256 estimatedFee = _calculateRedemptionFee(grossAmount, true);

        // Note: T+1 settlement, do not check liquidity at application
        // Liquidity check is done at _executeSettlement

        // Deduct emergency application quota (deduct regardless of whether approval is required)
        vault.reduceEmergencyQuota(grossAmount);

        requestId = ++_requestIdCounter;

        PPTTypes.RedemptionStatus status = requiresApproval
            ? PPTTypes.RedemptionStatus.PENDING_APPROVAL
            : PPTTypes.RedemptionStatus.PENDING;
        uint256 settlementTime = requiresApproval ? 0 : block.timestamp + PPTTypes.EMERGENCY_REDEMPTION_DELAY;

        _requests[requestId] = PPTTypes.RedemptionRequest({
            requestId: requestId,
            owner: owner,
            receiver: receiver,
            shares: shares,
            grossAmount: grossAmount,
            lockedNav: nav,
            estimatedFee: estimatedFee,
            requestTime: block.timestamp,
            settlementTime: settlementTime,
            status: status,
            channel: PPTTypes.RedemptionChannel.EMERGENCY,
            requiresApproval: requiresApproval,
            windowId: 0,
            hasVoucher: false
        });

        _userRequests[owner].push(requestId);

        if (requiresApproval) {
            // Requires approval: only mark pending approval shares, no locking, no liability
            // Does not affect NAV, but restricts transfer
            vault.addPendingApprovalShares(owner, shares);
            // _pendingApprovals.push(requestId);
            _addToPendingApprovals(requestId);
            totalPendingApprovalAmount += grossAmount;
        } else {
            // No approval needed: lock shares + add liability + daily liability
            vault.lockShares(owner, shares);
            vault.addRedemptionLiability(grossAmount);
            _addDailyLiability(settlementTime, grossAmount);
        }

        emit RedemptionRequested(
            requestId, owner, receiver, shares, grossAmount, estimatedFee,
            PPTTypes.RedemptionChannel.EMERGENCY, requiresApproval, settlementTime, 0
        );
    }
    
    function _executeSettlement(
        PPTTypes.RedemptionRequest storage request,
        address payoutReceiver
    ) internal {
        // Guard check: ensure request is valid and status is correct
        if (request.requestId == 0) revert RequestNotFound(0);
        if (request.status != PPTTypes.RedemptionStatus.PENDING &&
            request.status != PPTTypes.RedemptionStatus.APPROVED) {
            revert InvalidRequestStatus(request.requestId);
        }
        if (block.timestamp < request.settlementTime) {
            revert SettlementTimeNotReached(request.settlementTime, block.timestamp);
        }

        uint256 actualFee = request.estimatedFee;
        uint256 payoutAmount = request.grossAmount;

        // 1. Calculate available funds for settlement (don't deduct emergencyQuota, it's an application-time limit)
        uint256 rawCash = IERC20(_asset()).balanceOf(address(vault));
        uint256 fees = vault.withdrawableRedemptionFees();
        uint256 locked = vault.lockedMintAssets();

        // Available = cash - reserved fees - locked assets
        uint256 reserved = fees + locked;
        uint256 availableCash = rawCash > reserved ? rawCash - reserved : 0;

        // 2. If available funds insufficient, try waterfall liquidation of TIER_1_CASH
        if (availableCash < payoutAmount) {
            uint256 deficit = payoutAmount - availableCash;

            // Call AssetController to waterfall liquidate Layer1 yield assets
            if (address(assetController) != address(0)) {
                uint256 funded = assetController.executeWaterfallLiquidation(
                    deficit,
                    PPTTypes.LiquidityTier.TIER_1_CASH  // Only liquidate L1 yield assets
                );

                emit SettlementWaterfallTriggered(request.requestId, deficit, funded);

                // Recalculate available funds
                rawCash = IERC20(_asset()).balanceOf(address(vault));
                availableCash = rawCash > reserved ? rawCash - reserved : 0;
            }

            // Final check
            if (availableCash < payoutAmount) {
                emit SettlementLiquidityInsufficient(request.requestId, availableCash, payoutAmount);
                revert InsufficientLiquidity(availableCash, payoutAmount);
            }
        }

        // 3. Remove liability at settlement (if has settlement time)
        if (request.settlementTime > 0) {
            _removeLiability(request.settlementTime, request.grossAmount);
        }

        // 4. Execute settlement (send assets to payoutReceiver, may be original receiver or NFT holder)
        vault.burnLockedShares(request.owner, request.shares);
        vault.removeRedemptionLiability(request.grossAmount);
        vault.addRedemptionFee(actualFee);
        vault.transferAssetTo(payoutReceiver, payoutAmount-actualFee);

        request.status = PPTTypes.RedemptionStatus.SETTLED;

        emit RedemptionSettled(
            request.requestId,
            request.owner,
            payoutReceiver,  // Use actual receiver
            request.grossAmount,
            actualFee,
            payoutAmount,
            request.channel
        );
    }

    // =============================================================================
    // Channel Detection
    // =============================================================================

    /// @notice Check if standard channel requires approval
    /// @dev Condition: single transaction > standardApprovalAmount OR > standardApprovalQuotaRatio of dynamic quota
    function _requiresStandardApproval(uint256 amount) internal view returns (bool) {
        // 1. Absolute threshold: > standardApprovalAmount requires approval
        if (amount > standardApprovalAmount) {
            return true;
        }
        // 2. Ratio threshold: > standardApprovalQuotaRatio of dynamic quota requires approval
        uint256 quota = vault.getStandardChannelQuota();
        uint256 ratioThreshold = (quota * standardApprovalQuotaRatio) / PPTTypes.BASIS_POINTS;
        return amount > ratioThreshold;
    }

    /// @notice Check if emergency channel requires approval
    /// @dev Condition: single transaction > emergencyApprovalAmount OR > emergencyApprovalQuotaRatio of emergency quota balance
    function _requiresEmergencyApproval(uint256 amount) internal view returns (bool) {
        // 1. Absolute threshold: > emergencyApprovalAmount requires approval
        if (amount > emergencyApprovalAmount) {
            return true;
        }
        // 2. Ratio threshold: > emergencyApprovalQuotaRatio of emergency quota balance requires approval
        uint256 emergencyQuota = vault.emergencyQuota();
        uint256 ratioThreshold = (emergencyQuota * emergencyApprovalQuotaRatio) / PPTTypes.BASIS_POINTS;
        return amount > ratioThreshold;
    }
    
    /// @notice Calculate redemption fee
    /// @dev Standard redemption: baseRedemptionFeeBps (default 1%)
    ///      Emergency redemption: baseRedemptionFeeBps + emergencyPenaltyFeeBps (default 2%)
    function _calculateRedemptionFee(uint256 amount, bool isEmergency) internal view returns (uint256) {
        uint256 feeBps = baseRedemptionFeeBps;

        if (isEmergency) {
            feeBps += emergencyPenaltyFeeBps;
        }

        return (amount * feeBps) / PPTTypes.BASIS_POINTS;
    }

    // =============================================================================
    // ERC4626 Helpers
    // =============================================================================

    /// @dev Get user Vault share balance
    function _balanceOf(address owner) internal view returns (uint256) {
        return IERC4626(address(vault)).balanceOf(owner);
    }

    /// @dev Get underlying asset address
    function _asset() internal view returns (address) {
        return IERC4626(address(vault)).asset();
    }

    /// @dev Get Vault total assets
    function _totalAssets() internal view returns (uint256) {
        return IERC4626(address(vault)).totalAssets();
    }

    // =============================================================================
    // Internal Helpers
    // =============================================================================

   function _addToPendingApprovals(uint256 requestId) internal {
        _pendingApprovals.push(requestId);
        _pendingApprovalIndex[requestId] = _pendingApprovals.length; // index + 1
    }

 function _removeFromPendingApprovals(uint256 requestId) internal {
    uint256 indexPlusOne = _pendingApprovalIndex[requestId];
    if (indexPlusOne == 0) return; // requestId not in pending approvals
    
    uint256 index = indexPlusOne - 1;
    uint256 lastIndex = _pendingApprovals.length - 1;
    
    if (index != lastIndex) {
        uint256 lastRequestId = _pendingApprovals[lastIndex];
        _pendingApprovals[index] = lastRequestId;
        _pendingApprovalIndex[lastRequestId] = indexPlusOne; // update the index of the last requestId
    }
    
    _pendingApprovals.pop();
    delete _pendingApprovalIndex[requestId];
}
    

    // function _checkLiquidityAndAlert() internal {
    //     if (block.timestamp < _lastLiquidityAlertTime + 1 hours) return;
        
    //     uint256 available = vault.getAvailableLiquidity();
    //     uint256 gross = _totalAssets() + vault.totalRedemptionLiability();
    //     if (gross == 0) return;
        
    //     uint256 ratio = (available * PPTTypes.BASIS_POINTS) / gross;
        
    //     if (ratio < PPTTypes.CRITICAL_LIQUIDITY_THRESHOLD) {
    //         emit CriticalLiquidityAlert(ratio, PPTTypes.CRITICAL_LIQUIDITY_THRESHOLD, available);
    //         _lastLiquidityAlertTime = block.timestamp;
    //     } else if (ratio < PPTTypes.LOW_LIQUIDITY_THRESHOLD) {
    //         emit LowLiquidityAlert(ratio, PPTTypes.LOW_LIQUIDITY_THRESHOLD, available, gross);
    //         _lastLiquidityAlertTime = block.timestamp;
    //     }
    // }

    // =============================================================================
    // View Functions
    // =============================================================================
    
    function getRedemptionRequest(uint256 requestId) external view override returns (PPTTypes.RedemptionRequest memory) {
        return _requests[requestId];
    }
    
    function getUserRedemptions(address user) external view override returns (uint256[] memory) {
        return _userRequests[user];
    }
    
    function getPendingApprovals() external view override returns (uint256[] memory) {
        return _pendingApprovals;
    }
    
    function getTotalPendingApprovalAmount() external view override returns (uint256) {
        return totalPendingApprovalAmount;
    }
    
    function getRequestCount() external view override returns (uint256) {
        return _requestIdCounter;
    }

    // =============================================================================
    // Liability Tracking Functions
    // =============================================================================

    /// @notice Get day index for a timestamp
    function _getDayIndex(uint256 timestamp) internal pure returns (uint256) {
        return timestamp / 1 days;
    }

    /// @notice Add liability for a specific day
    function _addDailyLiability(uint256 settlementTime, uint256 amount) internal {
        uint256 dayIndex = _getDayIndex(settlementTime);
        dailyLiability[dayIndex] += amount;
        emit DailyLiabilityAdded(dayIndex, amount);
    }

    /// @notice Remove liability (distinguish between overdue and non-overdue)
    /// @dev Overdue: deduct from both dailyLiability[dayIndex] and overdueLiability (overdueLiability is cache)
    ///      Non-overdue: only deduct from dailyLiability[dayIndex]
    function _removeLiability(uint256 settlementTime, uint256 amount) internal {
        uint256 dayIndex = _getDayIndex(settlementTime);
        uint256 today = _getDayIndex(block.timestamp);

        // Uniformly deduct from dailyLiability (regardless of whether overdue)


        // If overdue, also deduct from overdueLiability (keep cache in sync)
        if (dayIndex < today) {
            uint256 toRemoveFromOverdue = overdueLiability >= amount ? amount : overdueLiability;
            overdueLiability -= toRemoveFromOverdue;
        } 
        uint256 toRemove = dailyLiability[dayIndex] >= amount ? amount : dailyLiability[dayIndex];
        dailyLiability[dayIndex] -= toRemove;
        emit LiabilityRemoved(dayIndex, toRemove, dayIndex < today);
        
    }

    /// @notice Calculate total liability for the next 7 days (for Vault to call)
    function getSevenDayLiability() public view returns (uint256 total) {
        uint256 today = _getDayIndex(block.timestamp);
        for (uint256 i = 0; i <= 7; i++) {
            total += dailyLiability[today + i];
        }
    }

    /// @notice Get overdue unsettled liability
    function getOverdueLiability() public view returns (uint256) {
        return overdueLiability;
    }

    /// @notice Get liability for a specific day (for external queries)
    function getDailyLiability(uint256 dayIndex) public view returns (uint256) {
        return dailyLiability[dayIndex];
    }

    /// @notice Process yesterday's due liability to overdue (backend/Keeper daily call)
    // function processOverdueLiability() external {
    //     uint256 yesterday = _getDayIndex(block.timestamp) - 1;
    //     uint256 amount = dailyLiability[yesterday];
    //     if (amount > 0) {
    //         overdueLiability += amount;
    //         dailyLiability[yesterday] = 0;
    //         emit OverdueLiabilityProcessed(yesterday, amount);
    //     }
    // }

    // /// @notice Batch process overdue liability for the past N days
    // function processOverdueLiabilityBatch(uint256 daysBack) external view returns(uint256) {
    //     uint256 overdueLiabilityView=0;
    //     uint256 today = _getDayIndex(block.timestamp);
    //     for (uint256 i = 1; i <= daysBack; i++) {
    //         uint256 dayIndex = today - i;
    //         uint256 amount = dailyLiability[dayIndex];
    //         if (amount > 0) {
    //             overdueLiabilityView += amount;
    //             //dailyLiability[dayIndex] = 0;
    //             //emit OverdueLiabilityProcessed(dayIndex, amount);
    //         }
    //     }
    //     return overdueLiabilityView;
    // }

     /**
        * @notice Get total overdue liability from the past specified days
        * @dev Used to inform decisions for adjustOverdueLiability()
        * @param daysBack Number of days to look back
        * @return total Total unredeemed liability amount
    */
    function getOverdueLiability(uint256 daysBack) external view returns (uint256) {
         uint256 total = 0;
         uint256 today = _getDayIndex(block.timestamp);
         for (uint256 i = 1; i <= daysBack; i++) {
            total += dailyLiability[today - i];
         }
      return total;
    }

    /// @notice Admin adjust overdueLiability (for emergency/fix purposes)
    function adjustOverdueLiability(uint256 amount) external onlyRole(KEEPER_ROLE) {
        overdueLiability = amount;
        emit AdjustOverdueLiability(amount);
    }

    /// @notice Admin adjust liability for a specific day (for emergency/fix purposes)
    function adjustDailyLiability(uint256 dayIndex, uint256 amount) external onlyRole(KEEPER_ROLE) {
        dailyLiability[dayIndex] = amount;
         emit AdjustDailyLiability(dayIndex, amount);
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice Set redemption voucher NFT contract
    /// @param voucher_ RedemptionVoucher contract address
    // function setRedemptionVoucher(address voucher_) external onlyRole(ADMIN_ROLE) {
    //     address old = address(redemptionVoucher);
    //     redemptionVoucher = IRedemptionVoucher(voucher_);
    //     emit RedemptionVoucherUpdated(old, voucher_);
    // }

    /// @notice Set NFT generation threshold
    /// @param threshold_ Delay threshold (seconds), generate NFT if exceeds this threshold
    function setVoucherThreshold(uint256 threshold_) external onlyRole(ADMIN_ROLE) {
        uint256 old = voucherThreshold;
        voucherThreshold = threshold_;
        emit VoucherThresholdUpdated(old, threshold_);
    }

    // function setAssetScheduler(address scheduler) external onlyRole(ADMIN_ROLE) {
    //     address old = address(assetScheduler);
    //     assetScheduler = IAssetScheduler(scheduler);
    //     emit AssetSchedulerUpdated(old, scheduler);
    // }

    function setAssetController(address controller) external onlyRole(ADMIN_ROLE) {
        address old = address(assetController);
        assetController = IAssetController(controller);
        emit AssetControllerUpdated(old, controller);
    }

    /// @notice Set base redemption fee (basis points)
    /// @param feeBps Fee ratio, e.g., 100 = 1%
    function setBaseRedemptionFee(uint256 feeBps) external onlyRole(ADMIN_ROLE) {
        require(feeBps <= 1000, "Fee too high"); // Max 10%
        uint256 old = baseRedemptionFeeBps;
        baseRedemptionFeeBps = feeBps;
        emit BaseRedemptionFeeUpdated(old, feeBps);
    }

    /// @notice Set emergency redemption penalty fee (basis points)
    /// @param feeBps Penalty fee ratio, e.g., 100 = 1%
    function setEmergencyPenaltyFee(uint256 feeBps) external onlyRole(ADMIN_ROLE) {
        require(feeBps <= 1000, "Fee too high"); // Max 10%
        uint256 old = emergencyPenaltyFeeBps;
        emergencyPenaltyFeeBps = feeBps;
        emit EmergencyPenaltyFeeUpdated(old, feeBps);
    }

    /// @notice Set standard channel approval amount threshold
    /// @param amount Amount threshold (18 decimals), e.g., 50_000e18 = 50K USDT
    function setStandardApprovalAmount(uint256 amount) external onlyRole(ADMIN_ROLE) {
        uint256 old = standardApprovalAmount;
        standardApprovalAmount = amount;
        emit StandardApprovalAmountUpdated(old, amount);
    }

    /// @notice Set standard channel approval ratio threshold
    /// @param ratio Ratio threshold (basis points), e.g., 2000 = 20%
    function setStandardApprovalQuotaRatio(uint256 ratio) external onlyRole(ADMIN_ROLE) {
        require(ratio <= PPTTypes.BASIS_POINTS, "Ratio too high"); // Max 100%
        uint256 old = standardApprovalQuotaRatio;
        standardApprovalQuotaRatio = ratio;
        emit StandardApprovalQuotaRatioUpdated(old, ratio);
    }

    /// @notice Set emergency channel approval amount threshold
    /// @param amount Amount threshold (18 decimals), e.g., 30_000e18 = 30K USDT
    function setEmergencyApprovalAmount(uint256 amount) external onlyRole(ADMIN_ROLE) {
        uint256 old = emergencyApprovalAmount;
        emergencyApprovalAmount = amount;
        emit EmergencyApprovalAmountUpdated(old, amount);
    }

    /// @notice Set emergency channel approval ratio threshold
    /// @param ratio Ratio threshold (basis points), e.g., 2000 = 20%
    function setEmergencyApprovalQuotaRatio(uint256 ratio) external onlyRole(ADMIN_ROLE) {
        require(ratio <= PPTTypes.BASIS_POINTS, "Ratio too high"); // Max 100%
        uint256 old = emergencyApprovalQuotaRatio;
        emergencyApprovalQuotaRatio = ratio;
        emit EmergencyApprovalQuotaRatioUpdated(old, ratio);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}