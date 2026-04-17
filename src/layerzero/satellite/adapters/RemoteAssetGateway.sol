// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {OFTComposeMsgCodec} from "@layerzero-v2/oapp/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {IStargate} from "../../interfaces/IStargateIntegration.sol";
import {StargateComposeCodec} from "../../libraries/StargateComposeCodec.sol";
import {LzOptionsLib} from "../../libraries/LzOptionsLib.sol";
import {IRemoteProtocolImplementation} from "../../interfaces/IRemoteProtocolImplementation.sol";
import {MessageCodec} from "../../libraries/MessageCodec.sol";

/// @title RemoteAssetGateway
/// @notice Receives USDT + deploy commands from Hub via Stargate compose,
///         executes DeFi operations, and bridges returns back to Hub
/// @dev Deployed on each remote DeFi chain (ETH, ARB, Base, etc.)
contract RemoteAssetGateway is OApp, ILayerZeroComposer, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========== Constants ==========

    uint128 public constant STARGATE_RECEIVE_GAS = 65_000;
    uint128 public constant COMPOSE_GAS_RETURN = 100_000;
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 50;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ========== State Variables ==========

    /// @notice Stargate USDT pool on this chain
    address public immutable stargatePool;

    /// @notice The underlying asset (USDT)
    IERC20 public immutable asset;

    /// @notice Hub chain endpoint ID
    uint32 public immutable hubEid;

    /// @notice This chain's endpoint ID (for NAV reporting)
    uint32 public immutable thisEid;

    /// @notice Hub composer address (target for Stargate return sends)
    address public hubComposer;

    /// @notice Protocol implementations (protocolName => implementation)
    mapping(string => address) public protocolImplementations;

    /// @notice Assets deployed per protocol address
    mapping(address => uint256) public protocolDeposits;

    /// @notice Total assets deployed across all protocols
    uint256 public totalDeposited;

    /// @notice Slippage tolerance in basis points
    uint256 public slippageBps;

    /// @notice [M02] Default dust tolerance (in asset smallest unit) for
    ///         reported-vs-actual withdrawal/deploy discrepancies.
    /// @dev Index-based protocols (Aave liquidityIndex, Compound exchangeRate, Curve)
    ///      produce 1-2 wei rounding in share-to-asset conversion. Default of 2 wei is
    ///      chosen to tolerate one round trip; per-protocol override available below.
    uint256 public defaultDust = 2;

    /// @notice [M02] Optional per-protocol dust override, keyed by protocol name hash
    mapping(bytes32 => uint256) public dustByProtocol;

    struct PendingReturn {
        uint256 amount;
        bool isYield;
    }

    mapping(uint256 => PendingReturn) public pendingReturns;
    uint256 public pendingReturnCount;

    // ========== Events ==========

    event DeployReceived(address indexed protocol, string protocolName, uint256 amount);
    event WithdrawAndBridged(address indexed protocol, string protocolName, uint256 amount);
    event HarvestAndBridged(address indexed protocol, string protocolName, uint256 yieldAmount);
    event PendingReturnStored(uint256 indexed returnId, uint256 amount, bool isYield);
    event PendingReturnFlushed(uint256 indexed returnId, uint256 amount, bool isYield);
    event HubComposerUpdated(address oldComposer, address newComposer);
    event ProtocolUpdated(string protocolName, address implementation);
    event DefaultDustUpdated(uint256 oldDust, uint256 newDust);
    event ProtocolDustUpdated(string protocolName, uint256 oldDust, uint256 newDust);

    // ========== Errors ==========

    error OnlyStargate();
    error OnlyHub();
    error UnexpectedSourceEid(uint32 srcEid);
    error UntrustedSource(address composeFrom);
    error UnknownAction(uint8 action);
    error UnknownMessageType(bytes1 msgType);
    error ZeroAddress();
    error ZeroAmount();
    error ProtocolNotSupported();
    error InsufficientDeposit();
    error InvalidProtocolAmount(uint256 requested, uint256 actual);
    error ReportedActualMismatch(uint256 reported, uint256 actual, uint256 allowedDust);
    error ShortfallExceedsDust(uint256 requested, uint256 actual, uint256 allowedDust);

    // ========== Constructor ==========

    constructor(
        address _endpoint,
        address _stargatePool,
        address _asset,
        uint32 _hubEid,
        uint32 _thisEid,
        address _owner
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        if (_endpoint == address(0)) revert ZeroAddress();
        if (_stargatePool == address(0)) revert ZeroAddress();
        if (_asset == address(0)) revert ZeroAddress();
        if (_hubEid == 0) revert ZeroAmount();
        if (_thisEid == 0) revert ZeroAmount();
        if (_owner == address(0)) revert ZeroAddress();

        stargatePool = _stargatePool;
        asset = IERC20(_asset);
        hubEid = _hubEid;
        thisEid = _thisEid;
        slippageBps = DEFAULT_SLIPPAGE_BPS;
    }

    // ========== Stargate Compose Callback ==========

    /// @notice Handle Stargate compose from Hub (USDT + deploy command)
    function lzCompose(
        address _from,
        bytes32 /*_guid*/,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) external payable override nonReentrant whenNotPaused {
        if (msg.sender != address(endpoint)) revert OnlyEndpoint(msg.sender);
        if (_from != stargatePool) revert OnlyStargate();

        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
        uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
        bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);

        if (srcEid != hubEid) revert UnexpectedSourceEid(srcEid);

        // Verify compose sender is Hub composer
        bytes32 composeFromBytes = OFTComposeMsgCodec.composeFrom(_message);
        address composeFrom = _bytes32ToAddress(composeFromBytes);
        if (composeFrom != hubComposer) revert UntrustedSource(composeFrom);

        uint8 action = StargateComposeCodec.decodeAction(composeMsg);

        if (action == StargateComposeCodec.ACTION_DEPLOY) {
            _handleDeploy(amountLD, composeMsg);
        } else {
            revert UnknownAction(action);
        }
    }

    // ========== LayerZero Receive ==========

    function _lzReceive(
        Origin calldata _origin,
        bytes32, /*_guid*/
        bytes calldata _payload,
        address, /*_executor*/
        bytes calldata /*_extraData*/
    ) internal override whenNotPaused nonReentrant {
        if (_origin.srcEid != hubEid) revert OnlyHub();

        bytes1 msgType = MessageCodec.decodeMsgType(_payload);

        if (msgType == MessageCodec.MSG_WITHDRAW_ASSET) {
            _handleWithdrawCommand(_payload);
        } else if (msgType == MessageCodec.MSG_HARVEST) {
            _handleHarvestCommand(_payload);
        } else {
            revert UnknownMessageType(msgType);
        }
    }

    // ========== Internal Handlers ==========

    /// @notice Handle deploy: USDT arrived → deploy to DeFi protocol
    /// @dev [M02] Uses balance-delta as source of truth. Reported return value is
    ///      validated against actual balance consumed; divergence > dust reverts.
    function _handleDeploy(uint256 amount, bytes memory composeMsg) internal {
        (address protocol, string memory protocolName) = StargateComposeCodec.decodeDeploy(composeMsg);
        if (amount == 0) revert ZeroAmount();

        address implementation = protocolImplementations[protocolName];
        if (implementation == address(0)) revert ProtocolNotSupported();

        uint256 balanceBefore = asset.balanceOf(address(this));

        // Approve and deploy (forceApprove for USDT compatibility)
        asset.forceApprove(implementation, amount);
        uint256 reported = IRemoteProtocolImplementation(implementation).deploy(
            address(asset), protocol, amount
        );
        asset.forceApprove(implementation, 0);

        // [M02] actualConsumed = assets that left this contract into the protocol
        uint256 balanceAfter = asset.balanceOf(address(this));
        uint256 actualConsumed = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;

        if (actualConsumed > amount) revert InvalidProtocolAmount(amount, actualConsumed);

        uint256 allowedDust = _dustFor(protocolName);
        uint256 diff = reported > actualConsumed ? reported - actualConsumed : actualConsumed - reported;
        if (diff > allowedDust) revert ReportedActualMismatch(reported, actualConsumed, allowedDust);

        protocolDeposits[protocol] += actualConsumed;
        totalDeposited += actualConsumed;

        uint256 undeployedAmount = amount - actualConsumed;
        if (undeployedAmount > 0) {
            _bridgeOrQueueReturn(undeployedAmount, false);
        }

        emit DeployReceived(protocol, protocolName, actualConsumed);
    }

    /// @dev [M02] balance-delta authoritative: protocol return value is only a sanity check.
    ///      Accounting and bridging use `actualReceived` (asset.balanceOf delta).
    function _handleWithdrawCommand(bytes calldata _payload) internal {
        (uint256 amount, address protocol, string memory protocolName) =
            MessageCodec.decodeAmountProtocolCommand(_payload);
        if (amount == 0) revert ZeroAmount();
        if (protocolDeposits[protocol] < amount) revert InsufficientDeposit();

        address implementation = protocolImplementations[protocolName];
        if (implementation == address(0)) revert ProtocolNotSupported();

        uint256 balanceBefore = asset.balanceOf(address(this));
        uint256 reported = IRemoteProtocolImplementation(implementation).withdraw(address(asset), protocol, amount);
        uint256 balanceAfter = asset.balanceOf(address(this));
        uint256 actualReceived = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;

        if (actualReceived > amount) revert InvalidProtocolAmount(amount, actualReceived);

        uint256 allowedDust = _dustFor(protocolName);
        uint256 diff = reported > actualReceived ? reported - actualReceived : actualReceived - reported;
        if (diff > allowedDust) revert ReportedActualMismatch(reported, actualReceived, allowedDust);

        uint256 shortfall = amount - actualReceived;
        if (shortfall > allowedDust) revert ShortfallExceedsDust(amount, actualReceived, allowedDust);

        protocolDeposits[protocol] -= actualReceived;
        totalDeposited -= actualReceived;

        _bridgeOrQueueReturn(actualReceived, false);
        emit WithdrawAndBridged(protocol, protocolName, actualReceived);
    }

    function _handleHarvestCommand(bytes calldata _payload) internal {
        (address protocol, string memory protocolName) = MessageCodec.decodeHarvestCommand(_payload);
        address implementation = protocolImplementations[protocolName];
        if (implementation == address(0)) revert ProtocolNotSupported();

        uint256 yieldAmount = IRemoteProtocolImplementation(implementation).harvest(address(asset), protocol);
        if (yieldAmount > 0) {
            _bridgeOrQueueReturn(yieldAmount, true);
        }

        emit HarvestAndBridged(protocol, protocolName, yieldAmount);
    }

    function flushPendingReturn(uint256 returnId) external payable onlyOwner nonReentrant whenNotPaused {
        PendingReturn memory pending = pendingReturns[returnId];
        if (pending.amount == 0) revert ZeroAmount();

        delete pendingReturns[returnId];
        _bridgeToHub(pending.amount, pending.isYield, msg.value);

        emit PendingReturnFlushed(returnId, pending.amount, pending.isYield);
    }

    // ========== Internal Functions ==========

    function _bridgeToHub(uint256 amount, bool isYield, uint256 nativeFee) internal {
        if (hubComposer == address(0)) revert ZeroAddress();

        // Encode this chain's EID so Hub can update the correct chain's NAV
        bytes memory composeMsg = StargateComposeCodec.encodeReturn(isYield);
        bytes memory options = LzOptionsLib.buildComposeOptions(STARGATE_RECEIVE_GAS, COMPOSE_GAS_RETURN);
        uint256 minAmount = _calcMinAmount(amount);

        asset.forceApprove(stargatePool, amount);

        IStargate.SendParam memory params = IStargate.SendParam({
            dstEid: hubEid,
            to: _addressToBytes32(hubComposer),
            amountLD: amount,
            minAmountLD: minAmount,
            extraOptions: options,
            composeMsg: composeMsg,
            oftCmd: "" // Taxi mode
        });

        IStargate(stargatePool).send{value: nativeFee}(
            params,
            MessagingFee(nativeFee, 0),
            address(this) // refund to this contract
        );
        asset.forceApprove(stargatePool, 0);
    }

    function _bridgeOrQueueReturn(uint256 amount, bool isYield) internal {
        uint256 nativeFee = _quoteBridgeFee(amount, isYield);

        if (address(this).balance >= nativeFee) {
            _bridgeToHub(amount, isYield, nativeFee);
            return;
        }

        uint256 returnId = pendingReturnCount++;
        pendingReturns[returnId] = PendingReturn({amount: amount, isYield: isYield});
        emit PendingReturnStored(returnId, amount, isYield);
    }

    function _quoteBridgeFee(uint256 amount, bool isYield) internal view returns (uint256 nativeFee) {
        if (hubComposer == address(0)) revert ZeroAddress();

        bytes memory composeMsg = StargateComposeCodec.encodeReturn(isYield);
        bytes memory options = LzOptionsLib.buildComposeOptions(STARGATE_RECEIVE_GAS, COMPOSE_GAS_RETURN);
        uint256 minAmount = _calcMinAmount(amount);

        IStargate.SendParam memory params = IStargate.SendParam({
            dstEid: hubEid,
            to: _addressToBytes32(hubComposer),
            amountLD: amount,
            minAmountLD: minAmount,
            extraOptions: options,
            composeMsg: composeMsg,
            oftCmd: ""
        });

        MessagingFee memory fee = IStargate(stargatePool).quoteSend(params, false);
        return fee.nativeFee;
    }

    function _calcMinAmount(uint256 amount) internal view returns (uint256) {
        uint256 slippage = slippageBps == 0 ? DEFAULT_SLIPPAGE_BPS : slippageBps;
        return amount * (BPS_DENOMINATOR - slippage) / BPS_DENOMINATOR;
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

    function setProtocolImplementation(string calldata protocolName, address implementation) external onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        protocolImplementations[protocolName] = implementation;
        emit ProtocolUpdated(protocolName, implementation);
    }

    function setSlippageBps(uint256 _bps) external onlyOwner {
        slippageBps = _bps;
    }

    /// @notice [M02] Update default dust tolerance for reported/actual discrepancies
    function setDefaultDust(uint256 _dust) external onlyOwner {
        emit DefaultDustUpdated(defaultDust, _dust);
        defaultDust = _dust;
    }

    /// @notice [M02] Set a per-protocol dust override
    function setProtocolDust(string calldata protocolName, uint256 _dust) external onlyOwner {
        bytes32 key = keccak256(bytes(protocolName));
        emit ProtocolDustUpdated(protocolName, dustByProtocol[key], _dust);
        dustByProtocol[key] = _dust;
    }

    function _dustFor(string memory protocolName) internal view returns (uint256) {
        uint256 override_ = dustByProtocol[keccak256(bytes(protocolName))];
        return override_ > 0 ? override_ : defaultDust;
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

    /// @notice Receive native token for Stargate fees
    receive() external payable {}
}
