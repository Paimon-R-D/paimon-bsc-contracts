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
import {IPPT, IRedemptionManager, IAssetScheduler, IAssetController, IRedemptionVoucher} from "./IPPTContracts.sol";

/// @title RedemptionManager
/// @author Paimon Yield Protocol
/// @notice Redemption management contract - Users directly call for redemption operations (UUPS Upgradeable)
/// @dev Redemption channel description:
///      1. Standard channel (T+7): Base fee (default 1%, configurable)
///         - Approval condition: >=100K USDT or exceeds dynamic quota
///      2. Emergency channel (T+1): Base fee + penalty fee (default 2%, configurable)
///         - Approval condition: >30K USDT or >10% of Layer1
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
    bytes32 public constant VIP_APPROVER_ROLE = keccak256("VIP_APPROVER_ROLE");

    // =============================================================================
    // External Contracts
    // =============================================================================

    /// @notice Vault contract address (immutable, preserved during upgrades)
    IPPT public vault;
    IAssetScheduler public assetScheduler;
    IAssetController public assetController;

    // =============================================================================
    // Fee Configuration (Admin Configurable)
    // =============================================================================

    /// @notice Base redemption fee (default 1% = 100 bps)
    uint256 public baseRedemptionFeeBps;

    /// @notice Emergency redemption penalty fee (default 1% = 100 bps)
    uint256 public emergencyPenaltyFeeBps;

    // =============================================================================
    // State Variables
    // =============================================================================

    mapping(uint256 => PPTTypes.RedemptionRequest) private _requests;
    mapping(address => uint256[]) private _userRequests;
    uint256 private _requestIdCounter;

    uint256[] private _pendingApprovals;
    uint256 public  totalPendingApprovalAmount;

    uint256 private _lastLiquidityAlertTime;

    // =============================================================================
    // Liability Tracking State Variables
    // =============================================================================

    /// @notice Liability amount mapped by settlement date (dayIndex => amount)
    mapping(uint256 => uint256) public dailyLiability;

    /// @notice Total overdue unsettled liability (must be reserved immediately)
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
    event RedemptionCancelled(uint256 indexed requestId, address indexed owner);
    event LowLiquidityAlert(uint256 currentRatio, uint256 threshold, uint256 available, uint256 total);
    event CriticalLiquidityAlert(uint256 currentRatio, uint256 threshold, uint256 available);
    event AssetSchedulerUpdated(address indexed oldScheduler, address indexed newScheduler);
    event AssetControllerUpdated(address indexed oldController, address indexed newController);
   // event OverdueLiabilityProcessed(uint256 indexed dayIndex, uint256 amount);
    event DailyLiabilityAdded(uint256 indexed dayIndex, uint256 amount);
    event LiabilityRemoved(uint256 indexed dayIndex, uint256 amount, bool wasOverdue);
    event BaseRedemptionFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event EmergencyPenaltyFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event SettlementWaterfallTriggered(uint256 indexed requestId, uint256 deficit, uint256 funded);
    event RedemptionVoucherUpdated(address indexed oldVoucher, address indexed newVoucher);
    event VoucherThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event VoucherMinted(uint256 indexed requestId, uint256 indexed tokenId, address indexed owner);

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
    error EmergencyModeNotActive();
    error SchedulerNotConfigured();
    error NotRequestOwner();
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
    /// @param admin_ Admin address
    function initialize(address vault_, address admin_) external initializer {
        if (vault_ == address(0) || admin_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        vault = IPPT(vault_);

        // Initialize fee configuration
        baseRedemptionFeeBps = 100; // 1%
        emergencyPenaltyFeeBps = 100; // 1%

        // Initialize NFT voucher threshold (default 7 days)
        voucherThreshold = 7 days;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(VIP_APPROVER_ROLE, admin_);
    }

    // =============================================================================
    // UUPS Upgrade Authorization
    // =============================================================================

    /// @notice Authorize upgrade (only ADMIN can call)
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // =============================================================================
    // User Functions - Users directly call
    // =============================================================================

    /// @notice Request redemption (user directly calls) - Standard channel T+7
    /// @param shares Number of shares to redeem
    /// @param receiver Address to receive USDT
    /// @return requestId Redemption request ID
    function requestRedemption(
        uint256 shares,
        address receiver
    ) external override nonReentrant whenNotPaused returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        address owner = msg.sender;
        // Since pending approval and locked shares are transferred to vault, user's balanceOf is available balance
        uint256 availableShares = IERC20(address(vault)).balanceOf(owner);

        if (availableShares < shares) revert InsufficientShares(availableShares, shares);

        uint256 nav = vault.sharePrice();
        uint256 grossAmount = (shares * nav) / PPTTypes.PRECISION;

        return _processStandardRedemption(owner, shares, receiver, grossAmount, nav);
    }

    /// @notice Request emergency redemption (user directly calls)
    /// @param shares Number of shares to redeem
    /// @param receiver Address to receive USDT
    /// @return requestId Redemption request ID
    function requestEmergencyRedemption(
        uint256 shares,
        address receiver
    ) external override nonReentrant returns (uint256 requestId) {
        if (!vault.emergencyMode()) revert EmergencyModeNotActive();
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        address owner = msg.sender;
        // Since pending approval and locked shares are transferred to vault, user's balanceOf is available balance
        uint256 availableShares = IERC20(address(vault)).balanceOf(owner);

        if (availableShares < shares) revert InsufficientShares(availableShares, shares);

        uint256 nav = vault.sharePrice();
        uint256 grossAmount = (shares * nav) / PPTTypes.PRECISION;

        return _processEmergencyRedemption(owner, shares, receiver, grossAmount, nav);
    }

    /// @notice Settle redemption (via requestId)
    /// @dev Without NFT voucher: Anyone can call, assets sent to receiver
    ///      With NFT voucher: Only NFT holder can call, assets sent to NFT holder
    function settleRedemption(uint256 requestId) external override nonReentrant {
        _settleRedemptionCore(requestId);
    }

    /// @notice NFT voucher holder dedicated settlement method (via tokenId)
    /// @dev Settle via tokenId, convenient for NFT holders who don't know requestId
    /// @param tokenId NFT voucher tokenId
    function settleWithVoucher(uint256 tokenId) external nonReentrant {
        // Verify caller is NFT holder
        address voucherOwner = redemptionVoucher.ownerOf(tokenId);
        if (msg.sender != voucherOwner) {
            revert NotVoucherOwner(msg.sender, voucherOwner);
        }

        // Get associated requestId and call core settlement logic
        (uint256 requestId, , , ) = redemptionVoucher.voucherInfo(tokenId);
        if (requestId == 0) revert RequestNotFound(0);

        _settleRedemptionCore(requestId);
    }

    /// @dev Settlement core logic (shared by settleRedemption and settleWithVoucher)
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

            // Assets sent to NFT holder
            payoutReceiver = voucherOwner;

            // Burn NFT
            redemptionVoucher.burn(tokenId);
        }

        _executeSettlement(request, payoutReceiver);
    }

    /// @notice User cancels unsettled redemption request (disabled)
    /// @dev Redemption requests cannot be cancelled once submitted, can only wait for settlement or rejection
    function cancelRedemption(uint256 requestId) external override nonReentrant {
        // Redemption cancellation feature is disabled
        revert CancellationDisabled();
    }

    // =============================================================================
    // Preview Functions - Users directly call
    // =============================================================================

    /// @notice Preview redemption (user directly calls)
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

        uint256 userBalance = _balanceOf(msg.sender);
        uint256 lockedShares = vault.lockedSharesOf(msg.sender);
        uint256 availableShares = userBalance > lockedShares ? userBalance - lockedShares : 0;

        if (availableShares < shares) {
            preview.canProcess = false;
            preview.channelReason = "Insufficient available shares";
            return preview;
        }

        uint256 nav = vault.sharePrice();
        preview.grossAmount = (shares * nav) / PPTTypes.PRECISION;
        preview.fee = _calculateRedemptionFee(preview.grossAmount, false);
        preview.netAmount = preview.grossAmount - preview.fee;

        preview.channel = PPTTypes.RedemptionChannel.STANDARD;
        preview.requiresApproval = _requiresStandardApproval(preview.grossAmount);
        preview.settlementDelay = PPTTypes.STANDARD_REDEMPTION_DELAY;
        // Note: If approval required, actual settlement time starts from approval time
        preview.estimatedSettlementTime = block.timestamp + PPTTypes.STANDARD_REDEMPTION_DELAY;

        // T+7 settlement, don't check liquidity at request time
        // Liquidity is checked at _executeSettlement
        preview.canProcess = true;
        preview.channelReason = preview.requiresApproval
            ? "Standard channel (T+7): Requires approval (>50K or >20% of dynamic quota)"
            : "Standard channel (T+7): No approval required";
    }

    /// @notice Preview emergency redemption
    function previewEmergencyRedemption(uint256 shares) external view override returns (PPTTypes.RedemptionPreview memory preview) {
        if (!vault.emergencyMode()) {
            preview.canProcess = false;
            preview.channelReason = "Emergency mode not active";
            return preview;
        }

        address owner = msg.sender;
        if (shares == 0) {
            preview.canProcess = false;
            preview.channelReason = "Shares cannot be zero";
            return preview;
        }

        uint256 userBalance = _balanceOf(owner);
        uint256 lockedShares = vault.lockedSharesOf(owner);
        uint256 availableShares = userBalance > lockedShares ? userBalance - lockedShares : 0;

        if (availableShares < shares) {
            preview.canProcess = false;
            preview.channelReason = "Insufficient available shares";
            return preview;
        }

        uint256 nav = vault.sharePrice();
        preview.grossAmount = (shares * nav) / PPTTypes.PRECISION;
        preview.fee = _calculateRedemptionFee(preview.grossAmount, true);
        preview.netAmount = preview.grossAmount - preview.fee;
        preview.channel = PPTTypes.RedemptionChannel.EMERGENCY;
        preview.requiresApproval = _requiresEmergencyApproval(preview.grossAmount);
        preview.settlementDelay = PPTTypes.EMERGENCY_REDEMPTION_DELAY;
        preview.estimatedSettlementTime = block.timestamp + PPTTypes.EMERGENCY_REDEMPTION_DELAY;

        // Check emergency quota (hard limit, deducted at request time)
        uint256 quota = vault.emergencyQuota();
        if (preview.grossAmount > quota) {
            preview.canProcess = false;
            preview.channelReason = "Emergency channel: Quota exceeded";
            return preview;
        }

        // T+1 settlement, don't check liquidity at request time
        // Liquidity is checked at _executeSettlement
        preview.canProcess = true;
        preview.channelReason = preview.requiresApproval
            ? "Emergency channel (T+1): Requires approval (>30K or >20% of emergency quota), +1% fee"
            : "Emergency channel (T+1): No approval required, +1% fee";
    }

    // =============================================================================
    // Approval Functions - VIP Approver calls
    // =============================================================================

    /// @notice Approve redemption (using default settlement time)
    /// @dev Standard channel +7 days, emergency channel +1 day
    function approveRedemption(uint256 requestId) external override onlyRole(VIP_APPROVER_ROLE) {
        _approveRedemptionCore(requestId, 0);
    }

    /// @notice Approve redemption with custom settlement date
    /// @dev customSettlementTime=0 uses default delay; delay > voucherThreshold generates NFT
    /// @param requestId Redemption request ID
    /// @param customSettlementTime Custom settlement timestamp (0 means use default)
    function approveRedemptionWithDate(
        uint256 requestId,
        uint256 customSettlementTime
    ) external onlyRole(VIP_APPROVER_ROLE) {
        _approveRedemptionCore(requestId, customSettlementTime);
    }

    /// @dev Approval core logic (shared by approveRedemption and approveRedemptionWithDate)
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

        // Calculate delay and decide whether to generate NFT
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

    function rejectRedemption(uint256 requestId, string calldata reason) external override onlyRole(VIP_APPROVER_ROLE) {
        PPTTypes.RedemptionRequest storage request = _requests[requestId];

        if (request.requestId == 0) revert RequestNotFound(requestId);
        if (!request.requiresApproval) revert NotPendingApproval(requestId);
        if (request.status != PPTTypes.RedemptionStatus.PENDING_APPROVAL) {
            revert NotPendingApproval(requestId);
        }

        request.status = PPTTypes.RedemptionStatus.CANCELLED;

        // PENDING_APPROVAL status: Only pending approval shares were added at request time (doesn't affect NAV)
        // On rejection: Remove pending approval shares marker, user can freely transfer
        // No need to removeRedemptionLiability (because it was never added)
        // No need to removeLiability (because settlementTime=0, no daily liability was recorded)
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

        // Note: T+7 settlement, don't check liquidity at request time
        // Liquidity check happens at _executeSettlement

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
            // Requires approval: Only mark pending approval shares, don't lock or add liability
            // Completely doesn't affect NAV, but restricts transfers
            vault.addPendingApprovalShares(owner, shares);
            _pendingApprovals.push(requestId);
            totalPendingApprovalAmount += grossAmount;
        } else {
            // No approval needed: Lock shares + add liability + daily liability
            vault.lockShares(owner, shares);
            vault.addRedemptionLiability(grossAmount);
            _addDailyLiability(settlementTime, grossAmount);
        }

        emit RedemptionRequested(
            requestId, owner, receiver, shares, grossAmount, estimatedFee,
            PPTTypes.RedemptionChannel.STANDARD, requiresApproval, settlementTime, 0
        );

        _checkLiquidityAndAlert();
    }

    function _processEmergencyRedemption(
        address owner,
        uint256 shares,
        address receiver,
        uint256 grossAmount,
        uint256 nav
    ) internal returns (uint256 requestId) {
        // Check emergency quota
        uint256 quota = vault.emergencyQuota();
        if (grossAmount > quota) {
            revert EmergencyQuotaExceeded(quota, grossAmount);
        }

        bool requiresApproval = _requiresEmergencyApproval(grossAmount);
        uint256 estimatedFee = _calculateRedemptionFee(grossAmount, true);

        // Note: T+1 settlement, don't check liquidity at request time
        // Liquidity check happens at _executeSettlement

        // Deduct emergency quota (regardless of approval requirement)
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
            // Requires approval: Only mark pending approval shares, don't lock or add liability
            // Completely doesn't affect NAV, but restricts transfers
            vault.addPendingApprovalShares(owner, shares);
            _pendingApprovals.push(requestId);
            totalPendingApprovalAmount += grossAmount;
        } else {
            // No approval needed: Lock shares + add liability + daily liability
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
        // Safety check: Ensure request is valid and status is correct
        if (request.requestId == 0) revert RequestNotFound(0);
        if (request.status != PPTTypes.RedemptionStatus.PENDING &&
            request.status != PPTTypes.RedemptionStatus.APPROVED) {
            revert InvalidRequestStatus(request.requestId);
        }
        if (block.timestamp < request.settlementTime) {
            revert SettlementTimeNotReached(request.settlementTime, block.timestamp);
        }

        bool isEmergency = request.channel == PPTTypes.RedemptionChannel.EMERGENCY;
        uint256 actualFee = _calculateRedemptionFee(request.grossAmount, isEmergency);
        uint256 payoutAmount = request.grossAmount - actualFee;

        // 1. Calculate settlement available funds (don't deduct emergencyQuota, it's a limit at request time)
        uint256 rawCash = IERC20(_asset()).balanceOf(address(vault));
        uint256 fees = vault.withdrawableRedemptionFees();
        uint256 locked = vault.lockedMintAssets();

        // Available = cash - fee reserve - locked assets
        uint256 reserved = fees + locked;
        uint256 availableCash = rawCash > reserved ? rawCash - reserved : 0;

        // 2. If available funds insufficient, try waterfall liquidation TIER_1_CASH
        if (availableCash < payoutAmount) {
            uint256 deficit = payoutAmount - availableCash;

            // Call AssetController waterfall liquidation Layer1 yield assets
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
                revert InsufficientLiquidity(availableCash, payoutAmount);
            }
        }

        // 3. Remove liability at settlement (if settlement time exists)
        if (request.settlementTime > 0) {
            _removeLiability(request.settlementTime, request.grossAmount);
        }

        // 4. Execute settlement (assets sent to payoutReceiver, may be original receiver or NFT holder)
        vault.burnLockedShares(request.owner, request.shares);
        vault.removeRedemptionLiability(request.grossAmount);
        vault.addRedemptionFee(actualFee);
        vault.transferAssetTo(payoutReceiver, payoutAmount);

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

    /// @notice Determine if standard channel requires approval
    /// @dev Condition: Single > 50K USDT or > 20% of dynamic quota
    function _requiresStandardApproval(uint256 amount) internal view returns (bool) {
        // 1. Absolute threshold: > 50K USDT requires approval
        if (amount > PPTTypes.STANDARD_APPROVAL_AMOUNT) {
            return true;
        }
        // 2. Ratio threshold: > 20% of dynamic quota requires approval
        uint256 quota = vault.getStandardChannelQuota();
        uint256 ratioThreshold = (quota * PPTTypes.STANDARD_APPROVAL_QUOTA_RATIO) / PPTTypes.BASIS_POINTS;
        return amount > ratioThreshold;
    }

    /// @notice Determine if emergency channel requires approval
    /// @dev Condition: Single > 30K USDT or > 20% of emergency quota balance
    function _requiresEmergencyApproval(uint256 amount) internal view returns (bool) {
        // 1. Absolute threshold: > 30K USDT requires approval
        if (amount > PPTTypes.EMERGENCY_APPROVAL_AMOUNT) {
            return true;
        }
        // 2. Ratio threshold: > 20% of emergency quota balance requires approval
        uint256 emergencyQuota = vault.emergencyQuota();
        uint256 ratioThreshold = (emergencyQuota * PPTTypes.EMERGENCY_APPROVAL_QUOTA_RATIO) / PPTTypes.BASIS_POINTS;
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

    function _removeFromPendingApprovals(uint256 requestId) internal {
        uint256 len = _pendingApprovals.length;
        for (uint256 i = 0; i < len; i++) {
            if (_pendingApprovals[i] == requestId) {
                _pendingApprovals[i] = _pendingApprovals[len - 1];
                _pendingApprovals.pop();
                return;
            }
        }
    }

    function _checkLiquidityAndAlert() internal {
        if (block.timestamp < _lastLiquidityAlertTime + 1 hours) return;

        uint256 available = vault.getAvailableLiquidity();
        uint256 gross = _totalAssets() + vault.totalRedemptionLiability();
        if (gross == 0) return;

        uint256 ratio = (available * PPTTypes.BASIS_POINTS) / gross;

        if (ratio < PPTTypes.CRITICAL_LIQUIDITY_THRESHOLD) {
            emit CriticalLiquidityAlert(ratio, PPTTypes.CRITICAL_LIQUIDITY_THRESHOLD, available);
            _lastLiquidityAlertTime = block.timestamp;
        } else if (ratio < PPTTypes.LOW_LIQUIDITY_THRESHOLD) {
            emit LowLiquidityAlert(ratio, PPTTypes.LOW_LIQUIDITY_THRESHOLD, available, gross);
            _lastLiquidityAlertTime = block.timestamp;
        }
    }

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

    /// @notice Add daily liability
    function _addDailyLiability(uint256 settlementTime, uint256 amount) internal {
        uint256 dayIndex = _getDayIndex(settlementTime);
        dailyLiability[dayIndex] += amount;
        emit DailyLiabilityAdded(dayIndex, amount);
    }

    /// @notice Remove liability (distinguish between overdue and not overdue)
    /// @dev Overdue: Deduct from both dailyLiability[dayIndex] and overdueLiability (overdueLiability is cache)
    ///      Not overdue: Only deduct from dailyLiability[dayIndex]
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

    /// @notice Calculate total liability for next 7 days (called by Vault)
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

    /// @notice Get daily liability (for external queries)
    function getDailyLiability(uint256 dayIndex) public view returns (uint256) {
        return dailyLiability[dayIndex];
    }

    /// @notice Process yesterday's due to overdue (backend/Keeper daily call)
    // function processOverdueLiability() external {
    //     uint256 yesterday = _getDayIndex(block.timestamp) - 1;
    //     uint256 amount = dailyLiability[yesterday];
    //     if (amount > 0) {
    //         overdueLiability += amount;
    //         dailyLiability[yesterday] = 0;
    //         emit OverdueLiabilityProcessed(yesterday, amount);
    //     }
    // }

    /// @notice Batch process overdue liability for past N days
    function processOverdueLiabilityBatch(uint256 daysBack) external {
        overdueLiability=0;
        uint256 today = _getDayIndex(block.timestamp);
        for (uint256 i = 1; i <= daysBack; i++) {
            uint256 dayIndex = today - i;
            uint256 amount = dailyLiability[dayIndex];
            if (amount > 0) {
                overdueLiability += amount;
                //dailyLiability[dayIndex] = 0;
                //emit OverdueLiabilityProcessed(dayIndex, amount);
            }
        }
    }

    /// @notice Admin adjust overdueLiability (emergency/fix use)
    function adjustOverdueLiability(uint256 amount) external onlyRole(ADMIN_ROLE) {
        overdueLiability = amount;
    }

    /// @notice Admin adjust daily liability (emergency/fix use)
    function adjustDailyLiability(uint256 dayIndex, uint256 amount) external onlyRole(ADMIN_ROLE) {
        dailyLiability[dayIndex] = amount;
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice Set redemption voucher NFT contract
    /// @param voucher_ RedemptionVoucher contract address
    function setRedemptionVoucher(address voucher_) external onlyRole(ADMIN_ROLE) {
        address old = address(redemptionVoucher);
        redemptionVoucher = IRedemptionVoucher(voucher_);
        emit RedemptionVoucherUpdated(old, voucher_);
    }

    /// @notice Set NFT generation threshold
    /// @param threshold_ Delay threshold (seconds), generate NFT when exceeds this threshold
    function setVoucherThreshold(uint256 threshold_) external onlyRole(ADMIN_ROLE) {
        uint256 old = voucherThreshold;
        voucherThreshold = threshold_;
        emit VoucherThresholdUpdated(old, threshold_);
    }

    function setAssetScheduler(address scheduler) external onlyRole(ADMIN_ROLE) {
        address old = address(assetScheduler);
        assetScheduler = IAssetScheduler(scheduler);
        emit AssetSchedulerUpdated(old, scheduler);
    }

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

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}
