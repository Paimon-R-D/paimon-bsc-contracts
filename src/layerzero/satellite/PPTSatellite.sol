// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PPTOFT} from "./PPTOFT.sol";
import {LiquidityPool} from "./LiquidityPool.sol";
import {IPPTSatellite} from "../interfaces/IPPTSatellite.sol";
import {MessageCodec} from "../libraries/MessageCodec.sol";
import {LzOptionsLib} from "../libraries/LzOptionsLib.sol";

/// @title PPTSatellite
/// @notice Entry point for PPT operations on remote chains
/// @dev Integrates PPTOFT and LiquidityPool for unified user experience
contract PPTSatellite is OApp, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========== Constants ==========

    uint256 public constant MAX_INSTANT_WITHDRAW_FEE = 1000;
    uint128 public constant DEFAULT_GAS_LIMIT = 300000;

    // ========== State Variables ==========

    PPTOFT public immutable pptOft;
    LiquidityPool public immutable liquidityPool;
    IERC20 public immutable asset;
    uint32 public immutable hubEid;

    address public hubAdapter;
    uint256 public instantWithdrawFeeBps;

    /// @notice Current share price (from Hub, updated via cross-chain)
    /// @dev Price per share in asset terms, scaled by 1e18
    uint256 public sharePrice = 1e18;

    // ========== Events ==========

    event CrossChainDeposit(address indexed user, uint256 assets, uint256 shares, uint64 nonce);
    event CrossChainWithdraw(address indexed user, uint256 shares, uint256 assets, uint64 nonce);
    event InstantWithdraw(address indexed user, uint256 shares, uint256 assets, uint256 fee);
    event HubAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event InstantWithdrawFeeUpdated(uint256 oldFee, uint256 newFee);
    event SharePriceUpdated(uint256 oldPrice, uint256 newPrice);

    // ========== Errors ==========

    error InvalidAmount();
    error InsufficientFee();
    error InsufficientLiquidity();
    error FeeTooHigh();
    error OnlyHub();
    error ZeroAddress();
    error HubEidImmutable();
    error UnknownMessageType(bytes1 msgType);
    error InvalidSharePrice();

    // ========== Constructor ==========

    constructor(
        address _endpoint,
        address _delegate,
        address _pptOft,
        address _liquidityPool,
        address _asset,
        uint32 _hubEid
    ) OApp(_endpoint, _delegate) Ownable(_delegate) {
        pptOft = PPTOFT(_pptOft);
        liquidityPool = LiquidityPool(_liquidityPool);
        asset = IERC20(_asset);
        hubEid = _hubEid;
    }

    // ========== View Functions ==========

    function previewDeposit(uint256 assets) public view returns (uint256 shares) {
        return (assets * 1e18) / sharePrice;
    }

    function previewWithdraw(uint256 shares) public view returns (uint256 assets) {
        return (shares * sharePrice) / 1e18;
    }

    function previewInstantWithdraw(uint256 shares) public view returns (
        bool available,
        uint256 assets,
        uint256 fee
    ) {
        uint256 grossAssets = previewWithdraw(shares);
        fee = (grossAssets * instantWithdrawFeeBps) / 10000;
        assets = grossAssets - fee;

        available = assets <= liquidityPool.availableLiquidity();
    }

    // ========== Quote Functions ==========

    function quoteDeposit(uint256 assets, address receiver) external view returns (uint256 nativeFee, uint256 lzTokenFee) {
        bytes memory payload = MessageCodec.encodeDeposit(receiver, assets);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);
        MessagingFee memory fee = _quote(hubEid, payload, options, false);
        return (fee.nativeFee, fee.lzTokenFee);
    }

    function quoteWithdraw(uint256 shares, address receiver) external view returns (uint256 nativeFee, uint256 lzTokenFee) {
        bytes memory payload = MessageCodec.encodeWithdraw(receiver, shares);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);
        MessagingFee memory fee = _quote(hubEid, payload, options, false);
        return (fee.nativeFee, fee.lzTokenFee);
    }

    // ========== User Actions ==========

    function deposit(
        uint256 assets,
        address receiver
    ) external payable nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) revert InvalidAmount();

        asset.safeTransferFrom(msg.sender, address(this), assets);

        asset.approve(address(liquidityPool), assets);
        liquidityPool.addLiquidity(assets);

        // Send cross-chain message to Hub using MessageCodec (MSG_DEPOSIT = 0x30)
        bytes memory payload = MessageCodec.encodeDeposit(receiver, assets);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);

        MessagingFee memory fee = _quote(hubEid, payload, options, false);
        if (msg.value < fee.nativeFee) revert InsufficientFee();

        MessagingReceipt memory receipt = _lzSend(
            hubEid,
            payload,
            options,
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );

        emit CrossChainDeposit(receiver, assets, 0, receipt.nonce);

        return 0; // Shares minted async on Hub
    }

    function instantWithdraw(
        uint256 shares,
        address receiver
    ) external nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert InvalidAmount();

        uint256 grossAssets = previewWithdraw(shares);
        uint256 fee = (grossAssets * instantWithdrawFeeBps) / 10000;
        assets = grossAssets - fee;

        if (assets > liquidityPool.availableLiquidity()) revert InsufficientLiquidity();

        pptOft.transferFrom(msg.sender, address(this), shares);
        pptOft.burn(shares);

        liquidityPool.withdrawForUser(receiver, assets);

        emit InstantWithdraw(receiver, shares, assets, fee);

        return assets;
    }

    function withdraw(
        uint256 shares,
        address receiver
    ) external payable nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert InvalidAmount();

        pptOft.transferFrom(msg.sender, address(this), shares);
        pptOft.burn(shares);

        // Send cross-chain message to Hub using MessageCodec (MSG_WITHDRAW = 0x31)
        bytes memory payload = MessageCodec.encodeWithdraw(receiver, shares);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);

        MessagingFee memory fee = _quote(hubEid, payload, options, false);
        if (msg.value < fee.nativeFee) revert InsufficientFee();

        MessagingReceipt memory receipt = _lzSend(
            hubEid,
            payload,
            options,
            MessagingFee(msg.value, 0),
            payable(msg.sender)
        );

        emit CrossChainWithdraw(receiver, shares, 0, receipt.nonce);

        return 0; // Assets received async on Hub
    }

    // ========== LayerZero Receive ==========

    /// @notice Handle messages from Hub
    /// @dev P0-6 FIX: MSG_MINT_SHARES reverts on invalid data instead of silently skipping
    function _lzReceive(
        Origin calldata _origin,
        bytes32 /*_guid*/,
        bytes calldata _payload,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override whenNotPaused {
        if (_origin.srcEid != hubEid) revert OnlyHub();

        bytes1 msgType = MessageCodec.decodeMsgType(_payload);

        if (msgType == MessageCodec.MSG_SHARE_PRICE_UPDATE) {
            uint256 newPrice = MessageCodec.decodeAmount(_payload);
            _updateSharePrice(newPrice);
        } else if (msgType == MessageCodec.MSG_CREDIT_UPDATE) {
            // Hub sends delta (increment), not absolute value
            uint256 creditDelta = MessageCodec.decodeAmount(_payload);
            liquidityPool.increaseCredit(creditDelta);
        } else if (msgType == MessageCodec.MSG_MINT_SHARES) {
            (address receiver, uint256 shares) = MessageCodec.decodeAddressAndAmount(_payload);
            // P0-6 FIX: Revert on invalid data instead of silently skipping
            if (receiver == address(0)) revert ZeroAddress();
            if (shares == 0) revert InvalidAmount();
            pptOft.mint(receiver, shares);
        } else {
            revert UnknownMessageType(msgType);
        }
    }

    function _updateSharePrice(uint256 newPrice) internal {
        if (newPrice == 0) revert InvalidSharePrice();
        emit SharePriceUpdated(sharePrice, newPrice);
        sharePrice = newPrice;
    }

    // ========== Configuration ==========

    function setHubEid(uint32 /*_hubEid*/) external pure {
        revert HubEidImmutable();
    }

    function setHubAdapter(address _hubAdapter) external onlyOwner {
        if (_hubAdapter == address(0)) revert ZeroAddress();
        emit HubAdapterUpdated(hubAdapter, _hubAdapter);
        hubAdapter = _hubAdapter;
    }

    function setInstantWithdrawFee(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_INSTANT_WITHDRAW_FEE) revert FeeTooHigh();
        emit InstantWithdrawFeeUpdated(instantWithdrawFeeBps, _feeBps);
        instantWithdrawFeeBps = _feeBps;
    }

    function setSharePrice(uint256 _sharePrice) external onlyOwner {
        if (_sharePrice == 0) revert InvalidSharePrice();
        emit SharePriceUpdated(sharePrice, _sharePrice);
        sharePrice = _sharePrice;
    }

    function setPaused(bool _paused) external onlyOwner {
        if (_paused) {
            _pause();
        } else {
            _unpause();
        }
    }

    receive() external payable {}
}
