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

/// @title PPTSatellite
/// @notice Entry point for PPT operations on remote chains
/// @dev Integrates PPTOFT and LiquidityPool for unified user experience
contract PPTSatellite is OApp, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========== Constants ==========

    /// @notice Maximum instant withdrawal fee (10% = 1000 bps)
    uint256 public constant MAX_INSTANT_WITHDRAW_FEE = 1000;

    /// @notice Default gas limit for cross-chain messages
    uint128 public constant DEFAULT_GAS_LIMIT = 300000;

    // Message types (outgoing)
    bytes1 public constant MSG_DEPOSIT = 0x01;
    bytes1 public constant MSG_WITHDRAW = 0x02;
    bytes1 public constant MSG_CREDIT_USED = 0x10;

    // Message types (incoming from Hub)
    bytes1 public constant MSG_SHARE_PRICE_UPDATE = 0x20;
    bytes1 public constant MSG_CREDIT_UPDATE = 0x21;
    bytes1 public constant MSG_MINT_SHARES = 0x22;

    // ========== State Variables ==========

    /// @notice The PPTOFT token on this chain
    PPTOFT public immutable pptOft;

    /// @notice The LiquidityPool for instant withdrawals
    LiquidityPool public immutable liquidityPool;

    /// @notice The underlying asset (e.g., USDT)
    IERC20 public immutable asset;

    /// @notice Hub chain EID (BSC = 102)
    uint32 public immutable hubEid;

    /// @notice Hub PPTOFTAdapter address
    address public hubAdapter;

    /// @notice Instant withdrawal fee in basis points
    uint256 public instantWithdrawFeeBps;

    /// @notice Current share price (from Hub, updated via cross-chain)
    /// @dev Price per share in asset terms, scaled by 1e18
    uint256 public sharePrice = 1e18; // Default 1:1

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

    /// @notice Initialize the PPTSatellite
    /// @param _endpoint LayerZero endpoint address
    /// @param _delegate Owner/delegate address
    /// @param _pptOft PPTOFT token address
    /// @param _liquidityPool LiquidityPool address
    /// @param _asset Underlying asset address
    /// @param _hubEid Hub chain endpoint ID
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

    /// @notice Preview deposit - estimate shares to receive
    /// @param assets Amount of assets to deposit
    /// @return shares Estimated shares to receive
    function previewDeposit(uint256 assets) public view returns (uint256 shares) {
        // shares = assets * 1e18 / sharePrice
        return (assets * 1e18) / sharePrice;
    }

    /// @notice Preview withdrawal - estimate assets to receive
    /// @param shares Amount of shares to withdraw
    /// @return assets Estimated assets to receive
    function previewWithdraw(uint256 shares) public view returns (uint256 assets) {
        // assets = shares * sharePrice / 1e18
        return (shares * sharePrice) / 1e18;
    }

    /// @notice Check if instant withdrawal is available
    /// @param shares Amount of shares to withdraw
    /// @return available True if instant withdrawal is possible
    /// @return assets Estimated assets to receive (after fee)
    /// @return fee Fee for instant withdrawal
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

    /// @notice Quote LayerZero fee for deposit
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive shares
    /// @return nativeFee Native token fee required
    /// @return lzTokenFee LayerZero token fee (if applicable)
    function quoteDeposit(uint256 assets, address receiver) external view returns (uint256 nativeFee, uint256 lzTokenFee) {
        bytes memory payload = _buildDepositPayload(assets, receiver);
        bytes memory options = _buildDefaultOptions();
        MessagingFee memory fee = _quote(hubEid, payload, options, false);
        return (fee.nativeFee, fee.lzTokenFee);
    }

    /// @notice Quote LayerZero fee for cross-chain withdrawal
    /// @param shares Amount of shares to withdraw
    /// @param receiver Address to receive assets
    /// @return nativeFee Native token fee required
    /// @return lzTokenFee LayerZero token fee (if applicable)
    function quoteWithdraw(uint256 shares, address receiver) external view returns (uint256 nativeFee, uint256 lzTokenFee) {
        bytes memory payload = _buildWithdrawPayload(shares, receiver);
        bytes memory options = _buildDefaultOptions();
        MessagingFee memory fee = _quote(hubEid, payload, options, false);
        return (fee.nativeFee, fee.lzTokenFee);
    }

    // ========== User Actions ==========

    /// @notice Deposit assets and receive PPT shares via cross-chain
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive shares
    /// @return shares Amount of shares to be received (0 initially, async)
    function deposit(
        uint256 assets,
        address receiver
    ) external payable nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) revert InvalidAmount();

        // Transfer assets from user
        asset.safeTransferFrom(msg.sender, address(this), assets);

        // Deposit to liquidity pool (increases pool balance)
        asset.approve(address(liquidityPool), assets);
        liquidityPool.addLiquidity(assets);

        // Send cross-chain message to Hub
        bytes memory payload = _buildDepositPayload(assets, receiver);
        bytes memory options = _buildDefaultOptions();

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

    /// @notice Instant withdrawal using local liquidity pool
    /// @param shares Amount of shares to burn
    /// @param receiver Address to receive assets
    /// @return assets Amount of assets received (after fee)
    function instantWithdraw(
        uint256 shares,
        address receiver
    ) external nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert InvalidAmount();

        // Calculate assets and fee
        uint256 grossAssets = previewWithdraw(shares);
        uint256 fee = (grossAssets * instantWithdrawFeeBps) / 10000;
        assets = grossAssets - fee;

        // Check liquidity
        if (assets > liquidityPool.availableLiquidity()) revert InsufficientLiquidity();

        // Burn user's PPT shares
        pptOft.transferFrom(msg.sender, address(this), shares);
        pptOft.burn(shares);

        // Withdraw from liquidity pool to user
        liquidityPool.withdrawForUser(receiver, assets);

        emit InstantWithdraw(receiver, shares, assets, fee);

        return assets;
    }

    /// @notice Standard cross-chain withdraw
    /// @param shares Amount of shares to withdraw
    /// @param receiver Address to receive assets
    /// @return assets Amount of assets to receive (0 initially, async)
    function withdraw(
        uint256 shares,
        address receiver
    ) external payable nonReentrant whenNotPaused returns (uint256 assets) {
        if (shares == 0) revert InvalidAmount();

        // Burn user's PPT shares
        pptOft.transferFrom(msg.sender, address(this), shares);
        pptOft.burn(shares);

        // Send cross-chain message to Hub
        bytes memory payload = _buildWithdrawPayload(shares, receiver);
        bytes memory options = _buildDefaultOptions();

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
    function _lzReceive(
        Origin calldata _origin,
        bytes32 /*_guid*/,
        bytes calldata _payload,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override whenNotPaused {
        if (_origin.srcEid != hubEid) revert OnlyHub();

        bytes1 msgType = bytes1(_payload[0]);

        if (msgType == MSG_SHARE_PRICE_UPDATE) {
            // Update share price from Hub
            uint256 newPrice = abi.decode(_payload[1:], (uint256));
            _updateSharePrice(newPrice);
        } else if (msgType == MSG_CREDIT_UPDATE) {
            // Update credit allocation
            uint256 newCredit = abi.decode(_payload[1:], (uint256));
            liquidityPool.updateCredit(newCredit);
        } else if (msgType == MSG_MINT_SHARES) {
            // Mint shares to user (deposit confirmation)
            (address receiver, uint256 shares) = abi.decode(_payload[1:], (address, uint256));
            if (receiver != address(0) && shares > 0) {
                pptOft.mint(receiver, shares);
            }
        } else {
            revert UnknownMessageType(msgType);
        }
    }

    /// @notice Internal function to update share price
    /// @param newPrice New share price (scaled by 1e18)
    function _updateSharePrice(uint256 newPrice) internal {
        if (newPrice == 0) revert InvalidSharePrice();
        emit SharePriceUpdated(sharePrice, newPrice);
        sharePrice = newPrice;
    }

    // ========== Internal Functions ==========

    /// @notice Build deposit payload
    function _buildDepositPayload(uint256 assets, address receiver) internal pure returns (bytes memory) {
        return abi.encodePacked(MSG_DEPOSIT, abi.encode(receiver, assets));
    }

    /// @notice Build withdraw payload
    function _buildWithdrawPayload(uint256 shares, address receiver) internal pure returns (bytes memory) {
        return abi.encodePacked(MSG_WITHDRAW, abi.encode(receiver, shares));
    }

    /// @notice Build default options for messages
    function _buildDefaultOptions() internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(3), DEFAULT_GAS_LIMIT, uint128(0));
    }

    // ========== Configuration ==========

    /// @notice Set the Hub endpoint ID (not used - immutable)
    function setHubEid(uint32 /*_hubEid*/) external pure {
        // hubEid is immutable, this function exists for interface compatibility
        revert HubEidImmutable();
    }

    /// @notice Set the Hub adapter address
    /// @param _hubAdapter New Hub adapter address
    function setHubAdapter(address _hubAdapter) external onlyOwner {
        if (_hubAdapter == address(0)) revert ZeroAddress();
        emit HubAdapterUpdated(hubAdapter, _hubAdapter);
        hubAdapter = _hubAdapter;
    }

    /// @notice Set instant withdrawal fee
    function setInstantWithdrawFee(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_INSTANT_WITHDRAW_FEE) revert FeeTooHigh();
        emit InstantWithdrawFeeUpdated(instantWithdrawFeeBps, _feeBps);
        instantWithdrawFeeBps = _feeBps;
    }

    /// @notice Set share price (emergency admin function)
    /// @dev In production, sharePrice should only be updated via cross-chain message
    /// @param _sharePrice New share price (scaled by 1e18)
    function setSharePrice(uint256 _sharePrice) external onlyOwner {
        if (_sharePrice == 0) revert InvalidSharePrice();
        emit SharePriceUpdated(sharePrice, _sharePrice);
        sharePrice = _sharePrice;
    }

    /// @notice Pause/unpause the satellite
    function setPaused(bool _paused) external onlyOwner {
        if (_paused) {
            _pause();
        } else {
            _unpause();
        }
    }

    /// @notice Receive native token for gas
    receive() external payable {}
}
