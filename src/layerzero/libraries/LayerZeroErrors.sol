// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LayerZeroErrors
/// @notice Shared error definitions for LayerZero contracts
/// @dev Provides consistent error handling across the LayerZero module
library LayerZeroErrors {
    /// @notice Thrown when message type is unknown
    error UnknownMessageType(bytes1 msgType);

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when recipient address is invalid
    error InvalidRecipient();

    /// @notice Thrown when amount is zero or invalid
    error InvalidAmount();

    /// @notice Thrown when peer verification fails
    error InvalidPeer(uint32 srcEid, bytes32 sender);

    /// @notice Thrown when source chain is not authorized
    error UnauthorizedSource(uint32 srcEid);

    /// @notice Thrown when array lengths don't match
    error LengthMismatch(uint256 expected, uint256 actual);

    /// @notice Thrown when array is empty
    error EmptyArray();

    /// @notice Thrown when insufficient native fee provided
    error InsufficientFee(uint256 provided, uint256 required);

    /// @notice Thrown when chain is not supported
    error ChainNotSupported(uint32 eid);

    /// @notice Thrown when credit is insufficient
    error InsufficientCredit(uint256 available, uint256 required);

    /// @notice Thrown when a stub function is called without being overridden
    error NotImplemented(string functionName);

    /// @notice Thrown when contract has insufficient gas balance for cross-chain message
    error InsufficientGasBalance(uint256 available, uint256 required);
}
