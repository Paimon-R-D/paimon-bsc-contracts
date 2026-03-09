// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import 'forge-std/console.sol';
import {Script} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// PPT Core Contracts
import {PPT} from "../../src/ppt/PPT.sol";
import {AssetController} from "../../src/ppt/AssetController.sol";
import {RedemptionManager} from "../../src/ppt/RedemptionManager.sol";
import {PaimonOracleAdapter} from "../../src/adapters/PaimonOracleAdapter.sol";
import {PPTTypes} from "../../src/ppt/PPTTypes.sol";
import {BSCMainnet} from "./BSCMainnet.sol";

/// @title PPTAuditUpgrade
/// @notice 审计修复批量升级脚本 - PPT/AssetController/RedemptionManager/PaimonOracleAdapter
/// @dev 升级流程:
///      Step 1:  部署 4 个新 Implementation (deployer 执行)
///      Step 2~5:  生成每个合约的 schedule calldata (多签提交)
///      Step 6~9:  生成每个合约的 execute calldata (等待 1h 后多签提交)
///      Step 10: 生成角色授权 calldata (多签提交)
///      Step 11: Fork 验证全部升级
contract PPTAuditUpgrade is Script, Test {
    uint256 public privateKey;
    address public deployer;

    // =============================================================================
    // 已部署合约地址 (复用 BSCMainnet 配置)
    // =============================================================================

    address public constant PPT_PROXY = BSCMainnet.PAIMON_PPT;
    address public constant ASSET_CONTROLLER_PROXY = BSCMainnet.PAIMON_ASSET_CONTROLLER;
    address public constant REDEMPTION_MANAGER_PROXY = BSCMainnet.PAIMON_REDEMPTION_MANAGER;
    address public constant ORACLE_ADAPTER_PROXY = BSCMainnet.PAIMON_ORACLE_ADAPTER;

    address public constant TIMELOCK = BSCMainnet.PAIMON_TIMELOCK;
    address public constant ADMIN_SIG = BSCMainnet.ADMIN_SIG;
    address public constant USDT = BSCMainnet.USDT;

    uint256 public constant TIMELOCK_DELAY = 1 hours;

    // =============================================================================
    // Salt 常量 (每个合约独立 salt 防止冲突)
    // =============================================================================

    bytes32 public constant SALT_PPT = keccak256("audit-upgrade-ppt-v2");
    bytes32 public constant SALT_ASSET_CONTROLLER = keccak256("audit-upgrade-asset-controller-v2");
    bytes32 public constant SALT_REDEMPTION_MANAGER = keccak256("audit-upgrade-redemption-manager-v2");
    bytes32 public constant SALT_ORACLE_ADAPTER = keccak256("audit-upgrade-oracle-adapter-v2");

    // =============================================================================
    // 角色常量
    // =============================================================================

    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    // =============================================================================
    // 新实现地址 (Step 1 部署后填写)
    // =============================================================================

    address public NEW_PPT_IMPL = address(0x3D3a244bdb90C19680961645afc27312705DA0FA);
    address public NEW_ASSET_CONTROLLER_IMPL = address(0xB57A2327FAC0547D4F9de7265e07C65E6E3261E6);
    address public NEW_REDEMPTION_MANAGER_IMPL = address(0xDB5b2dF4C2a7AC118a1De3CB9d13eD5aCfF01c1F);
    address public NEW_ORACLE_ADAPTER_IMPL = address(0xB0b49355d0a9c2c115A433263E712357AF36AA7f);

    // =============================================================================
    // Setup
    // =============================================================================

    function setUp() public {
        privateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(privateKey);

        console.log("============================================");
        console.log("PPT Audit Upgrade Script - V2 Batch Upgrade");
        console.log("============================================");
        console.log("Deployer:", deployer);
        console.log("Timelock:", TIMELOCK);
        console.log("AdminSig:", ADMIN_SIG);
    }

    // =============================================================================
    // Step 1: 部署 4 个新 Implementation
    // =============================================================================

    function runStep1_DeployImplementations() public {
        vm.startBroadcast(privateKey);

        console.log("");
        console.log("=== Step 1: Deploy 4 New Implementations ===");
        console.log("");

        PPT pptImpl = new PPT();
        console.log("PPT Implementation:", address(pptImpl));

        AssetController acImpl = new AssetController();
        console.log("AssetController Implementation:", address(acImpl));

        RedemptionManager rmImpl = new RedemptionManager();
        console.log("RedemptionManager Implementation:", address(rmImpl));

        PaimonOracleAdapter oaImpl = new PaimonOracleAdapter();
        console.log("PaimonOracleAdapter Implementation:", address(oaImpl));

        vm.stopBroadcast();

        console.log("");
        console.log("IMPORTANT: Update implementation addresses in this script:");
        console.log("  NEW_PPT_IMPL =", address(pptImpl));
        console.log("  NEW_ASSET_CONTROLLER_IMPL =", address(acImpl));
        console.log("  NEW_REDEMPTION_MANAGER_IMPL =", address(rmImpl));
        console.log("  NEW_ORACLE_ADAPTER_IMPL =", address(oaImpl));
        console.log("");
        console.log("Next: Run Step 2~5 to generate schedule calldata");
    }

    // =============================================================================
    // Internal: 生成 schedule/execute calldata 的通用函数
    // =============================================================================

    function _buildUpgradeCalldata(address newImpl) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            UUPSUpgradeable.upgradeToAndCall.selector,
            newImpl,
            ""
        );
    }

    function _printScheduleCalldata(
        string memory name,
        address proxy,
        address newImpl,
        bytes32 salt
    ) internal pure {
        bytes memory upgradeCalldata = _buildUpgradeCalldata(newImpl);
        address target = proxy;
        uint256 value = 0;
        bytes32 predecessor = bytes32(0);

        bytes memory scheduleCalldata = abi.encodeWithSelector(
            TimelockController.schedule.selector,
            target, value, upgradeCalldata, predecessor, salt, TIMELOCK_DELAY
        );

        bytes32 operationId = keccak256(abi.encode(target, value, upgradeCalldata, predecessor, salt));

        console.log("");
        console.log("--- Schedule:", name, "---");
        console.log("Proxy:", proxy);
        console.log("New Impl:", newImpl);
        console.log("Salt:");
        console.logBytes32(salt);
        console.log("Operation ID:");
        console.logBytes32(operationId);
        console.log("");
        console.log("To: TimelockController", TIMELOCK);
        console.log("Value: 0");
        console.log("Data (schedule calldata):");
        console.logBytes(scheduleCalldata);
        console.log("");
        console.log("ABI params - schedule(address,uint256,bytes,bytes32,bytes32,uint256):");
        console.log("  target:", target);
        console.log("  value:", value);
        console.log("  payload:");
        console.logBytes(upgradeCalldata);
        console.log("  predecessor:");
        console.logBytes32(predecessor);
        console.log("  salt:");
        console.logBytes32(salt);
        console.log("  delay:", TIMELOCK_DELAY);
    }

    function _printExecuteCalldata(
        string memory name,
        address proxy,
        address newImpl,
        bytes32 salt
    ) internal pure {
        bytes memory upgradeCalldata = _buildUpgradeCalldata(newImpl);
        address target = proxy;
        uint256 value = 0;
        bytes32 predecessor = bytes32(0);

        bytes memory executeCalldata = abi.encodeWithSelector(
            TimelockController.execute.selector,
            target, value, upgradeCalldata, predecessor, salt
        );

        bytes32 operationId = keccak256(abi.encode(target, value, upgradeCalldata, predecessor, salt));

        console.log("");
        console.log("--- Execute:", name, "---");
        console.log("Operation ID:");
        console.logBytes32(operationId);
        console.log("");
        console.log("To: TimelockController", TIMELOCK);
        console.log("Value: 0");
        console.log("Data (execute calldata):");
        console.logBytes(executeCalldata);
        console.log("");
        console.log("ABI params - execute(address,uint256,bytes,bytes32,bytes32):");
        console.log("  target:", target);
        console.log("  value:", value);
        console.log("  payload:");
        console.logBytes(upgradeCalldata);
        console.log("  predecessor:");
        console.logBytes32(predecessor);
        console.log("  salt:");
        console.logBytes32(salt);
    }

    // =============================================================================
    // Step 2~5: 生成 4 个合约的 Schedule Calldata
    // =============================================================================

    function runStep2_SchedulePPT() public view {
        _requireImpl(NEW_PPT_IMPL, "NEW_PPT_IMPL");
        console.log("");
        console.log("=== Step 2: Schedule PPT Upgrade ===");
        _printScheduleCalldata("PPT", PPT_PROXY, NEW_PPT_IMPL, SALT_PPT);
        _printScheduleInstructions("Step 2");
    }

    function runStep3_ScheduleAssetController() public view {
        _requireImpl(NEW_ASSET_CONTROLLER_IMPL, "NEW_ASSET_CONTROLLER_IMPL");
        console.log("");
        console.log("=== Step 3: Schedule AssetController Upgrade ===");
        _printScheduleCalldata("AssetController", ASSET_CONTROLLER_PROXY, NEW_ASSET_CONTROLLER_IMPL, SALT_ASSET_CONTROLLER);
        _printScheduleInstructions("Step 3");
    }

    function runStep4_ScheduleRedemptionManager() public view {
        _requireImpl(NEW_REDEMPTION_MANAGER_IMPL, "NEW_REDEMPTION_MANAGER_IMPL");
        console.log("");
        console.log("=== Step 4: Schedule RedemptionManager Upgrade ===");
        _printScheduleCalldata("RedemptionManager", REDEMPTION_MANAGER_PROXY, NEW_REDEMPTION_MANAGER_IMPL, SALT_REDEMPTION_MANAGER);
        _printScheduleInstructions("Step 4");
    }

    function runStep5_ScheduleOracleAdapter() public view {
        _requireImpl(NEW_ORACLE_ADAPTER_IMPL, "NEW_ORACLE_ADAPTER_IMPL");
        console.log("");
        console.log("=== Step 5: Schedule PaimonOracleAdapter Upgrade ===");
        _printScheduleCalldata("PaimonOracleAdapter", ORACLE_ADAPTER_PROXY, NEW_ORACLE_ADAPTER_IMPL, SALT_ORACLE_ADAPTER);
        _printScheduleInstructions("Step 5");
    }

    /// @notice 一次性输出所有 4 个 schedule calldata
    function runStep2to5_ScheduleAll() public view {
        _requireAllImpl();
        console.log("");
        console.log("=== Step 2~5: Schedule All 4 Upgrades ===");
        _printScheduleCalldata("PPT", PPT_PROXY, NEW_PPT_IMPL, SALT_PPT);
        _printScheduleCalldata("AssetController", ASSET_CONTROLLER_PROXY, NEW_ASSET_CONTROLLER_IMPL, SALT_ASSET_CONTROLLER);
        _printScheduleCalldata("RedemptionManager", REDEMPTION_MANAGER_PROXY, NEW_REDEMPTION_MANAGER_IMPL, SALT_REDEMPTION_MANAGER);
        _printScheduleCalldata("PaimonOracleAdapter", ORACLE_ADAPTER_PROXY, NEW_ORACLE_ADAPTER_IMPL, SALT_ORACLE_ADAPTER);
        console.log("");
        console.log("Submit all 4 schedule TXs via Gnosis Safe Transaction Builder.");
        console.log("Wait 1 hour after all confirmed, then run Step 6~9.");
    }

    // =============================================================================
    // Step 6~9: 生成 4 个合约的 Execute Calldata
    // =============================================================================

    function runStep6_ExecutePPT() public view {
        _requireImpl(NEW_PPT_IMPL, "NEW_PPT_IMPL");
        console.log("");
        console.log("=== Step 6: Execute PPT Upgrade ===");
        _printExecuteCalldata("PPT", PPT_PROXY, NEW_PPT_IMPL, SALT_PPT);
        _printExecuteInstructions("Step 6");
    }

    function runStep7_ExecuteAssetController() public view {
        _requireImpl(NEW_ASSET_CONTROLLER_IMPL, "NEW_ASSET_CONTROLLER_IMPL");
        console.log("");
        console.log("=== Step 7: Execute AssetController Upgrade ===");
        _printExecuteCalldata("AssetController", ASSET_CONTROLLER_PROXY, NEW_ASSET_CONTROLLER_IMPL, SALT_ASSET_CONTROLLER);
        _printExecuteInstructions("Step 7");
    }

    function runStep8_ExecuteRedemptionManager() public view {
        _requireImpl(NEW_REDEMPTION_MANAGER_IMPL, "NEW_REDEMPTION_MANAGER_IMPL");
        console.log("");
        console.log("=== Step 8: Execute RedemptionManager Upgrade ===");
        _printExecuteCalldata("RedemptionManager", REDEMPTION_MANAGER_PROXY, NEW_REDEMPTION_MANAGER_IMPL, SALT_REDEMPTION_MANAGER);
        _printExecuteInstructions("Step 8");
    }

    function runStep9_ExecuteOracleAdapter() public view {
        _requireImpl(NEW_ORACLE_ADAPTER_IMPL, "NEW_ORACLE_ADAPTER_IMPL");
        console.log("");
        console.log("=== Step 9: Execute PaimonOracleAdapter Upgrade ===");
        _printExecuteCalldata("PaimonOracleAdapter", ORACLE_ADAPTER_PROXY, NEW_ORACLE_ADAPTER_IMPL, SALT_ORACLE_ADAPTER);
        _printExecuteInstructions("Step 9");
    }

    /// @notice 一次性输出所有 4 个 execute calldata
    function runStep6to9_ExecuteAll() public view {
        _requireAllImpl();
        console.log("");
        console.log("=== Step 6~9: Execute All 4 Upgrades ===");
        _printExecuteCalldata("PPT", PPT_PROXY, NEW_PPT_IMPL, SALT_PPT);
        _printExecuteCalldata("AssetController", ASSET_CONTROLLER_PROXY, NEW_ASSET_CONTROLLER_IMPL, SALT_ASSET_CONTROLLER);
        _printExecuteCalldata("RedemptionManager", REDEMPTION_MANAGER_PROXY, NEW_REDEMPTION_MANAGER_IMPL, SALT_REDEMPTION_MANAGER);
        _printExecuteCalldata("PaimonOracleAdapter", ORACLE_ADAPTER_PROXY, NEW_ORACLE_ADAPTER_IMPL, SALT_ORACLE_ADAPTER);
        console.log("");
        console.log("Submit all 4 execute TXs via Gnosis Safe Transaction Builder.");
        console.log("Then run Step 10 for role grants, and Step 11 to verify.");
    }

    // =============================================================================
    // Step 10: 升级后配置 - 角色授权
    // =============================================================================

    function runStep10_PrintGrantRoleCalldata() public view {
        console.log("");
        console.log("=== Step 10: Post-Upgrade Role Configuration ===");
        console.log("");

        // AssetController.grantRole(LIQUIDATOR_ROLE, RedemptionManager)
        bytes memory grantRoleCalldata = abi.encodeWithSelector(
            IAccessControl.grantRole.selector,
            LIQUIDATOR_ROLE,
            REDEMPTION_MANAGER_PROXY
        );

        console.log("--- Grant LIQUIDATOR_ROLE to RedemptionManager ---");
        console.log("To: AssetController Proxy");
        console.log("  ", ASSET_CONTROLLER_PROXY);
        console.log("Value: 0");
        console.log("");
        console.log("Data (grantRole calldata):");
        console.logBytes(grantRoleCalldata);
        console.log("");
        console.log("ABI params - grantRole(bytes32,address):");
        console.log("  role (LIQUIDATOR_ROLE):");
        console.logBytes32(LIQUIDATOR_ROLE);
        console.log("  account:", REDEMPTION_MANAGER_PROXY);
        console.log("");
        console.log("NOTE: This call must be made by an account with DEFAULT_ADMIN_ROLE");
        console.log("on AssetController. Submit via Gnosis Safe -> Transaction Builder.");
        console.log("");
        console.log("DELAYED_ADAPTER_ROLE is declared but NOT granted.");
        console.log("Configure it later when an adapter needs delayed settlement access.");
    }

    // =============================================================================
    // Step 11: Fork 验证
    // =============================================================================

    /// @notice ERC1967 implementation storage slot
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function runStep11_VerifyAll() public {
        _requireAllImpl();

        console.log("");
        console.log("=== Step 11: Fork Verification ===");
        console.log("");

        // --- 11a: 验证 Implementation 地址 ---
        console.log("--- 11a: Verify Implementation Addresses ---");
        _verifyImplementation("PPT", PPT_PROXY, NEW_PPT_IMPL);
        _verifyImplementation("AssetController", ASSET_CONTROLLER_PROXY, NEW_ASSET_CONTROLLER_IMPL);
        _verifyImplementation("RedemptionManager", REDEMPTION_MANAGER_PROXY, NEW_REDEMPTION_MANAGER_IMPL);
        _verifyImplementation("PaimonOracleAdapter", ORACLE_ADAPTER_PROXY, NEW_ORACLE_ADAPTER_IMPL);
        console.log("");

        // --- 11b: 验证 PPT deposit (N39 虚拟份额) ---
        console.log("--- 11b: Verify PPT Deposit (N39 Virtual Shares) ---");
        _verifyPPTDeposit();
        console.log("");

        // --- 11c: 验证 LIQUIDATOR_ROLE ---
        console.log("--- 11c: Verify LIQUIDATOR_ROLE ---");
        bool hasRole = IAccessControl(ASSET_CONTROLLER_PROXY).hasRole(
            LIQUIDATOR_ROLE,
            REDEMPTION_MANAGER_PROXY
        );
        console.log("RedemptionManager has LIQUIDATOR_ROLE:", hasRole);
        if (hasRole) {
            console.log("  PASS");
        } else {
            console.log("  FAIL - Run Step 10 to grant role");
        }
        console.log("");

        // --- 11d: 验证 OracleAdapter 新字段可访问 ---
        console.log("--- 11d: Verify OracleAdapter New Fields ---");
        PaimonOracleAdapter oracle = PaimonOracleAdapter(ORACLE_ADAPTER_PROXY);
        uint256 staleness = oracle.defaultStaleness();
        address pythAddr = oracle.pythOracle();
        console.log("defaultStaleness:", staleness);
        console.log("pythOracle:", pythAddr);
        console.log("  PASS - New storage fields accessible");
        console.log("");

        console.log("=== Verification Complete ===");
    }

    function _verifyImplementation(string memory name, address proxy, address expectedImpl) internal view {
        bytes32 implSlot = vm.load(proxy, _IMPLEMENTATION_SLOT);
        address actualImpl = address(uint160(uint256(implSlot)));
        bool match_ = actualImpl == expectedImpl;
        console.log(name, "implementation:", actualImpl);
        if (match_) {
            console.log("  PASS");
        } else {
            console.log("  FAIL - expected:", expectedImpl);
        }
    }

    function _verifyPPTDeposit() internal {
        PPT ppt = PPT(PPT_PROXY);
        address testUser = address(0xBEEF);
        deal(USDT, testUser, 1000e18);
        vm.startPrank(testUser);
        IERC20(USDT).approve(PPT_PROXY, type(uint256).max);

        // deposit 10 USDT (应成功)
        console.log("Test: deposit 10 USDT (should succeed)");
        try ppt.deposit(10e18, testUser) returns (uint256 shares) {
            console.log("  PASS - shares:", shares);
        } catch {
            console.log("  FAIL - deposit reverted");
        }

        // deposit 9 USDT (低于 MIN_DEPOSIT，应失败)
        console.log("Test: deposit 9 USDT (should fail, below MIN_DEPOSIT)");
        try ppt.deposit(9e18, testUser) returns (uint256) {
            console.log("  FAIL - should have reverted");
        } catch {
            console.log("  PASS - reverted as expected");
        }

        vm.stopPrank();
    }

    // =============================================================================
    // Helper: 检查所有 Timelock 操作状态
    // =============================================================================

    function checkAllTimelockStatus() public view {
        _requireAllImpl();

        console.log("");
        console.log("=== Check Timelock Status for All Operations ===");
        console.log("");

        _checkTimelockStatus("PPT", PPT_PROXY, NEW_PPT_IMPL, SALT_PPT);
        _checkTimelockStatus("AssetController", ASSET_CONTROLLER_PROXY, NEW_ASSET_CONTROLLER_IMPL, SALT_ASSET_CONTROLLER);
        _checkTimelockStatus("RedemptionManager", REDEMPTION_MANAGER_PROXY, NEW_REDEMPTION_MANAGER_IMPL, SALT_REDEMPTION_MANAGER);
        _checkTimelockStatus("PaimonOracleAdapter", ORACLE_ADAPTER_PROXY, NEW_ORACLE_ADAPTER_IMPL, SALT_ORACLE_ADAPTER);
    }

    function _checkTimelockStatus(
        string memory name,
        address proxy,
        address newImpl,
        bytes32 salt
    ) internal view {
        bytes memory upgradeCalldata = _buildUpgradeCalldata(newImpl);
        bytes32 predecessor = bytes32(0);
        bytes32 operationId = keccak256(abi.encode(proxy, uint256(0), upgradeCalldata, predecessor, salt));

        TimelockController timelock = TimelockController(payable(TIMELOCK));

        bool isOp = timelock.isOperation(operationId);
        bool isPending = timelock.isOperationPending(operationId);
        bool isReady = timelock.isOperationReady(operationId);
        bool isDone = timelock.isOperationDone(operationId);

        console.log("---", name, "---");
        console.log("  Operation ID:");
        console.logBytes32(operationId);

        if (!isOp) {
            console.log("  Status: NOT SCHEDULED");
        } else if (isPending && !isReady) {
            uint256 ts = timelock.getTimestamp(operationId);
            console.log("  Status: PENDING");
            console.log("  Ready at:", ts);
            if (ts > block.timestamp) {
                console.log("  Remaining:", ts - block.timestamp, "seconds");
            }
        } else if (isReady) {
            console.log("  Status: READY TO EXECUTE");
        } else if (isDone) {
            console.log("  Status: DONE");
        }
        console.log("");
    }

    // =============================================================================
    // Internal Helpers
    // =============================================================================

    function _requireImpl(address impl, string memory name) internal pure {
        require(impl != address(0), string.concat("Set ", name, " first!"));
    }

    function _requireAllImpl() internal view {
        _requireImpl(NEW_PPT_IMPL, "NEW_PPT_IMPL");
        _requireImpl(NEW_ASSET_CONTROLLER_IMPL, "NEW_ASSET_CONTROLLER_IMPL");
        _requireImpl(NEW_REDEMPTION_MANAGER_IMPL, "NEW_REDEMPTION_MANAGER_IMPL");
        _requireImpl(NEW_ORACLE_ADAPTER_IMPL, "NEW_ORACLE_ADAPTER_IMPL");
    }

    function _printScheduleInstructions(string memory step) internal pure {
        console.log("");
        console.log(step, "Complete. Submit via Gnosis Safe Transaction Builder:");
        console.log("  To:", TIMELOCK);
        console.log("  Use the schedule calldata above.");
    }

    function _printExecuteInstructions(string memory step) internal pure {
        console.log("");
        console.log(step, "Complete. Ensure 1h has passed since schedule.");
        console.log("  Submit via Gnosis Safe Transaction Builder:");
        console.log("  To:", TIMELOCK);
        console.log("  Use the execute calldata above.");
    }
}
