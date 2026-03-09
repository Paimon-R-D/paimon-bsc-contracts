// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MessageCodec} from "../../libraries/MessageCodec.sol";
import {LzOptionsLib} from "../../libraries/LzOptionsLib.sol";
import {LayerZeroErrors} from "../../libraries/LayerZeroErrors.sol";

/// @title RemoteAssetAdapter
/// @notice Receives commands from Hub and executes DeFi operations on remote chain
/// @dev Deployed on each remote chain (ETH, ARB, Base, etc.)
///      Subclass and override _executeDeployToProtocol/_executeWithdrawFromProtocol/_calculateYield
///      for protocol-specific integrations.
contract RemoteAssetAdapter is OApp, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== Constants ==========

    uint128 public constant DEFAULT_GAS_LIMIT = 200000;

    // ========== State Variables ==========

    /// @notice Hub chain endpoint ID
    uint32 public immutable hubEid;

    /// @notice The underlying asset (e.g., USDT/USDC)
    IERC20 public immutable asset;

    /// @notice Protocol implementations
    mapping(string => address) public protocolImplementations;

    /// @notice Assets deployed per protocol
    mapping(address => uint256) public protocolDeposits;

    /// @notice Total assets deployed
    uint256 public totalDeposited;

    // ========== Events ==========

    event Deployed(address indexed protocol, string protocolName, uint256 amount);
    event Withdrawn(address indexed protocol, string protocolName, uint256 amount);
    event Harvested(address indexed protocol, string protocolName, uint256 yieldAmount);
    event ProtocolUpdated(string protocolName, address implementation);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    event WithdrawConfirmationSent(uint256 amount, bytes32 guid);
    event YieldReportSent(uint256 yieldAmount, bytes32 guid);

    // ========== Errors ==========

    error OnlyHub();
    error InvalidProtocol();
    error InsufficientDeposit();
    error ProtocolNotSupported();
    error UnknownMessageType(bytes1 msgType);
    error ZeroAddress();

    // ========== Constructor ==========

    constructor(address _endpoint, address _delegate, address _asset, uint32 _hubEid)
        OApp(_endpoint, _delegate)
        Ownable(_delegate)
    {
        asset = IERC20(_asset);
        hubEid = _hubEid;
    }

    // ========== View Functions ==========

    function getProtocolImplementation(string calldata protocolName) external view returns (address) {
        return protocolImplementations[protocolName];
    }

    // ========== LayerZero Receive ==========

    /// @notice Handle messages from Hub
    /// @dev P0-2 FIX: Uses MessageCodec for consistent decode (payload[1:] instead of abi.decode with bytes1)
    function _lzReceive(
        Origin calldata _origin,
        bytes32, /*_guid*/
        bytes calldata _payload,
        address, /*_executor*/
        bytes calldata /*_extraData*/
    )
        internal
        override
        whenNotPaused
        nonReentrant
    {
        if (_origin.srcEid != hubEid) revert OnlyHub();

        bytes1 msgType = MessageCodec.decodeMsgType(_payload);

        if (msgType == MessageCodec.MSG_DEPLOY) {
            _handleDeploy(_payload);
        } else if (msgType == MessageCodec.MSG_WITHDRAW_ASSET) {
            _handleWithdraw(_payload);
        } else if (msgType == MessageCodec.MSG_HARVEST) {
            _handleHarvest(_payload);
        } else {
            revert UnknownMessageType(msgType);
        }
    }

    // ========== Internal Handlers ==========

    /// @notice Handle deploy command
    /// @dev P1-4 FIX: Delegates actual asset deployment to virtual _executeDeployToProtocol
    function _handleDeploy(bytes calldata _payload) internal {
        (uint256 amount, address protocol, string memory protocolName) =
            MessageCodec.decodeDeployCommand(_payload);

        address implementation = protocolImplementations[protocolName];
        if (implementation == address(0)) revert ProtocolNotSupported();

        _executeDeployToProtocol(protocol, implementation, amount);

        protocolDeposits[protocol] += amount;
        totalDeposited += amount;

        emit Deployed(protocol, protocolName, amount);
    }

    /// @notice Handle withdraw command
    /// @dev P1-4 FIX: Delegates actual asset withdrawal to virtual _executeWithdrawFromProtocol
    function _handleWithdraw(bytes calldata _payload) internal {
        (uint256 amount, address protocol, string memory protocolName) =
            MessageCodec.decodeDeployCommand(_payload);

        if (protocolDeposits[protocol] < amount) revert InsufficientDeposit();

        _executeWithdrawFromProtocol(protocol, protocolImplementations[protocolName], amount);

        protocolDeposits[protocol] -= amount;
        totalDeposited -= amount;

        emit Withdrawn(protocol, protocolName, amount);

        _sendWithdrawConfirmation(amount);
    }

    /// @notice Handle harvest command
    function _handleHarvest(bytes calldata _payload) internal {
        (address protocol, string memory protocolName) = MessageCodec.decodeHarvestCommand(_payload);

        uint256 yieldAmount = _calculateYield(protocol);

        emit Harvested(protocol, protocolName, yieldAmount);

        if (yieldAmount > 0) {
            _sendYieldReport(yieldAmount);
        }
    }

    /// @notice Execute deployment to a DeFi protocol
    /// @dev P1-4 FIX: Virtual stub - must be overridden by subclass for actual protocol integration
    function _executeDeployToProtocol(address protocol, address implementation, uint256 amount) internal virtual {
        (protocol, implementation, amount); // silence unused warnings
        revert LayerZeroErrors.NotImplemented("_executeDeployToProtocol");
    }

    /// @notice Execute withdrawal from a DeFi protocol
    /// @dev P1-4 FIX: Virtual stub - must be overridden by subclass for actual protocol integration
    function _executeWithdrawFromProtocol(address protocol, address implementation, uint256 amount) internal virtual {
        (protocol, implementation, amount); // silence unused warnings
        revert LayerZeroErrors.NotImplemented("_executeWithdrawFromProtocol");
    }

    /// @notice Calculate yield from a protocol
    /// @dev P0-10 FIX: Virtual stub that reverts instead of silently returning 0
    function _calculateYield(address protocol) internal virtual returns (uint256) {
        (protocol); // silence unused warning
        revert LayerZeroErrors.NotImplemented("_calculateYield");
    }

    /// @notice Send withdrawal confirmation to Hub
    /// @dev P0-5 FIX: Reverts on insufficient gas instead of silently skipping
    /// @param amount Amount that was withdrawn
    function _sendWithdrawConfirmation(uint256 amount) internal {
        bytes memory payload = MessageCodec.encodeWithdrawConfirm(amount);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);

        MessagingFee memory fee = _quote(hubEid, payload, options, false);

        if (address(this).balance < fee.nativeFee) {
            revert LayerZeroErrors.InsufficientGasBalance(address(this).balance, fee.nativeFee);
        }

        MessagingReceipt memory receipt = _lzSend(
            hubEid,
            payload,
            options,
            MessagingFee(fee.nativeFee, 0),
            payable(address(this))
        );
        emit WithdrawConfirmationSent(amount, receipt.guid);
    }

    /// @notice Send yield report to Hub
    /// @dev P0-5 FIX: Reverts on insufficient gas instead of silently skipping
    /// @param yieldAmount Amount of yield harvested
    function _sendYieldReport(uint256 yieldAmount) internal {
        bytes memory payload = MessageCodec.encodeYieldReport(yieldAmount);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);

        MessagingFee memory fee = _quote(hubEid, payload, options, false);

        if (address(this).balance < fee.nativeFee) {
            revert LayerZeroErrors.InsufficientGasBalance(address(this).balance, fee.nativeFee);
        }

        MessagingReceipt memory receipt = _lzSend(
            hubEid,
            payload,
            options,
            MessagingFee(fee.nativeFee, 0),
            payable(address(this))
        );
        emit YieldReportSent(yieldAmount, receipt.guid);
    }

    /// @notice Receive native token for gas fees
    receive() external payable {}

    // ========== Admin Functions ==========

    function setProtocolImplementation(string calldata protocolName, address implementation) external onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        protocolImplementations[protocolName] = implementation;
        emit ProtocolUpdated(protocolName, implementation);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        asset.safeTransfer(to, amount);
        emit EmergencyWithdraw(to, amount);
    }
}
