// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MessageCodec} from "../libraries/MessageCodec.sol";
import {LzOptionsLib} from "../libraries/LzOptionsLib.sol";

/// @title CrossChainAssetController
/// @notice Manages cross-chain asset deployment commands to DeFi protocols (Aave, Compound, etc.)
/// @dev Deployed on BSC Hub chain, sends commands to remote chain adapters.
///      P0-9 FIX: Uses pending state for deploy/withdraw, confirmed via cross-chain messages.
contract CrossChainAssetController is OApp, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== Roles ==========

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    // ========== Constants ==========

    uint128 public constant DEFAULT_GAS_LIMIT = 500000;

    // ========== State Variables ==========

    /// @notice The underlying asset (e.g., USDT)
    IERC20 public immutable asset;

    /// @notice Confirmed deployed assets per chain
    mapping(uint32 => uint256) public deployedAssets;

    /// @notice Pending deploy amounts per chain (not yet confirmed)
    mapping(uint32 => uint256) public pendingDeploys;

    /// @notice Pending withdraw amounts per chain (not yet confirmed)
    mapping(uint32 => uint256) public pendingWithdraws;

    /// @notice Protocol allocation per chain per protocol
    mapping(uint32 => mapping(address => uint256)) internal _protocolAllocations;

    /// @notice Remote adapter address per chain
    mapping(uint32 => address) public remoteAdapter;

    /// @notice Supported chains
    uint32[] internal _supportedChains;

    /// @notice Chain support status
    mapping(uint32 => bool) internal _isChainSupported;

    /// @notice Hub Stargate Composer for bridged deploys
    address public hubStargateComposer;

    /// @notice Total deployed across all chains (for quick lookup)
    uint256 public totalDeployed;

    // ========== Events ==========

    event AssetDeployed(
        uint32 indexed dstEid, address indexed protocol, string protocolName, uint256 amount, bytes32 guid
    );
    event WithdrawalRequested(
        uint32 indexed dstEid, address indexed protocol, string protocolName, uint256 amount, bytes32 guid
    );
    event HarvestRequested(uint32 indexed dstEid, address indexed protocol, string protocolName, bytes32 guid);
    event YieldReceived(uint32 indexed srcEid, uint256 yieldAmount);
    event WithdrawalConfirmed(uint32 indexed srcEid, uint256 amount);
    event ChainAdded(uint32 indexed eid, address adapter);
    event ChainRemoved(uint32 indexed eid);
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

    constructor(address _endpoint, address _delegate, address _asset) OApp(_endpoint, _delegate) Ownable(_delegate) {
        asset = IERC20(_asset);

        _grantRole(DEFAULT_ADMIN_ROLE, _delegate);
        _grantRole(KEEPER_ROLE, _delegate);
        _grantRole(REBALANCER_ROLE, _delegate);
    }

    // ========== View Functions ==========

    function protocolAllocation(uint32 eid, address protocol) external view returns (uint256) {
        return _protocolAllocations[eid][protocol];
    }

    function isChainSupported(uint32 eid) external view returns (bool) {
        return _isChainSupported[eid];
    }

    function getSupportedChains() external view returns (uint32[] memory) {
        return _supportedChains;
    }

    function getTotalDeployedAssets() external view returns (uint256) {
        return totalDeployed;
    }

    // ========== Keeper Functions ==========

    /// @notice Deploy assets via Stargate bridge (USDT + deploy command in single tx)
    /// @dev Preferred method: bridges actual USDT to remote chain
    function deployViaBridge(uint32 dstEid, uint256 amount, address protocol, string calldata protocolName)
        external
        payable
        onlyRole(KEEPER_ROLE)
        whenNotPaused
    {
        if (amount == 0) revert InvalidAmount();
        if (!_isChainSupported[dstEid]) revert ChainNotSupported();
        if (hubStargateComposer == address(0)) revert ChainNotSupported();

        uint256 balance = asset.balanceOf(address(this));
        if (balance < amount) {
            revert InsufficientBalance(balance, amount);
        }

        // Transfer USDT to composer and bridge
        asset.safeTransfer(hubStargateComposer, amount);
        uint256 bridgedAmount = IHubStargateComposer(hubStargateComposer).bridgeAndDeploy{value: msg.value}(
            dstEid, amount, protocol, protocolName
        );

        // Record accounting
        pendingDeploys[dstEid] += bridgedAmount;
        _protocolAllocations[dstEid][protocol] += bridgedAmount;
        deployedAssets[dstEid] += bridgedAmount;
        totalDeployed += bridgedAmount;

        emit AssetDeployed(dstEid, protocol, protocolName, bridgedAmount, bytes32(0));
    }

    /// @notice Legacy deploy via OApp message only (no asset bridge)
    /// @dev DEPRECATED: Does not bridge actual assets. Prefer deployViaBridge.
    ///      Only sends a command message; remote adapter must already have tokens.
    function deployToRemote(uint32 dstEid, uint256 amount, address protocol, string calldata protocolName)
        external
        payable
        onlyRole(KEEPER_ROLE)
        whenNotPaused
    {
        if (amount == 0) revert InvalidAmount();
        if (!_isChainSupported[dstEid]) revert ChainNotSupported();

        bytes memory payload = MessageCodec.encodeDeploy(amount, protocol, protocolName);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);

        MessagingReceipt memory receipt =
            _lzSend(dstEid, payload, options, MessagingFee(msg.value, 0), payable(msg.sender));

        // Only record pending deploy (not yet confirmed)
        pendingDeploys[dstEid] += amount;
        _protocolAllocations[dstEid][protocol] += amount;

        emit AssetDeployed(dstEid, protocol, protocolName, amount, receipt.guid);
    }

    /// @notice Withdraw assets from a protocol on a remote chain
    /// @dev P0-9 FIX: Records to pendingWithdraws, settles on MSG_WITHDRAW_CONFIRM
    function withdrawFromRemote(uint32 dstEid, uint256 amount, address protocol, string calldata protocolName)
        external
        payable
        onlyRole(KEEPER_ROLE)
        whenNotPaused
    {
        if (amount == 0) revert InvalidAmount();
        if (!_isChainSupported[dstEid]) revert ChainNotSupported();
        if (_protocolAllocations[dstEid][protocol] < amount) revert InsufficientAllocation();

        bytes memory payload = MessageCodec.encodeWithdrawAsset(amount, protocol, protocolName);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);

        MessagingReceipt memory receipt =
            _lzSend(dstEid, payload, options, MessagingFee(msg.value, 0), payable(msg.sender));

        // Record as pending withdrawal
        pendingWithdraws[dstEid] += amount;
        _protocolAllocations[dstEid][protocol] -= amount;

        emit WithdrawalRequested(dstEid, protocol, protocolName, amount, receipt.guid);
    }

    /// @notice Harvest yield from a protocol on a remote chain
    function harvestYield(uint32 dstEid, address protocol, string calldata protocolName)
        external
        payable
        onlyRole(KEEPER_ROLE)
        whenNotPaused
    {
        if (!_isChainSupported[dstEid]) revert ChainNotSupported();

        bytes memory payload = MessageCodec.encodeHarvest(protocol, protocolName);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);

        MessagingReceipt memory receipt =
            _lzSend(dstEid, payload, options, MessagingFee(msg.value, 0), payable(msg.sender));

        emit HarvestRequested(dstEid, protocol, protocolName, receipt.guid);
    }

    // ========== LayerZero Receive ==========

    /// @notice Handle messages from remote adapters
    /// @dev P0-2 FIX: Uses MessageCodec for consistent decode (payload[1:])
    ///      P0-9 FIX: MSG_WITHDRAW_CONFIRM settles pending withdrawals
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
        if (!_isChainSupported[_origin.srcEid]) {
            revert UnauthorizedSource(_origin.srcEid);
        }

        bytes1 msgType = MessageCodec.decodeMsgType(_payload);

        if (msgType == MessageCodec.MSG_YIELD_REPORT) {
            uint256 yieldAmount = MessageCodec.decodeAmount(_payload);
            emit YieldReceived(_origin.srcEid, yieldAmount);
        } else if (msgType == MessageCodec.MSG_WITHDRAW_CONFIRM) {
            uint256 amount = MessageCodec.decodeAmount(_payload);
            // Settle pending withdrawal (safe subtraction to prevent nonce blocking)
            if (pendingWithdraws[_origin.srcEid] >= amount) {
                pendingWithdraws[_origin.srcEid] -= amount;
            } else {
                pendingWithdraws[_origin.srcEid] = 0;
            }
            // Safe subtraction for deployedAssets
            uint256 deployed = deployedAssets[_origin.srcEid];
            uint256 deducted = deployed >= amount ? amount : deployed;
            deployedAssets[_origin.srcEid] -= deducted;
            totalDeployed = totalDeployed >= deducted ? totalDeployed - deducted : 0;
            emit WithdrawalConfirmed(_origin.srcEid, amount);
        } else {
            revert UnknownMessageType(msgType);
        }
    }

    // ========== Admin Functions ==========

    function addSupportedChain(uint32 eid, address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_isChainSupported[eid]) revert ChainAlreadySupported();

        _isChainSupported[eid] = true;
        _supportedChains.push(eid);
        remoteAdapter[eid] = adapter;

        emit ChainAdded(eid, adapter);
    }

    function removeSupportedChain(uint32 eid) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_isChainSupported[eid]) revert ChainNotSupported();
        if (deployedAssets[eid] > 0) revert ChainHasDeployedAssets();

        _isChainSupported[eid] = false;
        delete remoteAdapter[eid];

        for (uint256 i = 0; i < _supportedChains.length; i++) {
            if (_supportedChains[i] == eid) {
                _supportedChains[i] = _supportedChains[_supportedChains.length - 1];
                _supportedChains.pop();
                break;
            }
        }

        emit ChainRemoved(eid);
    }

    function updateRemoteAdapter(uint32 eid, address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_isChainSupported[eid]) revert ChainNotSupported();
        remoteAdapter[eid] = adapter;
    }

    function emergencyWithdraw(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        asset.safeTransfer(to, amount);
        emit EmergencyWithdraw(to, amount);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function setHubStargateComposer(address _composer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hubStargateComposer = _composer;
    }
}

interface IHubStargateComposer {
    function bridgeAndDeploy(uint32 dstEid, uint256 amount, address protocol, string calldata protocolName)
        external
        payable
        returns (uint256 bridgedAmount);
}
