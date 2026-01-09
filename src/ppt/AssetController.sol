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
         _cachedAssetValue.timestamp = 0;
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


    /// @notice Purchase specified asset
    /// @dev Use USDT from Vault to purchase specified asset, choose OTC or SWAP based on config
    /// @param token Asset address to purchase
    /// @param usdtAmount USDT amount for purchase
    /// @return tokensReceived Amount of asset tokens received
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
            emit SwapNotExisted(token);
            revert SwapHelperNotConfigured();
        }
        
        _cachedAssetValue.timestamp = 0;
        emit AssetRedeemed(token, config.tier, tokenAmount, usdtReceived);
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
        return _executeWaterfallLiquidation(amountNeeded, maxTier);
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

    /// @dev Preview shares obtainable from deposit
    function _previewDeposit(uint256 assets) internal view returns (uint256) {
        return IERC4626(address(vault)).previewDeposit(assets);
    }



    /// @dev Execute asset purchase
    /// @param configIndex Asset config index
    /// @param usdtAmount Purchase amount
    /// @return spent Actual USDT spent
    /// @return tokensReceived Amount of tokens received
    ///
    /// @notice Purchase flow description:
    /// ┌─────────────────────────────────────────────────────────┐
    /// │  Step 0: Pre-validation checks                          │
    /// │    - Asset enabled, amount not 0, cash balance          │
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
        uint256 usdtAmount      // USDT amount for purchase
    ) internal returns (uint256 spent, uint256 tokensReceived) {

        // ==================== Step 0: Pre-validation checks ====================

        // Get asset config from storage (use storage reference to save gas)
        PPTTypes.AssetConfig storage config = _assetConfigs[configIndex];

        // Check 1: Asset must be enabled, disabled assets cannot be purchased
        if (!config.isActive) revert AssetNotPurchasable(config.tokenAddress);

        // Check 2: Purchase amount cannot be 0, return directly if 0
        if (usdtAmount == 0) return (0, 0);

        // Check 3: Vault cash balance must be sufficient
        uint256 vaultBalance = IERC20(_asset()).balanceOf(address(vault));  // Get USDT balance in Vault

        uint256 withdrawable = vault.withdrawableRedemptionFees();
        uint256 lockmint = vault.lockedMintAssets();

        uint256 totalDeductions = withdrawable + lockmint;
        uint256 cashBalance = vaultBalance > totalDeductions 
                             ? vaultBalance - totalDeductions : 0;
        if (usdtAmount > cashBalance) {
            revert NotEnoughAvailableCash(usdtAmount, cashBalance);  // Insufficient balance error
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

        // Get Vault's underlying asset address (usually USDT)
        address vaultAsset = _asset();

        // ==================== Step 2: Execute purchase ====================

        if (method == PPTTypes.PurchaseMethod.OTC) {
            // ---------- OTC mode ----------
            // Use cases: RWA assets, assets without on-chain liquidity, KYC required assets

            // Check adapter is configured
            if (config.purchaseAdapter == address(0)) revert AssetAdapterNotConfigured(config.tokenAddress);

            // Record token balance before purchase (to calculate actual amount received)
            uint256 balBefore = IERC20(config.tokenAddress).balanceOf(address(vault));

            // Approve adapter to use USDT from Vault
            vault.approveAsset(vaultAsset, config.purchaseAdapter, usdtAmount);

            // Call adapter's purchase method to execute purchase
            // Adapter internally: 1.Transfer USDT 2.Execute purchase logic 3.Transfer tokens to Vault
            (bool success,) = config.purchaseAdapter.call(
                abi.encodeWithSignature("purchase(uint256)", usdtAmount)
            );
            require(success, "Adapter purchase failed");  // Revert if purchase failed

            // Calculate actual tokens received via balance difference
            tokensReceived = IERC20(config.tokenAddress).balanceOf(address(vault)) - balBefore;
            spent = usdtAmount;  // Record USDT spent

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

            // Approve SwapHelper to use USDT from Vault
            vault.approveAsset(vaultAsset, address(swapHelper), usdtAmount);

            // Execute swap on DEX via SwapHelper
            // SwapHelper internally selects optimal route (e.g., Uniswap/Curve)
            tokensReceived = swapHelper.buyRWAAsset(vaultAsset, config.tokenAddress, usdtAmount, slippageBps, address(vault));
            spent = usdtAmount;  // Record USDT spent
        }

        // ==================== Step 3: Cleanup ====================

        // Emit purchase routed event, record purchase details
        // Contains: asset address, tier, purchase method, amount spent, tokens received
        emit PurchaseRouted(config.tokenAddress, config.tier, method, usdtAmount, tokensReceived);

        // Invalidate asset value cache (asset value changed after purchase)
        _cachedAssetValue.timestamp = 0;
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
        
        _cachedAssetValue.timestamp = 0;
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
        emit SwapSlippageUpdate(slippage);
    }

    /// @notice Refresh asset value cache
    /// @dev Force update asset value cache
    function refreshCache() external override {
        _cachedAssetValue = CachedValue({
            value: _calculateAssetValueInternal(),
            timestamp: block.timestamp
        });
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