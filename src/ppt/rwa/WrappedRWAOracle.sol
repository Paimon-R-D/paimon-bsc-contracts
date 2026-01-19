// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title WrappedRWAOracle
/// @author Paimon Yield Protocol
/// @notice WrappedRWA 价格预言机 - 返回每个 wrapper share 的 USDT 价值
/// @dev 价格 = wrapper.totalAssets() / wrapper.totalSupply()
///      这确保了 pending 交易的价值被正确计入
contract WrappedRWAOracle is AccessControl {
    // =============================================================================
    // Constants
    // =============================================================================

    uint256 public constant PRECISION = 1e18;

    // =============================================================================
    // Roles
    // =============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // =============================================================================
    // State Variables
    // =============================================================================

    /// @notice 已注册的 wrapper 列表
    mapping(address => bool) public isRegistered;

    /// @notice 后备 Oracle（用于非 wrapper 资产）
    address public fallbackOracle;

    // =============================================================================
    // Events
    // =============================================================================

    event WrapperRegistered(address indexed wrapper);
    event WrapperUnregistered(address indexed wrapper);
    event FallbackOracleUpdated(address indexed oldOracle, address indexed newOracle);

    // =============================================================================
    // Errors
    // =============================================================================

    error ZeroAddress();
    error NotRegistered(address wrapper);

    // =============================================================================
    // Constructor
    // =============================================================================

    constructor(address admin_, address fallbackOracle_) {
        if (admin_ == address(0)) revert ZeroAddress();

        fallbackOracle = fallbackOracle_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // =============================================================================
    // Price Functions
    // =============================================================================

    /// @notice 获取资产价格
    /// @dev 如果是注册的 wrapper，返回 share 价格
    ///      否则使用 fallback oracle
    /// @param token 资产地址
    /// @return price 价格（1e18 精度，表示 1 个 token 值多少 USDT）
    function getPrice(address token) external view returns (uint256 price) {
        if (isRegistered[token]) {
            return _getWrapperPrice(token);
        }

        // 使用 fallback oracle
        if (fallbackOracle != address(0)) {
            (bool success, bytes memory data) =
                fallbackOracle.staticcall(abi.encodeWithSignature("getPrice(address)", token));
            if (success && data.length >= 32) {
                return abi.decode(data, (uint256));
            }
        }

        // 默认返回 1:1
        return PRECISION;
    }

    /// @notice 获取 wrapper 的 share 价格
    /// @param wrapper WrappedRWA 地址
    /// @return price 每个 share 的 USDT 价值
    function _getWrapperPrice(address wrapper) internal view returns (uint256 price) {
        IERC4626 w = IERC4626(wrapper);

        uint256 totalAssets = w.totalAssets();
        uint256 totalSupply = w.totalSupply();

        if (totalSupply == 0) {
            return PRECISION; // 1:1
        }

        // 价格 = totalAssets / totalSupply
        // 注意：totalAssets 已经包含 pendingPurchaseUSDT
        uint8 decimals = IERC20Metadata(wrapper).decimals();

        // 标准化到 1e18 精度
        price = (totalAssets * PRECISION) / totalSupply;

        return price;
    }

    /// @notice 获取 wrapper 的详细信息
    /// @param wrapper WrappedRWA 地址
    /// @return totalAssets 总资产（包含 pending）
    /// @return totalSupply 总供应量
    /// @return pricePerShare 每 share 价格
    function getWrapperInfo(address wrapper)
        external
        view
        returns (uint256 totalAssets, uint256 totalSupply, uint256 pricePerShare)
    {
        IERC4626 w = IERC4626(wrapper);

        totalAssets = w.totalAssets();
        totalSupply = w.totalSupply();
        pricePerShare = totalSupply > 0 ? (totalAssets * PRECISION) / totalSupply : PRECISION;
    }

    // =============================================================================
    // Admin Functions
    // =============================================================================

    /// @notice 注册 wrapper
    function registerWrapper(address wrapper) external onlyRole(ADMIN_ROLE) {
        if (wrapper == address(0)) revert ZeroAddress();
        isRegistered[wrapper] = true;
        emit WrapperRegistered(wrapper);
    }

    /// @notice 取消注册 wrapper
    function unregisterWrapper(address wrapper) external onlyRole(ADMIN_ROLE) {
        isRegistered[wrapper] = false;
        emit WrapperUnregistered(wrapper);
    }

    /// @notice 批量注册 wrapper
    function registerWrappers(address[] calldata wrappers) external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < wrappers.length; i++) {
            if (wrappers[i] != address(0)) {
                isRegistered[wrappers[i]] = true;
                emit WrapperRegistered(wrappers[i]);
            }
        }
    }

    /// @notice 设置 fallback oracle
    function setFallbackOracle(address oracle) external onlyRole(ADMIN_ROLE) {
        address old = fallbackOracle;
        fallbackOracle = oracle;
        emit FallbackOracleUpdated(old, oracle);
    }
}

/// @title CompositeOracle
/// @notice 组合 Oracle - 支持多种资产类型
/// @dev 可以组合 WrappedRWAOracle 和其他 Oracle
contract CompositeOracle is AccessControl {
    uint256 public constant PRECISION = 1e18;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice 资产到 Oracle 的映射
    mapping(address => address) public assetOracle;

    /// @notice 默认 Oracle
    address public defaultOracle;

    event OracleSet(address indexed asset, address indexed oracle);
    event DefaultOracleSet(address indexed oracle);

    error ZeroAddress();

    constructor(address admin_, address defaultOracle_) {
        if (admin_ == address(0)) revert ZeroAddress();

        defaultOracle = defaultOracle_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    /// @notice 获取价格
    function getPrice(address token) external view returns (uint256) {
        address oracle = assetOracle[token];
        if (oracle == address(0)) {
            oracle = defaultOracle;
        }

        if (oracle == address(0)) {
            return PRECISION;
        }

        (bool success, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("getPrice(address)", token));

        if (success && data.length >= 32) {
            return abi.decode(data, (uint256));
        }

        return PRECISION;
    }

    /// @notice 设置资产的 Oracle
    function setAssetOracle(address asset, address oracle) external onlyRole(ADMIN_ROLE) {
        assetOracle[asset] = oracle;
        emit OracleSet(asset, oracle);
    }

    /// @notice 批量设置
    function setAssetOracles(address[] calldata assets, address[] calldata oracles) external onlyRole(ADMIN_ROLE) {
        require(assets.length == oracles.length, "Length mismatch");
        for (uint256 i = 0; i < assets.length; i++) {
            assetOracle[assets[i]] = oracles[i];
            emit OracleSet(assets[i], oracles[i]);
        }
    }

    /// @notice 设置默认 Oracle
    function setDefaultOracle(address oracle) external onlyRole(ADMIN_ROLE) {
        defaultOracle = oracle;
        emit DefaultOracleSet(oracle);
    }
}
