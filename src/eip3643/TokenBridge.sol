// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP3643Token} from "./EIP3643Token.sol";
import {ShadowERC20} from "./ShadowERC20.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";

/// @title TokenBridge - EIP-3643 ↔ ERC-20 多交易对转换桥（UUPS 可升级）
/// @notice 管理 N 组 EIP-3643 与 ERC-20 的 1:1 映射关系，每组有独立的转换比例
/// @dev 核心规则：
///   - 严格 1:1：一个 securityToken 只能对应一个 shadowToken，反过来也一样
///   - 双向查找：通过任意一方都能找到对应的交易对
///   - 存入（deposit）: 用户将 3643 锁入桥 → 桥铸造 ratio 倍 ERC-20
///   - 兑换（redeem）: KYC 用户将 ERC-20 交给桥 → 桥销毁 ERC-20 → 释放对应的 3643
///   - 不变量: 每个交易对的 ERC-20 总量 = 该对锁定的 3643 数量 × ratio
contract TokenBridge is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice 交易对信息
    struct Pair {
        address securityToken;       // EIP-3643 证券型代币
        address shadowToken;         // ERC-20 影子代币
        uint256 ratio;               // 转换比例：1 个 3643 = ratio 个 ERC-20
        uint256 lockedAmount;        // 桥中锁定的 3643 数量
    }

    /// @notice KYC 验证源（所有交易对共用）
    IIdentityRegistry public kycProvider;

    /// @notice securityToken → shadowToken 地址（正向查找）
    mapping(address => address) public getShadowToken;

    /// @notice shadowToken → 交易对详情（反向查找 + 存储）
    mapping(address => Pair) public pairs;

    /// @notice 所有影子代币地址列表（用于遍历所有交易对）
    address[] public allPairs;

    // ============ 事件 ============

    /// @notice 交易对创建事件
    event PairCreated(address indexed securityToken, address indexed shadowToken, uint256 ratio);

    /// @notice 存入事件
    event Deposited(address indexed shadowToken, address indexed user, uint256 securityAmount, uint256 shadowMinted);

    /// @notice 兑换事件
    event Redeemed(address indexed shadowToken, address indexed user, uint256 shadowBurned, uint256 securityReleased);

    /// @notice KYC 验证源更换事件
    event KYCProviderSet(address indexed kycProvider);

    /// @notice 交易对兑换比例修改事件
    event RatioSet(address indexed shadowToken, uint256 oldRatio, uint256 newRatio);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化函数（替代 constructor）
    /// @param _kycProvider KYC 验证源地址（KYCAggregator 或单个 Provider）
    /// @param admin 管理员地址（多签）
    /// @param upgrader 升级权限地址（时间锁）
    function initialize(address _kycProvider, address admin, address upgrader) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, upgrader);
        kycProvider = IIdentityRegistry(_kycProvider);
    }

    // ============ 交易对管理 ============

    /// @notice 创建新的交易对（仅管理员）
    /// @param _securityToken EIP-3643 代币地址
    /// @param _shadowToken ERC-20 影子代币地址
    /// @param _ratio 转换比例（1 个 3643 = _ratio 个 ERC-20）
    /// @dev 严格 1:1，每个代币只能参与一个交易对。创建前需确保：
    ///   1. Bridge 已被添加为 securityToken 的 Agent（用于 forcedTransfer）
    ///   2. Bridge 已被设置为 shadowToken 的 Bridge（用于 mint/burn）
    ///   3. Bridge 地址已在 KYC 白名单中（用于接收 3643）
    function createPair(
        address _securityToken,
        address _shadowToken,
        uint256 _ratio
    ) external onlyRole(OPERATOR_ROLE) {
        require(_securityToken != address(0) && _shadowToken != address(0), "Zero address");
        require(_securityToken != _shadowToken, "Identical addresses");
        require(_ratio > 0, "Ratio must be > 0");
        require(getShadowToken[_securityToken] == address(0), "Security token already paired");
        require(pairs[_shadowToken].securityToken == address(0), "Shadow token already paired");

        getShadowToken[_securityToken] = _shadowToken;
        pairs[_shadowToken] = Pair({
            securityToken: _securityToken,
            shadowToken: _shadowToken,
            ratio: _ratio,
            lockedAmount: 0
        });
        allPairs.push(_shadowToken);

        emit PairCreated(_securityToken, _shadowToken, _ratio);
    }

    /// @notice 更换 KYC 验证源（仅管理员）
    /// @param _kycProvider 新的 KYC 验证源地址
    function setKYCProvider(address _kycProvider) external onlyRole(ADMIN_ROLE) {
        kycProvider = IIdentityRegistry(_kycProvider);
        emit KYCProviderSet(_kycProvider);
    }

    /// @notice 修改交易对的兑换比例（仅管理员）
    /// @param _shadowToken 影子代币地址
    /// @param _newRatio 新比例（1 个 3643 = _newRatio 个 ERC-20）
    /// @dev 改比例前必须先把影子代币余额迁移到新口径（如 xSPCX ×3/50 反向拆分），
    ///      否则 deposit/redeem 口径错位会被套利掏空桥。时序：暂停影子代币 → 迁移余额 → setRatio → 解锁
    function setRatio(address _shadowToken, uint256 _newRatio) external onlyRole(ADMIN_ROLE) {
        Pair storage pair = _getPair(_shadowToken);
        require(_newRatio > 0, "Ratio must be > 0");
        emit RatioSet(_shadowToken, pair.ratio, _newRatio);
        pair.ratio = _newRatio;
    }

    // ============ 存入 ============

    /// @notice 存入 3643 代币，获得 ratio 倍 ERC-20 影子代币
    /// @param _shadowToken 影子代币地址
    /// @param amount 存入的 3643 代币数量
    /// @param recipient 接收 ERC-20 的地址（可以是非 KYC 地址）
    function deposit(address _shadowToken, uint256 amount, address recipient) external {
        Pair storage pair = _getPair(_shadowToken);
        require(amount > 0, "Amount must be > 0");
        require(recipient != address(0), "Invalid recipient");

        uint256 shadowAmount = amount * pair.ratio;

        EIP3643Token(pair.securityToken).transferFrom(msg.sender, address(this), amount);
        pair.lockedAmount += amount;
        ShadowERC20(_shadowToken).mint(recipient, shadowAmount);

        emit Deposited(_shadowToken, msg.sender, amount, shadowAmount);
    }

    /// @notice 存入 3643 代币，ERC-20 发给自己（便捷方法）
    /// @param _shadowToken 影子代币地址
    /// @param amount 存入的 3643 代币数量
    function deposit(address _shadowToken, uint256 amount) external {
        Pair storage pair = _getPair(_shadowToken);
        require(amount > 0, "Amount must be > 0");

        uint256 shadowAmount = amount * pair.ratio;

        EIP3643Token(pair.securityToken).transferFrom(msg.sender, address(this), amount);
        pair.lockedAmount += amount;
        ShadowERC20(_shadowToken).mint(msg.sender, shadowAmount);

        emit Deposited(_shadowToken, msg.sender, amount, shadowAmount);
    }

    // ============ 兑换 ============

    /// @notice 用 ERC-20 兑换回 3643 代币（仅 KYC 用户）
    /// @param _shadowToken 影子代币地址
    /// @param shadowAmount 要兑换的 ERC-20 数量（必须是 ratio 的倍数）
    function redeem(address _shadowToken, uint256 shadowAmount) external {
        Pair storage pair = _getPair(_shadowToken);
        require(shadowAmount > 0, "Amount must be > 0");
        require(shadowAmount % pair.ratio == 0, "Must be multiple of ratio");
        require(kycProvider.isVerified(msg.sender), "Not KYC verified");

        uint256 securityAmount = shadowAmount / pair.ratio;
        require(securityAmount <= pair.lockedAmount, "Insufficient bridge balance");

        ShadowERC20(_shadowToken).burn(msg.sender, shadowAmount);
        pair.lockedAmount -= securityAmount;
        EIP3643Token(pair.securityToken).forcedTransfer(address(this), msg.sender, securityAmount);

        emit Redeemed(_shadowToken, msg.sender, shadowAmount, securityAmount);
    }

    // ============ 查询 ============

    /// @notice 查询交易对数量
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    /// @notice 查询交易对的转换比例
    /// @param _shadowToken 影子代币地址
    function getRatio(address _shadowToken) external view returns (uint256) {
        return _getPair(_shadowToken).ratio;
    }

    /// @notice 查询交易对中锁定的 3643 数量
    /// @param _shadowToken 影子代币地址
    function getLockedAmount(address _shadowToken) external view returns (uint256) {
        return _getPair(_shadowToken).lockedAmount;
    }

    /// @notice 查询交易对中可兑换的 ERC-20 等效余额
    /// @param _shadowToken 影子代币地址
    function getAvailableShadowTokens(address _shadowToken) external view returns (uint256) {
        Pair storage pair = _getPair(_shadowToken);
        return pair.lockedAmount * pair.ratio;
    }

    /// @notice 查询影子代币对应的 3643 代币地址
    /// @param _shadowToken 影子代币地址
    function getSecurityToken(address _shadowToken) external view returns (address) {
        return _getPair(_shadowToken).securityToken;
    }

    // ============ 内部函数 ============

    /// @dev 通过影子代币地址获取交易对（O(1)）
    function _getPair(address _shadowToken) internal view returns (Pair storage pair) {
        pair = pairs[_shadowToken];
        require(pair.securityToken != address(0), "Pair not found");
    }

    /// @dev UUPS 升级授权检查（仅时间锁合约）
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
}
