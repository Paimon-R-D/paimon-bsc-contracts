// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IIdentityRegistry - EIP-3643 标准身份注册接口
/// @notice 所有 KYC 机构（正规或测试用）都应实现此接口
/// @dev 遵循 EIP-3643 标准，正规 ONCHAINID 机构和简化白名单均实现此接口，
///      确保接口统一，可无缝替换底层实现
interface IIdentityRegistry {
    /// @notice 身份注册事件
    /// @param userAddress 注册的用户地址
    /// @param country ISO-3166 国家代码
    event IdentityRegistered(address indexed userAddress, uint16 country);

    /// @notice 身份移除事件
    /// @param userAddress 被移除的用户地址
    event IdentityRemoved(address indexed userAddress);

    /// @notice 国家代码更新事件
    /// @param userAddress 用户地址
    /// @param country 新的国家代码
    event CountryUpdated(address indexed userAddress, uint16 country);

    /// @notice 检查地址是否通过身份验证（KYC）
    /// @param userAddress 待检查的地址
    /// @return 是否已通过 KYC 验证
    function isVerified(address userAddress) external view returns (bool);

    /// @notice 检查地址是否已注册（不代表已验证）
    /// @param userAddress 待检查的地址
    /// @return 是否已注册
    function contains(address userAddress) external view returns (bool);

    /// @notice 获取用户的国家代码
    /// @param userAddress 用户地址
    /// @return ISO-3166 国家代码（如 156=中国, 840=美国）
    function investorCountry(address userAddress) external view returns (uint16);

    /// @notice 注册身份，需要 Agent 权限
    /// @param userAddress 要注册的用户地址
    /// @param country ISO-3166 国家代码
    function registerIdentity(address userAddress, uint16 country) external;

    /// @notice 移除身份，需要 Agent 权限
    /// @param userAddress 要移除的用户地址
    function deleteIdentity(address userAddress) external;

    /// @notice 更新用户国家代码
    /// @param userAddress 用户地址
    /// @param country 新的 ISO-3166 国家代码
    function updateCountry(address userAddress, uint16 country) external;

    /// @notice 批量注册身份
    /// @param userAddresses 用户地址数组
    /// @param countries 对应的国家代码数组，长度必须与 userAddresses 一致
    function batchRegisterIdentity(
        address[] calldata userAddresses,
        uint16[] calldata countries
    ) external;
}
