// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MessagingFee} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {OFTComposeMsgCodec} from "@layerzero-v2/oapp/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {IStargate} from "../interfaces/IStargateIntegration.sol";
import {StargateComposeCodec} from "../libraries/StargateComposeCodec.sol";
import {LzOptionsLib} from "../libraries/LzOptionsLib.sol";
import {ILiquidityPool} from "../interfaces/ILiquidityPool.sol";

/// @title SatelliteGateway
/// @notice Entry point for cross-chain deposits and settlement receiver on satellite chains
/// @dev Bridges USDT to Hub via Stargate compose for deposits.
///      Receives Stargate compose from Hub for settlements and liquidity replenishment.
contract SatelliteGateway is ILayerZeroComposer, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========== Constants ==========

    uint128 public constant STARGATE_RECEIVE_GAS = 65_000;
    uint128 public constant COMPOSE_GAS_DEPOSIT = 300_000;
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 50; // 0.5%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ========== State Variables ==========

    /// @notice LayerZero endpoint address
    address public immutable endpoint;

    /// @notice Stargate USDT pool on this chain
    address public immutable stargatePool;

    /// @notice The underlying asset (USDT)
    IERC20 public immutable asset;

    /// @notice Hub chain endpoint ID
    uint32 public immutable hubEid;

    /// @notice Hub composer address (target for Stargate sends)
    address public hubComposer;

    /// @notice Local LiquidityPool for replenishment
    ILiquidityPool public liquidityPool;

    /// @notice Trusted forwarding contract allowed to call depositFor on behalf of a payer
    address public depositForwarder;

    /// @notice Slippage tolerance in basis points
    uint256 public slippageBps;

    // ========== Events ==========

    event DepositBridged(address indexed user, address indexed receiver, uint256 assets, uint256 minShares);
    event SettlementReceived(address indexed receiver, uint256 amount, uint256 requestId);
    event ReplenishReceived(uint256 amount);
    event CreditRestoreNotified(address indexed satellite, uint256 amount);
    event CreditRestoreNotificationFailed(address indexed satellite, uint256 amount);
    event HubComposerUpdated(address oldComposer, address newComposer);
    event LiquidityPoolUpdated(address pool);
    event DepositForwarderUpdated(address oldForwarder, address newForwarder);

    // ========== Errors ==========

    error OnlyEndpoint();
    error OnlyStargate();
    error UntrustedSource(address composeFrom);
    error UnknownAction(uint8 action);
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientFee(uint256 provided, uint256 required);
    error UnauthorizedForwarder(address caller);

    // ========== Constructor ==========

    constructor(
        address _endpoint,
        address _stargatePool,
        address _asset,
        uint32 _hubEid,
        address _owner
    ) Ownable(_owner) {
        if (_endpoint == address(0)) revert ZeroAddress();
        if (_stargatePool == address(0)) revert ZeroAddress();
        if (_asset == address(0)) revert ZeroAddress();
        if (_hubEid == 0) revert ZeroAmount();
        if (_owner == address(0)) revert ZeroAddress();

        endpoint = _endpoint;
        stargatePool = _stargatePool;
        asset = IERC20(_asset);
        hubEid = _hubEid;
        slippageBps = DEFAULT_SLIPPAGE_BPS;
    }

    // ========== User Functions ==========

    /// @notice Bridge USDT to Hub for vault deposit
    /// @param assets Amount of USDT to deposit
    /// @param receiver Address to receive PPT shares (on this chain as PPTOFT)
    /// @param minShares Minimum shares expected (0 = no slippage check)
    function deposit(
        uint256 assets,
        address receiver,
        uint256 minShares
    ) external payable nonReentrant whenNotPaused {
        _depositFor(msg.sender, assets, receiver, minShares, msg.sender);
    }

    /// @notice Bridge USDT that has already been approved by `payer`
    /// @dev Allows a forwarding contract to custody funds first and still keep Stargate refunds routed to the end user.
    function depositFor(
        address payer,
        uint256 assets,
        address receiver,
        uint256 minShares,
        address refundAddress
    ) external payable nonReentrant whenNotPaused {
        if (msg.sender != payer && msg.sender != depositForwarder) revert UnauthorizedForwarder(msg.sender);
        _depositFor(payer, assets, receiver, minShares, refundAddress);
    }

    // ========== Stargate Compose Callback ==========

    /// @notice Handle Stargate compose from Hub (settlement/replenish)
    function lzCompose(
        address _from,
        bytes32 /*_guid*/,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) external payable override nonReentrant whenNotPaused {
        if (msg.sender != endpoint) revert OnlyEndpoint();
        if (_from != stargatePool) revert OnlyStargate();

        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
        bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);

        // Verify compose sender is Hub composer
        bytes32 composeFromBytes = OFTComposeMsgCodec.composeFrom(_message);
        address composeFrom = _bytes32ToAddress(composeFromBytes);
        if (composeFrom != hubComposer) revert UntrustedSource(composeFrom);

        uint8 action = StargateComposeCodec.decodeAction(composeMsg);

        if (action == StargateComposeCodec.ACTION_SETTLEMENT) {
            _handleSettlement(amountLD, composeMsg);
        } else if (action == StargateComposeCodec.ACTION_REPLENISH) {
            _handleReplenish(amountLD);
        } else {
            revert UnknownAction(action);
        }
    }

    // ========== Internal Handlers ==========

    /// @notice Handle settlement: USDT arrived from Hub → send to receiver
    function _handleSettlement(uint256 amount, bytes memory composeMsg) internal {
        (address receiver, uint256 requestId) = StargateComposeCodec.decodeSettlement(composeMsg);
        if (receiver == address(0)) revert ZeroAddress();

        asset.safeTransfer(receiver, amount);

        emit SettlementReceived(receiver, amount, requestId);
    }

    /// @notice Handle replenishment: USDT arrived from Hub → add to LiquidityPool
    function _handleReplenish(uint256 amount) internal {
        asset.forceApprove(address(liquidityPool), amount);
        liquidityPool.replenish(amount);
        asset.forceApprove(address(liquidityPool), 0);

        address satellite = liquidityPool.satellite();
        if (satellite != address(0)) {
            try IPPTSatelliteCreditNotifier(satellite).notifyCreditRestored(amount) {
                emit CreditRestoreNotified(satellite, amount);
            } catch {
                emit CreditRestoreNotificationFailed(satellite, amount);
            }
        }

        emit ReplenishReceived(amount);
    }

    // ========== Quote Functions ==========

    /// @notice Quote the native fee for a deposit bridge
    function quoteDeposit(uint256 assets, address receiver) external view returns (uint256 nativeFee, uint256 minReceive) {
        bytes memory composeMsg = StargateComposeCodec.encodeDeposit(receiver, 0);
        bytes memory options = LzOptionsLib.buildComposeOptions(STARGATE_RECEIVE_GAS, COMPOSE_GAS_DEPOSIT);
        minReceive = _calcMinAmount(assets);

        IStargate.SendParam memory params = IStargate.SendParam({
            dstEid: hubEid,
            to: _addressToBytes32(hubComposer),
            amountLD: assets,
            minAmountLD: minReceive,
            extraOptions: options,
            composeMsg: composeMsg,
            oftCmd: ""
        });

        MessagingFee memory fee = IStargate(stargatePool).quoteSend(params, false);
        return (fee.nativeFee, minReceive);
    }

    // ========== Internal ==========

    function _calcMinAmount(uint256 amount) internal view returns (uint256) {
        uint256 slippage = slippageBps == 0 ? DEFAULT_SLIPPAGE_BPS : slippageBps;
        return amount * (BPS_DENOMINATOR - slippage) / BPS_DENOMINATOR;
    }

    function _depositFor(
        address payer,
        uint256 assets,
        address receiver,
        uint256 minShares,
        address refundAddress
    ) internal {
        if (payer == address(0) || receiver == address(0) || refundAddress == address(0)) revert ZeroAddress();
        if (assets == 0) revert ZeroAmount();

        asset.safeTransferFrom(payer, address(this), assets);

        bytes memory composeMsg = StargateComposeCodec.encodeDeposit(receiver, minShares);
        bytes memory options = LzOptionsLib.buildComposeOptions(STARGATE_RECEIVE_GAS, COMPOSE_GAS_DEPOSIT);
        uint256 minAmount = _calcMinAmount(assets);

        asset.forceApprove(stargatePool, assets);

        IStargate.SendParam memory params = IStargate.SendParam({
            dstEid: hubEid,
            to: _addressToBytes32(hubComposer),
            amountLD: assets,
            minAmountLD: minAmount,
            extraOptions: options,
            composeMsg: composeMsg,
            oftCmd: ""
        });

        MessagingFee memory fee = IStargate(stargatePool).quoteSend(params, false);
        if (msg.value < fee.nativeFee) revert InsufficientFee(msg.value, fee.nativeFee);

        IStargate(stargatePool).send{value: msg.value}(
            params,
            MessagingFee(msg.value, 0),
            refundAddress
        );
        asset.forceApprove(stargatePool, 0);

        emit DepositBridged(payer, receiver, assets, minShares);
    }

    function _addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function _bytes32ToAddress(bytes32 b) internal pure returns (address) {
        return address(uint160(uint256(b)));
    }

    // ========== Configuration ==========

    function setHubComposer(address _hubComposer) external onlyOwner {
        if (_hubComposer == address(0)) revert ZeroAddress();
        emit HubComposerUpdated(hubComposer, _hubComposer);
        hubComposer = _hubComposer;
    }

    function setLiquidityPool(address _pool) external onlyOwner {
        if (_pool == address(0)) revert ZeroAddress();
        liquidityPool = ILiquidityPool(_pool);
        emit LiquidityPoolUpdated(_pool);
    }

    function setDepositForwarder(address _forwarder) external onlyOwner {
        emit DepositForwarderUpdated(depositForwarder, _forwarder);
        depositForwarder = _forwarder;
    }

    function setSlippageBps(uint256 _bps) external onlyOwner {
        slippageBps = _bps;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Receive native token for Stargate refunds
    receive() external payable {}
}

interface IPPTSatelliteCreditNotifier {
    function notifyCreditRestored(uint256 amount) external;
}
