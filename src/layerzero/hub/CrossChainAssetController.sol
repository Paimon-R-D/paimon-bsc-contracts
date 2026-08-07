// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MessageCodec} from "../libraries/MessageCodec.sol";
import {LzOptionsLib} from "../libraries/LzOptionsLib.sol";

/// @title CrossChainAssetController
/// @notice Manages bridge-backed deploys plus Hub-to-remote withdraw and harvest commands
/// @dev Deployed on the Hub chain and paired with RemoteAssetGateway peers on satellite chains.
contract CrossChainAssetController is OApp, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // ========== Roles ==========

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ========== Constants ==========

    uint128 public constant DEFAULT_GAS_LIMIT = 500000;

    // ========== State Variables ==========

    /// @notice The underlying asset (e.g., USDT)
    IERC20 public immutable asset;

    /// @notice Confirmed assets deployed through the Stargate bridge pathway
    mapping(uint32 => uint256) public bridgedDeployedAssets;

    /// @notice Supported chains
    uint32[] internal _supportedChains;

    /// @notice Chain support status
    mapping(uint32 => bool) internal _isChainSupported;

    /// @notice Hub Stargate Composer for bridged deploys
    address public hubStargateComposer;

    /// @notice Total deployed via Stargate bridge across all chains
    uint256 public totalBridgedDeployed;

    // ========== Events ==========

    event AssetDeployed(
        uint32 indexed dstEid, address indexed protocol, string protocolName, uint256 amount, bytes32 guid
    );
    event WithdrawalRequested(
        uint32 indexed dstEid, address indexed protocol, string protocolName, uint256 amount, bytes32 guid
    );
    event HarvestRequested(uint32 indexed dstEid, address indexed protocol, string protocolName, bytes32 guid);
    event ChainAdded(uint32 indexed eid, address gateway);
    event ChainRemoved(uint32 indexed eid);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    event BridgedReturnRecorded(uint32 indexed srcEid, uint256 amount, bool isYield);

    // ========== Errors ==========

    error InvalidAmount();
    error ChainNotSupported();
    error ChainAlreadySupported();
    error ChainHasDeployedAssets();
    error InsufficientBalance(uint256 available, uint256 required);
    error UnauthorizedComposer(address caller);
    error InboundMessagesDisabled();

    // ========== Constructor ==========

    constructor(address _endpoint, address _delegate, address _asset) OApp(_endpoint, _delegate) Ownable(_delegate) {
        asset = IERC20(_asset);

        _grantRole(DEFAULT_ADMIN_ROLE, _delegate);
        _grantRole(KEEPER_ROLE, _delegate);
    }

    // ========== View Functions ==========

    function isChainSupported(uint32 eid) external view returns (bool) {
        return _isChainSupported[eid];
    }

    function getSupportedChains() external view returns (uint32[] memory) {
        return _supportedChains;
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

        bridgedDeployedAssets[dstEid] += bridgedAmount;
        totalBridgedDeployed += bridgedAmount;

        emit AssetDeployed(dstEid, protocol, protocolName, bridgedAmount, bytes32(0));
    }

    /// @notice Withdraw assets from a protocol on a remote chain
    function withdrawFromRemote(uint32 dstEid, uint256 amount, address protocol, string calldata protocolName)
        external
        payable
        onlyRole(KEEPER_ROLE)
        whenNotPaused
    {
        if (amount == 0) revert InvalidAmount();
        if (!_isChainSupported[dstEid]) revert ChainNotSupported();

        bytes memory payload = MessageCodec.encodeWithdrawAsset(amount, protocol, protocolName);
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(DEFAULT_GAS_LIMIT);

        MessagingReceipt memory receipt =
            _lzSend(
                dstEid,
                payload,
                options,
                MessagingFee({nativeFee: msg.value, lzTokenFee: 0}),
                payable(msg.sender)
            );

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
            _lzSend(
                dstEid,
                payload,
                options,
                MessagingFee({nativeFee: msg.value, lzTokenFee: 0}),
                payable(msg.sender)
            );

        emit HarvestRequested(dstEid, protocol, protocolName, receipt.guid);
    }

    // ========== LayerZero Receive ==========

    function _lzReceive(
        Origin calldata,
        bytes32, /*_guid*/
        bytes calldata,
        address, /*_executor*/
        bytes calldata /*_extraData*/
    )
        internal
        override
        pure
    {
        revert InboundMessagesDisabled();
    }

    // ========== Admin Functions ==========

    function addSupportedChain(uint32 eid, address gateway) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_isChainSupported[eid]) revert ChainAlreadySupported();

        _isChainSupported[eid] = true;
        _supportedChains.push(eid);
        _setPeer(eid, bytes32(uint256(uint160(gateway))));

        emit ChainAdded(eid, gateway);
    }

    function removeSupportedChain(uint32 eid) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_isChainSupported[eid]) revert ChainNotSupported();
        if (bridgedDeployedAssets[eid] > 0) revert ChainHasDeployedAssets();

        _isChainSupported[eid] = false;
        _setPeer(eid, bytes32(0));

        for (uint256 i = 0; i < _supportedChains.length; i++) {
            if (_supportedChains[i] == eid) {
                _supportedChains[i] = _supportedChains[_supportedChains.length - 1];
                _supportedChains.pop();
                break;
            }
        }

        emit ChainRemoved(eid);
    }

    function updateRemoteGateway(uint32 eid, address gateway) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_isChainSupported[eid]) revert ChainNotSupported();
        _setPeer(eid, bytes32(uint256(uint160(gateway))));
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

    function recordBridgedReturn(uint32 eid, uint256 amount, bool isYield) external {
        if (msg.sender != hubStargateComposer) revert UnauthorizedComposer(msg.sender);
        if (!_isChainSupported[eid]) revert ChainNotSupported();

        if (!isYield) {
            uint256 deployed = bridgedDeployedAssets[eid];
            uint256 deducted = deployed >= amount ? amount : deployed;
            bridgedDeployedAssets[eid] -= deducted;
            totalBridgedDeployed = totalBridgedDeployed >= deducted ? totalBridgedDeployed - deducted : 0;
        }

        emit BridgedReturnRecorded(eid, amount, isYield);
    }
}

interface IHubStargateComposer {
    function bridgeAndDeploy(uint32 dstEid, uint256 amount, address protocol, string calldata protocolName)
        external
        payable
        returns (uint256 bridgedAmount);
}
