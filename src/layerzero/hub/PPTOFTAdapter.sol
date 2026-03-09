// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ICreditManager} from "../interfaces/ICreditManager.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRedemptionManager} from "../../ppt/IPPTContracts.sol";
import {MessageCodec} from "../libraries/MessageCodec.sol";
import {LzOptionsLib} from "../libraries/LzOptionsLib.sol";
import {LayerZeroErrors} from "../libraries/LayerZeroErrors.sol";

/// @title PPTOFTAdapter
/// @notice OFT Adapter for PPT token on BSC Hub chain
/// @dev Wraps existing PPT ERC20 into LayerZero OFT using lock/unlock mechanism.
///      Handles both standard OFT messages and typed Satellite deposit/withdraw messages.
contract PPTOFTAdapter is OApp, Pausable, ReentrancyGuard, ILayerZeroComposer {
    using SafeERC20 for IERC20;

    // ========== Constants ==========

    uint16 public constant MSG_TYPE_SEND = 1;
    uint16 public constant MSG_TYPE_SEND_AND_CALL = 2;

    bytes1 public constant COMPOSE_MSG_REDEEM = 0x01;
    bytes1 public constant COMPOSE_MSG_DEPOSIT = 0x02;

    uint8 public constant SHARED_DECIMALS = 6;

    uint128 public constant DEFAULT_GAS_LIMIT = 200000;

    // ========== State Variables ==========

    IERC20 public immutable innerToken;
    uint8 public immutable localDecimals;
    uint256 public immutable decimalConversionRate;

    ICreditManager public creditManager;
    address public vault;
    address public redemptionManager;

    // ========== Pending Mint Queue (ERR-002 fix) ==========

    struct PendingMint {
        uint32 dstEid;
        address receiver;
        uint256 shares;
    }

    mapping(uint256 => PendingMint) public pendingMints;
    uint256 public pendingMintCount;

    event PendingMintStored(uint256 indexed mintId, uint32 dstEid, address receiver, uint256 shares);
    event PendingMintFlushed(uint256 indexed mintId, uint32 dstEid, address receiver, uint256 shares);

    // ========== Events ==========

    event OFTSent(
        bytes32 indexed guid,
        uint32 dstEid,
        address indexed from,
        uint256 amountSentLD,
        uint256 amountReceivedLD
    );

    event OFTReceived(
        bytes32 indexed guid,
        uint32 srcEid,
        address indexed to,
        uint256 amountReceivedLD
    );

    event CrossChainRedemptionProcessed(
        bytes32 indexed guid,
        address indexed owner,
        uint256 shares,
        uint256 requestId
    );

    event CrossChainDepositProcessed(
        bytes32 indexed guid,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );

    event SatelliteDepositProcessed(
        uint32 indexed srcEid,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );

    event SatelliteWithdrawProcessed(
        uint32 indexed srcEid,
        address indexed receiver,
        uint256 shares
    );

    // ========== Errors ==========

    error InvalidAmount();
    error SlippageExceeded(uint256 amountLD, uint256 minAmountLD);
    error InsufficientBalance();
    error InvalidComposer();
    error InvalidComposeMessage();
    error InvalidPeer(uint32 srcEid, bytes32 sender);
    error ZeroAddress();

    // ========== Additional Events ==========

    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    // ========== Constructor ==========

    constructor(
        address _token,
        address _endpoint,
        address _delegate
    ) OApp(_endpoint, _delegate) Ownable(_delegate) {
        innerToken = IERC20(_token);
        localDecimals = IERC20Metadata(_token).decimals();

        if (localDecimals < SHARED_DECIMALS) revert InvalidAmount();
        decimalConversionRate = 10 ** (localDecimals - SHARED_DECIMALS);
    }

    // ========== View Functions ==========

    function token() external view returns (address) {
        return address(innerToken);
    }

    function decimals() external view returns (uint8) {
        return localDecimals;
    }

    function sharedDecimals() external pure returns (uint8) {
        return SHARED_DECIMALS;
    }

    function approvalRequired() external pure returns (bool) {
        return true;
    }

    // ========== OFT Send Functions ==========

    function quoteSend(
        uint32 _dstEid,
        uint256 _amountLD,
        bytes calldata _options,
        bool _payInLzToken
    ) external view returns (MessagingFee memory fee) {
        bytes memory message = _buildSendMessage(_amountLD, msg.sender);
        bytes memory options = _options.length > 0 ? _options : LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);
        return _quote(_dstEid, message, options, _payInLzToken);
    }

    function send(
        uint32 _dstEid,
        bytes32 _to,
        uint256 _amountLD,
        uint256 _minAmountLD,
        bytes calldata _options,
        address _refundAddress
    ) external payable whenNotPaused returns (MessagingReceipt memory receipt) {
        if (_amountLD == 0) revert InvalidAmount();

        (uint256 amountSentLD, uint256 amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);

        innerToken.safeTransferFrom(msg.sender, address(this), amountSentLD);

        bytes memory message = _buildSendMessage(amountReceivedLD, _bytes32ToAddress(_to));
        bytes memory options = _options.length > 0 ? _options : LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);

        receipt = _lzSend(_dstEid, message, options, MessagingFee(msg.value, 0), payable(_refundAddress));

        emit OFTSent(receipt.guid, _dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }

    // ========== LayerZero Receive ==========

    /// @notice Handle incoming LayerZero messages
    /// @dev P0-4 + P1-2 FIX: Dispatches both standard OFT messages and typed Satellite messages.
    ///      Standard OFT messages are 64 bytes (abi.encode(address, uint256)).
    ///      Typed messages have a bytes1 prefix at payload[0].
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _payload,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override whenNotPaused nonReentrant {
        bytes32 expectedPeer = peers[_origin.srcEid];
        if (expectedPeer == bytes32(0) || _origin.sender != expectedPeer) {
            revert InvalidPeer(_origin.srcEid, _origin.sender);
        }

        // Standard OFT message: abi.encode(address, uint256) = exactly 64 bytes
        if (_payload.length == 64) {
            (address to, uint256 amountLD) = abi.decode(_payload, (address, uint256));
            if (to == address(0)) revert ZeroAddress();
            _credit(to, amountLD, _origin.srcEid);
            emit OFTReceived(_guid, _origin.srcEid, to, amountLD);
            return;
        }

        // Typed message from Satellite: first byte is message type
        bytes1 msgType = MessageCodec.decodeMsgType(_payload);

        if (msgType == MessageCodec.MSG_DEPOSIT) {
            _handleSatelliteDeposit(_origin, _payload);
        } else if (msgType == MessageCodec.MSG_WITHDRAW) {
            _handleSatelliteWithdraw(_origin, _payload);
        } else if (msgType == MessageCodec.MSG_REDEEM) {
            _handleSatelliteRedemption(_origin, _payload);
        } else {
            revert LayerZeroErrors.UnknownMessageType(msgType);
        }
    }

    // ========== Compose Functions ==========

    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) external payable override {
        if (msg.sender != address(endpoint)) revert InvalidComposer();
        if (_from != address(this)) revert InvalidComposer();

        if (_message.length == 0) revert InvalidComposeMessage();

        bytes1 msgType = bytes1(_message[0]);

        if (msgType == COMPOSE_MSG_REDEEM) {
            _handleRedemption(_guid, _message[1:]);
        } else if (msgType == COMPOSE_MSG_DEPOSIT) {
            _handleDeposit(_guid, _message[1:]);
        } else {
            revert InvalidComposeMessage();
        }
    }

    // ========== Internal Functions ==========

    function _debitView(
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 /*_dstEid*/
    ) internal view returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        amountSentLD = _removeDust(_amountLD);
        amountReceivedLD = amountSentLD;

        if (amountReceivedLD < _minAmountLD) {
            revert SlippageExceeded(amountReceivedLD, _minAmountLD);
        }
    }

    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 /*_srcEid*/
    ) internal returns (uint256 amountReceivedLD) {
        innerToken.safeTransfer(_to, _amountLD);
        return _amountLD;
    }

    function _removeDust(uint256 _amountLD) internal view returns (uint256 amountLD) {
        return (_amountLD / decimalConversionRate) * decimalConversionRate;
    }

    function _buildSendMessage(uint256 _amountLD, address _to) internal pure returns (bytes memory) {
        return abi.encode(_to, _amountLD);
    }

    function _bytes32ToAddress(bytes32 _b) internal pure returns (address) {
        return address(uint160(uint256(_b)));
    }

    /// @notice Handle satellite deposit: deposit to vault, send mint shares back
    /// @dev Uses pending mint queue to prevent nonce blocking on insufficient gas
    function _handleSatelliteDeposit(Origin calldata _origin, bytes calldata _payload) internal {
        (address receiver, uint256 assets) = MessageCodec.decodeAddressAndAmount(_payload);

        if (vault == address(0)) revert ZeroAddress();
        if (receiver == address(0)) revert ZeroAddress();
        if (assets == 0) revert InvalidAmount();

        // Approve vault and deposit (forceApprove for USDT compatibility)
        innerToken.forceApprove(vault, assets);
        uint256 shares = IERC4626(vault).deposit(assets, address(this));
        innerToken.forceApprove(vault, 0);

        // Try to send mint shares message back to satellite
        bytes memory mintPayload = MessageCodec.encodeMintShares(receiver, shares);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);

        MessagingFee memory fee = _quote(_origin.srcEid, mintPayload, options, false);

        if (address(this).balance >= fee.nativeFee) {
            _lzSend(_origin.srcEid, mintPayload, options, MessagingFee(fee.nativeFee, 0), payable(address(this)));
        } else {
            // Store for keeper retry to prevent nonce blocking
            uint256 mintId = pendingMintCount++;
            pendingMints[mintId] = PendingMint(_origin.srcEid, receiver, shares);
            emit PendingMintStored(mintId, _origin.srcEid, receiver, shares);
        }

        emit SatelliteDepositProcessed(_origin.srcEid, receiver, assets, shares);
    }

    /// @notice Flush a pending mint that was stored due to insufficient gas
    function flushPendingMint(uint256 mintId) external payable whenNotPaused {
        PendingMint memory pm = pendingMints[mintId];
        if (pm.receiver == address(0)) revert ZeroAddress();

        delete pendingMints[mintId];

        bytes memory mintPayload = MessageCodec.encodeMintShares(pm.receiver, pm.shares);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);
        _lzSend(pm.dstEid, mintPayload, options, MessagingFee(msg.value, 0), payable(msg.sender));

        emit PendingMintFlushed(mintId, pm.dstEid, pm.receiver, pm.shares);
    }

    /// @notice Handle satellite withdraw: process redemption on hub
    function _handleSatelliteWithdraw(Origin calldata _origin, bytes calldata _payload) internal {
        (address receiver, uint256 shares) = MessageCodec.decodeAddressAndAmount(_payload);

        if (receiver == address(0)) revert ZeroAddress();
        if (shares == 0) revert InvalidAmount();

        if (hubStargateComposer != address(0)) {
            uint256 requestId = _requestSatelliteRedemption(_origin.srcEid, receiver, shares);
            emit CrossChainRedemptionProcessed(bytes32(0), receiver, shares, requestId);
        } else {
            _requestRedemption(shares, receiver);
        }

        emit SatelliteWithdrawProcessed(_origin.srcEid, receiver, shares);
    }

    /// @notice Handle satellite redemption request (PPTOFT.requestCrossChainRedemption)
    /// @dev Tokens were burned on remote chain; locked tokens on Hub are used for redemption
    function _handleSatelliteRedemption(Origin calldata _origin, bytes calldata _payload) internal {
        (address owner, uint256 shares) = MessageCodec.decodeAddressAndAmount(_payload);

        if (owner == address(0)) revert ZeroAddress();
        if (shares == 0) revert InvalidAmount();

        uint256 requestId = hubStargateComposer != address(0)
            ? _requestSatelliteRedemption(_origin.srcEid, owner, shares)
            : _requestRedemption(shares, owner);

        emit CrossChainRedemptionProcessed(bytes32(0), owner, shares, requestId);
    }

    /// @notice Handle cross-chain redemption request
    /// @dev P0-8 FIX: Removed unnecessary approve before safeTransfer
    function _handleRedemption(bytes32 _guid, bytes calldata _data) internal {
        (address owner, uint256 shares) = abi.decode(_data, (address, uint256));

        if (redemptionManager == address(0)) revert InvalidComposeMessage();
        if (owner == address(0)) revert ZeroAddress();
        if (shares == 0) revert InvalidAmount();

        uint256 requestId = _requestRedemption(shares, owner);

        emit CrossChainRedemptionProcessed(_guid, owner, shares, requestId);
    }

    /// @notice Internal function to request redemption through the configured manager
    function _requestRedemption(uint256 shares, address owner) internal returns (uint256) {
        if (redemptionManager == address(0)) revert InvalidComposeMessage();
        return IRedemptionManager(redemptionManager).requestRedemption(shares, owner);
    }

    function _requestSatelliteRedemption(uint32 srcEid, address receiver, uint256 shares) internal returns (uint256 requestId) {
        requestId = _requestRedemption(shares, hubStargateComposer);
        IHubStargateSettlementRegistrar(hubStargateComposer).registerSatelliteRedemption(requestId, srcEid, receiver);
    }

    /// @notice Handle cross-chain deposit
    function _handleDeposit(bytes32 _guid, bytes calldata _data) internal {
        (address receiver, uint256 assets) = abi.decode(_data, (address, uint256));

        if (vault == address(0)) revert InvalidComposeMessage();
        if (receiver == address(0)) revert ZeroAddress();
        if (assets == 0) revert InvalidAmount();

        innerToken.forceApprove(vault, assets);
        uint256 shares = IERC4626(vault).deposit(assets, receiver);
        innerToken.forceApprove(vault, 0);

        emit CrossChainDepositProcessed(_guid, receiver, assets, shares);
    }

    // ========== Stargate Composer Integration ==========

    /// @notice Hub Stargate Composer address (authorized to call mintSharesOnSatellite)
    address public hubStargateComposer;

    /// @notice Send PPT shares to a receiver on a satellite chain
    /// @dev Called by HubStargateComposer after a bridged deposit is processed
    function mintSharesOnSatellite(uint32 dstEid, address receiver, uint256 shares) external whenNotPaused {
        if (msg.sender != hubStargateComposer) revert InvalidComposer();
        if (receiver == address(0)) revert ZeroAddress();
        if (shares == 0) revert InvalidAmount();

        bytes memory payload = MessageCodec.encodeMintShares(receiver, shares);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);

        MessagingFee memory fee = _quote(dstEid, payload, options, false);
        if (address(this).balance >= fee.nativeFee) {
            _lzSend(dstEid, payload, options, MessagingFee(fee.nativeFee, 0), payable(address(this)));
        } else {
            uint256 mintId = pendingMintCount++;
            pendingMints[mintId] = PendingMint(dstEid, receiver, shares);
            emit PendingMintStored(mintId, dstEid, receiver, shares);
        }
    }

    function setHubStargateComposer(address _composer) external onlyOwner {
        hubStargateComposer = _composer;
    }

    // ========== Configuration ==========

    function setCreditManager(address _creditManager) external onlyOwner {
        if (_creditManager == address(0)) revert ZeroAddress();
        creditManager = ICreditManager(_creditManager);
    }

    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert ZeroAddress();
        vault = _vault;
    }

    function setRedemptionManager(address _redemptionManager) external onlyOwner {
        if (_redemptionManager == address(0)) revert ZeroAddress();
        redemptionManager = _redemptionManager;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address _token, address _to, uint256 _amount) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        IERC20(_token).safeTransfer(_to, _amount);
        emit EmergencyWithdraw(_token, _to, _amount);
    }

    /// @notice Override _payNative to use contract balance instead of msg.value
    /// @dev Required for _lzSend calls inside _lzReceive (where msg.value=0)
    function _payNative(uint256 _nativeFee) internal virtual override returns (uint256 nativeFee) {
        if (address(this).balance < _nativeFee) revert NotEnoughNative(_nativeFee);
        return _nativeFee;
    }

    /// @notice Receive native token for cross-chain message fees
    receive() external payable {}
}

interface IHubStargateSettlementRegistrar {
    function registerSatelliteRedemption(uint256 requestId, uint32 dstEid, address receiver) external;
}
