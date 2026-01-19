// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IWrappedRWA
/// @author Paimon Yield Protocol
/// @notice RWA 资产包装器接口 - 将非原子化的 RWA 交易封装为原子化接口
/// @dev 核心设计理念：
///      1. Vault 只与 WrappedRWA 交互，不直接接触底层 RWA
///      2. WrappedRWA 内部处理非原子化交易，对外表现为原子化
///      3. pending 状态的资产价值纳入 totalAssets 计算
interface IWrappedRWA is IERC4626 {
    // =============================================================================
    // 交易状态枚举
    // =============================================================================

    /// @notice 交易状态
    enum TransactionStatus {
        NONE, // 不存在
        PENDING, // 进行中
        COMPLETED, // 已完成
        CANCELLED, // 已取消
        EXPIRED // 已过期
    }

    /// @notice 交易类型
    enum TransactionType {
        PURCHASE, // 购买：USDT → RWA
        REDEMPTION // 赎回：RWA → USDT
    }

    // =============================================================================
    // 交易记录结构
    // =============================================================================

    /// @notice 交易记录
    struct Transaction {
        uint256 txId; // 交易 ID
        TransactionType txType; // 交易类型
        TransactionStatus status; // 状态

        uint256 usdtAmount; // USDT 金额
        uint256 tokenAmount; // RWA token 数量
        uint256 lockedPrice; // 锁定价格（发起时）

        uint256 initiatedAt; // 发起时间
        uint256 completedAt; // 完成时间
        uint256 expiresAt; // 过期时间

        address initiator; // 发起人
        string memo; // 备注（如 OTC 订单号）
    }

    // =============================================================================
    // 事件
    // =============================================================================

    /// @notice 购买发起
    event PurchaseInitiated(
        uint256 indexed txId, address indexed initiator, uint256 usdtAmount, uint256 expectedTokens, uint256 lockedPrice
    );

    /// @notice 购买完成
    event PurchaseCompleted(uint256 indexed txId, uint256 actualTokensReceived, uint256 actualPrice, int256 priceDelta);

    /// @notice 购买取消
    event PurchaseCancelled(uint256 indexed txId, uint256 sharesBurned, string reason);

    /// @notice 赎回发起
    event RedemptionInitiated(
        uint256 indexed txId, address indexed initiator, uint256 tokenAmount, uint256 expectedUsdt, uint256 lockedPrice
    );

    /// @notice 赎回完成
    event RedemptionCompleted(uint256 indexed txId, uint256 actualUsdtReceived, uint256 actualPrice, int256 priceDelta);

    /// @notice 赎回取消
    event RedemptionCancelled(uint256 indexed txId, uint256 sharesReturned, string reason);

    /// @notice Oracle 更新
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    /// @notice Vault 角色授予
    event VaultRoleGranted(address indexed vault);

    /// @notice 紧急提取
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed to);

    /// @notice 交易过期处理
    event TransactionExpiredAndProcessed(uint256 indexed txId, TransactionType txType);

    // =============================================================================
    // 错误
    // =============================================================================

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientBalance(uint256 available, uint256 required);
    error InsufficientShares(address holder, uint256 available, uint256 required);
    error TransactionNotFound(uint256 txId);
    error InvalidTransactionStatus(uint256 txId);
    error TransactionExpired(uint256 txId);
    error PriceDeviationTooHigh(uint256 expected, uint256 actual, uint256 maxBps);
    error Unauthorized();
    error OracleCallFailed(address oracle, address asset);
    error OraclePriceZero(address oracle, address asset);
    error OracleNotSet();

    // =============================================================================
    // 核心查询函数
    // =============================================================================

    /// @notice 底层 RWA 资产地址
    function underlying() external view returns (address);

    /// @notice 底层资产当前价格（1e18 精度）
    function underlyingPrice() external view returns (uint256);

    /// @notice 待完成的购买 USDT 总额
    function pendingPurchaseUSDT() external view returns (uint256);

    /// @notice 待完成的赎回 token 总量
    function pendingRedemptionTokens() external view returns (uint256);

    /// @notice 待支付的赎回 USDT 总额
    function pendingRedemptionUSDT() external view returns (uint256);

    /// @notice 获取交易详情
    function getTransaction(uint256 txId) external view returns (Transaction memory);

    /// @notice 获取所有活跃交易 ID
    function getActiveTransactions() external view returns (uint256[] memory);

    // =============================================================================
    // Keeper 操作函数
    // =============================================================================

    /// @notice 确认购买完成（底层 RWA 已到账）
    /// @param txId 交易 ID
    /// @param actualTokensReceived 实际收到的 token 数量
    function confirmPurchase(uint256 txId, uint256 actualTokensReceived) external;

    /// @notice 取消购买（退还 USDT）
    /// @param txId 交易 ID
    /// @param reason 取消原因
    function cancelPurchase(uint256 txId, string calldata reason) external;

    /// @notice 确认赎回完成（USDT 已收到）
    /// @param txId 交易 ID
    /// @param actualUsdtReceived 实际收到的 USDT
    function confirmRedemption(uint256 txId, uint256 actualUsdtReceived) external;

    /// @notice 取消赎回（退还 token）
    /// @param txId 交易 ID
    /// @param reason 取消原因
    function cancelRedemption(uint256 txId, string calldata reason) external;

    // =============================================================================
    // Admin 函数
    // =============================================================================

    /// @notice 设置价格偏差阈值
    function setMaxPriceDeviationBps(uint256 bps) external;

    /// @notice 设置默认过期时间
    function setDefaultExpirationPeriod(uint256 period) external;

    /// @notice 紧急提取（仅限管理员）
    function emergencyWithdraw(address token, uint256 amount, address to) external;
}

/// @title IWrappedRWAFactory
/// @notice WrappedRWA 工厂接口
interface IWrappedRWAFactory {
    /// @notice 创建新的 WrappedRWA
    function createWrapper(
        address underlying,
        address usdt,
        address oracle,
        string calldata name,
        string calldata symbol
    ) external returns (address wrapper);

    /// @notice 获取 underlying 对应的 wrapper
    function getWrapper(address underlying) external view returns (address);

    /// @notice 所有已创建的 wrapper
    function getAllWrappers() external view returns (address[] memory);
}
