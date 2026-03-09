// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRemoteProtocolImplementation} from "../../interfaces/IRemoteProtocolImplementation.sol";
import {MessageCodec} from "../../libraries/MessageCodec.sol";
import {LzOptionsLib} from "../../libraries/LzOptionsLib.sol";
import {LayerZeroErrors} from "../../libraries/LayerZeroErrors.sol";

/// @title RemoteAssetAdapter
/// @notice Receives commands from Hub and executes DeFi operations on remote chain
/// @dev Deployed on each remote chain (ETH, ARB, Base, etc.) and delegates protocol actions
///      to owner-configured implementation contracts.
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
    error InvalidProtocolAmount(uint256 requested, uint256 actual);
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

    function _handleDeploy(bytes calldata _payload) internal {
        (uint256 amount, address protocol, string memory protocolName) =
            MessageCodec.decodeDeployCommand(_payload);

        address implementation = _getProtocolImplementation(protocolName);

        // Approve protocol implementation to spend tokens (forceApprove for USDT compatibility)
        asset.forceApprove(implementation, amount);
        uint256 deployedAmount = IRemoteProtocolImplementation(implementation).deploy(address(asset), protocol, amount);
        asset.forceApprove(implementation, 0);
        if (deployedAmount > amount) revert InvalidProtocolAmount(amount, deployedAmount);

        protocolDeposits[protocol] += deployedAmount;
        totalDeposited += deployedAmount;

        emit Deployed(protocol, protocolName, deployedAmount);
    }

    function _handleWithdraw(bytes calldata _payload) internal {
        (uint256 amount, address protocol, string memory protocolName) =
            MessageCodec.decodeDeployCommand(_payload);

        if (protocolDeposits[protocol] < amount) revert InsufficientDeposit();
        address implementation = _getProtocolImplementation(protocolName);
        uint256 withdrawnAmount = IRemoteProtocolImplementation(implementation).withdraw(address(asset), protocol, amount);
        if (withdrawnAmount > amount) revert InvalidProtocolAmount(amount, withdrawnAmount);

        protocolDeposits[protocol] -= withdrawnAmount;
        totalDeposited -= withdrawnAmount;

        emit Withdrawn(protocol, protocolName, withdrawnAmount);

        _sendWithdrawConfirmation(withdrawnAmount);
    }

    function _handleHarvest(bytes calldata _payload) internal {
        (address protocol, string memory protocolName) = MessageCodec.decodeHarvestCommand(_payload);
        address implementation = _getProtocolImplementation(protocolName);
        uint256 yieldAmount = IRemoteProtocolImplementation(implementation).harvest(address(asset), protocol);

        emit Harvested(protocol, protocolName, yieldAmount);

        if (yieldAmount > 0) {
            _sendYieldReport(yieldAmount);
        }
    }

    function _getProtocolImplementation(string memory protocolName) internal view returns (address implementation) {
        implementation = protocolImplementations[protocolName];
        if (implementation == address(0)) revert ProtocolNotSupported();
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

    /// @notice Override _payNative to use contract balance instead of msg.value
    /// @dev Required for _lzSend calls inside _lzReceive (where msg.value=0)
    function _payNative(uint256 _nativeFee) internal virtual override returns (uint256 nativeFee) {
        if (address(this).balance < _nativeFee) revert NotEnoughNative(_nativeFee);
        return _nativeFee;
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
