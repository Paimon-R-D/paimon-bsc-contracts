// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title WrappedRWASingleAdapter
/// @author Paimon Yield Protocol
/// @notice 单个 WrappedRWA 的专用适配器
/// @dev 每个 WrappedRWA 部署一个此适配器，作为 AssetController 的 purchaseAdapter
///
/// 集成架构：
/// ```
/// AssetController
///      │
///      │ purchaseAsset(wrappedToken, usdtAmount)
///      ▼
/// WrappedRWASingleAdapter (作为 purchaseAdapter)
///      │
///      │ wrapper.deposit(usdtAmount, vault)
///      ▼
/// WrappedRWA (ERC4626)
///      │
///      │ 内部管理 pending 交易
///      ▼
/// Underlying RWA Token
/// ```
contract WrappedRWASingleAdapter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================================
    // Roles
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CALLER_ROLE = keccak256("CALLER_ROLE");

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice USDT 地址
    IERC20 public immutable usdt;

    /// @notice 对应的 WrappedRWA
    IERC4626 public immutable wrapper;

    /// @notice 底层 RWA token
    IERC20 public immutable underlying;

    // =============================================================================
    // Events
    // =============================================================================

    event Purchase(address indexed vault, uint256 usdtAmount, uint256 sharesReceived);
    event Redeem(address indexed vault, uint256 sharesAmount, uint256 assetsReceived);
    event CallerRoleGranted(address indexed caller);
    event CallerRoleRevoked(address indexed caller);
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed to);

    // =============================================================================
    // Errors
    // =============================================================================

    error ZeroAddress();
    error ZeroAmount();
    error WrapperCallFailed(address wrapper);
    error InvalidWrapperResponse(address wrapper, uint256 dataLength);

    // =============================================================================
    // Constructor
    // =============================================================================

    /// @param usdt_ USDT 地址
    /// @param wrapper_ WrappedRWA 地址
    /// @param admin_ 管理员地址
    constructor(address usdt_, address wrapper_, address admin_) {
        if (usdt_ == address(0) || wrapper_ == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }

        usdt = IERC20(usdt_);
        wrapper = IERC4626(wrapper_);

        // 获取底层资产（WrappedRWA 的 underlying）
        // 注意：WrappedRWA 的 asset() 返回 USDT，underlying() 返回实际 RWA
        (bool success, bytes memory data) = wrapper_.staticcall(abi.encodeWithSignature("underlying()"));
        if (!success) {
            revert WrapperCallFailed(wrapper_);
        }
        if (data.length < 32) {
            revert InvalidWrapperResponse(wrapper_, data.length);
        }
        underlying = IERC20(abi.decode(data, (address)));

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);

        // 预先 approve wrapper 使用 USDT
        usdt.approve(wrapper_, type(uint256).max);
    }

    // =============================================================================
    // AssetController 接口
    // =============================================================================

    /// @notice 购买 RWA
    /// @dev 被 AssetController.purchaseAsset 通过 call 调用
    ///      AssetController 会先调用 vault.approveAsset(usdt, adapter, amount)
    ///      只有被授权的 CALLER_ROLE 可以调用
    /// @param vault_ Vault 地址（USDT 来源，也是 shares 接收方）
    /// @param usdtAmount 购买金额
    function purchase(address vault_, uint256 usdtAmount) external nonReentrant onlyRole(CALLER_ROLE) {
        if (usdtAmount == 0) revert ZeroAmount();

        // 1. 从 Vault 转入 USDT
        usdt.safeTransferFrom(vault_, address(this), usdtAmount);

        // 2. 调用 WrappedRWA.deposit，获得 shares
        uint256 sharesBefore = wrapper.balanceOf(vault_);
        uint256 shares = wrapper.deposit(usdtAmount, vault_);
        uint256 sharesAfter = wrapper.balanceOf(vault_);

        // 验证 shares 到账
        require(sharesAfter >= sharesBefore + shares, "Shares not received");

        emit Purchase(vault_, usdtAmount, shares);
    }

    /// @notice 赎回 RWA
    /// @dev 被 AssetController.redeemAsset 通过 call 调用
    ///      AssetController 会先调用 vault.approveAsset(wrapper, adapter, amount)
    ///      只有被授权的 CALLER_ROLE 可以调用
    /// @param vault_ Vault 地址（shares 来源，也是 USDT 接收方）
    /// @param sharesAmount WrappedRWA 数量
    function redeem(address vault_, uint256 sharesAmount) external nonReentrant onlyRole(CALLER_ROLE) {
        if (sharesAmount == 0) revert ZeroAmount();

        // 1. 从 Vault 转入 WrappedRWA shares
        IERC20(address(wrapper)).safeTransferFrom(vault_, address(this), sharesAmount);

        // 2. 调用 WrappedRWA.redeem，请求 USDT
        // 注意：USDT 不会立即到账，而是在 Keeper 确认后发送
        uint256 assets = wrapper.redeem(sharesAmount, vault_, address(this));

        emit Redeem(vault_, sharesAmount, assets);
    }

    // =============================================================================
    // View Functions
    // =============================================================================

    /// @notice 获取 wrapper 地址
    function getWrapper() external view returns (address) {
        return address(wrapper);
    }

    /// @notice 获取 underlying 地址
    function getUnderlying() external view returns (address) {
        return address(underlying);
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice 授权调用者角色
    /// @param caller 调用者地址（通常是 AssetController）
    function grantCallerRole(address caller) external onlyRole(ADMIN_ROLE) {
        if (caller == address(0)) revert ZeroAddress();
        _grantRole(CALLER_ROLE, caller);
        emit CallerRoleGranted(caller);
    }

    /// @notice 撤销调用者角色
    /// @param caller 调用者地址
    function revokeCallerRole(address caller) external onlyRole(ADMIN_ROLE) {
        _revokeRole(CALLER_ROLE, caller);
        emit CallerRoleRevoked(caller);
    }

    /// @notice 紧急提取
    function emergencyWithdraw(address token, uint256 amount, address to) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, amount, to);
    }

    /// @notice 重新 approve（如果需要）
    function reapprove() external onlyRole(ADMIN_ROLE) {
        usdt.approve(address(wrapper), type(uint256).max);
    }
}
