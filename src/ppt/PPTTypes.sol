// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PPTTypes
/// @notice Shared enums, structs and constant definitions
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

    // Fee related
    uint256 constant BASE_REDEMPTION_FEE = 10;      // 0.1%
    uint256 constant EMERGENCY_FEE_PREMIUM = 100;   // 1%

    // Liquidity thresholds
    uint256 constant LOW_LIQUIDITY_THRESHOLD = 1500;      // 15%
    uint256 constant CRITICAL_LIQUIDITY_THRESHOLD = 1000; // 10%

    // Other
    uint256 constant CACHE_DURATION = 5 minutes;
    uint256 constant MAX_SLIPPAGE_BPS = 200;       // 2%

    // =============================================================================
    // Enums
    // =============================================================================
    
    enum LiquidityTier {
        TIER_1_CASH,  // Layer1: Cash + instant yield
        TIER_2_MMF,   // Layer2: Money market fund type
        TIER_3_HYD    // Layer3: High yield assets
    }

    enum PurchaseMethod {
        OTC,    // Over-the-counter
        SWAP,   // DEX swap
        AUTO    // Auto select
    }

    enum RedemptionStatus {
        PENDING,           // Awaiting settlement
        PENDING_APPROVAL,  // Awaiting approval
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
    /// @dev Records detailed information of user redemption application
    struct RedemptionRequest {
        uint256 requestId;          // Request unique identifier
        address owner;              // Redemption applicant address (PPT share holder)
        address receiver;           // USDT recipient address
        uint256 shares;             // Amount of PPT shares to redeem
        uint256 grossAmount;        // Gross amount (before fee deduction, unit: USDT)
        uint256 lockedNav;          // NAV price at lock time (NAV per share at application)
        uint256 estimatedFee;       // Estimated fee (calculated at application, may vary at settlement)
        uint256 requestTime;        // Application timestamp
        uint256 settlementTime;     // Settlement timestamp (0 means pending approval, set after approval)
        RedemptionStatus status;    // Request status (pending/pending approval/approved/settled/cancelled)
        RedemptionChannel channel;  // Redemption channel (standard/emergency/scheduled)
        bool requiresApproval;      // Whether approval required (large amount or exceeds threshold)
        uint256 windowId;           // Window ID (for SCHEDULED channel, currently unused, fixed at 0)
        bool hasVoucher;            // Whether has NFT voucher (generated when settlement delay > 7 days)
    }
    
    /// @notice Redemption preview struct
    /// @dev Redemption info returned when user calls preview function, for displaying estimated results
    struct RedemptionPreview {
        uint256 grossAmount;            // Gross amount (before fee deduction, unit: USDT)
        uint256 fee;                    // Fee amount (unit: USDT)
        uint256 netAmount;              // Net amount = grossAmount - fee (unit: USDT)
        RedemptionChannel channel;      // Available redemption channel (standard/emergency/scheduled)
        bool requiresApproval;          // Whether approval required
        uint256 settlementDelay;        // Settlement delay time (seconds), standard 7 days, emergency 1 day
        uint256 estimatedSettlementTime; // Estimated settlement timestamp (requestTime + settlementDelay)
        uint256 windowId;               // Window ID (for SCHEDULED channel, currently unused)
        bool canProcess;                // Whether can process (true = can apply, false = cannot apply)
        string channelReason;           // Channel explanation (why this channel or why cannot process)
    }
    
    /// @notice Asset config struct
    /// @dev Configure asset info that Vault can invest in, including address, liquidity tier, purchase method, etc.
    struct AssetConfig {
        address tokenAddress;       // Asset token address (e.g., USDC, USDT)
        LiquidityTier tier;         // Liquidity tier (Layer1 cash/Layer2 MMF/Layer3 high yield)
        bool isActive;              // Whether enabled (false means asset unavailable)
        address purchaseAdapter;    // Purchase adapter address (for executing purchases)
        uint8 decimals;             // Token decimals (e.g., USDC is 6, USDT is 18)
        PurchaseMethod purchaseMethod; // Purchase method (OTC/DEX/auto)
        uint256 maxSlippage;        // Maximum slippage (basis points, e.g., 200 = 2%)
    }
    
    /// @notice Layer config struct
    /// @dev Configure target ratio and min/max limits for each liquidity tier
    struct LayerConfig {
        uint256 targetRatio;    // Target allocation ratio (basis points, e.g., 1000 = 10%)
        uint256 minRatio;       // Minimum allocation ratio (basis points, for risk control)
        uint256 maxRatio;       // Maximum allocation ratio (basis points, for risk control)
    }

    /// @notice Buffer pool info struct
    /// @dev Used to track Layer1 buffer pool status, including cash and yield asset balances
    struct BufferPoolInfo {
        uint256 cashBalance;        // Cash balance (USDT/USDC stablecoins)
        uint256 yieldBalance;       // Yield asset balance (e.g., money market funds)
        uint256 totalBuffer;        // Total buffer = cashBalance + yieldBalance
        uint256 targetBuffer;       // Target buffer amount (for determining if adjustment needed)
        uint256 bufferRatio;        // Current buffer ratio (basis points, relative to total assets)
        bool needsRebalance;        // Whether needs rebalancing (true = needs adjustment)
    }

    /// @notice Vault state struct
    /// @dev Provides overall Vault state snapshot, including assets, liabilities, liquidity info
    struct VaultState {
        uint256 totalAssets;                // Total assets (net value after deducting liabilities and fees, unit: USDT)
        uint256 totalSupply;                // PPT token total supply
        uint256 sharePrice;                 // Price per share (NAV, unit: 1e18 precision)
        uint256 layer1Liquidity;            // Layer1 liquidity (cash + instant yield assets, unit: USDT)
        uint256 layer2Liquidity;            // Layer2 liquidity (money market fund type, unit: USDT)
        uint256 layer3Value;                // Layer3 value (high yield assets, unit: USDT)
        uint256 totalRedemptionLiability;   // Total redemption liability (applied but unsettled, unit: USDT)
        uint256 totalLockedShares;          // Total locked shares (PPT shares applied for redemption)
        bool emergencyMode;                 // Emergency mode status (true = emergency channel enabled)
    }

    /// @notice Redemption fee info struct
    /// @dev Used to track redemption fee status
    struct RedemptionFeeInfo {
        uint256 totalFees;          // Cumulative total fees (historical total redemption fees, unit: USDT)
        uint256 withdrawableFees;   // Withdrawable fees (current withdrawable fee balance, unit: USDT)
    }
}