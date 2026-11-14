// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

interface IPPTOFTAdapterUpgrade {
    function setNavReporter(address _navReporter) external;
    function setCreditManager(address _creditManager) external;
    function setVault(address _vault) external;
    function setRedemptionManager(address _redemptionManager) external;
    function setHubStargateComposer(address _composer) external;
    function totalMirroredShares() external view returns (uint256);
}

interface IGrantable {
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title LayerZero M04 Upgrade Script
/// @notice Mechanical post-deployment step for PR1 (audit finding M04).
///         Grants operator/reporter roles that the new `PPTOFTAdapter` needs to
///         execute `_handleSatelliteInstantWithdraw` (mirror burn + NAV debit).
///
/// @dev Usage: `forge script LayerZeroM04Upgrade --rpc-url $BSC_RPC --broadcast --sender $MULTISIG`
///      Required env vars:
///        - PPT_ADAPTER: address of the newly deployed PPTOFTAdapter
///        - PPT_VAULT: PPT token address (source of OPERATOR_ROLE)
///        - NAV_REPORTER: CrossChainNAVReporter address
///        - CREDIT_MANAGER, REDEMPTION_MANAGER, HUB_COMPOSER: dependency addresses
///
///      Run ONLY after confirming satellite pending queues are drained (see
///      `docs/AUDIT_FIX_PLAN_2026Q2.md` → PR1 Deployment Checklist).
contract LayerZeroM04Upgrade is Script {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");

    function run() external {
        address adapter = vm.envAddress("PPT_ADAPTER");
        address vault = vm.envAddress("PPT_VAULT");
        address navReporter = vm.envAddress("NAV_REPORTER");
        address creditManager = vm.envAddress("CREDIT_MANAGER");
        address redemptionManager = vm.envAddress("REDEMPTION_MANAGER");
        address hubComposer = vm.envAddress("HUB_COMPOSER");

        vm.startBroadcast();

        // 1. Grant OPERATOR_ROLE on PPT vault (required for lockShares + burnLockedShares)
        if (!IGrantable(vault).hasRole(OPERATOR_ROLE, adapter)) {
            IGrantable(vault).grantRole(OPERATOR_ROLE, adapter);
            console.log("Granted PPT.OPERATOR_ROLE to adapter:", adapter);
        }

        // 2. Grant REPORTER_ROLE on NAV reporter (required for recordSatelliteDebit/Credit)
        if (!IGrantable(navReporter).hasRole(REPORTER_ROLE, adapter)) {
            IGrantable(navReporter).grantRole(REPORTER_ROLE, adapter);
            console.log("Granted NAVReporter.REPORTER_ROLE to adapter:", adapter);
        }

        // 3. Wire adapter dependencies (idempotent — setters don't revert on same address)
        IPPTOFTAdapterUpgrade(adapter).setCreditManager(creditManager);
        IPPTOFTAdapterUpgrade(adapter).setVault(vault);
        IPPTOFTAdapterUpgrade(adapter).setRedemptionManager(redemptionManager);
        IPPTOFTAdapterUpgrade(adapter).setHubStargateComposer(hubComposer);
        IPPTOFTAdapterUpgrade(adapter).setNavReporter(navReporter);

        vm.stopBroadcast();

        // 4. Print post-upgrade invariant check
        console.log("Post-upgrade totalMirroredShares:", IPPTOFTAdapterUpgrade(adapter).totalMirroredShares());
        console.log("Expected initial value: 0 for fresh deploy, else migrated PPT balance of adapter");
    }
}
