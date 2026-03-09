// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title CrossChainNAVReporter
/// @notice Aggregates cross-chain asset positions for PPT vault NAV calculation
/// @dev Data sources:
///      - HubStargateComposer: deploy/return events update remoteDeployments
///      - Credit system: satellite pool balances
///      - Keeper: periodic forced sync
contract CrossChainNAVReporter is AccessControl {
    // ========== Roles ==========

    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");

    // ========== State Variables ==========

    /// @notice Satellite LiquidityPool USDT balances per chain
    mapping(uint32 => uint256) public satelliteBalances;

    /// @notice Remote DeFi deployment values per chain
    mapping(uint32 => uint256) public remoteDeployments;

    /// @notice Pending (in-transit) amounts per chain
    mapping(uint32 => uint256) public pendingTransits;

    /// @notice Last update timestamp per chain
    mapping(uint32 => uint256) public lastUpdateTime;

    /// @notice Supported chain list
    uint32[] internal _chains;
    mapping(uint32 => bool) internal _isChain;

    /// @notice Maximum age before data is considered stale (seconds)
    uint256 public stalePeriod = 7200; // 2 hours default

    // ========== Events ==========

    event SatelliteBalanceUpdated(uint32 indexed eid, uint256 oldBalance, uint256 newBalance);
    event RemoteDeploymentUpdated(uint32 indexed eid, uint256 oldValue, uint256 newValue);
    event DeployRecorded(uint32 indexed eid, uint256 amount);
    event ReturnRecorded(uint32 indexed eid, uint256 amount, bool isYield);
    event ChainAdded(uint32 indexed eid);
    event ChainRemoved(uint32 indexed eid);
    event StalePeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    // ========== Errors ==========

    error ChainNotSupported(uint32 eid);
    error ChainAlreadySupported(uint32 eid);
    error ZeroAddress();

    // ========== Constructor ==========

    constructor(address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(REPORTER_ROLE, _admin);
    }

    // ========== View Functions ==========

    /// @notice Get total cross-chain value for NAV calculation
    /// @return total Sum of all satellite balances + remote deployments
    function getCrossChainValue() external view returns (uint256 total) {
        for (uint256 i = 0; i < _chains.length; i++) {
            uint32 eid = _chains[i];
            total += satelliteBalances[eid];
            total += remoteDeployments[eid];
        }
    }

    /// @notice Check if a chain's data is stale
    function isStale(uint32 eid) external view returns (bool) {
        if (!_isChain[eid]) return true;
        return block.timestamp - lastUpdateTime[eid] > stalePeriod;
    }

    /// @notice Get all supported chains
    function getChains() external view returns (uint32[] memory) {
        return _chains;
    }

    /// @notice Get detailed position for a chain
    function getChainPosition(uint32 eid)
        external
        view
        returns (uint256 satellite, uint256 deployed, uint256 pending, uint256 lastUpdate)
    {
        return (
            satelliteBalances[eid],
            remoteDeployments[eid],
            pendingTransits[eid],
            lastUpdateTime[eid]
        );
    }

    // ========== Reporter Functions ==========

    /// @notice Update satellite LiquidityPool balance
    function updateSatelliteBalance(uint32 eid, uint256 balance) external onlyRole(REPORTER_ROLE) {
        if (!_isChain[eid]) revert ChainNotSupported(eid);
        uint256 old = satelliteBalances[eid];
        satelliteBalances[eid] = balance;
        lastUpdateTime[eid] = block.timestamp;
        emit SatelliteBalanceUpdated(eid, old, balance);
    }

    /// @notice Update remote deployment value
    function updateRemoteDeployment(uint32 eid, uint256 value) external onlyRole(REPORTER_ROLE) {
        if (!_isChain[eid]) revert ChainNotSupported(eid);
        uint256 old = remoteDeployments[eid];
        remoteDeployments[eid] = value;
        lastUpdateTime[eid] = block.timestamp;
        emit RemoteDeploymentUpdated(eid, old, value);
    }

    /// @notice Record a new deployment (called by HubStargateComposer)
    function recordDeploy(uint32 eid, uint256 amount) external onlyRole(REPORTER_ROLE) {
        if (!_isChain[eid]) revert ChainNotSupported(eid);
        remoteDeployments[eid] += amount;
        lastUpdateTime[eid] = block.timestamp;
        emit DeployRecorded(eid, amount);
    }

    event AccountingDiscrepancy(uint32 indexed eid, uint256 returnAmount, uint256 trackedDeployments);

    /// @notice Record a return from remote (withdrawal or yield)
    function recordReturn(uint32 eid, uint256 amount, bool isYield) external onlyRole(REPORTER_ROLE) {
        if (!_isChain[eid]) revert ChainNotSupported(eid);

        if (!isYield) {
            if (remoteDeployments[eid] >= amount) {
                remoteDeployments[eid] -= amount;
            } else {
                emit AccountingDiscrepancy(eid, amount, remoteDeployments[eid]);
                remoteDeployments[eid] = 0;
            }
        }
        // Yield doesn't reduce deployment value (it's additional return)

        lastUpdateTime[eid] = block.timestamp;
        emit ReturnRecorded(eid, amount, isYield);
    }

    // ========== Admin Functions ==========

    function addChain(uint32 eid) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_isChain[eid]) revert ChainAlreadySupported(eid);
        _isChain[eid] = true;
        _chains.push(eid);
        emit ChainAdded(eid);
    }

    function removeChain(uint32 eid) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_isChain[eid]) revert ChainNotSupported(eid);
        _isChain[eid] = false;
        delete satelliteBalances[eid];
        delete remoteDeployments[eid];
        delete pendingTransits[eid];
        delete lastUpdateTime[eid];

        for (uint256 i = 0; i < _chains.length; i++) {
            if (_chains[i] == eid) {
                _chains[i] = _chains[_chains.length - 1];
                _chains.pop();
                break;
            }
        }
        emit ChainRemoved(eid);
    }

    function setStalePeriod(uint256 _stalePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit StalePeriodUpdated(stalePeriod, _stalePeriod);
        stalePeriod = _stalePeriod;
    }
}
