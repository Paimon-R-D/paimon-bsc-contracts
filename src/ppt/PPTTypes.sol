// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PPTTypes
/// @notice Shared enums, structs, and constant definitions
library PPTTypes {
    // =============================================================================
    // Constants
    // =============================================================================
    
    uint256 constant PRECISION = 1e18;
    uint256 constant BASIS_POINTS = 10000;
    uint256 constant MIN_DEPOSIT = 500e18;
    
    // Redemption delays
    uint256 constant STANDARD_REDEMPTION_DELAY = 7 days;
    uint256 constant EMERGENCY_REDEMPTION_DELAY = 1 days;
    uint256 constant SCHEDULED_ADVANCE_DAYS = 15 days;

    // Fee-related
    uint256 constant BASE_REDEMPTION_FEE = 10;      // 0.1%
    uint256 constant MAX_REDEMPTION_FEE = 50;       // 0.5%
    uint256 constant EMERGENCY_FEE_PREMIUM = 100;   // 1%

    // Liquidity thresholds
    uint256 constant LOW_LIQUIDITY_THRESHOLD = 1500;      // 15%
    uint256 constant CRITICAL_LIQUIDITY_THRESHOLD = 1000; // 10%

    // Redemption approval thresholds
    uint256 constant STANDARD_APPROVAL_AMOUNT = 50_000e18;    // 50K USDT (absolute threshold per transaction)
    uint256 constant STANDARD_APPROVAL_QUOTA_RATIO = 2000;    // 20% (dynamic quota ratio threshold)
    uint256 constant EMERGENCY_APPROVAL_AMOUNT = 30_000e18;   // 30K USDT (absolute threshold per transaction)
    uint256 constant EMERGENCY_APPROVAL_QUOTA_RATIO = 2000;   // 20% (emergency quota ratio threshold)
    uint256 constant LARGE_REDEMPTION_THRESHOLD = 200;        // 2% (reserved)

    // Layer default configuration
    uint256 constant DEFAULT_LAYER1_RATIO = 1000;  // 10%
    uint256 constant DEFAULT_LAYER2_RATIO = 3000;  // 30%
    uint256 constant DEFAULT_LAYER3_RATIO = 6000;  // 60%
    uint256 constant MIN_LAYER1_RATIO = 500;       // 5%
    uint256 constant MAX_LAYER3_RATIO = 8000;      // 80%

    // Other
    uint256 constant CACHE_DURATION = 5 minutes;
    uint256 constant MAX_SLIPPAGE_BPS = 200;       // 2%

    // =============================================================================
    // Enums
    // =============================================================================
    
    enum LiquidityTier {
        TIER_1_CASH,  // Layer1: Cash + instant yield
        TIER_2_MMF,   // Layer2: Money market funds
        TIER_3_HYD    // Layer3: High-yield assets
    }

    enum PurchaseMethod {
        OTC,    // Over-the-counter trading
        SWAP,   // DEX swap
        AUTO    // Auto selection
    }

    enum RedemptionStatus {
        PENDING,           // Pending settlement
        PENDING_APPROVAL,  // Pending approval
        APPROVED,          // Approved
        SETTLED,           // Settled
        CANCELLED          // Cancelled
    }

    enum RedemptionChannel {
        STANDARD,   // Standard channel (T+7)
        EMERGENCY,  // Emergency channel (T+1)
        SCHEDULED   // Large scheduled channel
    }

    // =============================================================================
    // Structs
    // =============================================================================
    
    /// @notice Redemption request struct
    /// @dev Records detailed information about user redemption requests
    struct RedemptionRequest {
        uint256 requestId;          // Unique request ID
        address owner;              // Redeemer address (PPT share holder)
        address receiver;           // Address to receive USDT
        uint256 shares;             // Number of PPT shares to redeem
        uint256 grossAmount;        // Gross amount (before fee deduction, in USDT)
        uint256 lockedNav;          // NAV price at lock time (net asset value per share at request)
        uint256 estimatedFee;       // Estimated fee (calculated at request, may differ slightly at settlement)
        uint256 requestTime;        // Request timestamp
        uint256 settlementTime;     // Settlement timestamp (0 means pending approval, set after approval)
        RedemptionStatus status;    // Request status (pending settlement/pending approval/approved/settled/cancelled)
        RedemptionChannel channel;  // Redemption channel (standard/emergency/scheduled)
        bool requiresApproval;      // Whether approval required (large amount or exceeds threshold)
        uint256 windowId;           // Window ID (for SCHEDULED channel, currently unused, fixed at 0)
        bool hasVoucher;            // Whether NFT voucher exists (generated when settlement delay > 7 days, for voucher-based redemption)
    }
    
    /// @notice Redemption preview struct
    /// @dev Redemption information returned when user calls preview function, for displaying estimated results
    struct RedemptionPreview {
        uint256 grossAmount;            // Gross amount (before fee deduction, in USDT)
        uint256 fee;                    // Fee amount (in USDT)
        uint256 netAmount;              // Net amount received = grossAmount - fee (in USDT)
        RedemptionChannel channel;      // Available redemption channel (standard/emergency/scheduled)
        bool requiresApproval;          // Whether approval required
        uint256 settlementDelay;        // Settlement delay (seconds), 7 days for standard, 1 day for emergency
        uint256 estimatedSettlementTime; // Estimated settlement timestamp (requestTime + settlementDelay)
        uint256 windowId;               // Window ID (for SCHEDULED channel, currently unused)
        bool canProcess;                // Whether processable (true = can request, false = cannot request)
        string channelReason;           // Channel reason (explains why this channel or why cannot process)
    }
    
    /// @notice Asset configuration struct
    /// @dev Configures investable asset information for Vault, including asset address, liquidity tier, purchase method, etc.
    struct AssetConfig {
        address tokenAddress;       // Asset token address (e.g., USDC, USDT, etc.)
        LiquidityTier tier;         // Liquidity tier (Layer1 cash/Layer2 money market/Layer3 high-yield)
        bool isActive;              // Whether enabled (false = asset unavailable)
        address purchaseAdapter;    // Purchase adapter address (used to execute purchases)
        uint8 decimals;             // Token decimals (e.g., USDC is 6, USDT is 18)
        PurchaseMethod purchaseMethod; // Purchase method (OTC/DEX/auto selection)
        uint256 maxSlippage;        // Max slippage (basis points, e.g., 200 = 2%)
    }
    
    /// @notice Layer configuration struct
    /// @dev Configures target ratio and upper/lower limits for each liquidity tier
    struct LayerConfig {
        uint256 targetRatio;    // Target allocation ratio (basis points, e.g., 1000 = 10%)
        uint256 minRatio;       // Minimum allocation ratio (basis points, for risk control)
        uint256 maxRatio;       // Maximum allocation ratio (basis points, for risk control)
    }

    /// @notice Buffer pool information struct
    /// @dev Tracks Layer1 buffer pool status, including cash and yield asset balances
    struct BufferPoolInfo {
        uint256 cashBalance;        // Cash balance (stablecoins like USDT/USDC)
        uint256 yieldBalance;       // Yield asset balance (e.g., money market funds)
        uint256 totalBuffer;        // Total buffer = cashBalance + yieldBalance
        uint256 targetBuffer;       // Target buffer amount (used to determine if adjustment needed)
        uint256 bufferRatio;        // Current buffer ratio (basis points, relative to total assets)
        bool needsRebalance;        // Whether rebalancing needed (true = adjustment required)
    }

    /// @notice Vault state struct
    /// @dev Provides Vault overall state snapshot, including assets, liabilities, liquidity, etc.
    struct VaultState {
        uint256 totalAssets;                // Total assets (net value after deducting liabilities and fees, in USDT)
        uint256 totalSupply;                // Total PPT token supply
        uint256 sharePrice;                 // Price per share (NAV, in 1e18 precision)
        uint256 layer1Liquidity;            // Layer1 liquidity (cash + instant yield assets, in USDT)
        uint256 layer2Liquidity;            // Layer2 liquidity (money market funds, in USDT)
        uint256 layer3Value;                // Layer3 value (high-yield assets, in USDT)
        uint256 totalRedemptionLiability;   // Total redemption liability (requested but unsettled redemption amount, in USDT)
        uint256 totalLockedShares;          // Total locked shares (PPT shares requested for redemption)
        bool emergencyMode;                 // Emergency mode status (true = emergency channel enabled)
    }

    /// @notice Redemption fee information struct
    /// @dev Tracks redemption fee accumulation
    struct RedemptionFeeInfo {
        uint256 totalFees;          // Total accumulated fees (sum of all historical redemption fees, in USDT)
        uint256 withdrawableFees;   // Withdrawable fees (current withdrawable fee balance, in USDT)
    }
}