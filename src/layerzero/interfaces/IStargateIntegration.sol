// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";

/// @title IStargate
/// @notice Minimal Stargate V2 interface for USDT bridging with compose
/// @dev Stargate V2 implements IOFT; we only need the send/quote subset
interface IStargate {
    struct SendParam {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
        bytes composeMsg;
        bytes oftCmd; // "" = Taxi (supports compose), 0x01 = Bus (no compose)
    }

    struct OFTReceipt {
        uint256 amountSentLD;
        uint256 amountReceivedLD;
    }

    struct Ticket {
        uint72 ticketId;
        bytes passengerBytes;
    }

    /// @notice Quote the messaging fee for a send
    function quoteSend(
        SendParam calldata _sendParam,
        bool _payInLzToken
    ) external view returns (MessagingFee memory);

    /// @notice Standard OFT send
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory, OFTReceipt memory);

    /// @notice Stargate-specific send (returns Ticket for Bus mode)
    function sendToken(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory, OFTReceipt memory, Ticket memory);

    /// @notice Get the underlying token address
    function token() external view returns (address);

    /// @notice Whether approval is required before sending
    function approvalRequired() external view returns (bool);
}
