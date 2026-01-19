// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title WrappedRWAAdapter
/// @author Paimon Yield Protocol
/// @notice AssetController 与 WrappedRWA 之间的桥接适配器
/// @dev 实现 AssetController 期望的 purchase/redeem 接口
///      内部将调用转发给 WrappedRWA
///
/// 集成架构：
/// ```
/// AssetController
///      │
///      │ purchaseAsset(wrappedToken, usdtAmount)
///      ▼
/// WrappedRWAAdapter (作为 purchaseAdapter)
///      │
///      │ wrapper.deposit(usdtAmount, vault)
///      ▼
/// WrappedRWA (ERC4626)
///      │
///      │ 内部管理 pending 交易
///      ▼
/// Underlying RWA Token
/// ```
contract WrappedRWAAdapter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================================
    // Roles
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice USDT 地址
    IERC20 public immutable usdt;

    /// @notice WrappedRWA 地址映射：underlying => wrapper
    mapping(address => address) public wrappers;

    /// @notice Vault 地址（PPT）
    address public vault;

    // =============================================================================
    // Events
    // =============================================================================

    event WrapperRegistered(address indexed underlying, address indexed wrapper);
    event WrapperRemoved(address indexed underlying);
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event Purchase(address indexed wrapper, uint256 usdtAmount, uint256 sharesReceived);
    event Redeem(address indexed wrapper, uint256 sharesAmount, uint256 usdtExpected);

    // =============================================================================
    // Errors
    // =============================================================================

    error ZeroAddress();
    error WrapperNotFound(address underlying);
    error OnlyVault();

    // =============================================================================
    // Constructor
    // =============================================================================

    constructor(address usdt_, address admin_) {
        if (usdt_ == address(0) || admin_ == address(0)) revert ZeroAddress();

        usdt = IERC20(usdt_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // =============================================================================
    // AssetController 接口 - purchase/redeem
    // =============================================================================

    /// @notice 购买 RWA（被 AssetController 调用）
    /// @dev AssetController 会先 approve USDT 给本合约
    /// @param vault_ Vault 地址（用于接收 WrappedRWA）
    /// @param usdtAmount 购买金额
    function purchase(address vault_, uint256 usdtAmount) external nonReentrant {
        // 这个函数会被 AssetController 通过 call 调用
        // msg.sender 是 AssetController（或任何被授权的调用者）

        // 从 Vault 转入 USDT（AssetController 已经 approve）
        usdt.safeTransferFrom(vault_, address(this), usdtAmount);

        // 找到对应的 wrapper（需要通过某种方式知道是哪个 wrapper）
        // 这里有个设计问题：AssetController.purchaseAsset 传入的是 token 地址
        // 我们需要通过上下文知道是哪个 wrapper

        // 解决方案：这个 adapter 是针对特定 wrapper 的
        // 每个 WrappedRWA 有自己的 adapter 实例
        // 或者：使用 delegatecall 上下文

        // 简化设计：这个 adapter 对应单个 wrapper
        revert("Use WrappedRWASingleAdapter instead");
    }

    /// @notice 赎回 RWA（被 AssetController 调用）
    /// @param vault_ Vault 地址
    /// @param sharesAmount WrappedRWA 数量
    function redeem(address vault_, uint256 sharesAmount) external nonReentrant {
        revert("Use WrappedRWASingleAdapter instead");
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice 注册 wrapper
    function registerWrapper(address underlying, address wrapper) external onlyRole(ADMIN_ROLE) {
        if (underlying == address(0) || wrapper == address(0)) revert ZeroAddress();
        wrappers[underlying] = wrapper;
        emit WrapperRegistered(underlying, wrapper);
    }

    /// @notice 移除 wrapper
    function removeWrapper(address underlying) external onlyRole(ADMIN_ROLE) {
        delete wrappers[underlying];
        emit WrapperRemoved(underlying);
    }

    /// @notice 设置 vault
    function setVault(address vault_) external onlyRole(ADMIN_ROLE) {
        address old = vault;
        vault = vault_;
        emit VaultUpdated(old, vault_);
    }
}

/// @title WrappedRWASingleAdapter
/// @notice 单个 WrappedRWA 的专用适配器
/// @dev 每个 WrappedRWA 部署一个此适配器，作为 AssetController 的 purchaseAdapter
contract WrappedRWASingleAdapter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================================
    // Roles
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

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

    // =============================================================================
    // Errors
    // =============================================================================

    error ZeroAddress();
    error ZeroAmount();

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
        require(success && data.length >= 32, "Invalid wrapper");
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
    /// @param vault_ Vault 地址（USDT 来源，也是 shares 接收方）
    /// @param usdtAmount 购买金额
    function purchase(address vault_, uint256 usdtAmount) external nonReentrant {
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
    /// @param vault_ Vault 地址（shares 来源，也是 USDT 接收方）
    /// @param sharesAmount WrappedRWA 数量
    function redeem(address vault_, uint256 sharesAmount) external nonReentrant {
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

    /// @notice 紧急提取
    function emergencyWithdraw(address token, uint256 amount, address to) external onlyRole(ADMIN_ROLE) {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice 重新 approve（如果需要）
    function reapprove() external onlyRole(ADMIN_ROLE) {
        usdt.approve(address(wrapper), type(uint256).max);
    }
}
