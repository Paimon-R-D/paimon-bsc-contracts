// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MessageCodec
/// @notice Centralized message encoding/decoding for LayerZero cross-chain messages
/// @dev All messages follow: abi.encodePacked(bytes1(msgType), abi.encode(data...))
///      Decode: bytes1 msgType = payload[0]; abi.decode(payload[1:], (...))
library MessageCodec {
    // ========== Message Type Constants ==========
    // Namespace: 0x1x = Satellite→Hub (credit)
    //            0x2x = Hub→Satellite (credit/shares/price)
    //            0x3x = Satellite→Hub (deposit/withdraw)
    //            0x4x = Hub→RemoteAdapter (commands)
    //            0x5x = RemoteAdapter→Hub (confirmations)

    // --- Satellite → Hub (Credit) ---
    bytes1 internal constant MSG_CREDIT_USED = 0x10;

    // --- Hub → Satellite ---
    bytes1 internal constant MSG_SHARE_PRICE_UPDATE = 0x20;
    bytes1 internal constant MSG_CREDIT_UPDATE = 0x21;
    bytes1 internal constant MSG_MINT_SHARES = 0x22;

    // --- Satellite → Hub (Deposit/Withdraw/Redeem) ---
    bytes1 internal constant MSG_DEPOSIT = 0x30;
    bytes1 internal constant MSG_WITHDRAW = 0x31;
    bytes1 internal constant MSG_REDEEM = 0x32;

    // --- Hub → RemoteAdapter (Commands) ---
    bytes1 internal constant MSG_DEPLOY = 0x40;
    bytes1 internal constant MSG_WITHDRAW_ASSET = 0x41;
    bytes1 internal constant MSG_HARVEST = 0x42;

    // --- RemoteAdapter → Hub (Confirmations) ---
    bytes1 internal constant MSG_WITHDRAW_CONFIRM = 0x50;
    bytes1 internal constant MSG_YIELD_REPORT = 0x51;

    // ========== Encode Functions ==========

    /// @notice Encode credit update message (Hub → Satellite)
    function encodeCreditUpdate(uint256 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(MSG_CREDIT_UPDATE, abi.encode(amount));
    }

    /// @notice Encode share price update message (Hub → Satellite)
    function encodeSharePriceUpdate(uint256 price) internal pure returns (bytes memory) {
        return abi.encodePacked(MSG_SHARE_PRICE_UPDATE, abi.encode(price));
    }

    /// @notice Encode mint shares message (Hub → Satellite)
    function encodeMintShares(address receiver, uint256 shares) internal pure returns (bytes memory) {
        return abi.encodePacked(MSG_MINT_SHARES, abi.encode(receiver, shares));
    }

    /// @notice Encode deposit message (Satellite → Hub)
    function encodeDeposit(address receiver, uint256 assets) internal pure returns (bytes memory) {
        return abi.encodePacked(MSG_DEPOSIT, abi.encode(receiver, assets));
    }

    /// @notice Encode withdraw message (Satellite → Hub)
    function encodeWithdraw(address receiver, uint256 shares) internal pure returns (bytes memory) {
        return abi.encodePacked(MSG_WITHDRAW, abi.encode(receiver, shares));
    }

    /// @notice Encode redemption request message (Satellite → Hub)
    function encodeRedeem(address owner, uint256 shares) internal pure returns (bytes memory) {
        return abi.encodePacked(MSG_REDEEM, abi.encode(owner, shares));
    }

    /// @notice Encode credit used message (Satellite → Hub)
    function encodeCreditUsed(uint256 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(MSG_CREDIT_USED, abi.encode(amount));
    }

    /// @notice Encode deploy command (Hub → RemoteAdapter)
    function encodeDeploy(uint256 amount, address protocol, string memory protocolName)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(MSG_DEPLOY, abi.encode(amount, protocol, protocolName));
    }

    /// @notice Encode withdraw asset command (Hub → RemoteAdapter)
    function encodeWithdrawAsset(uint256 amount, address protocol, string memory protocolName)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(MSG_WITHDRAW_ASSET, abi.encode(amount, protocol, protocolName));
    }

    /// @notice Encode harvest command (Hub → RemoteAdapter)
    function encodeHarvest(address protocol, string memory protocolName) internal pure returns (bytes memory) {
        return abi.encodePacked(MSG_HARVEST, abi.encode(protocol, protocolName));
    }

    /// @notice Encode withdraw confirmation (RemoteAdapter → Hub)
    function encodeWithdrawConfirm(uint256 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(MSG_WITHDRAW_CONFIRM, abi.encode(amount));
    }

    /// @notice Encode yield report (RemoteAdapter → Hub)
    function encodeYieldReport(uint256 yieldAmount) internal pure returns (bytes memory) {
        return abi.encodePacked(MSG_YIELD_REPORT, abi.encode(yieldAmount));
    }

    // ========== Decode Functions ==========

    /// @notice Extract message type from payload
    function decodeMsgType(bytes calldata payload) internal pure returns (bytes1) {
        return bytes1(payload[0]);
    }

    /// @notice Decode a single uint256 from payload (skipping msgType byte)
    function decodeAmount(bytes calldata payload) internal pure returns (uint256) {
        return abi.decode(payload[1:], (uint256));
    }

    /// @notice Decode address and uint256 from payload (skipping msgType byte)
    function decodeAddressAndAmount(bytes calldata payload) internal pure returns (address, uint256) {
        return abi.decode(payload[1:], (address, uint256));
    }

    /// @notice Decode deploy/withdraw command (amount, protocol, protocolName)
    function decodeDeployCommand(bytes calldata payload)
        internal
        pure
        returns (uint256 amount, address protocol, string memory protocolName)
    {
        return abi.decode(payload[1:], (uint256, address, string));
    }

    /// @notice Decode harvest command (protocol, protocolName)
    function decodeHarvestCommand(bytes calldata payload)
        internal
        pure
        returns (address protocol, string memory protocolName)
    {
        return abi.decode(payload[1:], (address, string));
    }
}
