// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICrossChainNAVReporter
/// @notice Unified interface for cross-chain NAV reporting
/// @dev Single source of truth — imported by both PPT.sol (read) and HubStargateComposer (write)
interface ICrossChainNAVReporter {
    // ========== Read Functions (used by PPT vault) ==========

    function getCrossChainValue() external view returns (uint256);
    function isStale(uint32 eid) external view returns (bool);
    function getChains() external view returns (uint32[] memory);
    function getChainPosition(uint32 eid)
        external
        view
        returns (uint256 satellite, uint256 deployed, uint256 pending, uint256 lastUpdate);

    // ========== Write Functions (used by HubStargateComposer) ==========

    function recordDeploy(uint32 eid, uint256 amount) external;
    function recordReturn(uint32 eid, uint256 amount, bool isYield) external;
    function updateSatelliteBalance(uint32 eid, uint256 balance) external;
}
