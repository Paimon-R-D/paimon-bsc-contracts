// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PPTTypes} from "./PPTTypes.sol";
import {IPPT, IAssetController, IOracleAdapter, ISwapHelper, IOTCManager, IAssetScheduler} from "./IPPTContracts.sol";


/// @title AssetController
/// @author Paimon Yield Protocol
/// @notice Asset controller contract - Manages asset configuration, purchase, redemption and fees (UUPS Upgradeable)
/// @dev REBALANCER role directly calls for asset operations
contract AssetController is
    IAssetController,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // =============================================================================
    // Role Definitions
    // =============================================================================

    /// @notice Admin role - Can configure assets, set parameters, pause contract
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Rebalancer role - Can execute asset purchase, redemption, waterfall liquidation, etc.
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant KEEPER_ROLE=keccak256("KEEPER_ROLE");

    // =============================================================================
    // External Contract References
    // =============================================================================

    /// @notice PPT Vault contract - The vault holding all assets
    IPPT public vault;
    /// @notice Price oracle adapter - Gets asset prices
    IOracleAdapter public oracleAdapter;
    /// @notice Swap helper contract - Executes DEX trades
    ISwapHelper public swapHelper;


    // =============================================================================
    // Asset Configuration State
    // =============================================================================

    /// @dev Array of all added asset configurations
    PPTTypes.AssetConfig[] private _assetConfigs;
    /// @dev Mapping of asset address => config index+1 (0 means not exists)
    mapping(address => uint256) private _assetIndex;
    /// @notice Layer configurations (target ratio, min/max ratios)
    mapping(PPTTypes.LiquidityTier => PPTTypes.LayerConfig) public layerConfigs;
    /// @dev List of asset addresses in each layer
    mapping(PPTTypes.LiquidityTier => address[]) private _layerAssets;

    // =============================================================================
    // Other State
    // =============================================================================

    /// @notice Default swap slippage (basis points, 1% = 100)
    uint256 public defaultSwapSlippage;


    /// @dev Cache structure - Used to optimize frequent asset value calculations
    struct CachedValue {
        uint256 value;      // Cached total asset value
        uint256 timestamp;  // Cache timestamp
    }
    /// @dev Asset value cache
    CachedValue private _cachedAssetValue;

    // =============================================================================
    // Pending Settlement State (NAV Protection during settlement delay)
    // =============================================================================

    /// @notice Pending settlement record structure
    struct PendingSettlement {
        uint256 id;                         // Settlement ID
        PPTTypes.SettlementType sType;      // Settlement type (SALE/PURCHASE)
        address asset;                      // Asset involved (sold asset for SALE, expected asset for PURCHASE)
        uint256 assetAmount;                // Asset amount
        uint256 expectedUsdtValue;          // Expected USDT value (for NAV calculation)
        uint256 createdAt;                  // Creation timestamp
        uint256 deadline;                   // Settlement deadline
        PPTTypes.SettlementStatus status;   // Settlement status
    }

    /// @notice Pending settlement records mapping
    mapping(uint256 => PendingSettlement) public pendingSettlements;

    /// @notice Settlement ID counter
    uint256 public settlementIdCounter;

    /// @notice Total pending settlement value (USDT denominated)
    uint256 public totalPendingValue;

    /// @notice Whether asset is marked as delayed settlement type
    mapping(address => bool) public isDelayedSettlementAsset;

    /// @notice Default settlement timeout (configurable)
    uint256 public defaultSettlementTimeout;

    // =============================================================================
    // Event Definitions
    // =============================================================================

    /// @notice New asset added event
    event AssetAdded(address indexed token, PPTTypes.LiquidityTier tier);
    /// @notice Asset removed event
    event AssetRemoved(address indexed token);
    /// @notice Asset purchased event
    event AssetPurchased(address indexed token, PPTTypes.LiquidityTier tier, uint256 usdtAmount, uint256 tokensReceived);
    /// @notice Asset redeemed event
    event AssetRedeemed(address indexed token, PPTTypes.LiquidityTier tier, uint256 tokenAmount, uint256 usdtReceived);
    /// @notice Purchase routed event - Records the specific purchase method used
    event PurchaseRouted(address indexed token, PPTTypes.LiquidityTier indexed tier, PPTTypes.PurchaseMethod method, uint256 usdtAmount, uint256 tokensReceived);
    /// @notice Waterfall liquidation event - Liquidates assets from lower priority layers
    event WaterfallLiquidation(PPTTypes.LiquidityTier tier, address indexed token, uint256 amountLiquidated, uint256 usdtReceived);
    /// @notice Layer config updated event
    event LayerConfigUpdated(PPTTypes.LiquidityTier indexed tier, uint256 targetRatio, uint256 minRatio, uint256 maxRatio);
    /// @notice Redemption fees withdrawn event
    event RedemptionFeesWithdrawn(address indexed recipient, uint256 amount);
    /// @notice Oracle adapter updated event
    event OracleAdapterUpdated(address indexed oldOracle, address indexed newOracle);
    /// @notice Swap helper contract updated event
    event SwapHelperUpdated(address indexed oldHelper, address indexed newHelper);
    /// @notice Asset active status updated event
    event AssetActiveUpdated(address indexed token, bool active);
    /// @notice Asset tier updated event
    event AssetTierUpdated(address indexed token, PPTTypes.LiquidityTier oldTier, PPTTypes.LiquidityTier newTier);
    /// @notice Asset config updated event
    event AssetConfigUpdated(address indexed token, PPTTypes.LiquidityTier tier, address purchaseAdapter, PPTTypes.PurchaseMethod method, uint256 maxSlippage);
    event SwapNotExisted(address indexed assert);
    event SwapSlippageUpdate(uint256 slippage);
    event PPTUpgraded(address indexed newImplementation, uint256 timestamp, uint256 blockNumber);
    /// @notice Cache refreshed event
    event CacheRefreshed(uint256 value, uint256 timestamp);

    // ========== Pending Settlement Events ==========
    /// @notice Settlement created event
    event SettlementCreated(uint256 indexed id, PPTTypes.SettlementType sType, address indexed asset, uint256 amount, uint256 expectedValue);
    /// @notice Settlement confirmed event
    event SettlementConfirmed(uint256 indexed id, uint256 actualAmount);
    /// @notice Settlement marked as abnormal event
    event SettlementMarkedAbnormal(uint256 indexed id);
    /// @notice Delayed settlement asset configuration updated event
    event DelayedSettlementAssetUpdated(address indexed asset, bool isDelayed);
    /// @notice Default settlement timeout updated event
    event DefaultSettlementTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);

    // =============================================================================
    // Error Definitions
    // =============================================================================

    /// @notice Zero address error
    error ZeroAddress();
    /// @notice Zero amount error
    error ZeroAmount();
    /// @notice Asset already exists
    error AssetAlreadyExists(address token);
    /// @notice Asset not found
    error AssetNotFound(address token);
    /// @notice Asset not purchasable (disabled)
    error AssetNotPurchasable(address token);
    /// @notice Invalid layer ratios configuration
    error InvalidLayerRatios();
    /// @notice Swap helper not configured
    error SwapHelperNotConfigured();
    /// @notice Asset adapter not configured
    error AssetAdapterNotConfigured(address token);
    /// @notice Not enough available cash
    error NotEnoughAvailableCash(uint256 requested, uint256 available);
    /// @notice Slippage too high
    error SlippageTooHigh(uint256 provided, uint256 maxAllowed);
    /// @notice Insufficient liquidity
    error InsufficientLiquidity(uint256 available, uint256 required);
    /// @notice Attempting to set same active status
    error SameActiveStatus(bool status);
    error AssetNotAllowed(address token);

    // ========== Pending Settlement Errors ==========
    /// @notice Asset is not configured as delayed settlement type
    error NotDelayedSettlementAsset(address token);
    /// @notice Settlement not found
    error SettlementNotFound(uint256 settlementId);
    /// @notice Invalid settlement status for operation
    error InvalidSettlementStatus(uint256 settlementId, PPTTypes.SettlementStatus currentStatus);
    /// @notice Settlement not yet timed out
    error SettlementNotTimedOut(uint256 settlementId, uint256 deadline, uint256 currentTime);

    // =============================================================================
    // Constructor & Initialization
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev Constructor - Disables initialization of implementation contract (required by UUPS proxy pattern)
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize function (replaces constructor in proxy pattern)
    /// @param vault_ Vault contract address
    /// @param admin_ Admin address
    function initialize(address vault_, address admin_,address timerlock) external initializer {
        if (vault_ == address(0) || admin_ == address(0)||timerlock==address(0)) revert ZeroAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        vault = IPPT(vault_);
        defaultSwapSlippage = 100; // 1%
        defaultSettlementTimeout = 7 days; // Default 7 days settlement timeout

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(REBALANCER_ROLE, admin_);
        _grantRole(UPGRADER_ROLE, timerlock);
    }

    // =============================================================================
    // UUPS Upgrade Authorization
    // =============================================================================

    /// @notice Authorize contract upgrade (only ADMIN can call)
    /// @dev UUPS pattern requires overriding this function to control upgrade permissions
    /// @param newImplementation New implementation contract address
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        emit PPTUpgraded(newImplementation, block.timestamp, block.number);
    }

    // =============================================================================
    // Asset Configuration Management (ADMIN only)
    // =============================================================================

    /// @notice Add new asset to configuration
    /// @dev Add asset to specified layer, configure all parameters at once
    /// @param token Asset token address
    /// @param tier Liquidity tier (TIER_1_CASH/TIER_2_MMF/TIER_3_HYD)
    /// @param purchaseAdapter Purchase adapter address (for OTC purchase, 0 uses DEX)
    /// @param method Purchase method (AUTO/SWAP/OTC)
    /// @param maxSlippage Maximum slippage (basis points, 0=use default)
    function addAsset(
        address token,
        PPTTypes.LiquidityTier tier,
        address purchaseAdapter,
        PPTTypes.PurchaseMethod method,
        uint256 maxSlippage
    ) external override onlyRole(KEEPER_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (_assetIndex[token] != 0) revert AssetAlreadyExists(token);
        if (maxSlippage > PPTTypes.MAX_SLIPPAGE_BPS) revert SlippageTooHigh(maxSlippage, PPTTypes.MAX_SLIPPAGE_BPS);
         if (token == _asset()) revert AssetNotAllowed(token);

        uint8 decimals = IERC20Metadata(token).decimals();

        _assetConfigs.push(PPTTypes.AssetConfig({
            tokenAddress: token,
            tier: tier,
            isActive: true,
            purchaseAdapter: purchaseAdapter,
            decimals: decimals,
            purchaseMethod: method,
            maxSlippage: maxSlippage
        }));

        _assetIndex[token] = _assetConfigs.length;
        _layerAssets[tier].push(token);

        emit AssetAdded(token, tier);
    }

    /// @notice Remove asset from configuration
    /// @dev Remove specified asset from config array and layer asset list
    /// @param token Asset address to remove
    function removeAsset(address token) external override onlyRole(KEEPER_ROLE) {
        uint256 index = _assetIndex[token];
        if (index == 0) revert AssetNotFound(token);
        
        PPTTypes.LiquidityTier tier = _assetConfigs[index - 1].tier;
        
        uint256 lastIndex = _assetConfigs.length - 1;
        if (index - 1 != lastIndex) {
            PPTTypes.AssetConfig memory lastConfig = _assetConfigs[lastIndex];
            _assetConfigs[index - 1] = lastConfig;
            _assetIndex[lastConfig.tokenAddress] = index;
        }
        _assetConfigs.pop();
        delete _assetIndex[token];
        
        address[] storage layerAssets = _layerAssets[tier];
        for (uint256 i = 0; i < layerAssets.length; i++) {
            if (layerAssets[i] == token) {
                layerAssets[i] = layerAssets[layerAssets.length - 1];
                layerAssets.pop();
                break;
            }
        }
         //_cachedAssetValue.timestamp = 0;
        emit AssetRemoved(token);
    }

    /// @notice Update asset configuration
    /// @dev Update asset's tier, adapter, purchase method and slippage config at once
    /// @param token Asset address
    /// @param newTier New liquidity tier
    /// @param purchaseAdapter Purchase adapter address (0 uses DEX)
    /// @param method Purchase method (AUTO/SWAP/OTC)
    /// @param maxSlippage Maximum slippage (basis points)
    function updateAssetConfig(
        address token,
        PPTTypes.LiquidityTier newTier,
        address purchaseAdapter,
        PPTTypes.PurchaseMethod method,
        uint256 maxSlippage
    ) external override onlyRole(KEEPER_ROLE) {
        uint256 index = _assetIndex[token];
        if (index == 0) revert AssetNotFound(token);
        if (maxSlippage > PPTTypes.MAX_SLIPPAGE_BPS) revert SlippageTooHigh(maxSlippage, PPTTypes.MAX_SLIPPAGE_BPS);

        PPTTypes.AssetConfig storage config = _assetConfigs[index - 1];
        PPTTypes.LiquidityTier oldTier = config.tier;

        // If tier changed, update _layerAssets mapping
        if (oldTier != newTier) {
            // Remove from old tier
            address[] storage oldLayerAssets = _layerAssets[oldTier];
            for (uint256 i = 0; i < oldLayerAssets.length; i++) {
                if (oldLayerAssets[i] == token) {
                    oldLayerAssets[i] = oldLayerAssets[oldLayerAssets.length - 1];
                    oldLayerAssets.pop();
                    break;
                }
            }
            // Add to new tier
            _layerAssets[newTier].push(token);
            config.tier = newTier;
            emit AssetTierUpdated(token, oldTier, newTier);
        }

        // Update other configurations
        config.purchaseAdapter = purchaseAdapter;
        config.purchaseMethod = method;
        config.maxSlippage = maxSlippage;

        emit AssetConfigUpdated(token, newTier, purchaseAdapter, method, maxSlippage);
    }

    /// @notice Set asset active status
    /// @dev Modify asset's isActive status, supports pausing/resuming asset purchase
    /// @param token Asset address
    /// @param active Whether active (true=enabled, false=disabled)
    function setAssetActive(
        address token,
        bool active
    ) external override onlyRole(KEEPER_ROLE) {
        uint256 index = _assetIndex[token];
        if (index == 0) revert AssetNotFound(token);

        PPTTypes.AssetConfig storage config = _assetConfigs[index - 1];
        if (config.isActive == active) revert SameActiveStatus(active);

        config.isActive = active;
        emit AssetActiveUpdated(token, active);
    }

    // =============================================================================
    // Asset Operations (REBALANCER only)
    // =============================================================================


    /// @notice Purchase specified asset with specified input token
    /// @dev Use specified token from Vault to purchase target asset, choose OTC or SWAP based on config
    /// @param tokenIn Input token address (address(0) = use vault's underlying asset/USDT)
    /// @param tokenOut Asset address to purchase
    /// @param amountIn Amount of input token for purchase
    /// @return tokensReceived Amount of asset tokens received
    function purchaseAsset(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external override onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused returns (uint256 tokensReceived) {
        uint256 index = _assetIndex[tokenOut];
        if (index == 0) revert AssetNotFound(tokenOut);
        if (amountIn == 0) revert ZeroAmount();

        // If tokenIn is address(0), use vault's underlying asset (USDT)
        address actualTokenIn = tokenIn == address(0) ? _asset() : tokenIn;

        (uint256 spent, uint256 received) = _executePurchase(index - 1, actualTokenIn, amountIn);
        tokensReceived = received;

        emit AssetPurchased(tokenOut, _assetConfigs[index - 1].tier, spent, received);

        // Invalidate cache after asset purchase
        _invalidateCache();
    }

    /// @notice Redeem specified asset
    /// @dev Sell asset tokens for USDT, prioritize using adapter, otherwise use DEX swap
    /// @param token Asset address to redeem
    /// @param tokenAmount Amount of tokens to redeem
    /// @return usdtReceived Amount of USDT received
    function redeemAsset(
        address token,
        uint256 tokenAmount
    ) external override onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused returns (uint256 usdtReceived) {
        uint256 index = _assetIndex[token];
        if (index == 0) revert AssetNotFound(token);
        if (tokenAmount == 0) revert ZeroAmount();
        
        PPTTypes.AssetConfig memory config = _assetConfigs[index - 1];
        
      bool success;
           (usdtReceived, success) = _sellAsset(token, tokenAmount, config);
       if (!success) {
            revert SwapHelperNotConfigured();
        }
        emit AssetRedeemed(token, config.tier, tokenAmount, usdtReceived);

        // Invalidate cache after asset redemption
        _invalidateCache();
    }

    /// @notice Execute waterfall liquidation
    /// @dev Liquidate assets from lower priority layers to meet funding needs (Layer1 → Layer2)
    /// @param amountNeeded USDT amount needed
    /// @param maxTier Maximum tier allowed for liquidation
    /// @return funded Actual USDT amount raised
    function executeWaterfallLiquidation(
        uint256 amountNeeded,
        PPTTypes.LiquidityTier maxTier
    ) external override onlyRole(REBALANCER_ROLE) nonReentrant returns (uint256 funded) {
        funded = _executeWaterfallLiquidation(amountNeeded, maxTier);

        // Invalidate cache after liquidation
        _invalidateCache();
    }


    // =============================================================================
    // Layer Configuration (ADMIN only)
    // =============================================================================

    /// @notice Set layer configuration
    /// @dev Configure layer's target ratio, minimum ratio and maximum ratio
    /// @param tier Layer type
    /// @param targetRatio Target ratio (basis points)
    /// @param minRatio Minimum ratio (basis points)
    /// @param maxRatio Maximum ratio (basis points)
    function setLayerConfig(
        PPTTypes.LiquidityTier tier,
        uint256 targetRatio,
        uint256 minRatio,
        uint256 maxRatio
    ) external override onlyRole(KEEPER_ROLE) {
        if (targetRatio < minRatio || targetRatio > maxRatio) revert InvalidLayerRatios();
        if (maxRatio > PPTTypes.BASIS_POINTS) revert InvalidLayerRatios();
        
        layerConfigs[tier] = PPTTypes.LayerConfig({
            targetRatio: targetRatio,
            minRatio: minRatio,
            maxRatio: maxRatio
        });
        
        emit LayerConfigUpdated(tier, targetRatio, minRatio, maxRatio);
    }

    /// @notice Get all layer configurations
    /// @dev Returns configuration info for all three layers
    /// @return layer1 Layer1 (cash layer) configuration
    /// @return layer2 Layer2 (money market fund layer) configuration
    /// @return layer3 Layer3 (high yield debt layer) configuration
    function getLayerConfigs() external view override returns (
        PPTTypes.LayerConfig memory layer1,
        PPTTypes.LayerConfig memory layer2,
        PPTTypes.LayerConfig memory layer3
    ) {
        layer1 = layerConfigs[PPTTypes.LiquidityTier.TIER_1_CASH];
        layer2 = layerConfigs[PPTTypes.LiquidityTier.TIER_2_MMF];
        layer3 = layerConfigs[PPTTypes.LiquidityTier.TIER_3_HYD];
    }

    /// @notice Validate layer ratio configuration
    /// @dev Check if the sum of target ratios of all three layers equals 100%
    /// @return valid Whether valid (sum = 10000 basis points)
    /// @return totalRatio Current total ratio
    function validateLayerRatios() public view override returns (bool valid, uint256 totalRatio) {
        totalRatio = layerConfigs[PPTTypes.LiquidityTier.TIER_1_CASH].targetRatio +
                     layerConfigs[PPTTypes.LiquidityTier.TIER_2_MMF].targetRatio +
                     layerConfigs[PPTTypes.LiquidityTier.TIER_3_HYD].targetRatio;
        valid = (totalRatio == PPTTypes.BASIS_POINTS);
    }

    // =============================================================================
    // Redemption Fee Management (ADMIN only)
    // =============================================================================

    /// @notice Withdraw redemption fees
    /// @dev Withdraw fees generated from user redemptions from Vault
    /// @param amount Withdrawal amount, 0 means withdraw all available
    /// @param recipient Fee recipient address
    function withdrawRedemptionFees(uint256 amount, address recipient) external onlyRole(ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 withdrawable = vault.withdrawableRedemptionFees();
        if (withdrawable == 0) return;

        uint256 toWithdraw = amount == 0 ? withdrawable : amount;
        if (toWithdraw > withdrawable) toWithdraw = withdrawable;

        uint256 availableCash = IERC20(_asset()).balanceOf(address(vault));
        if (availableCash < toWithdraw) {
            revert InsufficientLiquidity(availableCash, toWithdraw);
        }

        vault.reduceRedemptionFee(toWithdraw);
        vault.transferAssetTo(recipient, toWithdraw);

        emit RedemptionFeesWithdrawn(recipient, toWithdraw);
    }



   

    // =============================================================================
    // View Functions
    // =============================================================================

    /// @notice Get all asset configurations
    /// @return Asset configuration array
    function getAssetConfigs() external view override returns (PPTTypes.AssetConfig[] memory) {
        return _assetConfigs;
    }

    /// @notice Get asset list for specified layer
    /// @param tier Layer type
    /// @return Asset addresses array in this layer
    function getLayerAssets(PPTTypes.LiquidityTier tier) external view override returns (address[] memory) {
        return _layerAssets[tier];
    }

    /// @notice Get total value for specified layer
    /// @dev Calculate sum of USDT value of all assets in the layer
    /// @param tier Layer type
    /// @return total Total value (USDT denominated)
    function getLayerValue(PPTTypes.LiquidityTier tier) public view override returns (uint256 total) {
        if (tier == PPTTypes.LiquidityTier.TIER_1_CASH) {
            total = IERC20(_asset()).balanceOf(address(vault));
        }
        
        address[] storage assets = _layerAssets[tier];
        for (uint256 i = 0; i < assets.length; i++) {
            address token = assets[i];
            uint256 balance = IERC20(token).balanceOf(address(vault));
            if (balance > 0 && address(oracleAdapter) != address(0)) {
                uint256 price = oracleAdapter.getPrice(token);
                uint8 decimals = _assetConfigs[_assetIndex[token] - 1].decimals;
                total += (balance * price) / (10 ** decimals);
            }
        }
    }

    /// @notice Calculate total value of all assets
    /// @dev Uses cache mechanism to optimize frequent calls, recalculate when cache expires
    /// @return totalValue Total USDT value of all assets
    function calculateAssetValue() public view override returns (uint256 totalValue) {
        // Check if cache is valid
        if (_cachedAssetValue.timestamp != 0 &&
            _cachedAssetValue.timestamp + PPTTypes.CACHE_DURATION > block.timestamp) {
            return _cachedAssetValue.value;
        }

        return _calculateAssetValueInternal();
    }

    /// @notice Force refresh and return latest asset value (for transaction operations)
    /// @dev Non-view function, updates cache to prevent arbitrage
    /// @return value Latest total asset value
    function calculateAssetValueFresh() public override returns (uint256 value) {
        value = _calculateAssetValueInternal();
        _cachedAssetValue = CachedValue({
            value: value,
            timestamp: block.timestamp
        });
        emit CacheRefreshed(value, block.timestamp);
    }

    /// @notice Refresh cache externally
    /// @dev Can be called by anyone to update cache
    function refreshCache() external override {
        uint256 value = _calculateAssetValueInternal();
        _cachedAssetValue = CachedValue({
            value: value,
            timestamp: block.timestamp
        });
        emit CacheRefreshed(value, block.timestamp);
    }

    /// @notice Invalidate cache
    /// @dev Internal function to invalidate cache when assets change
    function _invalidateCache() internal {
        _cachedAssetValue.timestamp = 0;
    }

    /// @dev Internal function: Calculate total value of all assets (without cache)
    /// @notice Includes pending settlement value to protect NAV during settlement delays
    function _calculateAssetValueInternal() internal view returns (uint256 totalValue) {
        if (address(oracleAdapter) == address(0)) return totalPendingValue;

        uint8 baseDecimals = IERC20Metadata(_asset()).decimals();

        // 1. Calculate vault's held assets (existing logic)
        for (uint256 i = 0; i < _assetConfigs.length; i++) {
            PPTTypes.AssetConfig memory config = _assetConfigs[i];
            if (!config.isActive) continue;

            uint256 balance = IERC20(config.tokenAddress).balanceOf(address(vault));
            if (balance == 0) continue;

            uint256 price = oracleAdapter.getPrice(config.tokenAddress);
            uint256 value = (balance * price) / (10 ** config.decimals);

            if (baseDecimals < 18) {
                value = value / (10 ** (18 - baseDecimals));
            } else if (baseDecimals > 18) {
                value = value * (10 ** (baseDecimals - 18));
            }

            totalValue += value;
        }

        // 2. Add pending settlement receivable value (KEY ADDITION for NAV protection!)
        totalValue += totalPendingValue;
    }


    // =============================================================================
    // Internal Helper Functions
    // =============================================================================

    /// @dev Get underlying asset address (via IERC4626)
    function _asset() internal view returns (address) {
        return IERC4626(address(vault)).asset();
    }

    /// @dev Get Vault total assets
    function _totalAssets() internal view returns (uint256) {
        return IERC4626(address(vault)).totalAssets();
    }

    /// @dev Preview shares obtainable from deposit
    function _previewDeposit(uint256 assets) internal view returns (uint256) {
        return IERC4626(address(vault)).previewDeposit(assets);
    }



    /// @dev Execute asset purchase
    /// @param configIndex Asset config index
    /// @param tokenIn Input token address for purchase
    /// @param amountIn Amount of input token for purchase
    /// @return spent Actual token spent
    /// @return tokensReceived Amount of tokens received
    ///
    /// @notice Purchase flow description:
    /// ┌─────────────────────────────────────────────────────────┐
    /// │  Step 0: Pre-validation checks                          │
    /// │    - Asset enabled, amount not 0, balance check         │
    /// ├─────────────────────────────────────────────────────────┤
    /// │  Step 1: Determine purchase method                      │
    /// │    AUTO mode: has adapter→OTC / no adapter→SWAP         │
    /// ├─────────────────────────────────────────────────────────┤
    /// │  Step 2: Execute purchase                               │
    /// │    OTC mode: adapter.purchase() → balance diff for gain │
    /// │    SWAP mode: swapHelper.buyRWAAsset() → direct return  │
    /// ├─────────────────────────────────────────────────────────┤
    /// │  Step 3: Cleanup                                        │
    /// │    Emit events, invalidate cache                        │
    /// └─────────────────────────────────────────────────────────┘
    ///
    /// Comparison of two purchase modes:
    /// | Feature   | OTC Mode              | SWAP Mode              |
    /// |-----------|----------------------|------------------------|
    /// | Use Case  | RWA, large amount,KYC| On-chain liquid tokens |
    /// | Executor  | Custom adapter       | SwapHelper (DEX aggr.) |
    /// | Examples  | T-Bill tokens, PE    | aUSDC, stETH           |
    ///
    function _executePurchase(
        uint256 configIndex,    // Asset index in _assetConfigs array
        address tokenIn,        // Input token address for purchase
        uint256 amountIn        // Amount of input token for purchase
    ) internal returns (uint256 spent, uint256 tokensReceived) {

        // ==================== Step 0: Pre-validation checks ====================

        // Get asset config from storage (use storage reference to save gas)
        PPTTypes.AssetConfig storage config = _assetConfigs[configIndex];

        // Check 1: Asset must be enabled, disabled assets cannot be purchased
        if (!config.isActive) revert AssetNotPurchasable(config.tokenAddress);

        // Check 2: Purchase amount cannot be 0, return directly if 0
        if (amountIn == 0) return (0, 0);

        // Check 3: Vault token balance must be sufficient
        uint256 vaultBalance = IERC20(tokenIn).balanceOf(address(vault));

        // For vault's underlying asset (USDT), need to check reserved amounts
        address vaultAsset = _asset();
        if (tokenIn == vaultAsset) {
            uint256 withdrawable = vault.withdrawableRedemptionFees();
            uint256 lockmint = vault.lockedMintAssets();
            uint256 totalDeductions = withdrawable + lockmint;
            uint256 availableBalance = vaultBalance > totalDeductions
                                 ? vaultBalance - totalDeductions : 0;
            if (amountIn > availableBalance) {
                revert NotEnoughAvailableCash(amountIn, availableBalance);
            }
        } else {
            // For other tokens, just check balance
            if (amountIn > vaultBalance) {
                revert NotEnoughAvailableCash(amountIn, vaultBalance);
            }
        }

        // ==================== Step 1: Determine purchase method ====================

        // Get configured purchase method
        PPTTypes.PurchaseMethod method = config.purchaseMethod;

        // If AUTO mode, auto-select based on adapter configuration:
        // - Has adapter → OTC (OTC trading, suitable for large or special assets)
        // - No adapter → SWAP (DEX trading, suitable for liquid assets)
        if (method == PPTTypes.PurchaseMethod.AUTO) {
            method = config.purchaseAdapter != address(0)
                ? PPTTypes.PurchaseMethod.OTC
                : PPTTypes.PurchaseMethod.SWAP;
        }

        // ==================== Step 2: Execute purchase ====================

        if (method == PPTTypes.PurchaseMethod.OTC) {
            // ---------- OTC mode ----------
            // Use cases: RWA assets, assets without on-chain liquidity, KYC required assets

            // Check adapter is configured
            if (config.purchaseAdapter == address(0)) revert AssetAdapterNotConfigured(config.tokenAddress);

            // Record token balance before purchase (to calculate actual amount received)
            uint256 balBefore = IERC20(config.tokenAddress).balanceOf(address(vault));

            // Approve adapter to use input token from Vault
            vault.approveAsset(tokenIn, config.purchaseAdapter, amountIn);

            // Call adapter's purchase method to execute purchase
            // Adapter internally: 1.Transfer token 2.Execute purchase logic 3.Transfer tokens to Vault
            (bool success,) = config.purchaseAdapter.call(
                abi.encodeWithSignature("purchase(address,uint256)", address(vault), amountIn)
            );
            require(success, "Adapter purchase failed");  // Revert if purchase failed

            // Calculate actual tokens received via balance difference
            tokensReceived = IERC20(config.tokenAddress).balanceOf(address(vault)) - balBefore;
            spent = amountIn;  // Record token spent

        } else {
            // ---------- DEX SWAP mode ----------
            // Use cases: Tokens with on-chain liquidity (e.g., aUSDC, stETH)

            // Check SwapHelper is configured
            if (address(swapHelper) == address(0)) revert SwapHelperNotConfigured();

            // Determine slippage: prefer asset custom slippage, otherwise use default
            uint256 slippageBps = config.maxSlippage > 0 ? config.maxSlippage : defaultSwapSlippage;

            // Slippage safety check, prevent MEV attacks from high slippage
            if (slippageBps > PPTTypes.MAX_SLIPPAGE_BPS) {
                revert SlippageTooHigh(slippageBps, PPTTypes.MAX_SLIPPAGE_BPS);
            }

            // Approve SwapHelper to use input token from Vault
            vault.approveAsset(tokenIn, address(swapHelper), amountIn);

            // Execute swap on DEX via SwapHelper
            // SwapHelper internally selects optimal route (e.g., Uniswap/Curve)
            tokensReceived = swapHelper.buyRWAAsset(tokenIn, config.tokenAddress, amountIn, slippageBps, address(vault));
            spent = amountIn;  // Record token spent
        }

        // ==================== Step 3: Cleanup ====================

        // Emit purchase routed event, record purchase details
        // Contains: asset address, tier, purchase method, amount spent, tokens received
        emit PurchaseRouted(config.tokenAddress, config.tier, method, amountIn, tokensReceived);

        // Invalidate asset value cache (asset value changed after purchase)

    }

/// @dev Internal function: Execute asset sale (supports both Adapter and SwapHelper paths)
/// @param token Asset address to sell
/// @param tokenAmount Amount of tokens to sell
/// @param config Asset configuration
/// @return usdtReceived Amount of USDT received
/// @return success Whether execution was successful

function _sellAsset(
    address token,
    uint256 tokenAmount,
    PPTTypes.AssetConfig memory config
) internal returns (uint256 usdtReceived, bool success) {
    address vaultAsset = _asset();

    // Path 1: Prefer using purchaseAdapter (OTC method)
    if (config.purchaseAdapter != address(0)) {
        uint256 balanceBefore = IERC20(vaultAsset).balanceOf(address(vault));
        vault.approveAsset(token, config.purchaseAdapter, tokenAmount);
        (bool callSuccess,) = config.purchaseAdapter.call(
            abi.encodeWithSignature("redeem(address,uint256)", address(vault), tokenAmount)
        );
        if (callSuccess) {
            usdtReceived = IERC20(vaultAsset).balanceOf(address(vault)) - balanceBefore;
            return (usdtReceived, true);
        }
        // If Adapter fails, continue trying swapHelper
    }

    // Path 2: Use swapHelper (DEX method)
    if (address(swapHelper) != address(0)) {
        vault.approveAsset(token, address(swapHelper), tokenAmount);
        try swapHelper.sellRWAAsset(
            token, vaultAsset, tokenAmount, defaultSwapSlippage, address(vault)
        ) returns (uint256 received) {
            return (received, true);
        } catch {
            return (0, false);
        }
    }

    return (0, false);
}



    /// @dev Execute waterfall liquidation (internal implementation)
    /// @param amountNeeded USDT amount to raise
    /// @param maxTier Maximum tier allowed for liquidation
    /// @return funded Actual amount raised
    function _executeWaterfallLiquidation(
        uint256 amountNeeded,
        PPTTypes.LiquidityTier maxTier
    ) internal returns (uint256 funded) {
        if (address(swapHelper) == address(0)) return 0;
        
        uint256 remaining = amountNeeded;

        // Liquidate Layer1 yield assets
        address[] storage l1Assets = _layerAssets[PPTTypes.LiquidityTier.TIER_1_CASH];
        for (uint256 i = 0; i < l1Assets.length && remaining > 0; i++) {
            remaining = _liquidateAsset(l1Assets[i], remaining, PPTTypes.LiquidityTier.TIER_1_CASH);
        }

        // Liquidate Layer2
        if (maxTier >= PPTTypes.LiquidityTier.TIER_2_MMF) {
            address[] storage l2Assets = _layerAssets[PPTTypes.LiquidityTier.TIER_2_MMF];
            for (uint256 i = 0; i < l2Assets.length && remaining > 0; i++) {
                remaining = _liquidateAsset(l2Assets[i], remaining, PPTTypes.LiquidityTier.TIER_2_MMF);
            }
        }
        
      
        funded = amountNeeded - remaining;
    }

    /// @dev Liquidate single asset
    /// @param token Asset address
    /// @param amountNeeded USDT amount needed
    /// @param tier Asset's layer
    /// @return remaining Remaining unfulfilled demand
    function _liquidateAsset(
        address token,
        uint256 amountNeeded,
        PPTTypes.LiquidityTier tier
    ) internal returns (uint256 remaining) {
        uint256 balance = IERC20(token).balanceOf(address(vault));
        if (balance == 0) return amountNeeded;
        if (address(oracleAdapter) == address(0)) return amountNeeded;
        
        uint256 price = oracleAdapter.getPrice(token);
        uint8 decimals = _assetConfigs[_assetIndex[token] - 1].decimals;
        uint256 tokenValue = (balance * price) / (10 ** decimals);
        
        uint256 tokensToSell;
        if (tokenValue <= amountNeeded) {
            tokensToSell = balance;
        } else {
            tokensToSell = (amountNeeded * (10 ** decimals)) / price;
        }
        
        if (tokensToSell == 0) return amountNeeded;
        
         PPTTypes.AssetConfig memory config = _assetConfigs[_assetIndex[token] - 1];
        (uint256 received, bool success) = _sellAsset(token, tokensToSell, config);

        if (success) {
          emit WaterfallLiquidation(tier, token, tokensToSell, received);
           return received >= amountNeeded ? 0 : amountNeeded - received;
        }

        return amountNeeded;
    }

    

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice Set oracle adapter
    /// @param oracle Oracle adapter address
    function setOracleAdapter(address oracle) external override onlyRole(ADMIN_ROLE) {
        address old = address(oracleAdapter);
        oracleAdapter = IOracleAdapter(oracle);
        emit OracleAdapterUpdated(old, oracle);
    }

    /// @notice Set swap helper contract
    /// @param helper Swap helper contract address
    function setSwapHelper(address helper) external override onlyRole(ADMIN_ROLE) {
        address old = address(swapHelper);
        swapHelper = ISwapHelper(helper);
        emit SwapHelperUpdated(old, helper);
    }



    /// @notice Set default swap slippage
    /// @param slippage Slippage value (basis points, 1% = 100)
    function setDefaultSwapSlippage(uint256 slippage) external override onlyRole(ADMIN_ROLE) {
        if (slippage > PPTTypes.MAX_SLIPPAGE_BPS) revert SlippageTooHigh(slippage, PPTTypes.MAX_SLIPPAGE_BPS);
        defaultSwapSlippage = slippage;
        emit SwapSlippageUpdate(slippage);
    }

    // /// @notice Refresh asset value cache
    // /// @dev Force update asset value cache
    // function refreshCache() external override {
    //     _cachedAssetValue = CachedValue({
    //         value: _calculateAssetValueInternal(),
    //         timestamp: block.timestamp
    //     });
    // }

    // =============================================================================
    // Pending Settlement Functions (NAV Protection during settlement delay)
    // =============================================================================

    /// @notice Set whether an asset uses delayed settlement
    /// @dev Only ADMIN can configure which assets have delayed settlement
    /// @param asset Asset address
    /// @param isDelayed Whether this asset uses delayed settlement
    function setDelayedSettlementAsset(address asset, bool isDelayed) external override onlyRole(ADMIN_ROLE) {
        isDelayedSettlementAsset[asset] = isDelayed;
        emit DelayedSettlementAssetUpdated(asset, isDelayed);
    }

    /// @notice Set default settlement timeout
    /// @dev Only ADMIN can set the timeout period
    /// @param timeout Timeout in seconds
    function setDefaultSettlementTimeout(uint256 timeout) external override onlyRole(ADMIN_ROLE) {
        uint256 oldTimeout = defaultSettlementTimeout;
        defaultSettlementTimeout = timeout;
        emit DefaultSettlementTimeoutUpdated(oldTimeout, timeout);
    }

    /// @notice Redeem delayed settlement asset (creates pending settlement record)
    /// @dev REBALANCER calls this when selling assets with delayed settlement
    /// @param token Asset to sell
    /// @param tokenAmount Amount of tokens to sell
    /// @param expectedUsdt Expected USDT value (calculated by caller based on current price)
    /// @return settlementId The created settlement ID
    function redeemDelayedAsset(
        address token,
        uint256 tokenAmount,
        uint256 expectedUsdt
    ) external override onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused returns (uint256 settlementId) {
        if (!isDelayedSettlementAsset[token]) revert NotDelayedSettlementAsset(token);
        if (tokenAmount == 0) revert ZeroAmount();

        uint256 index = _assetIndex[token];
        if (index == 0) revert AssetNotFound(token);

        PPTTypes.AssetConfig memory config = _assetConfigs[index - 1];

        // Execute asset transfer out (sell via adapter or swap)
        (uint256 usdtReceived, bool success) = _sellAsset(token, tokenAmount, config);

        // If direct sale succeeded, no need for pending settlement tracking
        // This handles the case where the sale is immediate (e.g., DEX swap)
        if (success && usdtReceived > 0) {
            emit AssetRedeemed(token, config.tier, tokenAmount, usdtReceived);
            _invalidateCache();
            return 0; // No pending settlement needed
        }

        // For delayed settlement (asset transferred but USDT not yet received)
        // Create pending settlement record
        settlementId = ++settlementIdCounter;
        pendingSettlements[settlementId] = PendingSettlement({
            id: settlementId,
            sType: PPTTypes.SettlementType.SALE,
            asset: token,
            assetAmount: tokenAmount,
            expectedUsdtValue: expectedUsdt,
            createdAt: block.timestamp,
            deadline: block.timestamp + defaultSettlementTimeout,
            status: PPTTypes.SettlementStatus.PENDING
        });

        // Add to total pending value (protects NAV)
        totalPendingValue += expectedUsdt;

        emit SettlementCreated(settlementId, PPTTypes.SettlementType.SALE, token, tokenAmount, expectedUsdt);
        _invalidateCache();
    }

    /// @notice Purchase delayed settlement asset (creates pending settlement record)
    /// @dev REBALANCER calls this when buying assets with delayed settlement (e.g., CASH+)
    ///      USDT has been sent but asset tokens not yet received
    /// @param token Asset being purchased
    /// @param usdtAmount USDT amount spent on purchase
    /// @param expectedTokenValue Expected value of tokens to receive (in USDT terms, for NAV calculation)
    /// @return settlementId The created settlement ID
    function purchaseDelayedAsset(
        address token,
        uint256 usdtAmount,
        uint256 expectedTokenValue
    ) external override onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused returns (uint256 settlementId) {
        if (!isDelayedSettlementAsset[token]) revert NotDelayedSettlementAsset(token);
        if (usdtAmount == 0) revert ZeroAmount();

        // Create pending settlement record for PURCHASE type
        // This tracks: USDT sent out, waiting for asset tokens to arrive
        settlementId = ++settlementIdCounter;
        pendingSettlements[settlementId] = PendingSettlement({
            id: settlementId,
            sType: PPTTypes.SettlementType.PURCHASE,
            asset: token,
            assetAmount: usdtAmount,              // USDT amount spent
            expectedUsdtValue: expectedTokenValue, // Expected value of tokens (protects NAV)
            createdAt: block.timestamp,
            deadline: block.timestamp + defaultSettlementTimeout,
            status: PPTTypes.SettlementStatus.PENDING
        });

        // Add to total pending value (protects NAV during settlement period)
        // This compensates for the USDT that left the vault
        totalPendingValue += expectedTokenValue;

        emit SettlementCreated(settlementId, PPTTypes.SettlementType.PURCHASE, token, usdtAmount, expectedTokenValue);
        _invalidateCache();
    }

    /// @notice Confirm settlement completed (USDT arrived)
    /// @dev KEEPER calls this when USDT has arrived in vault
    /// @param settlementId Settlement ID to confirm
    function confirmSettlement(uint256 settlementId) external override onlyRole(KEEPER_ROLE) {
        PendingSettlement storage settlement = pendingSettlements[settlementId];
        if (settlement.id == 0) revert SettlementNotFound(settlementId);
        if (settlement.status != PPTTypes.SettlementStatus.PENDING) {
            revert InvalidSettlementStatus(settlementId, settlement.status);
        }

        // Remove from total pending value
        totalPendingValue -= settlement.expectedUsdtValue;

        settlement.status = PPTTypes.SettlementStatus.SETTLED;

        emit SettlementConfirmed(settlementId, settlement.expectedUsdtValue);
        _invalidateCache();
    }

    /// @notice Check and mark settlement as abnormal if timed out
    /// @dev Anyone can call this to mark timed out settlements
    /// @param settlementId Settlement ID to check
    function checkAndMarkAbnormal(uint256 settlementId) external override {
        PendingSettlement storage settlement = pendingSettlements[settlementId];
        if (settlement.id == 0) revert SettlementNotFound(settlementId);
        if (settlement.status != PPTTypes.SettlementStatus.PENDING) {
            revert InvalidSettlementStatus(settlementId, settlement.status);
        }
        if (block.timestamp <= settlement.deadline) {
            revert SettlementNotTimedOut(settlementId, settlement.deadline, block.timestamp);
        }

        // Remove from total pending value (abnormal settlements don't count in NAV)
        totalPendingValue -= settlement.expectedUsdtValue;

        settlement.status = PPTTypes.SettlementStatus.ABNORMAL;

        emit SettlementMarkedAbnormal(settlementId);
        _invalidateCache();
    }

    /// @notice Pause contract
    /// @dev Pause all non-admin operations
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause contract
    /// @dev Resume normal contract operations
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}