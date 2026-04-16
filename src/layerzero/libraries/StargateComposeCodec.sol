// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StargateComposeCodec
/// @notice Encode/decode compose message payloads for Stargate V2 bridging
/// @dev These are the custom payloads embedded in Stargate's composeMsg field.
///      Format: abi.encodePacked(uint8(action), abi.encode(params...))
///      The outer OFTComposeMsgCodec wrapping (nonce, srcEid, amountLD, composeFrom)
///      is handled by Stargate/LayerZero automatically.
library StargateComposeCodec {
    // ========== Compose Action Types ==========

    uint8 internal constant ACTION_DEPOSIT = 0x01;
    uint8 internal constant ACTION_SETTLEMENT = 0x02;
    uint8 internal constant ACTION_DEPLOY = 0x03;
    uint8 internal constant ACTION_RETURN = 0x04;
    uint8 internal constant ACTION_REPLENISH = 0x05;
    uint8 internal constant ACTION_HARVEST_RETURN = 0x06;

    // ========== Encode Functions ==========

    /// @notice Encode deposit compose: SatelliteGateway → HubComposer
    /// @param receiver The address to receive PPT shares
    /// @param minShares Minimum shares expected (slippage protection)
    function encodeDeposit(address receiver, uint256 minShares) internal pure returns (bytes memory) {
        return abi.encodePacked(ACTION_DEPOSIT, abi.encode(receiver, minShares));
    }

    /// @notice Encode settlement compose: HubComposer → SatelliteGateway
    /// @param receiver The address to receive redeemed USDT
    /// @param requestId The redemption request ID
    function encodeSettlement(address receiver, uint256 requestId) internal pure returns (bytes memory) {
        return abi.encodePacked(ACTION_SETTLEMENT, abi.encode(receiver, requestId));
    }

    /// @notice Encode deploy compose: HubComposer → RemoteAssetGateway
    /// @param protocol Target protocol address (e.g., Aave pool)
    /// @param protocolName Protocol identifier string
    function encodeDeploy(address protocol, string memory protocolName) internal pure returns (bytes memory) {
        return abi.encodePacked(ACTION_DEPLOY, abi.encode(protocol, protocolName));
    }

    /// @notice Encode return compose: RemoteAssetGateway → HubComposer
    /// @param isYield Whether this is yield (true) or withdrawal return (false)
    /// @dev The source chain is derived from the LayerZero-authenticated outer srcEid
    ///      on the Hub side; redundantly carrying it in the payload allowed a compromised
    ///      gateway to forge cross-chain NAV accounting.
    function encodeReturn(bool isYield) internal pure returns (bytes memory) {
        return abi.encodePacked(ACTION_RETURN, abi.encode(isYield));
    }

    /// @notice Encode replenish compose: HubComposer → SatelliteGateway
    function encodeReplenish() internal pure returns (bytes memory) {
        return abi.encodePacked(ACTION_REPLENISH);
    }

    // ========== Decode Functions ==========

    /// @notice Extract action type from compose message
    function decodeAction(bytes memory composeMsg) internal pure returns (uint8) {
        return uint8(composeMsg[0]);
    }

    /// @notice Decode deposit params
    function decodeDeposit(bytes memory composeMsg)
        internal
        pure
        returns (address receiver, uint256 minShares)
    {
        return abi.decode(_stripAction(composeMsg), (address, uint256));
    }

    /// @notice Decode settlement params
    function decodeSettlement(bytes memory composeMsg)
        internal
        pure
        returns (address receiver, uint256 requestId)
    {
        return abi.decode(_stripAction(composeMsg), (address, uint256));
    }

    /// @notice Decode deploy params
    function decodeDeploy(bytes memory composeMsg)
        internal
        pure
        returns (address protocol, string memory protocolName)
    {
        return abi.decode(_stripAction(composeMsg), (address, string));
    }

    /// @notice Decode return params
    function decodeReturn(bytes memory composeMsg) internal pure returns (bool isYield) {
        return abi.decode(_stripAction(composeMsg), (bool));
    }

    // ========== Internal ==========

    /// @dev Strip the 1-byte action prefix, return remaining bytes for abi.decode
    function _stripAction(bytes memory data) private pure returns (bytes memory) {
        bytes memory result = new bytes(data.length - 1);
        for (uint256 i = 1; i < data.length; i++) {
            result[i - 1] = data[i];
        }
        return result;
    }
}
