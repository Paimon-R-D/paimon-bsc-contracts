// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {LzOptionsLib} from "../libraries/LzOptionsLib.sol";
import {MessageCodec} from "../libraries/MessageCodec.sol";

/// @title PPTOFT
/// @notice LayerZero OFT for PPT on non-hub (remote) chains
/// @dev Uses mint/burn mechanism for cross-chain transfers
contract PPTOFT is OApp, ERC20, Pausable {

    // ========== Constants ==========

    uint16 public constant MSG_TYPE_SEND = 1;
    uint16 public constant MSG_TYPE_SEND_AND_CALL = 2;

    bytes1 public constant COMPOSE_MSG_REDEEM = 0x01;

    uint8 public constant SHARED_DECIMALS = 6;
    uint128 public constant DEFAULT_GAS_LIMIT = 200000;

    // ========== State Variables ==========

    uint32 public immutable hubEid;
    uint8 public immutable localDecimals;
    uint256 public immutable decimalConversionRate;

    address public minter;

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

    event CrossChainRedemptionRequested(
        address indexed owner,
        uint256 shares,
        bytes32 guid
    );

    event MinterUpdated(address indexed oldMinter, address indexed newMinter);

    // ========== Errors ==========

    error InvalidAmount();
    error SlippageExceeded(uint256 amountLD, uint256 minAmountLD);
    error InsufficientBalance();
    error InvalidRecipient();
    error OnlyMinter();

    // ========== Constructor ==========

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

    function token() external view returns (address) {
        return address(this);
    }

    function sharedDecimals() external pure returns (uint8) {
        return SHARED_DECIMALS;
    }

    function approvalRequired() external pure returns (bool) {
        return false;
    }

    // ========== Mint/Burn Functions ==========

    function mint(address _to, uint256 _amount) external {
        if (msg.sender != minter && msg.sender != owner()) revert OnlyMinter();
        if (_to == address(0)) revert InvalidRecipient();
        if (_amount == 0) revert InvalidAmount();
        _mint(_to, _amount);
    }

    function burn(uint256 _amount) external {
        if (_amount == 0) revert InvalidAmount();
        _burn(msg.sender, _amount);
    }

    function setMinter(address _minter) external onlyOwner {
        emit MinterUpdated(minter, _minter);
        minter = _minter;
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

    function quoteRedemptionFee(
        uint256 _shares,
        bytes calldata _options
    ) external view returns (MessagingFee memory fee) {
        bytes memory message = _buildRedemptionMessage(_shares, msg.sender);
        bytes memory options = _options.length > 0 ? _options : LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);
        return _quote(hubEid, message, options, false);
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

        _burn(msg.sender, amountSentLD);

        bytes memory message = _buildSendMessage(amountReceivedLD, _bytes32ToAddress(_to));
        bytes memory options = _options.length > 0 ? _options : LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);

        receipt = _lzSend(_dstEid, message, options, MessagingFee(msg.value, 0), payable(_refundAddress));

        emit OFTSent(receipt.guid, _dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }

    function requestCrossChainRedemption(
        uint256 _shares,
        bytes calldata _options
    ) external payable whenNotPaused returns (MessagingReceipt memory receipt) {
        if (_shares == 0) revert InvalidAmount();
        if (balanceOf(msg.sender) < _shares) revert InsufficientBalance();

        _burn(msg.sender, _shares);

        bytes memory message = _buildRedemptionMessage(_shares, msg.sender);
        bytes memory options = _options.length > 0 ? _options : LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);

        receipt = _lzSend(hubEid, message, options, MessagingFee(msg.value, 0), payable(msg.sender));

        emit CrossChainRedemptionRequested(msg.sender, _shares, receipt.guid);
    }

    // ========== LayerZero Receive ==========

    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _payload,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override whenNotPaused {
        (address to, uint256 amountLD) = abi.decode(_payload, (address, uint256));
        _credit(to, amountLD, _origin.srcEid);
        emit OFTReceived(_guid, _origin.srcEid, to, amountLD);
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
        if (_to == address(0)) revert InvalidRecipient();
        _mint(_to, _amountLD);
        return _amountLD;
    }

    function _removeDust(uint256 _amountLD) internal view returns (uint256 amountLD) {
        return (_amountLD / decimalConversionRate) * decimalConversionRate;
    }

    function _buildSendMessage(uint256 _amountLD, address _to) internal pure returns (bytes memory) {
        return abi.encode(_to, _amountLD);
    }

    function _buildRedemptionMessage(uint256 _shares, address _owner) internal pure returns (bytes memory) {
        return MessageCodec.encodeRedeem(_owner, _shares);
    }

    function _bytes32ToAddress(bytes32 _b) internal pure returns (address) {
        return address(uint160(uint256(_b)));
    }

    // ========== Pausable Overrides ==========

    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override whenNotPaused {
        super._update(from, to, value);
    }

    // ========== Admin Functions ==========

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
