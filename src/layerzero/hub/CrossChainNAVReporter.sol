// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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

    /// @notice Cached total cross-chain value to avoid linear iteration on hot paths
    uint256 public totalCrossChainValue;

    /// @notice Timestamp when the reporter last committed a full cross-chain snapshot
    uint256 public lastGlobalSyncTime;

    /// @notice Supported chain list
    uint32[] internal _chains;
    mapping(uint32 => bool) internal _isChain;

    /// @notice Maximum age before data is considered stale (seconds)
    uint256 public stalePeriod = 7200; // 2 hours default

    /// @notice When enabled, reads revert until the off-chain reporter commits a fresh global snapshot
    bool public enforceGlobalFreshness;

    // ========== Events ==========

    event SatelliteBalanceUpdated(uint32 indexed eid, uint256 oldBalance, uint256 newBalance);
    event RemoteDeploymentUpdated(uint32 indexed eid, uint256 oldValue, uint256 newValue);
    event DeployRecorded(uint32 indexed eid, uint256 amount);
    event ReturnRecorded(uint32 indexed eid, uint256 amount, bool isYield);
    event ChainAdded(uint32 indexed eid);
    event ChainRemoved(uint32 indexed eid);
    event StalePeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event GlobalSyncCommitted(uint256 timestamp);
    event GlobalFreshnessEnforcementUpdated(bool oldValue, bool newValue);

    // ========== Errors ==========

    error ChainNotSupported(uint32 eid);
    error ChainAlreadySupported(uint32 eid);
    error ZeroAddress();
    error LengthMismatch(uint256 expected, uint256 actual);
    error EmptyArray();
    error StaleCrossChainValue(uint256 lastGlobalSyncTime, uint256 stalePeriod);

    // ========== Constructor ==========

    constructor(address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(REPORTER_ROLE, _admin);
    }

    // ========== View Functions ==========

    /// @notice Get total cross-chain value for NAV calculation
    /// @return total Sum of all satellite balances + remote deployments
    function getCrossChainValue() external view returns (uint256 total) {
        if (enforceGlobalFreshness && _chains.length > 0) {
            if (lastGlobalSyncTime == 0 || block.timestamp - lastGlobalSyncTime > stalePeriod) {
                revert StaleCrossChainValue(lastGlobalSyncTime, stalePeriod);
            }
        }
        return totalCrossChainValue;
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
        totalCrossChainValue = totalCrossChainValue + balance - old;
        lastUpdateTime[eid] = block.timestamp;
        emit SatelliteBalanceUpdated(eid, old, balance);
    }

    /// @notice Update remote deployment value
    function updateRemoteDeployment(uint32 eid, uint256 value) external onlyRole(REPORTER_ROLE) {
        if (!_isChain[eid]) revert ChainNotSupported(eid);
        uint256 old = remoteDeployments[eid];
        remoteDeployments[eid] = value;
        totalCrossChainValue = totalCrossChainValue + value - old;
        lastUpdateTime[eid] = block.timestamp;
        emit RemoteDeploymentUpdated(eid, old, value);
    }

    /// @notice Record a new deployment (called by HubStargateComposer)
    function recordDeploy(uint32 eid, uint256 amount) external onlyRole(REPORTER_ROLE) {
        if (!_isChain[eid]) revert ChainNotSupported(eid);
        remoteDeployments[eid] += amount;
        totalCrossChainValue += amount;
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
                totalCrossChainValue -= amount;
            } else {
                totalCrossChainValue -= remoteDeployments[eid];
                emit AccountingDiscrepancy(eid, amount, remoteDeployments[eid]);
                remoteDeployments[eid] = 0;
            }
        }
        // Yield doesn't reduce deployment value (it's additional return)

        lastUpdateTime[eid] = block.timestamp;
        emit ReturnRecorded(eid, amount, isYield);
    }

    function batchSyncChainPositions(
        uint32[] calldata eids,
        uint256[] calldata satelliteValues,
        uint256[] calldata remoteValues
    ) external onlyRole(REPORTER_ROLE) {
        if (eids.length == 0) revert EmptyArray();
        if (eids.length != satelliteValues.length) revert LengthMismatch(eids.length, satelliteValues.length);
        if (eids.length != remoteValues.length) revert LengthMismatch(eids.length, remoteValues.length);

        for (uint256 i = 0; i < eids.length; i++) {
            uint32 eid = eids[i];
            if (!_isChain[eid]) revert ChainNotSupported(eid);

            uint256 oldSatellite = satelliteBalances[eid];
            uint256 oldRemote = remoteDeployments[eid];
            uint256 newSatellite = satelliteValues[i];
            uint256 newRemote = remoteValues[i];

            satelliteBalances[eid] = newSatellite;
            remoteDeployments[eid] = newRemote;
            totalCrossChainValue = totalCrossChainValue + newSatellite + newRemote - oldSatellite - oldRemote;
            lastUpdateTime[eid] = block.timestamp;

            emit SatelliteBalanceUpdated(eid, oldSatellite, newSatellite);
            emit RemoteDeploymentUpdated(eid, oldRemote, newRemote);
        }

        lastGlobalSyncTime = block.timestamp;
        emit GlobalSyncCommitted(lastGlobalSyncTime);
    }

    function commitGlobalSync() external onlyRole(REPORTER_ROLE) {
        lastGlobalSyncTime = block.timestamp;
        emit GlobalSyncCommitted(lastGlobalSyncTime);
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
        totalCrossChainValue -= satelliteBalances[eid] + remoteDeployments[eid];
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

    function setEnforceGlobalFreshness(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit GlobalFreshnessEnforcementUpdated(enforceGlobalFreshness, enabled);
        enforceGlobalFreshness = enabled;
    }
}
