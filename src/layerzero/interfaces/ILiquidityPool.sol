// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILiquidityPool
/// @notice Liquidity pool interface for instant withdrawals on satellite chains
/// @dev Manages local liquidity buffer funded by credit allocation from Hub
interface ILiquidityPool {
    // ========== Events ==========

    /// @notice Emitted when liquidity is added to the pool
    /// @param provider Address of the liquidity provider
    /// @param amount Amount of liquidity added
    event LiquidityAdded(address indexed provider, uint256 amount);

    /// @notice Emitted when liquidity is removed from the pool
    /// @param provider Address of the liquidity provider
    /// @param amount Amount of liquidity removed
    event LiquidityRemoved(address indexed provider, uint256 amount);

    /// @notice Emitted when liquidity is used for instant withdrawal
    /// @param satellite Address of the satellite contract
    /// @param user Address of the user receiving funds
    /// @param amount Amount withdrawn
    event LiquidityUsed(address indexed satellite, address indexed user, uint256 amount);

    /// @notice Emitted when credit allocation is updated
    /// @param oldCredit Previous credit amount
    /// @param newCredit New credit amount
    event CreditUpdated(uint256 oldCredit, uint256 newCredit);

    /// @notice Emitted when credit is utilized
    /// @param amount Amount of credit utilized
    /// @param remainingCredit Remaining available credit
    event CreditUtilized(uint256 amount, uint256 remainingCredit);

    /// @notice Emitted when credit utilization is released
    /// @param amount Amount of credit released
    /// @param totalCredit Total credit after release
    event CreditReleased(uint256 amount, uint256 totalCredit);

    /// @notice Emitted when pool is replenished from Hub
    /// @param amount Amount replenished
    /// @param source Source of replenishment (Hub address)
    event PoolReplenished(uint256 amount, address indexed source);

    // ========== View Functions ==========

    /// @notice Get the underlying asset address
    /// @return Address of the underlying asset (e.g., USDT)
    function asset() external view returns (address);

    /// @notice Get available liquidity for instant withdrawals
    /// @return Amount of available liquidity
    function availableLiquidity() external view returns (uint256);

    /// @notice Get total credit allocated to this pool
    /// @return Total credit allocation
    function credit() external view returns (uint256);

    /// @notice Get current credit utilization
    /// @return Amount of credit currently utilized
    function utilized() external view returns (uint256);

    /// @notice Get remaining credit (credit - utilized)
    /// @return Remaining usable credit
    function remainingCredit() external view returns (uint256);

    /// @notice Get credit utilization ratio
    /// @return Utilization ratio in basis points (10000 = 100%)
    function utilizationRatio() external view returns (uint256);

    /// @notice Get the satellite contract address
    /// @return Address of the associated PPTSatellite
    function satellite() external view returns (address);

    /// @notice Check if instant withdrawal is available for an amount
    /// @param amount Amount to check
    /// @return True if instant withdrawal is possible
    function canInstantWithdraw(uint256 amount) external view returns (bool);

    // ========== Liquidity Operations (Satellite Only) ==========

    /// @notice Withdraw assets for a user (instant withdrawal)
    /// @dev Only callable by authorized satellite contract
    /// @param user Address to receive the assets
    /// @param amount Amount to withdraw
    /// @return actualAmount Actual amount withdrawn
    function withdrawForUser(address user, uint256 amount) external returns (uint256 actualAmount);

    // ========== Credit Management (CreditManager/Hub Only) ==========

    /// @notice Update the credit allocation
    /// @dev Only callable by CreditManager through LayerZero
    /// @param newCredit New credit amount
    function updateCredit(uint256 newCredit) external;

    /// @notice Increase credit (when credits received from Hub)
    /// @param amount Amount to increase
    function increaseCredit(uint256 amount) external;

    /// @notice Decrease credit (when credits sent to Hub)
    /// @param amount Amount to decrease
    function decreaseCredit(uint256 amount) external;

    // ========== Liquidity Provider Functions ==========

    /// @notice Add liquidity to the pool
    /// @param amount Amount of asset to add
    function addLiquidity(uint256 amount) external;

    /// @notice Remove liquidity from the pool
    /// @param amount Amount of asset to remove
    function removeLiquidity(uint256 amount) external;

    // ========== Replenishment (Cross-chain from Hub) ==========

    /// @notice Replenish pool with assets from Hub
    /// @dev Called after cross-chain transfer completes
    /// @param amount Amount replenished
    function replenish(uint256 amount) external;

    // ========== Configuration ==========

    /// @notice Set the satellite contract address
    /// @param _satellite Address of the PPTSatellite
    function setSatellite(address _satellite) external;

    /// @notice Set the Stargate gateway allowed to replenish local liquidity
    /// @param _gateway Address of the SatelliteGateway
    function setLiquidityGateway(address _gateway) external;

    /// @notice Set minimum liquidity buffer
    /// @param _minBuffer Minimum liquidity to maintain
    function setMinBuffer(uint256 _minBuffer) external;
}
