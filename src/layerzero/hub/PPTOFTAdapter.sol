// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ICreditManager} from "../interfaces/ICreditManager.sol";
import {IPPTOFTAdapter} from "../interfaces/IPPTOFTAdapter.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PPTOFTAdapter
/// @notice OFT Adapter for PPT token on BSC Hub chain
/// @dev Wraps existing PPT ERC20 into LayerZero OFT using lock/unlock mechanism
contract PPTOFTAdapter is OApp, Pausable, ReentrancyGuard, ILayerZeroComposer {
    using SafeERC20 for IERC20;

    // ========== Constants ==========

    /// @notice Message type for standard OFT send
    uint16 public constant MSG_TYPE_SEND = 1;

    /// @notice Message type for send with compose (lzCompose)
    uint16 public constant MSG_TYPE_SEND_AND_CALL = 2;

    /// @notice Compose message type: Redemption request
    bytes1 public constant COMPOSE_MSG_REDEEM = 0x01;

    /// @notice Compose message type: Deposit
    bytes1 public constant COMPOSE_MSG_DEPOSIT = 0x02;

    /// @notice Shared decimals for cross-chain compatibility (LayerZero standard)
    uint8 public constant SHARED_DECIMALS = 6;

    /// @notice Default gas limit for cross-chain messages
    uint128 public constant DEFAULT_GAS_LIMIT = 200000;

    // ========== State Variables ==========

    /// @notice The underlying PPT token
    IERC20 public immutable innerToken;

    /// @notice Local token decimals
    uint8 public immutable localDecimals;

    /// @notice Decimal conversion rate (10^(localDecimals - sharedDecimals))
    uint256 public immutable decimalConversionRate;

    /// @notice Credit manager for tracking cross-chain credit
    ICreditManager public creditManager;

    /// @notice PPT Vault address for deposits
    address public vault;

    /// @notice Redemption manager address
    address public redemptionManager;

    // ========== Events ==========

    /// @notice Emitted when tokens are sent cross-chain
    event OFTSent(
        bytes32 indexed guid,
        uint32 dstEid,
        address indexed from,
        uint256 amountSentLD,
        uint256 amountReceivedLD
    );

    /// @notice Emitted when tokens are received from cross-chain
    event OFTReceived(
        bytes32 indexed guid,
        uint32 srcEid,
        address indexed to,
        uint256 amountReceivedLD
    );

    /// @notice Emitted when cross-chain redemption is processed
    event CrossChainRedemptionProcessed(
        bytes32 indexed guid,
        address indexed owner,
        uint256 shares,
        uint256 requestId
    );

    /// @notice Emitted when cross-chain deposit is processed
    event CrossChainDepositProcessed(
        bytes32 indexed guid,
        address indexed receiver,
        uint256 assets,
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

    /// @notice Emitted when emergency withdrawal is executed
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    // ========== Constructor ==========

    /// @notice Initialize the PPTOFTAdapter
    /// @param _token PPT token address
    /// @param _endpoint LayerZero endpoint address
    /// @param _delegate Owner/delegate address
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

    /// @notice Get the underlying token address
    function token() external view returns (address) {
        return address(innerToken);
    }

    /// @notice Get token decimals
    function decimals() external view returns (uint8) {
        return localDecimals;
    }

    /// @notice Get shared decimals for cross-chain
    function sharedDecimals() external pure returns (uint8) {
        return SHARED_DECIMALS;
    }

    /// @notice Whether approval is required to send
    function approvalRequired() external pure returns (bool) {
        return true;
    }

    // ========== OFT Send Functions ==========

    /// @notice Quote the messaging fee for a send operation
    /// @param _dstEid Destination chain endpoint ID
    /// @param _amountLD Amount in local decimals
    /// @param _options Extra options for the message
    /// @param _payInLzToken Whether to pay in LZ token
    /// @return fee The messaging fee
    function quoteSend(
        uint32 _dstEid,
        uint256 _amountLD,
        bytes calldata _options,
        bool _payInLzToken
    ) external view returns (MessagingFee memory fee) {
        bytes memory message = _buildSendMessage(_amountLD, msg.sender);
        bytes memory options = _options.length > 0 ? _options : _buildDefaultOptions();
        return _quote(_dstEid, message, options, _payInLzToken);
    }

    /// @notice Send tokens to a destination chain
    /// @param _dstEid Destination chain endpoint ID
    /// @param _to Recipient address on destination chain
    /// @param _amountLD Amount in local decimals
    /// @param _minAmountLD Minimum amount to receive (slippage protection)
    /// @param _options Extra options for the message
    /// @param _refundAddress Address to refund excess fee
    /// @return receipt Messaging receipt
    function send(
        uint32 _dstEid,
        bytes32 _to,
        uint256 _amountLD,
        uint256 _minAmountLD,
        bytes calldata _options,
        address _refundAddress
    ) external payable whenNotPaused returns (MessagingReceipt memory receipt) {
        if (_amountLD == 0) revert InvalidAmount();

        // Calculate amounts with decimal conversion
        (uint256 amountSentLD, uint256 amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);

        // Lock tokens from sender
        innerToken.safeTransferFrom(msg.sender, address(this), amountSentLD);

        // Build and send message
        bytes memory message = _buildSendMessage(amountReceivedLD, _bytes32ToAddress(_to));
        bytes memory options = _options.length > 0 ? _options : _buildDefaultOptions();

        receipt = _lzSend(_dstEid, message, options, MessagingFee(msg.value, 0), payable(_refundAddress));

        emit OFTSent(receipt.guid, _dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }

    // ========== LayerZero Receive ==========

    /// @notice Handle incoming LayerZero messages
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _payload,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override whenNotPaused nonReentrant {
        // Verify message is from trusted peer
        bytes32 expectedPeer = peers[_origin.srcEid];
        if (expectedPeer == bytes32(0) || _origin.sender != expectedPeer) {
            revert InvalidPeer(_origin.srcEid, _origin.sender);
        }

        // Decode message: [to (address)][amountLD (uint256)]
        (address to, uint256 amountLD) = abi.decode(_payload, (address, uint256));

        // Validate recipient
        if (to == address(0)) revert ZeroAddress();

        // Unlock tokens to recipient
        _credit(to, amountLD, _origin.srcEid);

        emit OFTReceived(_guid, _origin.srcEid, to, amountLD);
    }

    // ========== Compose Functions ==========

    /// @notice Handle composed messages (cross-chain redemption/deposit)
    /// @dev Called by LayerZero endpoint after lzReceive
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) external payable override {
        // Only endpoint can call this
        if (msg.sender != address(endpoint)) revert InvalidComposer();
        // Only accept compose from self (after lzReceive)
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

    /// @notice Calculate debit amounts with slippage check
    function _debitView(
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 /*_dstEid*/
    ) internal view returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        // Remove dust for cross-chain compatibility
        amountSentLD = _removeDust(_amountLD);
        amountReceivedLD = amountSentLD;

        if (amountReceivedLD < _minAmountLD) {
            revert SlippageExceeded(amountReceivedLD, _minAmountLD);
        }
    }

    /// @notice Credit tokens to recipient (unlock)
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 /*_srcEid*/
    ) internal returns (uint256 amountReceivedLD) {
        innerToken.safeTransfer(_to, _amountLD);
        return _amountLD;
    }

    /// @notice Remove dust for cross-chain decimal compatibility
    function _removeDust(uint256 _amountLD) internal view returns (uint256 amountLD) {
        return (_amountLD / decimalConversionRate) * decimalConversionRate;
    }

    /// @notice Build send message payload
    function _buildSendMessage(uint256 _amountLD, address _to) internal pure returns (bytes memory) {
        return abi.encode(_to, _amountLD);
    }

    /// @notice Build default options for messages
    function _buildDefaultOptions() internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(3), DEFAULT_GAS_LIMIT, uint128(0));
    }

    /// @notice Convert bytes32 to address
    function _bytes32ToAddress(bytes32 _b) internal pure returns (address) {
        return address(uint160(uint256(_b)));
    }

    /// @notice Handle cross-chain redemption request
    function _handleRedemption(bytes32 _guid, bytes calldata _data) internal {
        (address owner, uint256 shares) = abi.decode(_data, (address, uint256));

        if (redemptionManager == address(0)) revert InvalidComposeMessage();
        if (owner == address(0)) revert ZeroAddress();
        if (shares == 0) revert InvalidAmount();

        // Tokens are already unlocked via lzReceive, approve redemption manager
        innerToken.approve(redemptionManager, shares);

        // Call redemption manager to create redemption request
        // Note: The redemption manager interface may vary - this is a common pattern
        // The actual requestId would be returned by the redemption manager
        uint256 requestId = _requestRedemption(shares, owner);

        emit CrossChainRedemptionProcessed(_guid, owner, shares, requestId);
    }

    /// @notice Internal function to request redemption
    /// @dev Override this in production to call actual RedemptionManager
    function _requestRedemption(uint256 shares, address owner) internal virtual returns (uint256 requestId) {
        // In production deployment, this would call:
        // return IRedemptionManager(redemptionManager).requestRedemption(shares, owner);
        // For now, we transfer tokens to redemption manager and emit event
        innerToken.safeTransfer(redemptionManager, shares);
        return uint256(keccak256(abi.encodePacked(block.timestamp, owner, shares)));
    }

    /// @notice Handle cross-chain deposit
    function _handleDeposit(bytes32 _guid, bytes calldata _data) internal {
        (address receiver, uint256 assets) = abi.decode(_data, (address, uint256));

        if (vault == address(0)) revert InvalidComposeMessage();
        if (receiver == address(0)) revert ZeroAddress();
        if (assets == 0) revert InvalidAmount();

        // Approve vault and deposit
        innerToken.approve(vault, assets);

        // Call vault deposit
        uint256 shares = IERC4626(vault).deposit(assets, receiver);

        emit CrossChainDepositProcessed(_guid, receiver, assets, shares);
    }

    // ========== Configuration ==========

    /// @notice Set credit manager address
    /// @param _creditManager New credit manager address
    function setCreditManager(address _creditManager) external onlyOwner {
        if (_creditManager == address(0)) revert ZeroAddress();
        creditManager = ICreditManager(_creditManager);
    }

    /// @notice Set vault address
    /// @param _vault New vault address
    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert ZeroAddress();
        vault = _vault;
    }

    /// @notice Set redemption manager address
    /// @param _redemptionManager New redemption manager address
    function setRedemptionManager(address _redemptionManager) external onlyOwner {
        if (_redemptionManager == address(0)) revert ZeroAddress();
        redemptionManager = _redemptionManager;
    }

    /// @notice Pause the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Emergency withdraw locked tokens (admin only)
    /// @param _token Token address to withdraw
    /// @param _to Recipient address
    /// @param _amount Amount to withdraw
    function emergencyWithdraw(address _token, address _to, uint256 _amount) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        IERC20(_token).safeTransfer(_to, _amount);
        emit EmergencyWithdraw(_token, _to, _amount);
    }
}
