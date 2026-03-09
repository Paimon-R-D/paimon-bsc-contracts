// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RemoteAssetAdapter
/// @notice Receives commands from Hub and executes DeFi operations on remote chain
/// @dev Deployed on each remote chain (ETH, ARB, Base, etc.)
contract RemoteAssetAdapter is OApp, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== Message Types (from Hub) ==========

    bytes1 public constant MSG_DEPLOY = 0x01;
    bytes1 public constant MSG_WITHDRAW = 0x02;
    bytes1 public constant MSG_HARVEST = 0x03;

    // ========== Message Types (to Hub) ==========

    bytes1 public constant MSG_YIELD_REPORT = 0x10;
    bytes1 public constant MSG_WITHDRAW_CONFIRM = 0x11;

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

    /// @notice Emitted when assets are deployed to a protocol
    event Deployed(address indexed protocol, string protocolName, uint256 amount);

    /// @notice Emitted when assets are withdrawn from a protocol
    event Withdrawn(address indexed protocol, string protocolName, uint256 amount);

    /// @notice Emitted when yield is harvested
    event Harvested(address indexed protocol, string protocolName, uint256 yieldAmount);

    /// @notice Emitted when protocol implementation is updated
    event ProtocolUpdated(string protocolName, address implementation);

    // ========== Errors ==========

    error OnlyHub();
    error InvalidProtocol();
    error InsufficientDeposit();
    error ProtocolNotSupported();
    error UnknownMessageType(bytes1 msgType);
    error ZeroAddress();

    // ========== Additional Events ==========

    /// @notice Emitted when emergency withdrawal is executed
    event EmergencyWithdraw(address indexed to, uint256 amount);

    /// @notice Emitted when withdrawal confirmation is sent
    event WithdrawConfirmationSent(uint256 amount, bytes32 guid);

    /// @notice Emitted when yield report is sent
    event YieldReportSent(uint256 yieldAmount, bytes32 guid);

    // ========== Constructor ==========

    /// @notice Initialize the RemoteAssetAdapter
    /// @param _endpoint LayerZero endpoint address
    /// @param _delegate Owner/delegate address
    /// @param _asset Underlying asset address
    /// @param _hubEid Hub chain endpoint ID
    constructor(address _endpoint, address _delegate, address _asset, uint32 _hubEid)
        OApp(_endpoint, _delegate)
        Ownable(_delegate)
    {
        asset = IERC20(_asset);
        hubEid = _hubEid;
    }

    // ========== View Functions ==========

    /// @notice Get protocol implementation address
    /// @param protocolName Protocol identifier
    /// @return Implementation address
    function getProtocolImplementation(string calldata protocolName) external view returns (address) {
        return protocolImplementations[protocolName];
    }

    // ========== LayerZero Receive ==========

    /// @notice Handle messages from Hub
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
        // Only accept messages from Hub
        if (_origin.srcEid != hubEid) revert OnlyHub();

        bytes1 msgType = bytes1(_payload[0]);

        if (msgType == MSG_DEPLOY) {
            _handleDeploy(_payload);
        } else if (msgType == MSG_WITHDRAW) {
            _handleWithdraw(_payload);
        } else if (msgType == MSG_HARVEST) {
            _handleHarvest(_payload);
        } else {
            revert UnknownMessageType(msgType);
        }
    }

    // ========== Internal Handlers ==========

    /// @notice Handle deploy command
    function _handleDeploy(bytes calldata _payload) internal {
        (, uint256 amount, address protocol, string memory protocolName) =
            abi.decode(_payload, (bytes1, uint256, address, string));

        address implementation = protocolImplementations[protocolName];
        if (implementation == address(0)) revert ProtocolNotSupported();

        // Transfer assets to protocol (simplified - actual implementation would call protocol)
        // In production, this would call the protocol's deposit function
        protocolDeposits[protocol] += amount;
        totalDeposited += amount;

        emit Deployed(protocol, protocolName, amount);
    }

    /// @notice Handle withdraw command
    function _handleWithdraw(bytes calldata _payload) internal {
        (, uint256 amount, address protocol, string memory protocolName) =
            abi.decode(_payload, (bytes1, uint256, address, string));

        if (protocolDeposits[protocol] < amount) revert InsufficientDeposit();

        // Withdraw from protocol (simplified)
        protocolDeposits[protocol] -= amount;
        totalDeposited -= amount;

        emit Withdrawn(protocol, protocolName, amount);

        // Send confirmation back to Hub
        _sendWithdrawConfirmation(amount);
    }

    /// @notice Handle harvest command
    function _handleHarvest(bytes calldata _payload) internal {
        (, address protocol, string memory protocolName) = abi.decode(_payload, (bytes1, address, string));

        // Calculate yield (simplified - actual implementation would query protocol)
        uint256 yieldAmount = _calculateYield(protocol);

        emit Harvested(protocol, protocolName, yieldAmount);

        // Send yield report back to Hub
        if (yieldAmount > 0) {
            _sendYieldReport(yieldAmount);
        }
    }

    /// @notice Calculate yield from a protocol (placeholder)
    function _calculateYield(
        address /*protocol*/
    )
        internal
        pure
        returns (uint256)
    {
        // In production, this would query the protocol for accrued yield
        return 0;
    }

    /// @notice Send withdrawal confirmation to Hub
    /// @param amount Amount that was withdrawn
    function _sendWithdrawConfirmation(uint256 amount) internal {
        bytes memory payload = abi.encodePacked(MSG_WITHDRAW_CONFIRM, amount);
        bytes memory options = _buildOptions(DEFAULT_GAS_LIMIT);

        // Note: This requires the contract to have native balance for fees
        // In production, fees should be pre-funded or use a fee management system
        MessagingFee memory fee = _quote(hubEid, payload, options, false);

        // Only send if we have enough balance
        if (address(this).balance >= fee.nativeFee) {
            MessagingReceipt memory receipt = _lzSend(
                hubEid,
                payload,
                options,
                MessagingFee(fee.nativeFee, 0),
                payable(address(this))
            );
            emit WithdrawConfirmationSent(amount, receipt.guid);
        }
    }

    /// @notice Send yield report to Hub
    /// @param yieldAmount Amount of yield harvested
    function _sendYieldReport(uint256 yieldAmount) internal {
        bytes memory payload = abi.encodePacked(MSG_YIELD_REPORT, yieldAmount);
        bytes memory options = _buildOptions(DEFAULT_GAS_LIMIT);

        // Note: This requires the contract to have native balance for fees
        MessagingFee memory fee = _quote(hubEid, payload, options, false);

        // Only send if we have enough balance
        if (address(this).balance >= fee.nativeFee) {
            MessagingReceipt memory receipt = _lzSend(
                hubEid,
                payload,
                options,
                MessagingFee(fee.nativeFee, 0),
                payable(address(this))
            );
            emit YieldReportSent(yieldAmount, receipt.guid);
        }
    }

    /// @notice Receive native token for gas fees
    receive() external payable {}

    // ========== Admin Functions ==========

    /// @notice Set protocol implementation
    /// @param protocolName Protocol identifier
    /// @param implementation Implementation address
    function setProtocolImplementation(string calldata protocolName, address implementation) external onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        protocolImplementations[protocolName] = implementation;
        emit ProtocolUpdated(protocolName, implementation);
    }

    /// @notice Pause the adapter
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the adapter
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Emergency withdraw
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        asset.safeTransfer(to, amount);
        emit EmergencyWithdraw(to, amount);
    }

    // ========== Internal Functions ==========

    function _buildOptions(uint128 gasLimit) internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(3), gasLimit, uint128(0));
    }
}
