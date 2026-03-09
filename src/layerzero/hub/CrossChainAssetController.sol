// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CrossChainAssetController
/// @notice Manages cross-chain asset deployment commands to DeFi protocols (Aave, Compound, etc.)
/// @dev Deployed on BSC Hub chain, sends commands to remote chain adapters.
///      This contract tracks asset allocation across chains via cross-chain messages.
///      Actual asset transfer must be handled separately (via OFT or bridge).
contract CrossChainAssetController is OApp, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== Roles ==========

    /// @notice Keeper role - Can execute deploy/withdraw/harvest operations
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @notice Rebalancer role - Can rebalance across chains
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    // ========== Message Types ==========

    /// @notice Deploy assets to a protocol
    bytes1 public constant MSG_DEPLOY = 0x01;

    /// @notice Withdraw assets from a protocol
    bytes1 public constant MSG_WITHDRAW = 0x02;

    /// @notice Harvest yield from a protocol
    bytes1 public constant MSG_HARVEST = 0x03;

    /// @notice Yield report from remote adapter
    bytes1 public constant MSG_YIELD_REPORT = 0x10;

    /// @notice Withdrawal confirmation from remote adapter
    bytes1 public constant MSG_WITHDRAW_CONFIRM = 0x11;

    // ========== Constants ==========

    /// @notice Default gas limit for DeFi operations
    uint128 public constant DEFAULT_GAS_LIMIT = 500000;

    // ========== State Variables ==========

    /// @notice The underlying asset (e.g., USDT)
    IERC20 public immutable asset;

    /// @notice Deployed assets per chain
    mapping(uint32 => uint256) public deployedAssets;

    /// @notice Protocol allocation per chain per protocol
    mapping(uint32 => mapping(address => uint256)) internal _protocolAllocations;

    /// @notice Remote adapter address per chain
    mapping(uint32 => address) public remoteAdapter;

    /// @notice Supported chains
    uint32[] internal _supportedChains;

    /// @notice Chain support status
    mapping(uint32 => bool) internal _isChainSupported;

    /// @notice Total deployed across all chains (for quick lookup)
    uint256 public totalDeployed;

    // ========== Events ==========

    /// @notice Emitted when assets are deployed to a remote chain
    event AssetDeployed(
        uint32 indexed dstEid, address indexed protocol, string protocolName, uint256 amount, bytes32 guid
    );

    /// @notice Emitted when withdrawal is requested from remote chain
    event WithdrawalRequested(
        uint32 indexed dstEid, address indexed protocol, string protocolName, uint256 amount, bytes32 guid
    );

    /// @notice Emitted when yield harvest is requested
    event HarvestRequested(uint32 indexed dstEid, address indexed protocol, string protocolName, bytes32 guid);

    /// @notice Emitted when yield is received from remote chain
    event YieldReceived(uint32 indexed srcEid, uint256 yieldAmount);

    /// @notice Emitted when withdrawal is confirmed
    event WithdrawalConfirmed(uint32 indexed srcEid, uint256 amount);

    /// @notice Emitted when a chain is added
    event ChainAdded(uint32 indexed eid, address adapter);

    /// @notice Emitted when a chain is removed
    event ChainRemoved(uint32 indexed eid);

    /// @notice Emitted when emergency withdrawal is executed
    event EmergencyWithdraw(address indexed to, uint256 amount);

    // ========== Errors ==========

    error InvalidAmount();
    error ChainNotSupported();
    error ChainAlreadySupported();
    error ChainHasDeployedAssets();
    error InsufficientAllocation();
    error InsufficientBalance(uint256 available, uint256 required);
    error UnauthorizedSource(uint32 srcEid);
    error UnknownMessageType(bytes1 msgType);

    // ========== Constructor ==========

    /// @notice Initialize the CrossChainAssetController
    /// @param _endpoint LayerZero endpoint address
    /// @param _delegate Owner/delegate address
    /// @param _asset Underlying asset address (e.g., USDT)
    constructor(address _endpoint, address _delegate, address _asset) OApp(_endpoint, _delegate) Ownable(_delegate) {
        asset = IERC20(_asset);

        _grantRole(DEFAULT_ADMIN_ROLE, _delegate);
        _grantRole(KEEPER_ROLE, _delegate);
        _grantRole(REBALANCER_ROLE, _delegate);
    }

    // ========== View Functions ==========

    /// @notice Get protocol allocation for a chain and protocol
    /// @param eid Chain endpoint ID
    /// @param protocol Protocol address
    /// @return Allocated amount
    function protocolAllocation(uint32 eid, address protocol) external view returns (uint256) {
        return _protocolAllocations[eid][protocol];
    }

    /// @notice Check if a chain is supported
    /// @param eid Chain endpoint ID
    /// @return True if supported
    function isChainSupported(uint32 eid) external view returns (bool) {
        return _isChainSupported[eid];
    }

    /// @notice Get all supported chains
    /// @return Array of supported chain EIDs
    function getSupportedChains() external view returns (uint32[] memory) {
        return _supportedChains;
    }

    /// @notice Get total deployed assets across all chains
    /// @return Total deployed amount
    function getTotalDeployedAssets() external view returns (uint256) {
        return totalDeployed;
    }

    // ========== Keeper Functions ==========

    /// @notice Deploy assets to a protocol on a remote chain
    /// @param dstEid Destination chain endpoint ID
    /// @param amount Amount of assets to deploy
    /// @param protocol Protocol address on remote chain
    /// @param protocolName Protocol identifier (e.g., "aave", "compound")
    function deployToRemote(uint32 dstEid, uint256 amount, address protocol, string calldata protocolName)
        external
        payable
        onlyRole(KEEPER_ROLE)
        whenNotPaused
    {
        if (amount == 0) revert InvalidAmount();
        if (!_isChainSupported[dstEid]) revert ChainNotSupported();

        // Verify sufficient balance for tracking
        uint256 balance = asset.balanceOf(address(this));
        if (balance < amount) {
            revert InsufficientBalance(balance, amount);
        }

        // Build message payload
        bytes memory payload = abi.encode(MSG_DEPLOY, amount, protocol, protocolName);
        bytes memory options = _buildOptions(DEFAULT_GAS_LIMIT);

        // Send cross-chain message
        MessagingReceipt memory receipt =
            _lzSend(dstEid, payload, options, MessagingFee(msg.value, 0), payable(msg.sender));

        // Update tracking
        deployedAssets[dstEid] += amount;
        _protocolAllocations[dstEid][protocol] += amount;
        totalDeployed += amount;

        emit AssetDeployed(dstEid, protocol, protocolName, amount, receipt.guid);
    }

    /// @notice Withdraw assets from a protocol on a remote chain
    /// @param dstEid Destination chain endpoint ID
    /// @param amount Amount of assets to withdraw
    /// @param protocol Protocol address on remote chain
    /// @param protocolName Protocol identifier
    function withdrawFromRemote(uint32 dstEid, uint256 amount, address protocol, string calldata protocolName)
        external
        payable
        onlyRole(KEEPER_ROLE)
        whenNotPaused
    {
        if (amount == 0) revert InvalidAmount();
        if (!_isChainSupported[dstEid]) revert ChainNotSupported();
        if (_protocolAllocations[dstEid][protocol] < amount) revert InsufficientAllocation();

        // Build message payload
        bytes memory payload = abi.encode(MSG_WITHDRAW, amount, protocol, protocolName);
        bytes memory options = _buildOptions(DEFAULT_GAS_LIMIT);

        // Send cross-chain message
        MessagingReceipt memory receipt =
            _lzSend(dstEid, payload, options, MessagingFee(msg.value, 0), payable(msg.sender));

        // Update tracking (optimistic update - will be confirmed by remote)
        deployedAssets[dstEid] -= amount;
        _protocolAllocations[dstEid][protocol] -= amount;
        totalDeployed -= amount;

        emit WithdrawalRequested(dstEid, protocol, protocolName, amount, receipt.guid);
    }

    /// @notice Harvest yield from a protocol on a remote chain
    /// @param dstEid Destination chain endpoint ID
    /// @param protocol Protocol address on remote chain
    /// @param protocolName Protocol identifier
    function harvestYield(uint32 dstEid, address protocol, string calldata protocolName)
        external
        payable
        onlyRole(KEEPER_ROLE)
        whenNotPaused
    {
        if (!_isChainSupported[dstEid]) revert ChainNotSupported();

        // Build message payload
        bytes memory payload = abi.encode(MSG_HARVEST, protocol, protocolName);
        bytes memory options = _buildOptions(DEFAULT_GAS_LIMIT);

        // Send cross-chain message
        MessagingReceipt memory receipt =
            _lzSend(dstEid, payload, options, MessagingFee(msg.value, 0), payable(msg.sender));

        emit HarvestRequested(dstEid, protocol, protocolName, receipt.guid);
    }

    // ========== LayerZero Receive ==========

    /// @notice Handle messages from remote adapters
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
        // Validate source chain is a supported remote adapter
        if (!_isChainSupported[_origin.srcEid]) {
            revert UnauthorizedSource(_origin.srcEid);
        }

        bytes1 msgType = bytes1(_payload[0]);

        if (msgType == MSG_YIELD_REPORT) {
            // Yield report from remote
            (, uint256 yieldAmount) = abi.decode(_payload, (bytes1, uint256));
            emit YieldReceived(_origin.srcEid, yieldAmount);
        } else if (msgType == MSG_WITHDRAW_CONFIRM) {
            // Withdrawal confirmation
            (, uint256 amount) = abi.decode(_payload, (bytes1, uint256));
            emit WithdrawalConfirmed(_origin.srcEid, amount);
        } else {
            revert UnknownMessageType(msgType);
        }
    }

    // ========== Admin Functions ==========

    /// @notice Add a supported chain
    /// @param eid Chain endpoint ID
    /// @param adapter Remote adapter address
    function addSupportedChain(uint32 eid, address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_isChainSupported[eid]) revert ChainAlreadySupported();

        _isChainSupported[eid] = true;
        _supportedChains.push(eid);
        remoteAdapter[eid] = adapter;

        emit ChainAdded(eid, adapter);
    }

    /// @notice Remove a supported chain
    /// @param eid Chain endpoint ID
    function removeSupportedChain(uint32 eid) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_isChainSupported[eid]) revert ChainNotSupported();
        if (deployedAssets[eid] > 0) revert ChainHasDeployedAssets();

        _isChainSupported[eid] = false;
        delete remoteAdapter[eid];

        // Remove from array
        for (uint256 i = 0; i < _supportedChains.length; i++) {
            if (_supportedChains[i] == eid) {
                _supportedChains[i] = _supportedChains[_supportedChains.length - 1];
                _supportedChains.pop();
                break;
            }
        }

        emit ChainRemoved(eid);
    }

    /// @notice Update remote adapter address
    /// @param eid Chain endpoint ID
    /// @param adapter New adapter address
    function updateRemoteAdapter(uint32 eid, address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_isChainSupported[eid]) revert ChainNotSupported();
        remoteAdapter[eid] = adapter;
    }

    /// @notice Emergency withdraw assets
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    function emergencyWithdraw(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        asset.safeTransfer(to, amount);
        emit EmergencyWithdraw(to, amount);
    }

    /// @notice Pause the contract
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ========== Internal Functions ==========

    /// @notice Build LayerZero executor options
    /// @param gasLimit Gas limit for execution
    /// @return options Encoded options bytes
    function _buildOptions(uint128 gasLimit) internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(3), gasLimit, uint128(0));
    }
}
