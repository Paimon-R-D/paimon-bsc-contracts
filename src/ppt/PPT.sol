// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PPTTypes} from "./PPTTypes.sol";
import {IPPT, IAssetController, IRedemptionManager} from "./IPPTContracts.sol";

/// @title PPT (Paimon Prime Token)
/// @author Paimon Yield Protocol
/// @notice FoF (Fund of Funds) Vault - ERC4626 Core Contract (UUPS Upgradeable)
/// @dev Redemption operations call RedemptionManager directly, asset operations call AssetController directly
contract PPT is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IPPT
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    // =============================================================================
    // Constants
    // =============================================================================

    /// @notice Standard channel application limit ratio (default 70% = 7000 / 10000, configurable)
    uint256 public standardQuotaRatio = 7000;

    // =============================================================================
    // Roles
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Authorized contract role (RedemptionManager and AssetController)
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice Asset controller (for calculating asset value)
    IAssetController public assetController;

    /// @notice Redemption manager (for getting liability data)
    IRedemptionManager public redemptionManager;

    /// @notice Total redemption liability
    uint256 public override totalRedemptionLiability;

    /// @notice Total locked shares
    uint256 public override totalLockedShares;

    /// @notice Withdrawable redemption fees
    uint256 public override withdrawableRedemptionFees;

    /// @notice Historical accumulated redemption fees
    uint256 public totalAccumulatedRedemptionFees;

    /// @notice Emergency mode
    bool public override emergencyMode;

    /// @notice Emergency application available quota (admin periodically refreshes)
    uint256 public override emergencyQuota;

    /// @notice Underlying assets locked by mint within period (not available for redemption)
    uint256 public override lockedMintAssets;

    /// @notice Locked shares per user
    mapping(address => uint256) public override lockedSharesOf;

    /// @notice Last NAV update time
    uint256 public lastNavUpdate;

    // =============================================================================
    // Events
    // =============================================================================
    
    //event DepositProcessed(address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
    event AssetControllerUpdated(address indexed oldController, address indexed newController);
    event EmergencyModeChanged(bool enabled);
    event SharesLocked(address indexed owner, uint256 shares);
    event SharesUnlocked(address indexed owner, uint256 shares);
    event SharesBurned(address indexed owner, uint256 shares);
    event RedemptionFeeAdded(uint256 fee);
    event RedemptionFeeReduced(uint256 fee);
    event NavUpdated(uint256 oldNav, uint256 newNav, uint256 timestamp);
    event EmergencyQuotaRefreshed(uint256 amount);
    event EmergencyQuotaRestored(uint256 amount);
    event LockedMintAssetsReset(uint256 oldAmount);
    event RedemptionManagerUpdated(address indexed oldManager, address indexed newManager);
    event StandardQuotaRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event PendingApprovalSharesAdded(address indexed owner, uint256 shares);
    event PendingApprovalSharesRemoved(address indexed owner, uint256 shares);
    event PendingApprovalSharesConverted(address indexed owner, uint256 shares);

    // =============================================================================
    // Errors
    // =============================================================================
    
    error ZeroAddress();
    error ZeroAmount();
    error DepositBelowMinimum(uint256 amount, uint256 minimum);
    error InsufficientShares(uint256 available, uint256 required);
    error OnlyOperator();

    // =============================================================================
    // Modifiers
    // =============================================================================
    
    modifier onlyOperator() {
        if (!hasRole(OPERATOR_ROLE, msg.sender)) revert OnlyOperator();
        _;
    }

    // =============================================================================
    // Constructor & Initializer
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize function (replaces constructor in proxy pattern)
    /// @param asset_ Underlying asset address
    /// @param admin_ Admin address
    function initialize(IERC20 asset_, address admin_) external initializer {
        if (admin_ == address(0)) revert ZeroAddress();

        __ERC4626_init(asset_);
        __ERC20_init("PPT Token", "PPT");
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);

        lastNavUpdate = block.timestamp;
        standardQuotaRatio = 7000; // Default 70%
    }

    // =============================================================================
    // UUPS Upgrade Authorization
    // =============================================================================

    /// @notice Authorize upgrade (only ADMIN can call)
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // =============================================================================
    // ERC4626 Core - View Functions
    // =============================================================================
    
    /// @notice Calculate total assets (after deducting liabilities and fees)
    function totalAssets() public view override returns (uint256) {
        uint256 grossValue = _getGrossAssets();

        // Deduct redemption liability
        if (totalRedemptionLiability >= grossValue) return 0;
        uint256 netValue = grossValue - totalRedemptionLiability;

        // Deduct withdrawable fees
        if (withdrawableRedemptionFees >= netValue) return 0;
        return netValue - withdrawableRedemptionFees;
    }

    /// @notice Effective circulating supply (excluding locked shares)
    function effectiveSupply() public view override returns (uint256) {
        uint256 total = totalSupply();
        if (totalLockedShares >= total) return 0;
        return total - totalLockedShares;
    }

    /// @notice Price per share
    function sharePrice() public view override returns (uint256) {
        uint256 supply = effectiveSupply();
        if (supply == 0) return PPTTypes.PRECISION;
        return (totalAssets() * PPTTypes.PRECISION) / supply;
    }

    /// @notice Gross assets (without deducting liabilities)
    function grossAssets() public view returns (uint256) {
        return _getGrossAssets();
    }
    
    function _getGrossAssets() internal view returns (uint256) {
        uint256 cashValue = IERC20(asset()).balanceOf(address(this));
        uint256 assetValue = address(assetController) != address(0)
            ? assetController.calculateAssetValue()
            : 0;
        return cashValue + assetValue;
    }

    // =============================================================================
    // ERC4626 Core - Conversion Overrides (Using effectiveSupply to maintain pricing consistency)
    // =============================================================================

    /// @notice Override share conversion, using effectiveSupply to maintain consistency with sharePrice
    /// @dev Default ERC4626 uses totalSupply(), but we need to use effectiveSupply()
    ///      because totalAssets() has deducted redemption liability, locked shares should also be excluded
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual override returns (uint256) {
        uint256 supply = effectiveSupply();
        return assets.mulDiv(supply + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    /// @notice Override asset conversion, using effectiveSupply to maintain consistency with sharePrice
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual override returns (uint256) {
        uint256 supply = effectiveSupply();
        return shares.mulDiv(totalAssets() + 1, supply + 10 ** _decimalsOffset(), rounding);
    }

    // =============================================================================
    // ERC4626 Core - Deposit Functions
    // =============================================================================
    
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (assets < PPTTypes.MIN_DEPOSIT) revert DepositBelowMinimum(assets, PPTTypes.MIN_DEPOSIT);
        if (receiver == address(0)) revert ZeroAddress();

        shares = previewDeposit(assets);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        // Accumulate period locked assets
        lockedMintAssets += assets;

        emit Deposit(msg.sender, receiver, assets, shares);
        //emit DepositProcessed(msg.sender, receiver, assets, shares);
    }
    
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        assets = previewMint(shares);
        if (assets < PPTTypes.MIN_DEPOSIT) revert DepositBelowMinimum(assets, PPTTypes.MIN_DEPOSIT);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        // Accumulate period locked assets
        lockedMintAssets += assets;

        emit Deposit(msg.sender, receiver, assets, shares);
        //emit DepositProcessed(msg.sender, receiver, assets, shares);
    }
    
    /// @notice Disable direct withdraw - Use RedemptionManager
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("error");
    }

    /// @notice Disable direct redeem - Use RedemptionManager
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert("error");
    }

    // =============================================================================
    // Liquidity View Functions
    // =============================================================================
    
    function getLayer1Liquidity() public view override returns (uint256) {
        if (address(assetController) == address(0)) return 0;
        return assetController.getLayerValue(PPTTypes.LiquidityTier.TIER_1_CASH);
    }
    
    function getLayer1Cash() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }
    
    function getLayer1YieldAssets() public view override returns (uint256) {
        if (address(assetController) == address(0)) return 0;
        uint256 l1Total = assetController.getLayerValue(PPTTypes.LiquidityTier.TIER_1_CASH);
        uint256 cash = getLayer1Cash();
        return l1Total > cash ? l1Total - cash : 0;
    }
    
    function getLayer2Liquidity() public view override returns (uint256) {
        if (address(assetController) == address(0)) return 0;
        return assetController.getLayerValue(PPTTypes.LiquidityTier.TIER_2_MMF);
    }
    
    function getLayer3Value() public view override returns (uint256) {
        if (address(assetController) == address(0)) return 0;
        return assetController.getLayerValue(PPTTypes.LiquidityTier.TIER_3_HYD);
    }
    
    function getAvailableLiquidity() public view override returns (uint256) {
        return getLayer1Liquidity() + getLayer2Liquidity();
    }

    /// @notice Get redeemable liquidity (Layer1 only, deducting locked assets and platform fees)
    function getRedeemableLiquidity() public view override returns (uint256) {
        uint256 layer1 = getLayer1Liquidity();
        uint256 reserved = lockedMintAssets + withdrawableRedemptionFees;
        if (layer1 <= reserved) return 0;
        return layer1 - reserved;
    }
    /// @notice Get standard channel application limit
    /// @dev Formula: (L1 + L2) × 70% - emergencyQuota - fees - lockedMint - overdue - sevenDay
    function getStandardChannelQuota() public view override returns (uint256) {
        uint256 totalLiquidity = getLayer1Liquidity() + getLayer2Liquidity();

        // 1. Maximum by ratio (default 70%)
        uint256 maxAvailable = (totalLiquidity * standardQuotaRatio) / PPTTypes.BASIS_POINTS;

        // 2. Get liability data from RedemptionManager
        uint256 overdue = address(redemptionManager) != address(0)
            ? redemptionManager.getOverdueLiability()
            : 0;
        uint256 sevenDay = address(redemptionManager) != address(0)
            ? redemptionManager.getSevenDayLiability()
            : 0;

        // 3. Calculate all deductions
        uint256 totalDeductions = emergencyQuota           // Emergency reserve (Layer1 exclusive)
                                + withdrawableRedemptionFees // Platform fees
                                + lockedMintAssets          // Period locked mint
                                + overdue                   // Overdue unsettled (must reserve)
                                + sevenDay;                 // Due in next 7 days

        // 4. Return available quota
        return maxAvailable > totalDeductions ? maxAvailable - totalDeductions : 0;
    }

    function getVaultState() external view override returns (PPTTypes.VaultState memory state) {
        state.totalAssets = totalAssets();
        state.totalSupply = totalSupply();
        state.sharePrice = sharePrice();
        state.layer1Liquidity = getLayer1Liquidity();
        state.layer2Liquidity = getLayer2Liquidity();
        state.layer3Value = getLayer3Value();
        state.totalRedemptionLiability = totalRedemptionLiability;
        state.totalLockedShares = totalLockedShares;
        state.emergencyMode = emergencyMode;
    }
    
    function getLiquidityBreakdown() external view returns (
        uint256 layer1Cash,
        uint256 layer1Yield,
        uint256 layer2MMF,
        uint256 layer3HYD
    ) {
        layer1Cash = getLayer1Cash();
        layer1Yield = getLayer1YieldAssets();
        layer2MMF = getLayer2Liquidity();
        layer3HYD = getLayer3Value();
    }

    // =============================================================================
    // Operator Functions (For RedemptionManager / AssetController calls)
    // =============================================================================
    
    function lockShares(address owner, uint256 shares) external override onlyOperator {
        uint256 available = balanceOf(owner);
        if (available < shares) revert InsufficientShares(available, shares);
        
        _transfer(owner, address(this), shares);
        totalLockedShares += shares;
        // Do we need to record this
        lockedSharesOf[owner] += shares;
        
        emit SharesLocked(owner, shares);
    }
    
    function unlockShares(address owner, uint256 shares) external override onlyOperator {
        _transfer(address(this), owner, shares);
        totalLockedShares -= shares;
        lockedSharesOf[owner] -= shares;
        
        emit SharesUnlocked(owner, shares);
    }
    
    function burnLockedShares(address owner, uint256 shares) external override onlyOperator {
        _burn(address(this), shares);
        totalLockedShares -= shares;
        lockedSharesOf[owner] -= shares;
        
        emit SharesBurned(owner, shares);
    }
    
    function addRedemptionLiability(uint256 amount) external override onlyOperator {
        totalRedemptionLiability += amount;
    }
    
    function removeRedemptionLiability(uint256 amount) external override onlyOperator {
        totalRedemptionLiability -= amount;
    }
    
    function addRedemptionFee(uint256 fee) external override onlyOperator {
        totalAccumulatedRedemptionFees += fee;
        withdrawableRedemptionFees += fee;
        emit RedemptionFeeAdded(fee);
    }
    
    function reduceRedemptionFee(uint256 fee) external override onlyOperator {
        withdrawableRedemptionFees -= fee;
        emit RedemptionFeeReduced(fee);
    }
    
    function transferAssetTo(address to, uint256 amount) external override onlyOperator {
        IERC20(asset()).safeTransfer(to, amount);
    }
    // Duplicated
    function getAssetBalance(address token) external view override returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
    
    function approveAsset(address token, address spender, uint256 amount) external override onlyOperator {
        IERC20(token).safeIncreaseAllowance(spender, amount);
    }

    /// @notice Reduce emergency application quota (called by RedemptionManager)
    function reduceEmergencyQuota(uint256 amount) external override onlyOperator {
        emergencyQuota -= amount;
    }

    /// @notice Restore emergency application quota (called on cancel/reject)
    function restoreEmergencyQuota(uint256 amount) external override onlyOperator {
        emergencyQuota += amount;
        emit EmergencyQuotaRestored(amount);
    }

    // =============================================================================
    // Pending Approval Shares Management (Does not affect NAV)
    // =============================================================================

    /// @notice Add pending approval shares (called when application requires approval)
    /// @dev Transfer shares to vault, not counted in liability and locked
    function addPendingApprovalShares(address owner, uint256 shares) external override onlyOperator {
        _transfer(owner, address(this), shares);
        emit PendingApprovalSharesAdded(owner, shares);
    }

    /// @notice Remove pending approval shares (called on rejection)
    /// @dev Return shares to user
    function removePendingApprovalShares(address owner, uint256 shares) external override onlyOperator {
        _transfer(address(this), owner, shares);
        emit PendingApprovalSharesRemoved(owner, shares);
    }

    /// @notice Convert pending approval shares to locked shares (called on approval)
    /// @dev After approval: pending → locked (shares already in vault, no need to transfer again)
    function convertPendingToLocked(address owner, uint256 shares) external override onlyOperator {
        totalLockedShares += shares;
        lockedSharesOf[owner] += shares;
        emit PendingApprovalSharesConverted(owner, shares);
        emit SharesLocked(owner, shares);
    }
    

    // =============================================================================
    // Admin Functions
    // =============================================================================
    
    /// @notice Set asset controller with validation checks
    /// @dev [M04 FIX] Added validation to prevent unsafe controller changes:
    ///      1. Cannot remove controller if redemption liability > cash balance
    ///      2. New controller's asset value should >= current value (unless current is 0)
    function setAssetController(address controller) external onlyRole(ADMIN_ROLE) {
        address old = address(assetController);

        // Get current cash balance
        uint256 cashBalance = IERC20(asset()).balanceOf(address(this));

        // Check 1: Cannot remove controller if redemption liability > cash balance
        if (controller == address(0) && totalRedemptionLiability > cashBalance) {
            revert("Cannot remove controller: redemption liability exceeds cash");
        }

        // Check 2: New controller's asset value should >= current value
        if (old != address(0) && controller != address(0)) {
            uint256 oldValue = IAssetController(old).calculateAssetValue();
            uint256 newValue = IAssetController(controller).calculateAssetValue();
            // Only enforce if there's actual asset value to preserve
            if (oldValue > 0 && newValue < oldValue) {
                revert("New controller asset value less than current");
            }
        }

        assetController = IAssetController(controller);
        emit AssetControllerUpdated(old, controller);
    }
    
    /// @notice Grant RedemptionManager or AssetController to operate Vault
    function grantOperator(address operator) external onlyRole(ADMIN_ROLE) {
        _grantRole(OPERATOR_ROLE, operator);
    }

    /// @notice Revoke operator permission
    function revokeOperator(address operator) external onlyRole(ADMIN_ROLE) {
        _revokeRole(OPERATOR_ROLE, operator);
    }
    
    function setEmergencyMode(bool enabled) external onlyRole(ADMIN_ROLE) {
        emergencyMode = enabled;
        emit EmergencyModeChanged(enabled);
    }

    /// @notice Admin refresh emergency application quota
    function refreshEmergencyQuota(uint256 amount) external override onlyRole(ADMIN_ROLE) {
        emergencyQuota = amount;
        emit EmergencyQuotaRefreshed(amount);
    }

    /// @notice Admin reset period locked assets (called on period refresh)
    function resetLockedMintAssets() external override onlyRole(ADMIN_ROLE) {
        uint256 old = lockedMintAssets;
        lockedMintAssets = 0;
        emit LockedMintAssetsReset(old);
    }

    /// @notice Set redemption manager (for getting liability data)
    function setRedemptionManager(address manager) external onlyRole(ADMIN_ROLE) {
        address old = address(redemptionManager);
        redemptionManager = IRedemptionManager(manager);
        emit RedemptionManagerUpdated(old, manager);
    }

    /// @notice Set standard channel quota ratio
    /// @param ratio Ratio value (basis points, e.g., 7000 = 70%)
    function setStandardQuotaRatio(uint256 ratio) external onlyRole(ADMIN_ROLE) {
        require(ratio <= PPTTypes.BASIS_POINTS, "Ratio exceeds 100%");
        uint256 old = standardQuotaRatio;
        standardQuotaRatio = ratio;
        emit StandardQuotaRatioUpdated(old, ratio);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    /// @notice Emergency withdraw (only in emergency mode)
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(emergencyMode, "Not in emergency mode");
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Update NAV (for recording)
    function updateNav() external {
        uint256 oldNav = sharePrice();
        lastNavUpdate = block.timestamp;
        uint256 newNav = sharePrice();
        emit NavUpdated(oldNav, newNav, block.timestamp);
    }
}