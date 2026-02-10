// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice V2 Adapter Interface (optimized - settlementId passed directly)
interface IPaimonAdapter {
    /// @notice Purchase asset with payment token
    /// @param to Vault address (recipient)
    /// @param amount Payment token amount
    /// @param settlementId Settlement ID from AssetController for delayed settlement tracking
    /// @return tokensReceived Asset tokens received (0 for delayed settlement)
    function purchase(address to, uint256 amount, uint256 settlementId) external returns (uint256 tokensReceived);

    /// @notice Redeem asset for payment token
    /// @param to Vault address (recipient)
    /// @param amount Asset token amount
    /// @param settlementId Settlement ID from AssetController for delayed settlement tracking
    /// @return paymentReceived Payment tokens received (0 for delayed settlement)
    function redeem(address to, uint256 amount, uint256 settlementId) external returns (uint256 paymentReceived);

    function setVault(address newVault) external;
}

/// @notice Extended interface for delayed settlement adapters (e.g., CashPlus)
interface IPaimonDelayAdapter is IPaimonAdapter {
    // Keeper management functions (for linking with external protocol IDs)
    function linkSubscriptionId(uint256 pendingId, uint256 cashPlusSubscriptionId) external;
    function markSubscriptionApproved(uint256 pendingId, uint256 expectedShares) external;
    function linkRedemptionId(uint256 pendingId, uint256 cashPlusRedemptionId) external;
    function markRedemptionApproved(uint256 pendingId, uint256 expectedUsdt) external;

    // Controller atomic callbacks (replaces old claim/cancel)
    function onConfirmSettlement(uint256 settlementId) external returns (uint256 receivedAmount);
    function onCancelSettlement(uint256 settlementId) external returns (uint256 returnedAmount);
}
