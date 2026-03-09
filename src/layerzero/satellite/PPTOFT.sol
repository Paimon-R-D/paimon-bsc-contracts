// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PPTOFT
/// @notice LayerZero OFT for PPT on non-hub (remote) chains
/// @dev Uses mint/burn mechanism for cross-chain transfers
contract PPTOFT is OApp, ERC20, Pausable {

    // ========== Constants ==========

    /// @notice Message type for standard OFT send
    uint16 public constant MSG_TYPE_SEND = 1;

    /// @notice Message type for send with compose (lzCompose)
    uint16 public constant MSG_TYPE_SEND_AND_CALL = 2;

    /// @notice Compose message type: Redemption request
    bytes1 public constant COMPOSE_MSG_REDEEM = 0x01;

    /// @notice Shared decimals for cross-chain compatibility (LayerZero standard)
    uint8 public constant SHARED_DECIMALS = 6;

    /// @notice Default gas limit for cross-chain messages
    uint128 public constant DEFAULT_GAS_LIMIT = 200000;

    // ========== State Variables ==========

    /// @notice BSC Hub Chain endpoint ID
    uint32 public immutable hubEid;

    /// @notice Local token decimals (18 for PPT)
    uint8 public immutable localDecimals;

    /// @notice Decimal conversion rate (10^(localDecimals - sharedDecimals))
    uint256 public immutable decimalConversionRate;

    /// @notice Authorized minter (PPTSatellite)
    address public minter;

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

    /// @notice Emitted when cross-chain redemption is requested
    event CrossChainRedemptionRequested(
        address indexed owner,
        uint256 shares,
        bytes32 guid
    );

    /// @notice Emitted when minter is updated
    event MinterUpdated(address indexed oldMinter, address indexed newMinter);

    // ========== Errors ==========

    error InvalidAmount();
    error SlippageExceeded(uint256 amountLD, uint256 minAmountLD);
    error InsufficientBalance();
    error InvalidRecipient();
    error OnlyMinter();

    // ========== Constructor ==========

    /// @notice Initialize the PPTOFT
    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param _endpoint LayerZero endpoint address
    /// @param _delegate Owner/delegate address
    /// @param _hubEid BSC Hub chain endpoint ID
    constructor(
        string memory _name,
        string memory _symbol,
        address _endpoint,
        address _delegate,
        uint32 _hubEid
    ) OApp(_endpoint, _delegate) ERC20(_name, _symbol) Ownable(_delegate) {
        hubEid = _hubEid;
        localDecimals = 18;
        decimalConversionRate = 10 ** (localDecimals - SHARED_DECIMALS);
    }

    // ========== View Functions ==========

    /// @notice Get the token address (this contract)
    function token() external view returns (address) {
        return address(this);
    }

    /// @notice Get shared decimals for cross-chain
    function sharedDecimals() external pure returns (uint8) {
        return SHARED_DECIMALS;
    }

    /// @notice Whether approval is required to send (no for native OFT)
    function approvalRequired() external pure returns (bool) {
        return false;
    }

    // ========== Mint/Burn Functions ==========

    /// @notice Mint tokens (only minter or owner can call)
    /// @param _to Recipient address
    /// @param _amount Amount to mint
    function mint(address _to, uint256 _amount) external {
        if (msg.sender != minter && msg.sender != owner()) revert OnlyMinter();
        if (_to == address(0)) revert InvalidRecipient();
        if (_amount == 0) revert InvalidAmount();
        _mint(_to, _amount);
    }

    /// @notice Burn tokens from sender
    /// @param _amount Amount to burn
    function burn(uint256 _amount) external {
        if (_amount == 0) revert InvalidAmount();
        _burn(msg.sender, _amount);
    }

    /// @notice Set authorized minter address
    /// @param _minter New minter address (typically PPTSatellite)
    function setMinter(address _minter) external onlyOwner {
        emit MinterUpdated(minter, _minter);
        minter = _minter;
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

    /// @notice Quote the messaging fee for cross-chain redemption
    /// @param _shares Amount of shares to redeem
    /// @param _options Extra options for the message
    /// @return fee The messaging fee
    function quoteRedemptionFee(
        uint256 _shares,
        bytes calldata _options
    ) external view returns (MessagingFee memory fee) {
        bytes memory message = _buildRedemptionMessage(_shares, msg.sender);
        bytes memory options = _options.length > 0 ? _options : _buildDefaultOptions();
        return _quote(hubEid, message, options, false);
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

        // Burn tokens from sender
        _burn(msg.sender, amountSentLD);

        // Build and send message
        bytes memory message = _buildSendMessage(amountReceivedLD, _bytes32ToAddress(_to));
        bytes memory options = _options.length > 0 ? _options : _buildDefaultOptions();

        receipt = _lzSend(_dstEid, message, options, MessagingFee(msg.value, 0), payable(_refundAddress));

        emit OFTSent(receipt.guid, _dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }

    /// @notice Request redemption on BSC Hub via cross-chain message
    /// @param _shares Amount of PPT shares to redeem
    /// @param _options LayerZero execution options
    /// @return receipt Messaging receipt with GUID
    function requestCrossChainRedemption(
        uint256 _shares,
        bytes calldata _options
    ) external payable whenNotPaused returns (MessagingReceipt memory receipt) {
        if (_shares == 0) revert InvalidAmount();
        if (balanceOf(msg.sender) < _shares) revert InsufficientBalance();

        // Burn shares on this chain
        _burn(msg.sender, _shares);

        // Build redemption message
        bytes memory message = _buildRedemptionMessage(_shares, msg.sender);
        bytes memory options = _options.length > 0 ? _options : _buildDefaultOptions();

        // Send to Hub chain
        receipt = _lzSend(hubEid, message, options, MessagingFee(msg.value, 0), payable(msg.sender));

        emit CrossChainRedemptionRequested(msg.sender, _shares, receipt.guid);
    }

    // ========== LayerZero Receive ==========

    /// @notice Handle incoming LayerZero messages
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _payload,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override whenNotPaused {
        // Decode message: [to (address)][amountLD (uint256)]
        (address to, uint256 amountLD) = abi.decode(_payload, (address, uint256));

        // Mint tokens to recipient
        _credit(to, amountLD, _origin.srcEid);

        emit OFTReceived(_guid, _origin.srcEid, to, amountLD);
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

    /// @notice Credit tokens to recipient (mint)
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 /*_srcEid*/
    ) internal returns (uint256 amountReceivedLD) {
        if (_to == address(0)) revert InvalidRecipient();
        _mint(_to, _amountLD);
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

    /// @notice Build redemption message payload
    function _buildRedemptionMessage(uint256 _shares, address _owner) internal pure returns (bytes memory) {
        // Message format: [type (1 byte)][owner (address)][shares (uint256)]
        return abi.encodePacked(COMPOSE_MSG_REDEEM, abi.encode(_owner, _shares));
    }

    /// @notice Build default options for messages
    function _buildDefaultOptions() internal pure returns (bytes memory) {
        // Type 3 options with executor lzReceive option
        return abi.encodePacked(uint16(3), DEFAULT_GAS_LIMIT, uint128(0));
    }

    /// @notice Convert bytes32 to address
    function _bytes32ToAddress(bytes32 _b) internal pure returns (address) {
        return address(uint160(uint256(_b)));
    }

    // ========== Pausable Overrides ==========

    /// @notice Override _update to check pause state
    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override whenNotPaused {
        super._update(from, to, value);
    }

    // ========== Admin Functions ==========

    /// @notice Pause the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }
}
