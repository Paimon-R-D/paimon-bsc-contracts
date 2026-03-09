// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MessagingFee} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {OFTComposeMsgCodec} from "@layerzero-v2/oapp/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {IStargate} from "../interfaces/IStargateIntegration.sol";
import {StargateComposeCodec} from "../libraries/StargateComposeCodec.sol";
import {LzOptionsLib} from "../libraries/LzOptionsLib.sol";
import {ICrossChainNAVReporter} from "../interfaces/ICrossChainNAVReporter.sol";
import {IRedemptionManager} from "../../ppt/IPPTContracts.sol";

/// @title HubStargateComposer
/// @notice Coordinates USDT bridging + vault operations on the BSC Hub chain
/// @dev Receives Stargate compose callbacks for deposits/returns.
///      Initiates Stargate sends for settlements/deploys/replenishments.
contract HubStargateComposer is ILayerZeroComposer, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========== Roles ==========

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ========== Constants ==========

    uint128 public constant STARGATE_RECEIVE_GAS = 65_000;
    uint128 public constant COMPOSE_GAS_DEPOSIT = 300_000;
    uint128 public constant COMPOSE_GAS_SETTLEMENT = 100_000;
    uint128 public constant COMPOSE_GAS_DEPLOY = 350_000;
    uint128 public constant COMPOSE_GAS_REPLENISH = 150_000;
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 50; // 0.5%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ========== State Variables ==========

    /// @notice LayerZero endpoint address
    address public immutable endpoint;

    /// @notice Stargate USDT pool on BSC
    address public immutable stargatePool;

    /// @notice The underlying asset (USDT)
    IERC20 public immutable asset;

    /// @notice PPT Vault (ERC4626)
    IERC4626 public vault;

    /// @notice PPTOFTAdapter for sending shares cross-chain
    address public pptOftAdapter;

    /// @notice CrossChainNAVReporter for updating remote balances
    address public navReporter;

    /// @notice Redemption manager used for satellite standard withdrawals
    address public redemptionManager;

    /// @notice Trusted gateway per remote chain (eid => gateway address)
    mapping(uint32 => address) public trustedGateways;

    /// @notice Slippage tolerance in basis points per chain
    mapping(uint32 => uint256) public slippageBps;

    struct PendingSatelliteRedemption {
        uint32 dstEid;
        address receiver;
        bool exists;
    }

    mapping(uint256 => PendingSatelliteRedemption) public pendingSatelliteRedemptions;

    // ========== Events ==========

    event DepositReceived(uint32 indexed srcEid, address indexed receiver, uint256 assets, uint256 shares);
    event SettlementBridged(uint32 indexed dstEid, address indexed receiver, uint256 amount, uint256 requestId);
    event DeployBridged(uint32 indexed dstEid, address indexed protocol, uint256 amount);
    event ReturnReceived(uint32 indexed srcEid, uint256 amount, bool isYield);
    event ReplenishBridged(uint32 indexed dstEid, uint256 amount);
    event TrustedGatewayUpdated(uint32 indexed eid, address gateway);
    event VaultUpdated(address vault);
    event PptOftAdapterUpdated(address adapter);
    event NavReporterUpdated(address reporter);
    event RedemptionManagerUpdated(address manager);
    event SatelliteRedemptionRegistered(uint256 indexed requestId, uint32 indexed dstEid, address indexed receiver);
    event SatelliteRedemptionSettled(uint256 indexed requestId, uint32 indexed dstEid, address indexed receiver, uint256 amount);

    // ========== Errors ==========

    error OnlyEndpoint();
    error OnlyStargate();
    error UntrustedSource(uint32 srcEid, address composeFrom);
    error UnknownAction(uint8 action);
    error ZeroAddress();
    error ZeroAmount();
    error SlippageTooHigh(uint256 sharesReceived, uint256 minShares);
    error InsufficientBalance(uint256 available, uint256 required);
    error UnauthorizedRegistrar(address caller);
    error UnknownSatelliteRedemption(uint256 requestId);

    // ========== Constructor ==========

    /// @notice Failed deposit record for keeper retry
    struct FailedDeposit {
        uint32 srcEid;
        address receiver;
        uint256 assets;
        uint256 timestamp;
    }

    /// @notice Failed deposits awaiting retry
    mapping(uint256 => FailedDeposit) public failedDeposits;
    uint256 public failedDepositCount;

    event DepositFailed(uint256 indexed failedId, uint32 srcEid, address receiver, uint256 assets, string reason);
    event FailedDepositRetried(uint256 indexed failedId, uint256 shares);

    constructor(
        address _endpoint,
        address _stargatePool,
        address _asset,
        address _admin
    ) {
        if (_endpoint == address(0)) revert ZeroAddress();
        if (_stargatePool == address(0)) revert ZeroAddress();
        if (_asset == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        endpoint = _endpoint;
        stargatePool = _stargatePool;
        asset = IERC20(_asset);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _admin);
    }

    // ========== Stargate Compose Callback ==========

    /// @notice Handle Stargate compose messages (USDT arrived + instruction)
    /// @dev Called by LayerZero endpoint after Stargate delivers tokens
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) external payable override nonReentrant whenNotPaused {
        if (msg.sender != endpoint) revert OnlyEndpoint();
        if (_from != stargatePool) revert OnlyStargate();

        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
        bytes32 composeFromBytes = OFTComposeMsgCodec.composeFrom(_message);
        uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
        bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);

        // Verify the compose sender is a trusted gateway
        address composeFrom = _bytes32ToAddress(composeFromBytes);
        if (trustedGateways[srcEid] != composeFrom) {
            revert UntrustedSource(srcEid, composeFrom);
        }

        uint8 action = StargateComposeCodec.decodeAction(composeMsg);

        if (action == StargateComposeCodec.ACTION_DEPOSIT) {
            _handleDeposit(srcEid, amountLD, composeMsg, _guid);
        } else if (action == StargateComposeCodec.ACTION_RETURN) {
            _handleReturn(amountLD, composeMsg);
        } else {
            revert UnknownAction(action);
        }
    }

    // ========== Internal Handlers ==========

    /// @notice Handle cross-chain deposit: USDT arrived → deposit to vault → send shares back
    function _handleDeposit(uint32 srcEid, uint256 assets, bytes memory composeMsg, bytes32 /*guid*/) internal {
        (address receiver, uint256 minShares) = StargateComposeCodec.decodeDeposit(composeMsg);
        if (receiver == address(0)) revert ZeroAddress();
        if (assets == 0) revert ZeroAmount();
        if (address(vault) == address(0) || pptOftAdapter == address(0)) revert ZeroAddress();

        // Deposit USDT into PPT vault (try/catch to prevent nonce blocking)
        asset.forceApprove(address(vault), assets);
        try vault.deposit(assets, pptOftAdapter) returns (uint256 shares) {
            asset.forceApprove(address(vault), 0);

            if (minShares > 0 && shares < minShares) {
                revert SlippageTooHigh(shares, minShares);
            }

            // Send PPT shares back to receiver on source chain via PPTOFTAdapter
            _sendSharesBack(srcEid, receiver, shares);

            emit DepositReceived(srcEid, receiver, assets, shares);
        } catch Error(string memory reason) {
            asset.forceApprove(address(vault), 0);
            // Store failed deposit for keeper retry instead of reverting (would block nonce)
            uint256 failedId = failedDepositCount++;
            failedDeposits[failedId] = FailedDeposit(srcEid, receiver, assets, block.timestamp);
            emit DepositFailed(failedId, srcEid, receiver, assets, reason);
        } catch {
            asset.forceApprove(address(vault), 0);
            uint256 failedId = failedDepositCount++;
            failedDeposits[failedId] = FailedDeposit(srcEid, receiver, assets, block.timestamp);
            emit DepositFailed(failedId, srcEid, receiver, assets, "unknown");
        }
    }

    /// @notice Handle return from remote deployment (withdraw or yield)
    function _handleReturn(uint256 amount, bytes memory composeMsg) internal {
        (uint32 srcEid, bool isYield) = StargateComposeCodec.decodeReturn(composeMsg);
        if (address(vault) == address(0)) revert ZeroAddress();

        asset.safeTransfer(address(vault), amount);

        // Update NAV reporter
        if (navReporter != address(0)) {
            ICrossChainNAVReporter(navReporter).recordReturn(srcEid, amount, isYield);
        }

        emit ReturnReceived(srcEid, amount, isYield);
    }

    // ========== Outbound Bridge Functions ==========

    /// @notice Bridge USDT to satellite for redemption settlement
    /// @param dstEid Destination chain endpoint ID
    /// @param receiver The user to receive USDT on destination
    /// @param amount USDT amount to bridge
    /// @param requestId Redemption request ID for tracking
    function settleAndBridge(
        uint32 dstEid,
        address receiver,
        uint256 amount,
        uint256 requestId
    ) external payable onlyRole(KEEPER_ROLE) nonReentrant whenNotPaused {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _bridgeSettlement(dstEid, receiver, amount, requestId, msg.value);
    }

    /// @notice Register a pending satellite redemption after PPTOFTAdapter creates the Hub request
    function registerSatelliteRedemption(uint256 requestId, uint32 dstEid, address receiver)
        external
        whenNotPaused
    {
        if (msg.sender != pptOftAdapter) revert UnauthorizedRegistrar(msg.sender);
        if (receiver == address(0)) revert ZeroAddress();

        pendingSatelliteRedemptions[requestId] = PendingSatelliteRedemption({
            dstEid: dstEid,
            receiver: receiver,
            exists: true
        });

        emit SatelliteRedemptionRegistered(requestId, dstEid, receiver);
    }

    /// @notice Settle a registered redemption on Hub and bridge the settled USDT back to the satellite chain
    function settleSatelliteRedemption(uint256 requestId)
        external
        payable
        onlyRole(KEEPER_ROLE)
        nonReentrant
        whenNotPaused
    {
        PendingSatelliteRedemption memory pending = pendingSatelliteRedemptions[requestId];
        if (!pending.exists) revert UnknownSatelliteRedemption(requestId);
        if (redemptionManager == address(0)) revert ZeroAddress();

        uint256 balanceBefore = asset.balanceOf(address(this));
        IRedemptionManager(redemptionManager).settleRedemption(requestId);
        uint256 settledAmount = asset.balanceOf(address(this)) - balanceBefore;

        _bridgeSettlement(pending.dstEid, pending.receiver, settledAmount, requestId, msg.value);
        delete pendingSatelliteRedemptions[requestId];

        emit SatelliteRedemptionSettled(requestId, pending.dstEid, pending.receiver, settledAmount);
    }

    /// @notice Bridge USDT to remote chain for DeFi deployment
    /// @param dstEid Destination chain endpoint ID
    /// @param amount USDT amount to bridge and deploy
    /// @param protocol Target protocol address on remote chain
    /// @param protocolName Protocol name for routing
    function bridgeAndDeploy(
        uint32 dstEid,
        uint256 amount,
        address protocol,
        string calldata protocolName
    ) external payable onlyRole(KEEPER_ROLE) nonReentrant whenNotPaused returns (uint256 bridgedAmount) {
        if (amount == 0) revert ZeroAmount();

        bytes memory composeMsg = StargateComposeCodec.encodeDeploy(protocol, protocolName);
        bridgedAmount = _stargateSend(dstEid, amount, composeMsg, COMPOSE_GAS_DEPLOY, msg.value);

        // Update NAV reporter
        if (navReporter != address(0)) {
            ICrossChainNAVReporter(navReporter).recordDeploy(dstEid, bridgedAmount);
        }

        emit DeployBridged(dstEid, protocol, bridgedAmount);
    }

    /// @notice Bridge USDT to replenish satellite LiquidityPool
    /// @param dstEid Destination satellite chain
    /// @param amount USDT amount to replenish
    function replenishLiquidity(
        uint32 dstEid,
        uint256 amount
    ) external payable onlyRole(KEEPER_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        bytes memory composeMsg = StargateComposeCodec.encodeReplenish();
        _stargateSend(dstEid, amount, composeMsg, COMPOSE_GAS_REPLENISH, msg.value);

        emit ReplenishBridged(dstEid, amount);
    }

    // ========== Quote Functions ==========

    /// @notice Quote the native fee for bridging
    function quoteBridge(uint32 dstEid, uint256 amount, bytes calldata composeMsg, uint128 composeGas)
        external
        view
        returns (uint256 nativeFee)
    {
        bytes memory options = LzOptionsLib.buildComposeOptions(STARGATE_RECEIVE_GAS, composeGas);
        uint256 minAmount = _calcMinAmount(dstEid, amount);

        IStargate.SendParam memory params = IStargate.SendParam({
            dstEid: dstEid,
            to: _addressToBytes32(trustedGateways[dstEid]),
            amountLD: amount,
            minAmountLD: minAmount,
            extraOptions: options,
            composeMsg: composeMsg,
            oftCmd: "" // Taxi mode
        });

        MessagingFee memory fee = IStargate(stargatePool).quoteSend(params, false);
        return fee.nativeFee;
    }

    /// @notice Quote deposit bridge fee
    function quoteDeposit(uint32 srcEid, uint256 amount) external view returns (uint256) {
        bytes memory composeMsg = StargateComposeCodec.encodeDeposit(address(0), 0);
        bytes memory options = LzOptionsLib.buildComposeOptions(STARGATE_RECEIVE_GAS, COMPOSE_GAS_DEPOSIT);
        uint256 minAmount = _calcMinAmount(srcEid, amount);

        IStargate.SendParam memory params = IStargate.SendParam({
            dstEid: srcEid,
            to: _addressToBytes32(address(this)),
            amountLD: amount,
            minAmountLD: minAmount,
            extraOptions: options,
            composeMsg: composeMsg,
            oftCmd: ""
        });

        MessagingFee memory fee = IStargate(stargatePool).quoteSend(params, false);
        return fee.nativeFee;
    }

    // ========== Internal Functions ==========

    function _stargateSend(
        uint32 dstEid,
        uint256 amount,
        bytes memory composeMsg,
        uint128 composeGas,
        uint256 nativeFee
    ) internal returns (uint256 amountReceivedLD) {
        uint256 balance = asset.balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance(balance, amount);

        address gateway = trustedGateways[dstEid];
        if (gateway == address(0)) revert ZeroAddress();

        bytes memory options = LzOptionsLib.buildComposeOptions(STARGATE_RECEIVE_GAS, composeGas);
        uint256 minAmount = _calcMinAmount(dstEid, amount);

        asset.forceApprove(stargatePool, amount);

        IStargate.SendParam memory params = IStargate.SendParam({
            dstEid: dstEid,
            to: _addressToBytes32(gateway),
            amountLD: amount,
            minAmountLD: minAmount,
            extraOptions: options,
            composeMsg: composeMsg,
            oftCmd: "" // Taxi mode for compose support
        });

        (, IStargate.OFTReceipt memory oftReceipt) = IStargate(stargatePool).send{value: nativeFee}(
            params,
            MessagingFee(nativeFee, 0),
            address(this)
        );
        asset.forceApprove(stargatePool, 0);
        return oftReceipt.amountReceivedLD;
    }

    function _bridgeSettlement(
        uint32 dstEid,
        address receiver,
        uint256 amount,
        uint256 requestId,
        uint256 nativeFee
    ) internal {
        bytes memory composeMsg = StargateComposeCodec.encodeSettlement(receiver, requestId);
        _stargateSend(dstEid, amount, composeMsg, COMPOSE_GAS_SETTLEMENT, nativeFee);
        emit SettlementBridged(dstEid, receiver, amount, requestId);
    }

    function _sendSharesBack(uint32 dstEid, address receiver, uint256 shares) internal {
        // Delegate to PPTOFTAdapter to send mint-shares message
        IPPTOFTAdapterMintShares(pptOftAdapter).mintSharesOnSatellite(dstEid, receiver, shares);
    }

    function _calcMinAmount(uint32 eid, uint256 amount) internal view returns (uint256) {
        uint256 slippage = slippageBps[eid];
        if (slippage == 0) slippage = DEFAULT_SLIPPAGE_BPS;
        return amount * (BPS_DENOMINATOR - slippage) / BPS_DENOMINATOR;
    }

    function _addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function _bytes32ToAddress(bytes32 b) internal pure returns (address) {
        return address(uint160(uint256(b)));
    }

    // ========== Configuration ==========

    function setVault(address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_vault == address(0)) revert ZeroAddress();
        vault = IERC4626(_vault);
        emit VaultUpdated(_vault);
    }

    function setPptOftAdapter(address _adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_adapter == address(0)) revert ZeroAddress();
        pptOftAdapter = _adapter;
        emit PptOftAdapterUpdated(_adapter);
    }

    function setNavReporter(address _reporter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        navReporter = _reporter;
        emit NavReporterUpdated(_reporter);
    }

    function setRedemptionManager(address _manager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_manager == address(0)) revert ZeroAddress();
        redemptionManager = _manager;
        emit RedemptionManagerUpdated(_manager);
    }

    function setTrustedGateway(uint32 eid, address gateway) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (gateway == address(0)) revert ZeroAddress();
        trustedGateways[eid] = gateway;
        emit TrustedGatewayUpdated(eid, gateway);
    }

    function setSlippageBps(uint32 eid, uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        slippageBps[eid] = bps;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Receive native token for Stargate refunds
    receive() external payable {}
}

// ========== Minimal interfaces for internal use ==========

interface IPPTOFTAdapterMintShares {
    function mintSharesOnSatellite(uint32 dstEid, address receiver, uint256 shares) external;
}
