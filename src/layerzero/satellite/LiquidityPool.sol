// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ILiquidityPool} from "../interfaces/ILiquidityPool.sol";

/// @title LiquidityPool
/// @notice Provides instant withdrawal liquidity on remote chains
/// @dev Credit is managed by Hub's CreditManager via cross-chain messages
contract LiquidityPool is ILiquidityPool, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========== State Variables ==========

    /// @notice The underlying asset (e.g., USDT)
    IERC20 internal immutable _asset;

    /// @notice The PPTSatellite that can withdraw from this pool
    address public satellite;

    /// @notice Current credit allocation from Hub
    uint256 public credit;

    /// @notice Credit utilized (for tracking utilization)
    uint256 public utilized;

    /// @notice Minimum liquidity buffer to maintain
    uint256 public minBuffer;

    // ========== Errors ==========

    error InvalidAmount();
    error InsufficientLiquidity();
    error OnlySatellite();
    error CreditBelowUtilized();
    error InsufficientCredit(uint256 available, uint256 required);
    error ZeroAddress();

    // ========== Events ==========

    event SatelliteUpdated(address indexed oldSatellite, address indexed newSatellite);
    event LiquidityWithdrawn(address indexed user, uint256 amount);
    event CreditUsed(uint256 amount, uint256 remainingCredit);
    event MinBufferUpdated(uint256 oldBuffer, uint256 newBuffer);
    event EmergencyWithdraw(address indexed to, uint256 amount);

    // ========== Modifiers ==========

    modifier onlySatellite() {
        if (msg.sender != satellite) revert OnlySatellite();
        _;
    }

    modifier onlySatelliteOrOwner() {
        if (msg.sender != satellite && msg.sender != owner()) revert OnlySatellite();
        _;
    }

    // ========== Constructor ==========

    /// @notice Initialize the LiquidityPool
    /// @param asset_ The underlying asset address (e.g., USDT)
    /// @param _owner The owner address
    constructor(
        address asset_,
        address _owner
    ) Ownable(_owner) {
        _asset = IERC20(asset_);
    }

    // ========== View Functions ==========

    /// @inheritdoc ILiquidityPool
    function asset() external view override returns (address) {
        return address(_asset);
    }

    /// @inheritdoc ILiquidityPool
    function availableLiquidity() public view override returns (uint256) {
        uint256 poolBalance = _asset.balanceOf(address(this));
        uint256 remaining = remainingCredit();
        return poolBalance < remaining ? poolBalance : remaining;
    }

    /// @inheritdoc ILiquidityPool
    function remainingCredit() public view override returns (uint256) {
        return credit > utilized ? credit - utilized : 0;
    }

    /// @inheritdoc ILiquidityPool
    function utilizationRatio() external view override returns (uint256) {
        if (credit == 0) return 0;
        return (utilized * 10000) / credit;
    }

    /// @inheritdoc ILiquidityPool
    function canInstantWithdraw(uint256 amount) external view override returns (bool) {
        return amount <= availableLiquidity();
    }

    // ========== Liquidity Provider Functions ==========

    /// @inheritdoc ILiquidityPool
    function addLiquidity(uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();

        _asset.safeTransferFrom(msg.sender, address(this), amount);

        emit LiquidityAdded(msg.sender, amount);
    }

    /// @inheritdoc ILiquidityPool
    /// @dev P1-1 FIX: Added onlyOwner to prevent unauthorized liquidity removal
    function removeLiquidity(uint256 amount) external override onlyOwner nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();

        uint256 poolBalance = _asset.balanceOf(address(this));
        if (amount > poolBalance) revert InsufficientLiquidity();

        _asset.safeTransfer(msg.sender, amount);

        emit LiquidityRemoved(msg.sender, amount);
    }

    // ========== Satellite Functions ==========

    /// @inheritdoc ILiquidityPool
    function withdrawForUser(
        address user,
        uint256 amount
    ) external override onlySatellite nonReentrant whenNotPaused returns (uint256) {
        if (amount == 0) revert InvalidAmount();
        if (amount > availableLiquidity()) revert InsufficientLiquidity();

        // Update utilization
        utilized += amount;

        // Transfer to user
        _asset.safeTransfer(user, amount);

        emit LiquidityWithdrawn(user, amount);
        emit CreditUsed(amount, remainingCredit());

        return amount;
    }

    // ========== Credit Management ==========

    /// @inheritdoc ILiquidityPool
    function updateCredit(uint256 newCredit) external override onlySatelliteOrOwner {
        emit CreditUpdated(credit, newCredit);
        credit = newCredit;
    }

    /// @inheritdoc ILiquidityPool
    function increaseCredit(uint256 amount) external override onlySatelliteOrOwner {
        uint256 oldCredit = credit;
        credit += amount;
        emit CreditUpdated(oldCredit, credit);
    }

    /// @inheritdoc ILiquidityPool
    function decreaseCredit(uint256 amount) external override onlySatelliteOrOwner {
        // Check for underflow first
        if (amount > credit) revert InsufficientCredit(credit, amount);
        // Then check if remaining credit is sufficient for utilized
        if (credit - amount < utilized) revert CreditBelowUtilized();

        uint256 oldCredit = credit;
        credit -= amount;
        emit CreditUpdated(oldCredit, credit);
    }

    /// @inheritdoc ILiquidityPool
    function replenish(uint256 amount) external override onlyOwner {
        // Reduce utilized when pool is replenished from Hub
        if (amount >= utilized) {
            utilized = 0;
        } else {
            utilized -= amount;
        }

        emit CreditUpdated(credit, credit); // Pool replenished event
    }

    // ========== Configuration ==========

    /// @inheritdoc ILiquidityPool
    function setSatellite(address _satellite) external override onlyOwner {
        if (_satellite == address(0)) revert ZeroAddress();
        emit SatelliteUpdated(satellite, _satellite);
        satellite = _satellite;
    }

    /// @inheritdoc ILiquidityPool
    function setMinBuffer(uint256 _minBuffer) external override onlyOwner {
        emit MinBufferUpdated(minBuffer, _minBuffer);
        minBuffer = _minBuffer;
    }

    // ========== Emergency Functions ==========

    /// @notice Emergency withdraw assets (owner only)
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _asset.safeTransfer(to, amount);
        emit EmergencyWithdraw(to, amount);
    }

    /// @notice Pause the pool
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the pool
    function unpause() external onlyOwner {
        _unpause();
    }
}
