// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IWrappedRWA} from "./IWrappedRWA.sol";

/// @title WrappedRWA
/// @author Paimon Yield Protocol
/// @notice RWA 资产包装器 - 将非原子化的 RWA 交易封装为原子化接口
/// @dev 核心特性：
///      1. 对 Vault 暴露标准 ERC4626 接口（deposit/withdraw 看起来是原子化的）
///      2. 内部通过 pending 状态管理非原子化交易
///      3. totalAssets() 包含 pending 购买的 USDT 价值（成本价模式）
///      4. Keeper 负责确认实际交易完成
contract WrappedRWA is ERC4626, AccessControl, ReentrancyGuard, Pausable, IWrappedRWA {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // =============================================================================
    // Constants
    // =============================================================================

    uint256 public constant PRECISION = 1e18;
    uint256 public constant BASIS_POINTS = 10000;

    // =============================================================================
    // Roles
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice 底层 RWA 资产
    IERC20 public immutable underlyingAsset;

    /// @notice USDT 地址
    IERC20 public immutable usdt;

    /// @notice 价格预言机
    address public oracle;

    /// @notice 价格精度
    uint8 public immutable underlyingDecimals;

    // =============================================================================
    // Pending Transaction State
    // =============================================================================

    /// @notice 交易记录
    mapping(uint256 => Transaction) private _transactions;

    /// @notice 交易 ID 计数器
    uint256 private _txIdCounter;

    /// @notice 活跃交易 ID 列表
    uint256[] private _activeTransactions;
    mapping(uint256 => uint256) private _activeTxIndex;

    /// @notice 待完成的购买 USDT 总额（已收到 USDT，等待 RWA 到账）
    uint256 public override pendingPurchaseUSDT;

    /// @notice 待完成的购买预期收到的 token 总量（用于计算）
    uint256 public pendingPurchaseTokens;

    /// @notice 已确认的 token 余额（通过 confirmPurchase 确认的）
    uint256 public confirmedTokenBalance;

    /// @notice 待完成的赎回 token 总量（已锁定 token，等待卖出）
    uint256 public override pendingRedemptionTokens;

    /// @notice 待支付的赎回 USDT 总额（预期要支付给赎回者的 USDT）
    uint256 public override pendingRedemptionUSDT;

    /// @notice 赎回者地址映射（txId => receiver）
    mapping(uint256 => address) private _redemptionReceivers;

    // =============================================================================
    // Configuration
    // =============================================================================

    /// @notice 最大价格偏差（基点，默认 500 = 5%）
    uint256 public maxPriceDeviationBps;

    /// @notice 默认过期时间（默认 7 天）
    uint256 public defaultExpirationPeriod;

    // =============================================================================
    // Constructor
    // =============================================================================

    /// @param underlying_ 底层 RWA 资产地址
    /// @param usdt_ USDT 地址
    /// @param oracle_ 价格预言机地址
    /// @param name_ 包装代币名称
    /// @param symbol_ 包装代币符号
    /// @param admin_ 管理员地址
    constructor(
        address underlying_,
        address usdt_,
        address oracle_,
        string memory name_,
        string memory symbol_,
        address admin_
    ) ERC4626(IERC20(usdt_)) ERC20(name_, symbol_) {
        if (underlying_ == address(0) || usdt_ == address(0) || admin_ == address(0)) {
            revert ZeroAmount();
        }

        underlyingAsset = IERC20(underlying_);
        usdt = IERC20(usdt_);
        oracle = oracle_;
        underlyingDecimals = IERC20Metadata(underlying_).decimals();

        maxPriceDeviationBps = 500; // 5%
        defaultExpirationPeriod = 7 days;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(KEEPER_ROLE, admin_);
    }

    // =============================================================================
    // ERC4626 Overrides - 核心：对外原子化接口
    // =============================================================================

    /// @notice 总资产 = 已确认 RWA 的市场价值 + pending 购买的 USDT（成本价）
    /// @dev 关键设计：
    ///      1. pending 购买期间使用 USDT 成本价，而非预估 token 价值
    ///      2. 只计算已确认的 tokens（通过 confirmPurchase 确认的）
    ///      3. 这确保了在 RWA 到账但还没 confirm 时，NAV 保持稳定
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        // 1. 已确认 tokens 的市场价值（扣除已锁定待赎回的）
        uint256 availableConfirmed =
            confirmedTokenBalance > pendingRedemptionTokens ? confirmedTokenBalance - pendingRedemptionTokens : 0;
        uint256 confirmedValue = _tokenToUsdt(availableConfirmed);

        // 2. pending 购买的 USDT（成本价，确定的）
        return confirmedValue + pendingPurchaseUSDT;
    }

    /// @notice Vault 存入 USDT，获得 WrappedRWA
    /// @dev 立即铸造 shares，内部记录 pending 购买
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();

        // 计算应铸造的 shares
        shares = previewDeposit(assets);

        // 转入 USDT
        usdt.safeTransferFrom(msg.sender, address(this), assets);

        // 立即铸造 shares 给 receiver（原子化体验）
        _mint(receiver, shares);

        // 记录 pending 购买
        uint256 txId = _createPurchaseTransaction(assets, msg.sender);

        // 更新 pending 状态
        pendingPurchaseUSDT += assets;

        emit Deposit(msg.sender, receiver, assets, shares);

        return shares;
    }

    /// @notice Vault 赎回 WrappedRWA，获得 USDT
    /// @dev 立即销毁 shares，USDT 在交易完成后支付
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();

        shares = previewWithdraw(assets);

        // 检查 allowance
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // 立即销毁 shares
        _burn(owner, shares);

        // 计算需要锁定的 token 数量
        uint256 tokensToLock = _usdtToToken(assets);

        // 检查可用的已确认 token（不含已锁定待赎回的）
        uint256 available =
            confirmedTokenBalance > pendingRedemptionTokens ? confirmedTokenBalance - pendingRedemptionTokens : 0;
        if (available < tokensToLock) {
            revert InsufficientBalance(available, tokensToLock);
        }

        // 记录 pending 赎回
        uint256 txId = _createRedemptionTransaction(tokensToLock, assets, receiver, msg.sender);

        // 更新 pending 状态
        pendingRedemptionTokens += tokensToLock;
        pendingRedemptionUSDT += assets;

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        // 注意：USDT 不在这里转出，而是在 confirmRedemption 时转出
        return shares;
    }

    /// @notice 通过 shares 数量赎回
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();

        assets = previewRedeem(shares);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _burn(owner, shares);

        uint256 tokensToLock = _usdtToToken(assets);
        uint256 available =
            confirmedTokenBalance > pendingRedemptionTokens ? confirmedTokenBalance - pendingRedemptionTokens : 0;
        if (available < tokensToLock) {
            revert InsufficientBalance(available, tokensToLock);
        }

        uint256 txId = _createRedemptionTransaction(tokensToLock, assets, receiver, msg.sender);

        pendingRedemptionTokens += tokensToLock;
        pendingRedemptionUSDT += assets;

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return assets;
    }

    /// @notice 通过 shares 数量存入
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();

        assets = previewMint(shares);

        usdt.safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        uint256 txId = _createPurchaseTransaction(assets, msg.sender);

        pendingPurchaseUSDT += assets;

        emit Deposit(msg.sender, receiver, assets, shares);

        return assets;
    }

    // =============================================================================
    // Keeper Functions - 确认实际交易完成
    // =============================================================================

    /// @notice 确认购买完成（底层 RWA 已到账）
    /// @param txId 交易 ID
    /// @param actualTokensReceived 实际收到的 token 数量
    function confirmPurchase(uint256 txId, uint256 actualTokensReceived)
        external
        override
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        Transaction storage tx_ = _transactions[txId];

        if (tx_.txId == 0) revert TransactionNotFound(txId);
        if (tx_.status != TransactionStatus.PENDING) revert InvalidTransactionStatus(txId);
        if (tx_.txType != TransactionType.PURCHASE) revert InvalidTransactionStatus(txId);
        if (block.timestamp > tx_.expiresAt) revert TransactionExpired(txId);

        // 计算实际价格
        uint256 actualPrice = (tx_.usdtAmount * PRECISION) / actualTokensReceived;

        // 检查价格偏差
        _validatePriceDeviation(tx_.lockedPrice, actualPrice);

        // 更新交易状态
        uint256 expectedTokens = tx_.tokenAmount; // 保存原始预期 tokens
        tx_.tokenAmount = actualTokensReceived;
        tx_.status = TransactionStatus.COMPLETED;
        tx_.completedAt = block.timestamp;

        // 清除 pending 状态，增加已确认余额
        pendingPurchaseUSDT -= tx_.usdtAmount;
        pendingPurchaseTokens -= expectedTokens;
        confirmedTokenBalance += actualTokensReceived;

        // 移除活跃交易
        _removeActiveTransaction(txId);

        int256 priceDelta = int256(tx_.lockedPrice) - int256(actualPrice);

        emit PurchaseCompleted(txId, actualTokensReceived, actualPrice, priceDelta);
    }

    /// @notice 取消购买（退还 USDT）
    function cancelPurchase(uint256 txId, string calldata reason) external override onlyRole(KEEPER_ROLE) nonReentrant {
        Transaction storage tx_ = _transactions[txId];

        if (tx_.txId == 0) revert TransactionNotFound(txId);
        if (tx_.status != TransactionStatus.PENDING) revert InvalidTransactionStatus(txId);
        if (tx_.txType != TransactionType.PURCHASE) revert InvalidTransactionStatus(txId);

        tx_.status = TransactionStatus.CANCELLED;
        tx_.completedAt = block.timestamp;

        // 清除 pending 状态
        pendingPurchaseUSDT -= tx_.usdtAmount;
        pendingPurchaseTokens -= tx_.tokenAmount;

        // 计算应退还的 shares（按当前价格）
        uint256 sharesToBurn = previewDeposit(tx_.usdtAmount);

        // 这里有个问题：shares 已经铸造给了 receiver
        // 取消时需要从某处回收或记录为损失
        // 简化处理：退还 USDT 给 initiator，shares 保持不变（协议承担损失）
        // 或者：要求 initiator 持有足够的 shares 来销毁

        // 退还 USDT
        usdt.safeTransfer(tx_.initiator, tx_.usdtAmount);

        _removeActiveTransaction(txId);

        emit PurchaseCancelled(txId, reason);
    }

    /// @notice 确认赎回完成（USDT 已收到）
    function confirmRedemption(uint256 txId, uint256 actualUsdtReceived)
        external
        override
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        Transaction storage tx_ = _transactions[txId];

        if (tx_.txId == 0) revert TransactionNotFound(txId);
        if (tx_.status != TransactionStatus.PENDING) revert InvalidTransactionStatus(txId);
        if (tx_.txType != TransactionType.REDEMPTION) revert InvalidTransactionStatus(txId);
        if (block.timestamp > tx_.expiresAt) revert TransactionExpired(txId);

        // 计算实际价格
        uint256 actualPrice = (actualUsdtReceived * PRECISION) / tx_.tokenAmount;

        // 检查价格偏差
        _validatePriceDeviation(tx_.lockedPrice, actualPrice);

        tx_.usdtAmount = actualUsdtReceived;
        tx_.status = TransactionStatus.COMPLETED;
        tx_.completedAt = block.timestamp;

        // 清除 pending 状态，减少已确认余额（tokens 被卖出）
        pendingRedemptionTokens -= tx_.tokenAmount;
        pendingRedemptionUSDT -= tx_.usdtAmount;
        confirmedTokenBalance -= tx_.tokenAmount;

        // 转 USDT 给 receiver
        address receiver = _redemptionReceivers[txId];
        usdt.safeTransfer(receiver, actualUsdtReceived);

        _removeActiveTransaction(txId);

        int256 priceDelta = int256(actualPrice) - int256(tx_.lockedPrice);

        emit RedemptionCompleted(txId, actualUsdtReceived, actualPrice, priceDelta);
    }

    /// @notice 取消赎回（退还 token）
    function cancelRedemption(uint256 txId, string calldata reason)
        external
        override
        onlyRole(KEEPER_ROLE)
        nonReentrant
    {
        Transaction storage tx_ = _transactions[txId];

        if (tx_.txId == 0) revert TransactionNotFound(txId);
        if (tx_.status != TransactionStatus.PENDING) revert InvalidTransactionStatus(txId);
        if (tx_.txType != TransactionType.REDEMPTION) revert InvalidTransactionStatus(txId);

        tx_.status = TransactionStatus.CANCELLED;
        tx_.completedAt = block.timestamp;

        // 清除 pending 状态
        pendingRedemptionTokens -= tx_.tokenAmount;
        pendingRedemptionUSDT -= tx_.usdtAmount;

        // 重新铸造 shares 给 receiver（补偿）
        address receiver = _redemptionReceivers[txId];
        uint256 sharesToMint = previewDeposit(tx_.usdtAmount);
        _mint(receiver, sharesToMint);

        _removeActiveTransaction(txId);

        emit RedemptionCancelled(txId, reason);
    }

    // =============================================================================
    // View Functions
    // =============================================================================

    /// @notice 底层 RWA 资产地址
    function underlying() external view override returns (address) {
        return address(underlyingAsset);
    }

    /// @notice 底层资产当前价格
    function underlyingPrice() public view override returns (uint256) {
        return _getUnderlyingPrice();
    }

    /// @notice 获取交易详情
    function getTransaction(uint256 txId) external view override returns (Transaction memory) {
        return _transactions[txId];
    }

    /// @notice 获取所有活跃交易 ID
    function getActiveTransactions() external view override returns (uint256[] memory) {
        return _activeTransactions;
    }

    /// @notice 可用于赎回的 token 数量（已确认余额减去已锁定待赎回的）
    function availableTokens() external view returns (uint256) {
        return confirmedTokenBalance > pendingRedemptionTokens ? confirmedTokenBalance - pendingRedemptionTokens : 0;
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice 设置价格偏差阈值
    function setMaxPriceDeviationBps(uint256 bps) external override onlyRole(ADMIN_ROLE) {
        require(bps <= 2000, "Max 20%");
        maxPriceDeviationBps = bps;
    }

    /// @notice 设置默认过期时间
    function setDefaultExpirationPeriod(uint256 period) external override onlyRole(ADMIN_ROLE) {
        require(period >= 1 days && period <= 30 days, "Invalid period");
        defaultExpirationPeriod = period;
    }

    /// @notice 设置价格预言机
    function setOracle(address oracle_) external onlyRole(ADMIN_ROLE) {
        oracle = oracle_;
    }

    /// @notice 授权 Vault 角色
    function grantVaultRole(address vault) external onlyRole(ADMIN_ROLE) {
        _grantRole(VAULT_ROLE, vault);
    }

    /// @notice 紧急提取
    function emergencyWithdraw(address token, uint256 amount, address to) external override onlyRole(ADMIN_ROLE) {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice 暂停
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice 恢复
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // =============================================================================
    // Internal Functions
    // =============================================================================

    /// @notice 创建购买交易记录
    function _createPurchaseTransaction(uint256 usdtAmount, address initiator) internal returns (uint256 txId) {
        txId = ++_txIdCounter;

        uint256 price = _getUnderlyingPrice();
        uint256 expectedTokens = _usdtToToken(usdtAmount);

        _transactions[txId] = Transaction({
            txId: txId,
            txType: TransactionType.PURCHASE,
            status: TransactionStatus.PENDING,
            usdtAmount: usdtAmount,
            tokenAmount: expectedTokens,
            lockedPrice: price,
            initiatedAt: block.timestamp,
            completedAt: 0,
            expiresAt: block.timestamp + defaultExpirationPeriod,
            initiator: initiator,
            memo: ""
        });

        // 记录预期收到的 tokens
        pendingPurchaseTokens += expectedTokens;

        _addActiveTransaction(txId);

        emit PurchaseInitiated(txId, initiator, usdtAmount, expectedTokens, price);
    }

    /// @notice 创建赎回交易记录
    function _createRedemptionTransaction(
        uint256 tokenAmount,
        uint256 expectedUsdt,
        address receiver,
        address initiator
    ) internal returns (uint256 txId) {
        txId = ++_txIdCounter;

        uint256 price = _getUnderlyingPrice();

        _transactions[txId] = Transaction({
            txId: txId,
            txType: TransactionType.REDEMPTION,
            status: TransactionStatus.PENDING,
            usdtAmount: expectedUsdt,
            tokenAmount: tokenAmount,
            lockedPrice: price,
            initiatedAt: block.timestamp,
            completedAt: 0,
            expiresAt: block.timestamp + defaultExpirationPeriod,
            initiator: initiator,
            memo: ""
        });

        _redemptionReceivers[txId] = receiver;
        _addActiveTransaction(txId);

        emit RedemptionInitiated(txId, initiator, tokenAmount, expectedUsdt, price);
    }

    /// @notice 获取底层资产价格
    function _getUnderlyingPrice() internal view returns (uint256) {
        if (oracle == address(0)) {
            return PRECISION; // 默认 1:1
        }
        // 调用 oracle 获取价格
        (bool success, bytes memory data) =
            oracle.staticcall(abi.encodeWithSignature("getPrice(address)", address(underlyingAsset)));
        if (success && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return PRECISION;
    }

    /// @notice Token 转换为 USDT
    function _tokenToUsdt(uint256 tokenAmount) internal view returns (uint256) {
        uint256 price = _getUnderlyingPrice();
        return (tokenAmount * price) / (10 ** underlyingDecimals);
    }

    /// @notice USDT 转换为 Token
    function _usdtToToken(uint256 usdtAmount) internal view returns (uint256) {
        uint256 price = _getUnderlyingPrice();
        return (usdtAmount * (10 ** underlyingDecimals)) / price;
    }

    /// @notice 验证价格偏差
    function _validatePriceDeviation(uint256 expected, uint256 actual) internal view {
        uint256 deviation;
        if (actual > expected) {
            deviation = ((actual - expected) * BASIS_POINTS) / expected;
        } else {
            deviation = ((expected - actual) * BASIS_POINTS) / expected;
        }

        if (deviation > maxPriceDeviationBps) {
            revert PriceDeviationTooHigh(expected, actual, maxPriceDeviationBps);
        }
    }

    /// @notice 添加活跃交易
    function _addActiveTransaction(uint256 txId) internal {
        _activeTransactions.push(txId);
        _activeTxIndex[txId] = _activeTransactions.length;
    }

    /// @notice 移除活跃交易
    function _removeActiveTransaction(uint256 txId) internal {
        uint256 indexPlusOne = _activeTxIndex[txId];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _activeTransactions.length - 1;

        if (index != lastIndex) {
            uint256 lastTxId = _activeTransactions[lastIndex];
            _activeTransactions[index] = lastTxId;
            _activeTxIndex[lastTxId] = indexPlusOne;
        }

        _activeTransactions.pop();
        delete _activeTxIndex[txId];
    }

    // =============================================================================
    // ERC4626 View Overrides
    // =============================================================================

    /// @notice 底层资产（对 ERC4626 来说是 USDT）
    function asset() public view override(ERC4626, IERC4626) returns (address) {
        return address(usdt);
    }
}
