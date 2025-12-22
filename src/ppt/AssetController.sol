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
/// @notice Asset control contract - Manages asset configuration, purchase, redemption, and fees (UUPS Upgradeable)
/// @dev REBALANCER role calls directly for asset operations
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
    /// @notice Rebalancer role - Can execute asset purchases, redemptions, waterfall liquidations, etc.
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    // =============================================================================
    // External Contract References
    // =============================================================================

    /// @notice PPT Vault contract - Vault holding all assets
    IPPT public vault;
    /// @notice Price oracle adapter - Fetches asset prices
    IOracleAdapter public oracleAdapter;
    /// @notice Swap helper contract - Executes DEX trades
    ISwapHelper public swapHelper;


    // =============================================================================
    // Asset Configuration State
    // =============================================================================

    /// @dev Configuration array of all added assets
    PPTTypes.AssetConfig[] private _assetConfigs;
    /// @dev Asset address => config index+1 mapping (0 means non-existent)
    mapping(address => uint256) private _assetIndex;
    /// @notice Configuration for each tier (target ratio, min/max ratios)
    mapping(PPTTypes.LiquidityTier => PPTTypes.LayerConfig) public layerConfigs;
    /// @dev List of asset addresses included in each tier
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
    // Event Definitions
    // =============================================================================

    /// @notice Asset added event
    event AssetAdded(address indexed token, PPTTypes.LiquidityTier tier);
    /// @notice Asset removed event
    event AssetRemoved(address indexed token);
    /// @notice Asset adapter updated event
    event AssetAdapterUpdated(address indexed token, address indexed oldAdapter, address indexed newAdapter);
    /// @notice Asset purchased event
    event AssetPurchased(address indexed token, PPTTypes.LiquidityTier tier, uint256 usdtAmount, uint256 tokensReceived);
    /// @notice Asset redeemed event
    event AssetRedeemed(address indexed token, PPTTypes.LiquidityTier tier, uint256 tokenAmount, uint256 usdtReceived);
    /// @notice Purchase routed event - Records specific purchase method used
    event PurchaseRouted(address indexed token, PPTTypes.LiquidityTier indexed tier, PPTTypes.PurchaseMethod method, uint256 usdtAmount, uint256 tokensReceived);
    /// @notice Waterfall liquidation event - Liquidates assets from lower priority tiers
    event WaterfallLiquidation(PPTTypes.LiquidityTier tier, address indexed token, uint256 amountLiquidated, uint256 usdtReceived);
    /// @notice Layer configuration updated event
    event LayerConfigUpdated(PPTTypes.LiquidityTier indexed tier, uint256 targetRatio, uint256 minRatio, uint256 maxRatio);
    /// @notice Redemption fees withdrawn event
    event RedemptionFeesWithdrawn(address indexed recipient, uint256 amount);
    /// @notice Oracle adapter updated event
    event OracleAdapterUpdated(address indexed oldOracle, address indexed newOracle);
    /// @notice Swap helper updated event
    event SwapHelperUpdated(address indexed oldHelper, address indexed newHelper);

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
    /// @notice Invalid layer ratio configuration
    error InvalidLayerRatios();
    /// @notice Swap helper not configured
    error SwapHelperNotConfigured();
    /// @notice Asset adapter not configured
    error AssetAdapterNotConfigured(address token);
    /// @notice Insufficient available cash
    error NotEnoughAvailableCash(uint256 requested, uint256 available);
    /// @notice Slippage setting too high
    error SlippageTooHigh(uint256 provided, uint256 maxAllowed);
    /// @notice Insufficient liquidity
    error InsufficientLiquidity(uint256 available, uint256 required);

    // =============================================================================
    // Constructor & Initialization
    // =============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev Constructor - Disables implementation contract initialization (UUPS proxy pattern requirement)
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialization function (replaces constructor in proxy pattern)
    /// @param vault_ Vault contract address
    /// @param admin_ Admin address
    function initialize(address vault_, address admin_) external initializer {
        if (vault_ == address(0) || admin_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        vault = IPPT(vault_);
        defaultSwapSlippage = 100; // 1%

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(REBALANCER_ROLE, admin_);
    }

    // =============================================================================
    // UUPS Upgrade Authorization
    // =============================================================================

    /// @notice Authorize contract upgrade (ADMIN only)
    /// @dev UUPS pattern requires overriding this function to control upgrade permissions
    /// @param newImplementation New implementation contract address
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // =============================================================================
    // Asset Configuration Management (ADMIN Only)
    // =============================================================================

    /// @notice Add new asset to configuration
    /// @dev Adds asset to specified tier, uses equal allocation strategy
    /// @param token Asset token address
    /// @param tier Liquidity tier (TIER_1_CASH/TIER_2_MMF/TIER_3_HYD)
    /// @param purchaseAdapter Purchase adapter address (for OTC purchases)
    function addAsset(
        address token,
        PPTTypes.LiquidityTier tier,
        address purchaseAdapter
    ) external override onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (_assetIndex[token] != 0) revert AssetAlreadyExists(token);

        uint8 decimals = IERC20Metadata(token).decimals();

        _assetConfigs.push(PPTTypes.AssetConfig({
            tokenAddress: token,              // Asset token address
            tier: tier,                       // Liquidity tier (TIER_1_CASH/TIER_2_MMF/TIER_3_HYD)
            isActive: true,                   // Whether asset enabled
            purchaseAdapter: purchaseAdapter, // OTC purchase adapter address (0 means use DEX)
            decimals: decimals,               // Token decimals
            purchaseMethod: PPTTypes.PurchaseMethod.AUTO, // Purchase method: AUTO=auto select/SWAP=DEX/OTC=adapter
            maxSlippage: 0                    // Max slippage limit (basis points, 0=use default)
        }));

        _assetIndex[token] = _assetConfigs.length;
        _layerAssets[tier].push(token);

        emit AssetAdded(token, tier);
    }

    /// @notice Simplified add asset (without adapter)
    /// @dev Adds asset without specifying purchase adapter, will use DEX swap for purchases, uses equal allocation strategy
    /// @param token Asset token address
    /// @param tier Liquidity tier
    function addAssetSimple(
        address token,
        PPTTypes.LiquidityTier tier
    ) external override onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (_assetIndex[token] != 0) revert AssetAlreadyExists(token);

        uint8 decimals = IERC20Metadata(token).decimals();

        _assetConfigs.push(PPTTypes.AssetConfig({
            tokenAddress: token,
            tier: tier,
            isActive: true,
            purchaseAdapter: address(0),
            decimals: decimals,
            purchaseMethod: PPTTypes.PurchaseMethod.AUTO,
            maxSlippage: 0
        }));

        _assetIndex[token] = _assetConfigs.length;
        _layerAssets[tier].push(token);

        emit AssetAdded(token, tier);
    }

    /// @notice Remove asset from configuration
    /// @dev Removes specified asset from configuration array and tier asset list
    /// @param token Asset address to remove
    function removeAsset(address token) external override onlyRole(ADMIN_ROLE) {
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
        
        emit AssetRemoved(token);
    }

    /// @notice Set asset purchase adapter
    /// @dev Specifies OTC purchase adapter contract for asset
    /// @param token Asset address
    /// @param newAdapter New adapter address
    function setAssetAdapter(
        address token,
        address newAdapter
    ) external override onlyRole(ADMIN_ROLE) {
        uint256 index = _assetIndex[token];
        if (index == 0) revert AssetNotFound(token);
        
        address oldAdapter = _assetConfigs[index - 1].purchaseAdapter;
        _assetConfigs[index - 1].purchaseAdapter = newAdapter;
        
        emit AssetAdapterUpdated(token, oldAdapter, newAdapter);
    }

    /// @notice Set asset purchase configuration
    /// @dev Configures asset purchase method and slippage limits
    /// @param token Asset address
    /// @param method Purchase method (AUTO/SWAP/OTC)
    /// @param maxSlippage Max slippage (basis points)
    function setAssetPurchaseConfig(
        address token,
        PPTTypes.PurchaseMethod method,
        uint256 maxSlippage
    ) external override onlyRole(ADMIN_ROLE) {
        uint256 index = _assetIndex[token];
        if (index == 0) revert AssetNotFound(token);
        if (maxSlippage > PPTTypes.MAX_SLIPPAGE_BPS) revert SlippageTooHigh(maxSlippage, PPTTypes.MAX_SLIPPAGE_BPS);

        PPTTypes.AssetConfig storage cfg = _assetConfigs[index - 1];
        cfg.purchaseMethod = method;
        cfg.maxSlippage = maxSlippage;
    }

    // =============================================================================
    // Asset Operations (REBALANCER Only)
    // =============================================================================


    /// @notice Purchase specified asset
    /// @dev Uses USDT from Vault to purchase specified asset, selects OTC or SWAP based on configuration
    /// @param token Asset address to purchase
    /// @param usdtAmount USDT amount for purchase
    /// @return tokensReceived Asset tokens received
    function purchaseAsset(
        address token,
        uint256 usdtAmount
    ) external override onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused returns (uint256 tokensReceived) {
        uint256 index = _assetIndex[token];
        if (index == 0) revert AssetNotFound(token);
        if (usdtAmount == 0) revert ZeroAmount();
        
        (uint256 spent, uint256 received) = _executePurchase(index - 1, usdtAmount);
        tokensReceived = received;
        
        emit AssetPurchased(token, _assetConfigs[index - 1].tier, spent, received);
    }

    /// @notice Redeem specified asset
    /// @dev Sells asset tokens for USDT, uses adapter first, otherwise uses DEX swap
    /// @param token Asset address to redeem
    /// @param tokenAmount Token amount to redeem
    /// @return usdtReceived USDT received
    function redeemAsset(
        address token,
        uint256 tokenAmount
    ) external override onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused returns (uint256 usdtReceived) {
        uint256 index = _assetIndex[token];
        if (index == 0) revert AssetNotFound(token);
        if (tokenAmount == 0) revert ZeroAmount();
        
        PPTTypes.AssetConfig memory config = _assetConfigs[index - 1];
        address vaultAsset = _asset();
        
        if (config.purchaseAdapter != address(0)) {
            uint256 balanceBefore = IERC20(vaultAsset).balanceOf(address(vault));
            
            vault.approveAsset(token, config.purchaseAdapter, tokenAmount);
            
            (bool success,) = config.purchaseAdapter.call(
                abi.encodeWithSignature("redeem(uint256)", tokenAmount)
            );
            require(success, "Adapter redeem failed");
            
            usdtReceived = IERC20(vaultAsset).balanceOf(address(vault)) - balanceBefore;
        } else if (address(swapHelper) != address(0)) {
            vault.approveAsset(token, address(swapHelper), tokenAmount);
            usdtReceived = swapHelper.sellRWAAsset(token, vaultAsset, tokenAmount, defaultSwapSlippage, address(vault));
        } else {
            revert SwapHelperNotConfigured();
        }
        
        _cachedAssetValue.timestamp = 0;
        emit AssetRedeemed(token, config.tier, tokenAmount, usdtReceived);
    }

    /// @notice Execute waterfall liquidation
    /// @dev Liquidates assets by priority from lower tiers to meet funding needs (Layer1 → Layer2)
    /// @param amountNeeded USDT amount needed
    /// @param maxTier Maximum liquidation tier
    /// @return funded Actual USDT amount raised
    function executeWaterfallLiquidation(
        uint256 amountNeeded,
        PPTTypes.LiquidityTier maxTier
    ) external override onlyRole(REBALANCER_ROLE) nonReentrant returns (uint256 funded) {
        return _executeWaterfallLiquidation(amountNeeded, maxTier);
    }


    // =============================================================================
    // Layer Configuration (ADMIN Only)
    // =============================================================================

    /// @notice Set layer configuration
    /// @dev Configures layer target ratio, minimum ratio, and maximum ratio
    /// @param tier Tier type
    /// @param targetRatio Target ratio (basis points)
    /// @param minRatio Minimum ratio (basis points)
    /// @param maxRatio Maximum ratio (basis points)
    function setLayerConfig(
        PPTTypes.LiquidityTier tier,
        uint256 targetRatio,
        uint256 minRatio,
        uint256 maxRatio
    ) external override onlyRole(ADMIN_ROLE) {
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
    /// @dev Returns configuration information for all three tiers
    /// @return layer1 Layer1 (cash tier) configuration
    /// @return layer2 Layer2 (money market fund tier) configuration
    /// @return layer3 Layer3 (high-yield tier) configuration
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
    /// @dev Checks if sum of target ratios for all three tiers equals 100%
    /// @return valid Whether valid (sum = 10000 basis points)
    /// @return totalRatio Current total ratio
    function validateLayerRatios() public view override returns (bool valid, uint256 totalRatio) {
        totalRatio = layerConfigs[PPTTypes.LiquidityTier.TIER_1_CASH].targetRatio +
                     layerConfigs[PPTTypes.LiquidityTier.TIER_2_MMF].targetRatio +
                     layerConfigs[PPTTypes.LiquidityTier.TIER_3_HYD].targetRatio;
        valid = (totalRatio == PPTTypes.BASIS_POINTS);
    }

    // =============================================================================
    // Redemption Fee Management (ADMIN Only)
    // =============================================================================

    /// @notice Withdraw redemption fees
    /// @dev Withdraws fees generated from user redemptions from Vault
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

    /// @notice Get asset list for specified tier
    /// @param tier Tier type
    /// @return Array of asset addresses contained in this tier
    function getLayerAssets(PPTTypes.LiquidityTier tier) external view override returns (address[] memory) {
        return _layerAssets[tier];
    }

    /// @notice Get total value of specified tier
    /// @dev Calculates sum of USDT value of all assets in tier
    /// @param tier Tier type
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
    /// @dev Uses caching mechanism to optimize frequent calls, recalculates after cache expires
    /// @return totalValue Total USDT value of all assets
    function calculateAssetValue() public view override returns (uint256 totalValue) {
        if (_cachedAssetValue.timestamp != 0 && 
            _cachedAssetValue.timestamp + PPTTypes.CACHE_DURATION > block.timestamp) {
            return _cachedAssetValue.value;
        }
        
        return _calculateAssetValueInternal();
    }

    /// @dev Internal function: Calculate total value of all assets (without cache)
    function _calculateAssetValueInternal() internal view returns (uint256 totalValue) {
        if (address(oracleAdapter) == address(0)) return 0;
        
        uint8 baseDecimals = IERC20Metadata(_asset()).decimals();
        
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

    /// @dev Preview shares receivable from deposit
    function _previewDeposit(uint256 assets) internal view returns (uint256) {
        return IERC4626(address(vault)).previewDeposit(assets);
    }



    /// @dev Execute asset purchase
    /// @param configIndex Asset configuration index
    /// @param usdtAmount Purchase amount
    /// @return spent Actual USDT spent
    /// @return tokensReceived Tokens received
    ///
    /// @notice Purchase flow description:
    /// ┌─────────────────────────────────────────────────────────┐
    /// │  Step 0: Pre-validation checks                          │
    /// │    - Asset enabled, amount non-zero, cash balance       │
    /// ├─────────────────────────────────────────────────────────┤
    /// │  Step 1: Determine purchase method                      │
    /// │    AUTO mode: has adapter→OTC / no adapter→SWAP        │
    /// ├─────────────────────────────────────────────────────────┤
    /// │  Step 2: Execute purchase                               │
    /// │    OTC mode: adapter.purchase() → balance diff         │
    /// │    SWAP mode: swapHelper.buyRWAAsset() → direct return │
    /// ├─────────────────────────────────────────────────────────┤
    /// │  Step 3: Cleanup                                        │
    /// │    Emit event, invalidate cache                         │
    /// └─────────────────────────────────────────────────────────┘
    ///
    /// Purchase mode comparison:
    /// | Feature        | OTC Mode                  | SWAP Mode              |
    /// |----------------|---------------------------|------------------------|
    /// | Use case       | RWA, large, KYC required  | Onchain liquid tokens  |
    /// | Executor       | Custom adapter contract   | SwapHelper (DEX agg)   |
    /// | Typical assets | T-Bill tokens, funds      | aUSDC, stETH           |
    ///
    function _executePurchase(
        uint256 configIndex,    // Asset index in _assetConfigs array
        uint256 usdtAmount      // USDT amount for purchase
    ) internal returns (uint256 spent, uint256 tokensReceived) {

        // ==================== Step 0: Pre-validation checks ====================

        // Get asset config from storage (storage reference saves gas)
        PPTTypes.AssetConfig storage config = _assetConfigs[configIndex];

        // Check 1: Asset must be enabled, disabled assets cannot be purchased
        if (!config.isActive) revert AssetNotPurchasable(config.tokenAddress);

        // Check 2: Purchase amount cannot be 0, return directly if 0
        if (usdtAmount == 0) return (0, 0);

        // Check 3: Vault cash balance sufficient
        uint256 cashBalance = IERC20(_asset()).balanceOf(address(vault));  // Get Vault USDT balance
        if (usdtAmount > cashBalance) {
            revert NotEnoughAvailableCash(usdtAmount, cashBalance);  // Revert if insufficient
        }

        // ==================== Step 1: Determine purchase method ====================

        // Get configured purchase method
        PPTTypes.PurchaseMethod method = config.purchaseMethod;

        // If AUTO mode, auto-select based on adapter configuration:
        // - Has adapter → OTC (over-the-counter, suitable for large or special assets)
        // - No adapter → SWAP (DEX trading, suitable for liquid assets)
        if (method == PPTTypes.PurchaseMethod.AUTO) {
            method = config.purchaseAdapter != address(0)
                ? PPTTypes.PurchaseMethod.OTC
                : PPTTypes.PurchaseMethod.SWAP;
        }

        // Get Vault's underlying asset address (typically USDT)
        address vaultAsset = _asset();

        // ==================== Step 2: Execute purchase ====================

        if (method == PPTTypes.PurchaseMethod.OTC) {
            // ---------- OTC over-the-counter mode ----------
            // Suitable for: RWA assets, assets without onchain liquidity, KYC-required assets

            // Check adapter is configured
            if (config.purchaseAdapter == address(0)) revert AssetAdapterNotConfigured(config.tokenAddress);

            // Record token balance before purchase (to calculate actual amount received)
            uint256 balBefore = IERC20(config.tokenAddress).balanceOf(address(vault));

            // Approve adapter to use USDT from Vault
            vault.approveAsset(vaultAsset, config.purchaseAdapter, usdtAmount);

            // Call adapter's purchase method to execute purchase
            // Adapter internally: 1.Transfer USDT 2.Execute purchase logic 3.Transfer asset tokens to Vault
            (bool success,) = config.purchaseAdapter.call(
                abi.encodeWithSignature("purchase(uint256)", usdtAmount)
            );
            require(success, "Adapter purchase failed");  // Revert if purchase fails

            // Calculate actual tokens received via balance difference
            tokensReceived = IERC20(config.tokenAddress).balanceOf(address(vault)) - balBefore;
            spent = usdtAmount;  // Record USDT spent

        } else {
            // ---------- DEX SWAP mode ----------
            // Suitable for: Tokens with onchain liquidity (e.g., aUSDC, stETH, etc.)

            // Check SwapHelper is configured
            if (address(swapHelper) == address(0)) revert SwapHelperNotConfigured();

            // Determine slippage: prioritize asset custom slippage, otherwise use default
            uint256 slippageBps = config.maxSlippage > 0 ? config.maxSlippage : defaultSwapSlippage;

            // Slippage safety check, prevent high settings leading to MEV attacks
            if (slippageBps > PPTTypes.MAX_SLIPPAGE_BPS) {
                revert SlippageTooHigh(slippageBps, PPTTypes.MAX_SLIPPAGE_BPS);
            }

            // Approve SwapHelper to use USDT from Vault
            vault.approveAsset(vaultAsset, address(swapHelper), usdtAmount);

            // Execute swap on DEX via SwapHelper
            // SwapHelper internally selects optimal path (e.g., Uniswap/Curve)
            tokensReceived = swapHelper.buyRWAAsset(vaultAsset, config.tokenAddress, usdtAmount, slippageBps, address(vault));
            spent = usdtAmount;  // Record USDT spent
        }

        // ==================== Step 3: Cleanup ====================

        // Emit purchase routed event, recording detailed purchase information
        // Includes: asset address, tier, purchase method, spent amount, tokens received
        emit PurchaseRouted(config.tokenAddress, config.tier, method, usdtAmount, tokensReceived);

        // Invalidate asset value cache (since new assets purchased, total asset value changed)
        _cachedAssetValue.timestamp = 0;
    }

    /// @dev Execute waterfall liquidation (internal implementation)
    /// @param amountNeeded USDT amount to raise
    /// @param maxTier Maximum liquidation tier
    /// @return funded Actual amount raised
    function _executeWaterfallLiquidation(
        uint256 amountNeeded,
        PPTTypes.LiquidityTier maxTier
    ) internal returns (uint256 funded) {
        if (address(swapHelper) == address(0)) return 0;
        
        uint256 remaining = amountNeeded;
        
        // 清算 Layer1 生息资产
        address[] storage l1Assets = _layerAssets[PPTTypes.LiquidityTier.TIER_1_CASH];
        for (uint256 i = 0; i < l1Assets.length && remaining > 0; i++) {
            remaining = _liquidateAsset(l1Assets[i], remaining, PPTTypes.LiquidityTier.TIER_1_CASH);
        }
        
        // 清算 Layer2
        if (maxTier >= PPTTypes.LiquidityTier.TIER_2_MMF) {
            address[] storage l2Assets = _layerAssets[PPTTypes.LiquidityTier.TIER_2_MMF];
            for (uint256 i = 0; i < l2Assets.length && remaining > 0; i++) {
                remaining = _liquidateAsset(l2Assets[i], remaining, PPTTypes.LiquidityTier.TIER_2_MMF);
            }
        }
        
        _cachedAssetValue.timestamp = 0;
        funded = amountNeeded - remaining;
    }

    /// @dev Liquidate single asset
    /// @param token Asset address
    /// @param amountNeeded USDT amount needed
    /// @param tier Asset tier
    /// @return remaining Remaining unmet need
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
        
        vault.approveAsset(token, address(swapHelper), tokensToSell);

        try swapHelper.sellRWAAsset(token, _asset(), tokensToSell, defaultSwapSlippage, address(vault)) returns (uint256 received) {
            emit WaterfallLiquidation(tier, token, tokensToSell, received);
            return received >= amountNeeded ? 0 : amountNeeded - received;
        } catch {
            return amountNeeded;
        }
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
    }

    /// @notice Refresh asset value cache
    /// @dev Forces update of asset value cache
    function refreshCache() external override {
        _cachedAssetValue = CachedValue({
            value: _calculateAssetValueInternal(),
            timestamp: block.timestamp
        });
    }

    /// @notice Pause contract
    /// @dev Pauses all non-admin operations
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause contract
    /// @dev Resumes normal contract operations
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}