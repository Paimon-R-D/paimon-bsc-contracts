// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IPPTOFT
/// @notice OFT interface for PPT token representation on remote chains
/// @dev Deployed on remote chains (Ethereum, Arbitrum, Base, etc.)
///      This is a synthetic representation of PPT that can be transferred cross-chain
interface IPPTOFT is IERC20 {
    // ========== Structs ==========

    /// @notice Send parameters for cross-chain transfer
    struct SendParam {
        uint32 dstEid;              // Destination chain endpoint ID
        bytes32 to;                 // Recipient address (bytes32 for cross-chain compatibility)
        uint256 amountLD;           // Amount in local decimals
        uint256 minAmountLD;        // Minimum amount to receive (slippage protection)
        bytes extraOptions;         // Additional LayerZero options
        bytes composeMsg;           // Compose message for destination chain
        bytes oftCmd;               // OFT specific command
    }

    /// @notice Messaging fee structure
    struct MessagingFee {
        uint256 nativeFee;          // Native token fee
        uint256 lzTokenFee;         // LayerZero token fee
    }

    /// @notice Messaging receipt from LayerZero
    struct MessagingReceipt {
        bytes32 guid;               // Global unique identifier
        uint64 nonce;               // Message nonce
        MessagingFee fee;           // Fee paid
    }

    /// @notice OFT receipt for send operation
    struct OFTReceipt {
        uint256 amountSentLD;       // Amount sent in local decimals
        uint256 amountReceivedLD;   // Amount to be received in local decimals
    }

    // ========== Events ==========

    /// @notice Emitted when tokens are sent cross-chain
    /// @param guid Global unique identifier for the message
    /// @param dstEid Destination chain endpoint ID
    /// @param from Sender address
    /// @param amountSentLD Amount sent in local decimals
    /// @param amountReceivedLD Amount to be received in local decimals
    event OFTSent(
        bytes32 indexed guid,
        uint32 dstEid,
        address indexed from,
        uint256 amountSentLD,
        uint256 amountReceivedLD
    );

    /// @notice Emitted when tokens are received from cross-chain
    /// @param guid Global unique identifier for the message
    /// @param srcEid Source chain endpoint ID
    /// @param to Recipient address
    /// @param amountReceivedLD Amount received in local decimals
    event OFTReceived(
        bytes32 indexed guid,
        uint32 srcEid,
        address indexed to,
        uint256 amountReceivedLD
    );

    // ========== View Functions ==========

    /// @notice Get token decimals
    /// @return Number of decimals
    function decimals() external view returns (uint8);

    /// @notice Get shared decimals for cross-chain (LayerZero standard)
    /// @return Shared decimals (typically 6)
    function sharedDecimals() external view returns (uint8);

    /// @notice Get the LayerZero endpoint address
    /// @return Address of the LayerZero endpoint
    function endpoint() external view returns (address);

    /// @notice Get the local endpoint ID
    /// @return This chain's LayerZero endpoint ID
    function localEid() external view returns (uint32);

    /// @notice Check if a peer is set for a destination chain
    /// @param eid Destination chain endpoint ID
    /// @return True if peer is configured
    function isPeer(uint32 eid) external view returns (bool);

    /// @notice Get the peer address for a destination chain
    /// @param eid Destination chain endpoint ID
    /// @return Peer address in bytes32 format
    function peers(uint32 eid) external view returns (bytes32);

    /// @notice Get the Hub chain endpoint ID
    /// @return LayerZero endpoint ID of the Hub (BSC)
    function hubEid() external view returns (uint32);

    // ========== Core OFT Functions ==========

    /// @notice Quote the messaging fee for a send operation
    /// @param sendParam Send parameters
    /// @param payInLzToken Whether to pay fee in LZ token
    /// @return msgFee Messaging fee structure
    function quoteSend(
        SendParam calldata sendParam,
        bool payInLzToken
    ) external view returns (MessagingFee memory msgFee);

    /// @notice Send tokens cross-chain
    /// @param sendParam Send parameters
    /// @param fee Messaging fee to pay
    /// @param refundAddress Address to refund excess fee
    /// @return msgReceipt Messaging receipt
    /// @return oftReceipt OFT receipt
    function send(
        SendParam calldata sendParam,
        MessagingFee calldata fee,
        address refundAddress
    ) external payable returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt);

    // ========== Minting/Burning (PPTSatellite Only) ==========

    /// @notice Mint tokens to a recipient
    /// @dev Only callable by authorized minter (PPTSatellite)
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external;

    /// @notice Burn tokens from a holder
    /// @dev Only callable by authorized burner (PPTSatellite)
    /// @param from Holder address
    /// @param amount Amount to burn
    function burn(address from, uint256 amount) external;

    // ========== Peer Configuration ==========

    /// @notice Set peer address for a chain
    /// @param eid Chain endpoint ID
    /// @param peer Peer address in bytes32 format
    function setPeer(uint32 eid, bytes32 peer) external;

    /// @notice Set the Hub endpoint ID
    /// @param _hubEid LayerZero endpoint ID of the Hub
    function setHubEid(uint32 _hubEid) external;

    // ========== Configuration ==========

    /// @notice Set authorized minter address
    /// @param minter Address to authorize for minting
    /// @param authorized True to authorize, false to revoke
    function setMinter(address minter, bool authorized) external;

    /// @notice Set enforced options for a destination chain
    /// @param eid Destination endpoint ID
    /// @param msgType Message type
    /// @param options Enforced options bytes
    function setEnforcedOptions(uint32 eid, uint16 msgType, bytes calldata options) external;
}
