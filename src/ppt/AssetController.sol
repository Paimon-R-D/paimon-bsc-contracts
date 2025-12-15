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
/// @notice Asset Controller Contract - Manages asset allocation, purchase, redemption and fees (UUPS Upgradeable)
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
    // Roles
    // =============================================================================
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    // =============================================================================
    // External Contracts
    // =============================================================================

    IPPT public vault;
    IOracleAdapter public oracleAdapter;
    ISwapHelper public swapHelper;
    IOTCManager public otcManager;
    IAssetScheduler public assetScheduler;

    // =============================================================================
    // Asset Configuration State
    // =============================================================================
    
    PPTTypes.AssetConfig[] private _assetConfigs;
    mapping(address => uint256) private _assetIndex;
    mapping(PPTTypes.LiquidityTier => PPTTypes.LayerConfig) public layerConfigs;
    mapping(PPTTypes.LiquidityTier => address[]) private _layerAssets;

    // =============================================================================
    // Fee State
    // =============================================================================
    
    uint256 public lastFeeCollectionTime;
    uint256 public accumulatedManagementFees;
    uint256 public accumulatedPerformanceFees;
    uint256 public layer3HighWaterMark;
    address public feeRecipient;

    // =============================================================================
    // Other State
    // =============================================================================
    
    uint256 public defaultSwapSlippage;
    address[] private _yieldTokens;
    
    struct CachedValue {
        uint256 value;
        uint256 timestamp;
    }
    CachedValue private _cachedAssetValue;

    // =============================================================================
    // Events
    // =============================================================================
    
    event AssetAdded(address indexed token, PPTTypes.LiquidityTier tier, uint256 allocation);
    event AssetRemoved(address indexed token);
    event AssetAllocationUpdated(address indexed token, uint256 oldAllocation, uint256 newAllocation);
    event AssetAdapterUpdated(address indexed token, address indexed oldAdapter, address indexed newAdapter);
    event AssetPurchased(address indexed token, PPTTypes.LiquidityTier tier, uint256 usdtAmount, uint256 tokensReceived);
    event AssetRedeemed(address indexed token, PPTTypes.LiquidityTier tier, uint256 tokenAmount, uint256 usdtReceived);
    event PurchaseRouted(address indexed token, PPTTypes.LiquidityTier indexed tier, PPTTypes.PurchaseMethod method, uint256 usdtAmount, uint256 tokensReceived);
    event WaterfallLiquidation(PPTTypes.LiquidityTier tier, address indexed token, uint256 amountLiquidated, uint256 usdtReceived);
    event BufferPoolRebalanced(uint256 oldBuffer, uint256 newBuffer, uint256 targetBuffer);
    event LayerConfigUpdated(PPTTypes.LiquidityTier indexed tier, uint256 targetRatio, uint256 minRatio, uint256 maxRatio);
    event ManagementFeeCollected(uint256 feeAmount, uint256 totalAssets, uint256 period);
    event PerformanceFeeCollected(uint256 feeAmount, uint256 profit, uint256 newHighWaterMark);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event RedemptionFeesWithdrawn(address indexed recipient, uint256 amount);
    event OracleAdapterUpdated(address indexed oldOracle, address indexed newOracle);
    event SwapHelperUpdated(address indexed oldHelper, address indexed newHelper);
    event OTCManagerUpdated(address indexed oldManager, address indexed newManager);
    event AssetSchedulerUpdated(address indexed oldScheduler, address indexed newScheduler);
    event YieldCompounded(address indexed token, uint256 yieldAmount, uint256 sharesIssued);

    // =============================================================================
    // Errors
    // =============================================================================
    
    error ZeroAddress();
    error ZeroAmount();
    error AssetAlreadyExists(address token);
    error AssetNotFound(address token);
    error AssetNotPurchasable(address token);
    error InvalidAllocation(uint256 allocation);
    error InvalidLayerRatios();
    error OracleNotConfigured();
    error SwapHelperNotConfigured();
    error OTCManagerNotConfigured();
    error AssetAdapterNotConfigured(address token);
    error SubscriptionWindowClosed(address token, uint256 start, uint256 end, uint256 now_);
    error NotEnoughAvailableCash(uint256 requested, uint256 available);
    error SlippageTooHigh(uint256 provided, uint256 maxAllowed);
    error FeeRecipientNotSet();
    error NoFeesToCollect();
    error InsufficientLiquidity(uint256 available, uint256 required);

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
        feeRecipient = admin_;
        defaultSwapSlippage = 100; // 1%
        lastFeeCollectionTime = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(REBALANCER_ROLE, admin_);
    }

    // =============================================================================
    // UUPS Upgrade Authorization
    // =============================================================================

    /// @notice Authorize upgrade (only ADMIN can call)
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // =============================================================================
    // Asset Configuration (ADMIN)
    // =============================================================================
    
    function addAsset(
        address token,
        PPTTypes.LiquidityTier tier,
        uint256 targetAllocation,
        address purchaseAdapter
    ) external override onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (_assetIndex[token] != 0) revert AssetAlreadyExists(token);
        if (targetAllocation > PPTTypes.BASIS_POINTS) revert InvalidAllocation(targetAllocation);
        
        uint8 decimals = IERC20Metadata(token).decimals();
        
        _assetConfigs.push(PPTTypes.AssetConfig({
            tokenAddress: token,
            tier: tier,
            targetAllocation: targetAllocation,
            isActive: true,
            purchaseAdapter: purchaseAdapter,
            decimals: decimals,
            purchaseMethod: PPTTypes.PurchaseMethod.AUTO,
            maxSlippage: 0,
            minPurchaseAmount: 0,
            subscriptionStart: 0,
            subscriptionEnd: 0
        }));
        
        _assetIndex[token] = _assetConfigs.length;
        _layerAssets[tier].push(token);
        
        emit AssetAdded(token, tier, targetAllocation);
    }
    
    function addAssetSimple(
        address token,
        PPTTypes.LiquidityTier tier,
        uint256 targetAllocation
    ) external override onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (_assetIndex[token] != 0) revert AssetAlreadyExists(token);
        if (targetAllocation > PPTTypes.BASIS_POINTS) revert InvalidAllocation(targetAllocation);
        
        uint8 decimals = IERC20Metadata(token).decimals();
        
        _assetConfigs.push(PPTTypes.AssetConfig({
            tokenAddress: token,
            tier: tier,
            targetAllocation: targetAllocation,
            isActive: true,
            purchaseAdapter: address(0),
            decimals: decimals,
            purchaseMethod: PPTTypes.PurchaseMethod.AUTO,
            maxSlippage: 0,
            minPurchaseAmount: 0,
            subscriptionStart: 0,
            subscriptionEnd: 0
        }));
        
        _assetIndex[token] = _assetConfigs.length;
        _layerAssets[tier].push(token);
        
        emit AssetAdded(token, tier, targetAllocation);
    }
    
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
    
    function updateAssetAllocation(
        address token,
        uint256 newAllocation
    ) external override onlyRole(REBALANCER_ROLE) {
        uint256 index = _assetIndex[token];
        if (index == 0) revert AssetNotFound(token);
        if (newAllocation > PPTTypes.BASIS_POINTS) revert InvalidAllocation(newAllocation);
        
        uint256 oldAllocation = _assetConfigs[index - 1].targetAllocation;
        _assetConfigs[index - 1].targetAllocation = newAllocation;
        
        emit AssetAllocationUpdated(token, oldAllocation, newAllocation);
    }
    
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
    
    function setAssetPurchaseConfig(
        address token,
        PPTTypes.PurchaseMethod method,
        uint256 maxSlippage,
        uint256 minPurchaseAmount,
        uint256 subscriptionStart,
        uint256 subscriptionEnd
    ) external override onlyRole(ADMIN_ROLE) {
        uint256 index = _assetIndex[token];
        if (index == 0) revert AssetNotFound(token);
        if (maxSlippage > PPTTypes.MAX_SLIPPAGE_BPS) revert SlippageTooHigh(maxSlippage, PPTTypes.MAX_SLIPPAGE_BPS);
        
        PPTTypes.AssetConfig storage cfg = _assetConfigs[index - 1];
        cfg.purchaseMethod = method;
        cfg.maxSlippage = maxSlippage;
        cfg.minPurchaseAmount = minPurchaseAmount;
        cfg.subscriptionStart = subscriptionStart;
        cfg.subscriptionEnd = subscriptionEnd;
    }

    // =============================================================================
    // Asset Operations (REBALANCER)
    // =============================================================================
    
    function allocateToLayer(
        PPTTypes.LiquidityTier tier,
        uint256 amount
    ) external override onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused returns (uint256 allocated) {
        if (amount == 0) return 0;
        
        uint256 availableCash = IERC20(_asset()).balanceOf(address(vault));

        // If cash is insufficient, try waterfall liquidation
        if (amount > availableCash && tier != PPTTypes.LiquidityTier.TIER_1_CASH) {
            uint256 totalAvailable = _getTotalAvailableFunding(tier);
            if (amount > totalAvailable) return 0;
        } else if (amount > availableCash) {
            return 0;
        }
        
        bool useCascade = tier != PPTTypes.LiquidityTier.TIER_1_CASH;
        allocated = _allocateToTier(tier, amount, useCascade);
    }
    
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
            usdtReceived = swapHelper.sellRWAAsset(token, vaultAsset, tokenAmount, defaultSwapSlippage);
        } else {
            revert SwapHelperNotConfigured();
        }
        
        _cachedAssetValue.timestamp = 0;
        emit AssetRedeemed(token, config.tier, tokenAmount, usdtReceived);
    }
    
    function executeWaterfallLiquidation(
        uint256 amountNeeded,
        PPTTypes.LiquidityTier maxTier
    ) external override onlyRole(REBALANCER_ROLE) nonReentrant returns (uint256 funded) {
        return _executeWaterfallLiquidation(amountNeeded, maxTier);
    }
    
    function rebalanceBuffer() external override onlyRole(REBALANCER_ROLE) {
        PPTTypes.BufferPoolInfo memory info = getBufferPoolInfo();
        
        if (!info.needsRebalance) return;
        
        uint256 deficit = info.targetBuffer > info.totalBuffer ? info.targetBuffer - info.totalBuffer : 0;
        
        if (deficit > 0) {
            uint256 oldBuffer = info.totalBuffer;
            _executeWaterfallLiquidation(deficit, PPTTypes.LiquidityTier.TIER_2_MMF);
            uint256 newBuffer = IERC20(_asset()).balanceOf(address(vault));
            
            emit BufferPoolRebalanced(oldBuffer, newBuffer, info.targetBuffer);
        }
    }

    // =============================================================================
    // Layer Configuration (ADMIN)
    // =============================================================================
    
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
    
    function getLayerConfigs() external view override returns (
        PPTTypes.LayerConfig memory layer1,
        PPTTypes.LayerConfig memory layer2,
        PPTTypes.LayerConfig memory layer3
    ) {
        layer1 = layerConfigs[PPTTypes.LiquidityTier.TIER_1_CASH];
        layer2 = layerConfigs[PPTTypes.LiquidityTier.TIER_2_MMF];
        layer3 = layerConfigs[PPTTypes.LiquidityTier.TIER_3_HYD];
    }
    
    function validateLayerRatios() public view override returns (bool valid, uint256 totalRatio) {
        totalRatio = layerConfigs[PPTTypes.LiquidityTier.TIER_1_CASH].targetRatio +
                     layerConfigs[PPTTypes.LiquidityTier.TIER_2_MMF].targetRatio +
                     layerConfigs[PPTTypes.LiquidityTier.TIER_3_HYD].targetRatio;
        valid = (totalRatio == PPTTypes.BASIS_POINTS);
    }

    // =============================================================================
    // Fee Management (ADMIN)
    // =============================================================================
    
    function accrueManagementFee() public override {
        if (lastFeeCollectionTime == 0) {
            lastFeeCollectionTime = block.timestamp;
            return;
        }
        
        uint256 timePassed = block.timestamp - lastFeeCollectionTime;
        if (timePassed == 0) return;
        
        uint256 gross = _totalAssets() + vault.totalRedemptionLiability();
        if (gross == 0) return;
        
        uint256 fee = (gross * PPTTypes.MANAGEMENT_FEE_BPS * timePassed) / 
                      (PPTTypes.BASIS_POINTS * PPTTypes.SECONDS_PER_YEAR);
        
        accumulatedManagementFees += fee;
        lastFeeCollectionTime = block.timestamp;
        
        emit ManagementFeeCollected(fee, gross, timePassed);
    }
    
    function accruePerformanceFee() public override {
        uint256 currentLayer3Value = getLayerValue(PPTTypes.LiquidityTier.TIER_3_HYD);
        
        if (currentLayer3Value > layer3HighWaterMark) {
            uint256 profit = currentLayer3Value - layer3HighWaterMark;
            uint256 fee = (profit * PPTTypes.PERFORMANCE_FEE_BPS) / PPTTypes.BASIS_POINTS;
            
            accumulatedPerformanceFees += fee;
            layer3HighWaterMark = currentLayer3Value;
            
            emit PerformanceFeeCollected(fee, profit, currentLayer3Value);
        }
    }
    
    function collectFees() external override onlyRole(ADMIN_ROLE) {
        if (feeRecipient == address(0)) revert FeeRecipientNotSet();
        
        accrueManagementFee();
        accruePerformanceFee();
        
        uint256 totalFees = accumulatedManagementFees + accumulatedPerformanceFees;
        if (totalFees == 0) revert NoFeesToCollect();

        // Mint shares to feeRecipient
        uint256 feeShares = _previewDeposit(totalFees);
        // Note: Requires Vault to provide mintTo method, or directly transfer USDT
        // Simplified handling here: direct USDT transfer
        uint256 availableCash = IERC20(_asset()).balanceOf(address(vault));
        if (totalFees > availableCash) {
            totalFees = availableCash;
        }
        
        if (totalFees > 0) {
            vault.transferAssetTo(feeRecipient, totalFees);
        }
        
        accumulatedManagementFees = 0;
        accumulatedPerformanceFees = 0;
    }
    
    function withdrawRedemptionFees(uint256 amount) external override onlyRole(ADMIN_ROLE) {
        if (feeRecipient == address(0)) revert FeeRecipientNotSet();
        
        uint256 withdrawable = vault.withdrawableRedemptionFees();
        if (withdrawable == 0) revert NoFeesToCollect();
        
        uint256 toWithdraw = amount == 0 ? withdrawable : amount;
        if (toWithdraw > withdrawable) toWithdraw = withdrawable;
        
        uint256 availableCash = IERC20(_asset()).balanceOf(address(vault));
        if (availableCash < toWithdraw) {
            revert InsufficientLiquidity(availableCash, toWithdraw);
        }
        
        vault.reduceRedemptionFee(toWithdraw);
        vault.transferAssetTo(feeRecipient, toWithdraw);
        
        emit RedemptionFeesWithdrawn(feeRecipient, toWithdraw);
    }
    
    function setFeeRecipient(address recipient) external override onlyRole(ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        address oldRecipient = feeRecipient;
        feeRecipient = recipient;
        emit FeeRecipientUpdated(oldRecipient, recipient);
    }
    
    function setLayer3HighWaterMark(uint256 value) external override onlyRole(ADMIN_ROLE) {
        layer3HighWaterMark = value;
    }
    
    function getPendingFees() external view override returns (PPTTypes.FeeInfo memory info) {
        info.pendingManagementFee = accumulatedManagementFees;
        info.pendingPerformanceFee = accumulatedPerformanceFees;
        
        if (lastFeeCollectionTime > 0) {
            uint256 timePassed = block.timestamp - lastFeeCollectionTime;
            uint256 gross = _totalAssets() + vault.totalRedemptionLiability();
            if (gross > 0 && timePassed > 0) {
                uint256 additionalFee = (gross * PPTTypes.MANAGEMENT_FEE_BPS * timePassed) / 
                                        (PPTTypes.BASIS_POINTS * PPTTypes.SECONDS_PER_YEAR);
                info.pendingManagementFee += additionalFee;
            }
        }
        
        uint256 currentLayer3Value = getLayerValue(PPTTypes.LiquidityTier.TIER_3_HYD);
        if (currentLayer3Value > layer3HighWaterMark) {
            uint256 profit = currentLayer3Value - layer3HighWaterMark;
            uint256 additionalPerfFee = (profit * PPTTypes.PERFORMANCE_FEE_BPS) / PPTTypes.BASIS_POINTS;
            info.pendingPerformanceFee += additionalPerfFee;
        }
        
        info.totalPending = info.pendingManagementFee + info.pendingPerformanceFee;
        info.lastCollectionTime = lastFeeCollectionTime;
        info.layer3HighWaterMark = layer3HighWaterMark;
    }
    
    function getRedemptionFeeInfo() external view override returns (PPTTypes.RedemptionFeeInfo memory info) {
        info.withdrawableFees = vault.withdrawableRedemptionFees();
        // totalFees and alreadyWithdrawn need to be retrieved from Vault
        // Simplified handling: only return withdrawable
        info.totalFees = info.withdrawableFees;
        info.alreadyWithdrawn = 0;
    }

    // =============================================================================
    // OTC Management (REBALANCER)
    // =============================================================================
    
    function createOTCOrder(
        address rwaToken,
        uint256 usdtAmount,
        uint256 expectedTokens,
        address counterparty,
        uint256 expiresIn
    ) external override onlyRole(REBALANCER_ROLE) returns (uint256 orderId) {
        if (address(otcManager) == address(0)) revert OTCManagerNotConfigured();
        if (_assetIndex[rwaToken] == 0) revert AssetNotFound(rwaToken);
        
        vault.approveAsset(_asset(), address(otcManager), usdtAmount);
        orderId = otcManager.createOrder(rwaToken, usdtAmount, expectedTokens, counterparty, expiresIn);
    }
    
    function executeOTCPayment(uint256 orderId) external override onlyRole(REBALANCER_ROLE) {
        if (address(otcManager) == address(0)) revert OTCManagerNotConfigured();
        otcManager.executePayment(orderId);
        _cachedAssetValue.timestamp = 0;
    }
    
    function confirmOTCDelivery(uint256 orderId, uint256 actualTokens) external override onlyRole(REBALANCER_ROLE) {
        if (address(otcManager) == address(0)) revert OTCManagerNotConfigured();
        otcManager.confirmDelivery(orderId, actualTokens);
        _cachedAssetValue.timestamp = 0;
    }

    // =============================================================================
    // View Functions
    // =============================================================================
    
    function getAssetConfigs() external view override returns (PPTTypes.AssetConfig[] memory) {
        return _assetConfigs;
    }
    
    function getLayerAssets(PPTTypes.LiquidityTier tier) external view override returns (address[] memory) {
        return _layerAssets[tier];
    }
    
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
    
    function calculateAssetValue() public view override returns (uint256 totalValue) {
        if (_cachedAssetValue.timestamp != 0 && 
            _cachedAssetValue.timestamp + PPTTypes.CACHE_DURATION > block.timestamp) {
            return _cachedAssetValue.value;
        }
        
        return _calculateAssetValueInternal();
    }
    
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
    
    function getBufferPoolInfo() public view override returns (PPTTypes.BufferPoolInfo memory info) {
        info.cashBalance = IERC20(_asset()).balanceOf(address(vault));
        
        address[] storage l2Assets = _layerAssets[PPTTypes.LiquidityTier.TIER_2_MMF];
        for (uint256 i = 0; i < l2Assets.length; i++) {
            uint256 balance = IERC20(l2Assets[i]).balanceOf(address(vault));
            if (balance > 0 && address(oracleAdapter) != address(0)) {
                uint256 price = oracleAdapter.getPrice(l2Assets[i]);
                uint8 decimals = _assetConfigs[_assetIndex[l2Assets[i]] - 1].decimals;
                info.yieldBalance += (balance * price) / (10 ** decimals);
            }
        }
        
        info.totalBuffer = info.cashBalance + info.yieldBalance;
        
        uint256 gross = _totalAssets() + vault.totalRedemptionLiability();
        uint256 bufferTargetRatio = layerConfigs[PPTTypes.LiquidityTier.TIER_1_CASH].targetRatio +
                                    layerConfigs[PPTTypes.LiquidityTier.TIER_2_MMF].targetRatio;
        info.targetBuffer = (gross * bufferTargetRatio) / PPTTypes.BASIS_POINTS;
        
        if (gross > 0) {
            info.bufferRatio = (info.totalBuffer * PPTTypes.BASIS_POINTS) / gross;
        }
        
        info.needsRebalance = info.totalBuffer < info.targetBuffer;
    }

    // =============================================================================
    // Internal Functions
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

    function _getTotalAvailableFunding(PPTTypes.LiquidityTier targetTier) internal view returns (uint256 total) {
        total = IERC20(_asset()).balanceOf(address(vault));
        
        if (targetTier == PPTTypes.LiquidityTier.TIER_1_CASH) return total;

        // Can cascade Layer1 yield-bearing assets
        address[] storage l1Assets = _layerAssets[PPTTypes.LiquidityTier.TIER_1_CASH];
        for (uint256 i = 0; i < l1Assets.length; i++) {
            uint256 balance = IERC20(l1Assets[i]).balanceOf(address(vault));
            if (balance > 0 && address(oracleAdapter) != address(0)) {
                uint256 price = oracleAdapter.getPrice(l1Assets[i]);
                uint8 decimals = _assetConfigs[_assetIndex[l1Assets[i]] - 1].decimals;
                total += (balance * price) / (10 ** decimals);
            }
        }

        // Layer3 can also cascade Layer2
        if (targetTier == PPTTypes.LiquidityTier.TIER_3_HYD) {
            address[] storage l2Assets = _layerAssets[PPTTypes.LiquidityTier.TIER_2_MMF];
            for (uint256 i = 0; i < l2Assets.length; i++) {
                uint256 balance = IERC20(l2Assets[i]).balanceOf(address(vault));
                if (balance > 0 && address(oracleAdapter) != address(0)) {
                    uint256 price = oracleAdapter.getPrice(l2Assets[i]);
                    uint8 decimals = _assetConfigs[_assetIndex[l2Assets[i]] - 1].decimals;
                    total += (balance * price) / (10 ** decimals);
                }
            }
        }
    }
    
    function _allocateToTier(
        PPTTypes.LiquidityTier tier,
        uint256 budget,
        bool useCascade
    ) internal returns (uint256 spent) {
        if (budget == 0) return 0;
        
        address[] storage assets = _layerAssets[tier];
        if (assets.length == 0) return 0;
        
        if (useCascade) {
            uint256 availableCash = IERC20(_asset()).balanceOf(address(vault));
            if (budget > availableCash) {
                PPTTypes.LiquidityTier maxCascadeTier = tier == PPTTypes.LiquidityTier.TIER_2_MMF
                    ? PPTTypes.LiquidityTier.TIER_1_CASH
                    : PPTTypes.LiquidityTier.TIER_2_MMF;
                _executeWaterfallLiquidation(budget - availableCash, maxCascadeTier);
            }
        }
        
        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 index = _assetIndex[assets[i]];
            if (index > 0 && _assetConfigs[index - 1].isActive) {
                totalAllocation += _assetConfigs[index - 1].targetAllocation;
            }
        }
        
        if (totalAllocation == 0) return 0;
        
        uint256 remaining = budget;
        for (uint256 i = 0; i < assets.length && remaining > 0; i++) {
            uint256 index = _assetIndex[assets[i]];
            if (index == 0 || !_assetConfigs[index - 1].isActive) continue;
            
            uint256 allocation;
            if (i == assets.length - 1) {
                allocation = remaining;
            } else {
                allocation = (budget * _assetConfigs[index - 1].targetAllocation) / totalAllocation;
                if (allocation > remaining) allocation = remaining;
            }
            
            if (allocation == 0) continue;
            
            (uint256 assetSpent,) = _executePurchase(index - 1, allocation);
            spent += assetSpent;
            remaining -= assetSpent;
        }
    }
    
    function _executePurchase(
        uint256 configIndex,
        uint256 usdtAmount
    ) internal returns (uint256 spent, uint256 tokensReceived) {
        PPTTypes.AssetConfig storage config = _assetConfigs[configIndex];
        if (!config.isActive) revert AssetNotPurchasable(config.tokenAddress);
        if (usdtAmount == 0) return (0, 0);
        
        if (config.subscriptionStart != 0 && block.timestamp < config.subscriptionStart) {
            revert SubscriptionWindowClosed(config.tokenAddress, config.subscriptionStart, config.subscriptionEnd, block.timestamp);
        }
        if (config.subscriptionEnd != 0 && block.timestamp > config.subscriptionEnd) {
            revert SubscriptionWindowClosed(config.tokenAddress, config.subscriptionStart, config.subscriptionEnd, block.timestamp);
        }
        
        if (config.minPurchaseAmount > 0 && usdtAmount < config.minPurchaseAmount) {
            return (0, 0);
        }
        
        uint256 cashBalance = IERC20(_asset()).balanceOf(address(vault));
        if (usdtAmount > cashBalance) {
            revert NotEnoughAvailableCash(usdtAmount, cashBalance);
        }
        
        PPTTypes.PurchaseMethod method = config.purchaseMethod;
        if (method == PPTTypes.PurchaseMethod.AUTO) {
            method = config.purchaseAdapter != address(0) 
                ? PPTTypes.PurchaseMethod.OTC 
                : PPTTypes.PurchaseMethod.SWAP;
        }
        
        address vaultAsset = _asset();
        
        if (method == PPTTypes.PurchaseMethod.OTC) {
            if (config.purchaseAdapter == address(0)) revert AssetAdapterNotConfigured(config.tokenAddress);
            
            uint256 balBefore = IERC20(config.tokenAddress).balanceOf(address(vault));
            vault.approveAsset(vaultAsset, config.purchaseAdapter, usdtAmount);
            
            (bool success,) = config.purchaseAdapter.call(
                abi.encodeWithSignature("purchase(uint256)", usdtAmount)
            );
            require(success, "Adapter purchase failed");
            
            tokensReceived = IERC20(config.tokenAddress).balanceOf(address(vault)) - balBefore;
            spent = usdtAmount;
        } else {
            if (address(swapHelper) == address(0)) revert SwapHelperNotConfigured();
            
            uint256 slippageBps = config.maxSlippage > 0 ? config.maxSlippage : defaultSwapSlippage;
            if (slippageBps > PPTTypes.MAX_SLIPPAGE_BPS) {
                revert SlippageTooHigh(slippageBps, PPTTypes.MAX_SLIPPAGE_BPS);
            }
            
            vault.approveAsset(vaultAsset, address(swapHelper), usdtAmount);
            tokensReceived = swapHelper.buyRWAAsset(vaultAsset, config.tokenAddress, usdtAmount, slippageBps);
            spent = usdtAmount;
        }
        
        emit PurchaseRouted(config.tokenAddress, config.tier, method, usdtAmount, tokensReceived);
        _cachedAssetValue.timestamp = 0;
    }
    
    function _executeWaterfallLiquidation(
        uint256 amountNeeded,
        PPTTypes.LiquidityTier maxTier
    ) internal returns (uint256 funded) {
        if (address(swapHelper) == address(0)) return 0;
        
        uint256 remaining = amountNeeded;

        // Liquidate Layer1 yield-bearing assets
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
        
        try swapHelper.sellRWAAsset(token, _asset(), tokensToSell, defaultSwapSlippage) returns (uint256 received) {
            emit WaterfallLiquidation(tier, token, tokensToSell, received);
            return received >= amountNeeded ? 0 : amountNeeded - received;
        } catch {
            return amountNeeded;
        }
    }

    // =============================================================================
    // Yield Compound
    // =============================================================================
    
    function compoundYield() external onlyRole(REBALANCER_ROLE) {
        uint256 length = _assetConfigs.length;
        uint256 totalYield = 0;
        
        for (uint256 i = 0; i < length; i++) {
            PPTTypes.AssetConfig memory config = _assetConfigs[i];
            if (config.isActive && config.tier == PPTTypes.LiquidityTier.TIER_2_MMF) {
                uint256 yield = _collectYieldFromToken(config.tokenAddress);
                totalYield += yield;
            }
        }
        
        if (totalYield > 0) {
            _cachedAssetValue.timestamp = 0;
            emit YieldCompounded(address(0), totalYield, 0);
        }
    }
    
    function _collectYieldFromToken(address) internal pure returns (uint256) {
        return 0;
    }
    
    function addYieldToken(address token) external onlyRole(ADMIN_ROLE) {
        _yieldTokens.push(token);
    }
    
    function getYieldTokens() external view returns (address[] memory) {
        return _yieldTokens;
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================
    
    function setOracleAdapter(address oracle) external override onlyRole(ADMIN_ROLE) {
        address old = address(oracleAdapter);
        oracleAdapter = IOracleAdapter(oracle);
        emit OracleAdapterUpdated(old, oracle);
    }
    
    function setSwapHelper(address helper) external override onlyRole(ADMIN_ROLE) {
        address old = address(swapHelper);
        swapHelper = ISwapHelper(helper);
        emit SwapHelperUpdated(old, helper);
    }
    
    function setOTCManager(address manager) external override onlyRole(ADMIN_ROLE) {
        address old = address(otcManager);
        otcManager = IOTCManager(manager);
        emit OTCManagerUpdated(old, manager);
    }
    
    function setAssetScheduler(address scheduler) external override onlyRole(ADMIN_ROLE) {
        address old = address(assetScheduler);
        assetScheduler = IAssetScheduler(scheduler);
        emit AssetSchedulerUpdated(old, scheduler);
    }
    
    function setDefaultSwapSlippage(uint256 slippage) external override onlyRole(ADMIN_ROLE) {
        if (slippage > PPTTypes.MAX_SLIPPAGE_BPS) revert SlippageTooHigh(slippage, PPTTypes.MAX_SLIPPAGE_BPS);
        defaultSwapSlippage = slippage;
    }
    
    function refreshCache() external override {
        _cachedAssetValue = CachedValue({
            value: _calculateAssetValueInternal(),
            timestamp: block.timestamp
        });
    }
    
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}