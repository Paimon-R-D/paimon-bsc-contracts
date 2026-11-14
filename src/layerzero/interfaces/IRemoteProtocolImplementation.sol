// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRemoteProtocolImplementation
/// @notice Protocol-specific execution interface used by RemoteAssetGateway
interface IRemoteProtocolImplementation {
    /// @notice Deploy assets from the adapter into a remote protocol
    /// @param asset Address of the underlying asset held by the adapter
    /// @param protocol Target protocol or position address
    /// @param amount Requested asset amount to deploy
    /// @return deployedAmount Actual amount deployed into the protocol
    function deploy(address asset, address protocol, uint256 amount) external returns (uint256 deployedAmount);

    /// @notice Withdraw assets from a remote protocol back to the adapter
    /// @param asset Address of the underlying asset expected back at the adapter
    /// @param protocol Target protocol or position address
    /// @param amount Requested asset amount to withdraw
    /// @return withdrawnAmount Actual amount withdrawn back to the adapter
    function withdraw(address asset, address protocol, uint256 amount) external returns (uint256 withdrawnAmount);

    /// @notice Harvest yield from a remote protocol
    /// @param asset Address of the underlying asset expected as yield
    /// @param protocol Target protocol or position address
    /// @return yieldAmount Actual harvested yield amount
    function harvest(address asset, address protocol) external returns (uint256 yieldAmount);
}
