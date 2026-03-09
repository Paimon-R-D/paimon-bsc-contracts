// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICreditManager
/// @notice Credit allocation manager interface for Delta Algorithm implementation
/// @dev Manages cross-chain credit distribution following Stargate-style unified liquidity
interface ICreditManager {
    // ========== Structs ==========

    /// @notice Chain-specific credit allocation state
    struct ChainCredit {
        uint256 credit;         // Current credit allocation
        uint256 utilized;       // Credit currently in use
        uint256 lastUpdate;     // Last update timestamp
    }

    // ========== Events ==========

    /// @notice Emitted when credit allocation is updated for a chain
    /// @param eid Destination chain endpoint ID
    /// @param oldCredit Previous credit allocation
    /// @param newCredit New credit allocation
    event CreditUpdated(uint32 indexed eid, uint256 oldCredit, uint256 newCredit);

    /// @notice Emitted when credits are sent to a destination chain
    /// @param dstEid Destination chain endpoint ID
    /// @param amount Amount of credits sent
    event CreditsSent(uint32 indexed dstEid, uint256 amount);

    /// @notice Emitted when credits are received from a source chain
    /// @param srcEid Source chain endpoint ID
    /// @param amount Amount of credits received
    event CreditsReceived(uint32 indexed srcEid, uint256 amount);

    /// @notice Emitted when credit utilization changes
    /// @param eid Chain endpoint ID
    /// @param utilized New utilization amount
    event CreditUtilized(uint32 indexed eid, uint256 utilized);

    /// @notice Emitted when rebalancing occurs across multiple chains
    /// @param eids Array of chain endpoint IDs
    /// @param newCredits Array of new credit allocations
    event Rebalanced(uint32[] eids, uint256[] newCredits);

    // ========== View Functions ==========

    /// @notice Get credit allocation for a specific chain
    /// @param eid Chain endpoint ID
    /// @return Current credit allocation
    function credits(uint32 eid) external view returns (uint256);

    /// @notice Get total credit allocation across all chains
    /// @return Total credits allocated
    function totalCredits() external view returns (uint256);

    /// @notice Get credit utilization ratio for a specific chain
    /// @param eid Chain endpoint ID
    /// @return Utilization ratio in basis points (10000 = 100%)
    function getCreditUtilization(uint32 eid) external view returns (uint256);

    /// @notice Get available credit (credit - utilized) for a chain
    /// @param eid Chain endpoint ID
    /// @return Available credit amount
    function getAvailableCredit(uint32 eid) external view returns (uint256);

    /// @notice Get full credit state for a chain
    /// @param eid Chain endpoint ID
    /// @return Chain credit state including credit, utilized, and lastUpdate
    function getChainCredit(uint32 eid) external view returns (ChainCredit memory);

    /// @notice Get all supported chain endpoint IDs
    /// @return Array of supported chain endpoint IDs
    function getSupportedChains() external view returns (uint32[] memory);

    // ========== Credit Management (Cross-chain via LayerZero) ==========

    /// @notice Send credits to a destination chain
    /// @dev Requires msg.value for LayerZero fees
    /// @param dstEid Destination chain endpoint ID
    /// @param amount Amount of credits to send
    function sendCredits(uint32 dstEid, uint256 amount) external payable;

    /// @notice Reduce credit allocation (called when credit is utilized)
    /// @param eid Chain endpoint ID
    /// @param amount Amount to reduce
    function reduceCredit(uint32 eid, uint256 amount) external;

    /// @notice Restore credit allocation (called when utilization is released)
    /// @param eid Chain endpoint ID
    /// @param amount Amount to restore
    function restoreCredit(uint32 eid, uint256 amount) external;

    // ========== Rebalancing (Admin/Keeper) ==========

    /// @notice Rebalance credits across multiple chains
    /// @dev Requires msg.value for LayerZero fees
    /// @param eids Array of chain endpoint IDs
    /// @param amounts Array of new credit allocations
    function rebalance(uint32[] calldata eids, uint256[] calldata amounts) external payable;

    /// @notice Set credit for a specific chain (admin only)
    /// @param eid Chain endpoint ID
    /// @param amount New credit amount
    function setCredit(uint32 eid, uint256 amount) external;

    // ========== Configuration ==========

    /// @notice Add a new supported chain
    /// @param eid Chain endpoint ID
    /// @param initialCredit Initial credit allocation
    function addChain(uint32 eid, uint256 initialCredit) external;

    /// @notice Remove a supported chain
    /// @param eid Chain endpoint ID
    function removeChain(uint32 eid) external;

    // ========== Fee Quoting ==========

    /// @notice Quote LayerZero fee for sending credits
    /// @param dstEid Destination chain endpoint ID
    /// @param amount Amount of credits to send
    /// @return nativeFee Native token fee required
    /// @return lzTokenFee LayerZero token fee (if applicable)
    function quoteSendCredits(uint32 dstEid, uint256 amount) external view returns (uint256 nativeFee, uint256 lzTokenFee);
}
