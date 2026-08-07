// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPPTOFTAdapter
/// @notice OFT Adapter interface for PPT token on Hub chain (BSC)
/// @dev Wraps existing PPT ERC20 into LayerZero OFT for cross-chain transfers
interface IPPTOFTAdapter {
    // ========== Structs ==========

    /// @notice Send parameters for cross-chain transfer
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

    /// @notice Emitted when deposit message is processed
    /// @param srcEid Source chain endpoint ID
    /// @param depositor Address of the depositor
    /// @param assets Amount of assets deposited
    /// @param shares Shares minted
    event DepositProcessed(
        uint32 indexed srcEid,
        address indexed depositor,
        uint256 assets,
        uint256 shares
    );

    /// @notice Emitted when withdrawal message is processed
    /// @param srcEid Source chain endpoint ID
    /// @param withdrawer Address of the withdrawer
    /// @param shares Shares burned
    /// @param assets Assets to be sent
    event WithdrawProcessed(
        uint32 indexed srcEid,
        address indexed withdrawer,
        uint256 shares,
        uint256 assets
    );

    // ========== View Functions ==========

    /// @notice Get the underlying PPT token address
    /// @return Address of the PPT ERC20 token
    function token() external view returns (address);

    /// @notice Get the PPT Vault address
    /// @return Address of the PPT (ERC4626) vault
    function vault() external view returns (address);

    /// @notice Get the CreditManager address
    /// @return Address of the CreditManager
    function creditManager() external view returns (address);

    /// @notice Get the LayerZero endpoint address
    /// @return Address of the LayerZero endpoint
    function endpoint() external view returns (address);

    /// @notice Get the local endpoint ID
    /// @return This chain's LayerZero endpoint ID
    function localEid() external view returns (uint32);

    /// @notice Get token decimals
    /// @return Number of decimals
    function decimals() external view returns (uint8);

    /// @notice Get shared decimals for cross-chain (LayerZero standard)
    /// @return Shared decimals (typically 6)
    function sharedDecimals() external view returns (uint8);

    /// @notice Check if a peer is set for a destination chain
    /// @param eid Destination chain endpoint ID
    /// @return True if peer is configured
    function isPeer(uint32 eid) external view returns (bool);

    /// @notice Get the peer address for a destination chain
    /// @param eid Destination chain endpoint ID
    /// @return Peer address in bytes32 format
    function peers(uint32 eid) external view returns (bytes32);

    // ========== Core OFT Functions ==========

    /// @notice Quote the messaging fee for a send operation
    /// @param dstEid Destination chain endpoint ID
    /// @param amountLD Amount in local decimals
    /// @param options LayerZero options bytes
    /// @param payInLzToken Whether to pay fee in LZ token
    /// @return msgFee Messaging fee structure
    function quoteSend(
        uint32 dstEid,
        uint256 amountLD,
        bytes calldata options,
        bool payInLzToken
    ) external view returns (MessagingFee memory msgFee);

    /// @notice Send tokens cross-chain
    /// @param dstEid Destination chain endpoint ID
    /// @param to Recipient address in bytes32 format
    /// @param amountLD Amount in local decimals
    /// @param minAmountLD Minimum amount to receive
    /// @param options LayerZero options bytes
    /// @param refundAddress Address to refund excess fee
    /// @return msgReceipt Messaging receipt
    function send(
        uint32 dstEid,
        bytes32 to,
        uint256 amountLD,
        uint256 minAmountLD,
        bytes calldata options,
        address refundAddress
    ) external payable returns (MessagingReceipt memory msgReceipt);

    // ========== Cross-Chain Vault Operations ==========

    function mintSharesOnSatellite(uint32 dstEid, address receiver, uint256 shares) external;

    function syncCreditToSatellite(uint32 dstEid, uint256 newCredit, address refundAddress) external payable;

    function syncSharePrice(uint32 dstEid) external payable;

    // ========== Peer Configuration ==========

    /// @notice Set peer address for a chain
    /// @param eid Chain endpoint ID
    /// @param peer Peer address in bytes32 format
    function setPeer(uint32 eid, bytes32 peer) external;

    /// @notice Set multiple peers at once
    /// @param eids Array of endpoint IDs
    /// @param peers Array of peer addresses
    function setPeers(uint32[] calldata eids, bytes32[] calldata peers) external;

    // ========== Configuration ==========

    /// @notice Set the CreditManager address
    /// @param _creditManager Address of CreditManager
    function setCreditManager(address _creditManager) external;

    function setVault(address vault) external;

    function setRedemptionManager(address redemptionManager) external;

    function setHubStargateComposer(address composer) external;

    /// @notice Set enforced options for a destination chain
    /// @param eid Destination endpoint ID
    /// @param msgType Message type
    /// @param options Enforced options bytes
    function setEnforcedOptions(uint32 eid, uint16 msgType, bytes calldata options) external;
}
