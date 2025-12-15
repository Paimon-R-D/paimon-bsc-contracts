// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PPTTypes} from "./PPTTypes.sol";

/// @title IPPT
/// @notice Main Vault contract interface (custom functions, ERC4626 standard functions use IERC4626)
interface IPPT {
    // ========== Custom Query Functions ==========
    function sharePrice() external view returns (uint256);
    function effectiveSupply() external view returns (uint256);

    // ========== State Queries ==========
    function totalRedemptionLiability() external view returns (uint256);
    function totalLockedShares() external view returns (uint256);
    function withdrawableRedemptionFees() external view returns (uint256);
    function emergencyMode() external view returns (bool);
    function lockedSharesOf(address owner) external view returns (uint256);
    function pendingApprovalSharesOf(address owner) external view returns (uint256);
    function getAvailableShares(address owner) external view returns (uint256);
    function getVaultState() external view returns (PPTTypes.VaultState memory);

    // ========== Liquidity Queries ==========
    function getLayer1Liquidity() external view returns (uint256);
    function getLayer1Cash() external view returns (uint256);
    function getLayer1YieldAssets() external view returns (uint256);
    function getLayer2Liquidity() external view returns (uint256);
    function getLayer3Value() external view returns (uint256);
    function getAvailableLiquidity() external view returns (uint256);

    // ========== Redemption Liquidity and Emergency Quota ==========
    function emergencyQuota() external view returns (uint256);
    function lockedMintAssets() external view returns (uint256);
    function getRedeemableLiquidity() external view returns (uint256);
    function reduceEmergencyQuota(uint256 amount) external;
    function restoreEmergencyQuota(uint256 amount) external;
    function refreshEmergencyQuota(uint256 amount) external;
    function resetLockedMintAssets() external;

    // ========== Standard Channel Dynamic Quota ==========
    function getStandardChannelQuota() external view returns (uint256);

    // ========== For OPERATOR Role (RedemptionManager / AssetController) ==========
    function lockShares(address owner, uint256 shares) external;
    function unlockShares(address owner, uint256 shares) external;
    function burnLockedShares(address owner, uint256 shares) external;
    function addRedemptionLiability(uint256 amount) external;
    function removeRedemptionLiability(uint256 amount) external;
    function addRedemptionFee(uint256 fee) external;
    function reduceRedemptionFee(uint256 fee) external;
    function transferAssetTo(address to, uint256 amount) external;
    function getAssetBalance(address token) external view returns (uint256);
    function approveAsset(address token, address spender, uint256 amount) external;

    // ========== Pending Approval Shares Management (Does Not Affect NAV) ==========
    function addPendingApprovalShares(address owner, uint256 shares) external;
    function removePendingApprovalShares(address owner, uint256 shares) external;
    function convertPendingToLocked(address owner, uint256 shares) external;
}

/// @title IRedemptionManager
/// @notice Redemption Manager contract interface - Called directly by users
interface IRedemptionManager {
    // ========== Redemption Requests (Called directly by users) ==========
    function requestRedemption(uint256 shares, address receiver) external returns (uint256 requestId);
    function requestEmergencyRedemption(uint256 shares, address receiver) external returns (uint256 requestId);
    function cancelRedemption(uint256 requestId) external;

    // ========== Settlement ==========
    function settleRedemption(uint256 requestId) external;

    // ========== Approval (VIP_APPROVER calls) ==========
    function approveRedemption(uint256 requestId) external;
    function rejectRedemption(uint256 requestId, string calldata reason) external;

    // ========== Queries (Called directly by users) ==========
    function previewRedemption(uint256 shares) external view returns (PPTTypes.RedemptionPreview memory);
    function previewEmergencyRedemption(uint256 shares) external view returns (PPTTypes.RedemptionPreview memory);
    function getRedemptionRequest(uint256 requestId) external view returns (PPTTypes.RedemptionRequest memory);
    function getUserRedemptions(address user) external view returns (uint256[] memory);
    function getPendingApprovals() external view returns (uint256[] memory);
    function getTotalPendingApprovalAmount() external view returns (uint256);
    function getRequestCount() external view returns (uint256);

    // ========== Liability Tracking (Called by Vault) ==========
    function getSevenDayLiability() external view returns (uint256);
    function getOverdueLiability() external view returns (uint256);
    function getDailyLiability(uint256 dayIndex) external view returns (uint256);
    function processOverdueLiability() external;
}

/// @title IAssetController
/// @notice Asset Controller contract interface - Called by REBALANCER role
interface IAssetController {
    // ========== Asset Configuration (ADMIN calls) ==========
    function addAsset(
        address token,
        PPTTypes.LiquidityTier tier,
        uint256 targetAllocation,
        address purchaseAdapter
    ) external;
    function addAssetSimple(
        address token,
        PPTTypes.LiquidityTier tier,
        uint256 targetAllocation
    ) external;
    function removeAsset(address token) external;
    function updateAssetAllocation(address token, uint256 newAllocation) external;
    function setAssetAdapter(address token, address newAdapter) external;
    function setAssetPurchaseConfig(
        address token,
        PPTTypes.PurchaseMethod method,
        uint256 maxSlippage,
        uint256 minPurchaseAmount,
        uint256 subscriptionStart,
        uint256 subscriptionEnd
    ) external;

    // ========== Asset Operations (REBALANCER calls) ==========
    function allocateToLayer(PPTTypes.LiquidityTier tier, uint256 amount) external returns (uint256 allocated);
    function purchaseAsset(address token, uint256 usdtAmount) external returns (uint256 tokensReceived);
    function redeemAsset(address token, uint256 tokenAmount) external returns (uint256 usdtReceived);
    function executeWaterfallLiquidation(uint256 amountNeeded, PPTTypes.LiquidityTier maxTier) external returns (uint256 funded);
    function rebalanceBuffer() external;

    // ========== Layer Configuration (ADMIN calls) ==========
    function setLayerConfig(
        PPTTypes.LiquidityTier tier,
        uint256 targetRatio,
        uint256 minRatio,
        uint256 maxRatio
    ) external;
    function getLayerConfigs() external view returns (
        PPTTypes.LayerConfig memory layer1,
        PPTTypes.LayerConfig memory layer2,
        PPTTypes.LayerConfig memory layer3
    );
    function validateLayerRatios() external view returns (bool valid, uint256 totalRatio);

    // ========== Fee Management (ADMIN calls) ==========
    function accrueManagementFee() external;
    function accruePerformanceFee() external;
    function collectFees() external;
    function withdrawRedemptionFees(uint256 amount) external;
    function setFeeRecipient(address recipient) external;
    function setLayer3HighWaterMark(uint256 value) external;
    function getPendingFees() external view returns (PPTTypes.FeeInfo memory);
    function getRedemptionFeeInfo() external view returns (PPTTypes.RedemptionFeeInfo memory);

    // ========== OTC Management ==========
    function createOTCOrder(
        address rwaToken,
        uint256 usdtAmount,
        uint256 expectedTokens,
        address counterparty,
        uint256 expiresIn
    ) external returns (uint256 orderId);
    function executeOTCPayment(uint256 orderId) external;
    function confirmOTCDelivery(uint256 orderId, uint256 actualTokens) external;

    // ========== Queries ==========
    function getAssetConfigs() external view returns (PPTTypes.AssetConfig[] memory);
    function getLayerAssets(PPTTypes.LiquidityTier tier) external view returns (address[] memory);
    function getLayerValue(PPTTypes.LiquidityTier tier) external view returns (uint256);
    function getBufferPoolInfo() external view returns (PPTTypes.BufferPoolInfo memory);
    function calculateAssetValue() external view returns (uint256);

    // ========== External Contract Settings (ADMIN calls) ==========
    function setOracleAdapter(address oracle) external;
    function setSwapHelper(address helper) external;
    function setOTCManager(address manager) external;
    function setAssetScheduler(address scheduler) external;
    function setDefaultSwapSlippage(uint256 slippage) external;
    function refreshCache() external;
}

/// @title IOracleAdapter
interface IOracleAdapter {
    function getPrice(address token) external view returns (uint256);
}

/// @title ISwapHelper
interface ISwapHelper {
    function buyRWAAsset(address tokenIn, address tokenOut, uint256 amountIn, uint256 slippageBps) external returns (uint256);
    function sellRWAAsset(address tokenIn, address tokenOut, uint256 amountIn, uint256 slippageBps) external returns (uint256);
}

/// @title IOTCManager
interface IOTCManager {
    function createOrder(address rwaToken, uint256 usdtAmount, uint256 expectedTokens, address counterparty, uint256 expiresIn) external returns (uint256);
    function executePayment(uint256 orderId) external;
    function confirmDelivery(uint256 orderId, uint256 actualTokens) external;
}

/// @title IAssetScheduler
interface IAssetScheduler {
    struct RedemptionWindow {
        uint256 windowId;
        uint256 startDate;
        uint256 endDate;
        uint256 settlementDate;
        uint256 totalScheduledAmount;
        bool isActive;
    }

    function getCurrentWindow() external view returns (RedemptionWindow memory);
    function calculateNextWindowDate() external view returns (uint256 nextStart, uint256 nextSettlement);
    function getWindowSettlementTime(uint256 windowId) external view returns (uint256);
    function scheduleRedemptionWithAdvance(
        address owner,
        address receiver,
        uint256 shares,
        uint256 grossAmount,
        uint256 lockedNav,
        uint256 advanceDays
    ) external returns (uint256 schedulerRequestId, uint256 windowId);
}

/// @title IRedemptionVoucher
/// @notice Redemption Voucher NFT interface - Tradeable voucher for long-term redemptions
interface IRedemptionVoucher {
    struct VoucherInfo {
        uint256 requestId;       // Associated redemption request ID
        uint256 grossAmount;     // Redemption amount (USDT)
        uint256 settlementTime;  // Settlement date
        uint256 mintTime;        // Minting time
    }

    // ========== Minting/Burning (RedemptionManager only) ==========
    function mint(address to, uint256 requestId, uint256 grossAmount, uint256 settlementTime) external returns (uint256 tokenId);
    function burn(uint256 tokenId) external;

    // ========== Queries ==========
    function ownerOf(uint256 tokenId) external view returns (address);
    function voucherInfo(uint256 tokenId) external view returns (uint256 requestId, uint256 grossAmount, uint256 settlementTime, uint256 mintTime);
    function requestToToken(uint256 requestId) external view returns (uint256 tokenId);
    function getVoucherByRequest(uint256 requestId) external view returns (uint256 tokenId, VoucherInfo memory info);
}