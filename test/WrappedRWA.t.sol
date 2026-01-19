// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WrappedRWA} from "../src/ppt/rwa/WrappedRWA.sol";
import {WrappedRWASingleAdapter} from "../src/ppt/rwa/WrappedRWAAdapter.sol";
import {WrappedRWAOracle} from "../src/ppt/rwa/WrappedRWAOracle.sol";

/// @title MockUSDT
contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

/// @title MockRWA
contract MockRWA is ERC20 {
    constructor() ERC20("Mock T-Bill", "TBILL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

/// @title MockOracle
contract MockOracle {
    uint256 public price = 1e18; // 默认 $1.00

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function getPrice(address) external view returns (uint256) {
        return price;
    }
}

/// @title WrappedRWATest
contract WrappedRWATest is Test {
    MockUSDT usdt;
    MockRWA rwa;
    MockOracle oracle;
    WrappedRWA wrapper;
    WrappedRWASingleAdapter adapter;
    WrappedRWAOracle wrapperOracle;

    address admin = address(0x1);
    address keeper = address(0x2);
    address vault = address(0x3);
    address user = address(0x4);

    uint256 constant PRECISION = 1e18;

    function setUp() public {
        // 部署 mock 合约
        usdt = new MockUSDT();
        rwa = new MockRWA();
        oracle = new MockOracle();

        // 部署 WrappedRWA
        vm.prank(admin);
        wrapper = new WrappedRWA(address(rwa), address(usdt), address(oracle), "Wrapped T-Bill", "wTBILL", admin);

        // 部署 Adapter
        vm.prank(admin);
        adapter = new WrappedRWASingleAdapter(address(usdt), address(wrapper), admin);

        // 部署 Oracle
        vm.prank(admin);
        wrapperOracle = new WrappedRWAOracle(admin, address(oracle));

        // 配置权限
        vm.startPrank(admin);
        wrapper.grantRole(wrapper.KEEPER_ROLE(), keeper);
        wrapper.grantRole(wrapper.VAULT_ROLE(), vault);
        wrapperOracle.registerWrapper(address(wrapper));
        // 为 adapter 授权 CALLER_ROLE（允许 test 合约调用）
        adapter.grantCallerRole(address(this));
        vm.stopPrank();

        // 给 vault 一些 USDT
        usdt.mint(vault, 10_000_000e18);
    }

    // ========== 购买流程测试 ==========

    function test_deposit_creates_pending_purchase() public {
        uint256 depositAmount = 1_000_000e18;

        // vault approve 并 deposit
        vm.startPrank(vault);
        usdt.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, vault);
        vm.stopPrank();

        // 验证状态
        assertEq(shares, depositAmount, "Should receive equal shares");
        assertEq(wrapper.balanceOf(vault), depositAmount, "Vault should have shares");
        assertEq(wrapper.pendingPurchaseUSDT(), depositAmount, "Pending should be recorded");
        assertEq(wrapper.totalAssets(), depositAmount, "Total assets should include pending");
    }

    function test_nav_stable_during_pending_purchase() public {
        uint256 depositAmount = 1_000_000e18;

        // deposit
        vm.startPrank(vault);
        usdt.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, vault);
        vm.stopPrank();

        // 记录初始 NAV
        uint256 initialTotalAssets = wrapper.totalAssets();
        uint256 initialSupply = wrapper.totalSupply();
        uint256 initialNav = (initialTotalAssets * PRECISION) / initialSupply;

        // 模拟价格下跌 5%
        oracle.setPrice(0.95e18);

        // 检查 NAV（成本价模式下应该不变）
        uint256 newTotalAssets = wrapper.totalAssets();
        uint256 newNav = (newTotalAssets * PRECISION) / initialSupply;

        // 因为使用成本价模式，totalAssets 应该不变
        assertEq(newTotalAssets, initialTotalAssets, "Total assets should remain stable");
        assertEq(newNav, initialNav, "NAV should remain stable");
    }

    function test_confirm_purchase() public {
        uint256 depositAmount = 1_000_000e18;

        // deposit
        vm.startPrank(vault);
        usdt.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, vault);
        vm.stopPrank();

        // 获取 txId
        uint256[] memory txIds = wrapper.getActiveTransactions();
        assertEq(txIds.length, 1, "Should have one active transaction");

        // 模拟 RWA 到账
        rwa.mint(address(wrapper), 1_000_000e18);

        // keeper 确认
        vm.prank(keeper);
        wrapper.confirmPurchase(txIds[0], 1_000_000e18);

        // 验证状态
        assertEq(wrapper.pendingPurchaseUSDT(), 0, "Pending should be cleared");
        assertEq(wrapper.getActiveTransactions().length, 0, "No active transactions");

        // totalAssets 现在由实际 RWA 支撑
        uint256 expectedValue = 1_000_000e18; // 1M tokens * $1.00
        assertEq(wrapper.totalAssets(), expectedValue, "Total assets from actual RWA");
    }

    function test_nav_change_after_confirm_with_price_movement() public {
        uint256 depositAmount = 1_000_000e18;

        // deposit
        vm.startPrank(vault);
        usdt.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, vault);
        vm.stopPrank();

        uint256[] memory txIds = wrapper.getActiveTransactions();

        // 价格下跌到 $0.95
        oracle.setPrice(0.95e18);

        // 因为价格低，实际能买到更多 token
        // 假设以 $0.95 成交，100万 USDT 能买到 ~105.26万 tokens
        uint256 actualTokens = 1_052_631e18;
        rwa.mint(address(wrapper), actualTokens);

        // 确认前的 totalAssets（成本价模式）
        uint256 assetsBefore = wrapper.totalAssets();
        assertEq(assetsBefore, depositAmount, "Before confirm: cost basis");

        // keeper 确认
        vm.prank(keeper);
        wrapper.confirmPurchase(txIds[0], actualTokens);

        // 确认后的 totalAssets（市场价）
        uint256 assetsAfter = wrapper.totalAssets();
        uint256 expectedAfter = (actualTokens * 0.95e18) / PRECISION;

        assertEq(assetsAfter, expectedAfter, "After confirm: market value");

        // NAV 变化
        uint256 navBefore = assetsBefore; // supply = 1M
        uint256 navAfter = assetsAfter; // supply = 1M

        console.log("NAV before confirm:", navBefore);
        console.log("NAV after confirm:", navAfter);
        console.log("NAV change:", int256(navAfter) - int256(navBefore));

        // 这个变化是合理的市场波动，不是因为非原子化导致的暴跌
    }

    // ========== 赎回流程测试 ==========

    function test_redeem_creates_pending_redemption() public {
        // 先 deposit 并 confirm
        uint256 depositAmount = 1_000_000e18;

        vm.startPrank(vault);
        usdt.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, vault);
        vm.stopPrank();

        rwa.mint(address(wrapper), 1_000_000e18);

        vm.prank(keeper);
        wrapper.confirmPurchase(1, 1_000_000e18);

        // 现在 redeem
        uint256 redeemShares = 500_000e18;

        vm.prank(vault);
        uint256 assets = wrapper.redeem(redeemShares, vault, vault);

        // 验证状态
        assertEq(wrapper.balanceOf(vault), 500_000e18, "Remaining shares");
        assertEq(wrapper.pendingRedemptionTokens(), 500_000e18, "Pending tokens locked");
        assertGt(wrapper.pendingRedemptionUSDT(), 0, "Pending USDT recorded");
    }

    function test_confirm_redemption() public {
        // setup: deposit, confirm purchase, redeem
        uint256 depositAmount = 1_000_000e18;

        vm.startPrank(vault);
        usdt.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, vault);
        vm.stopPrank();

        rwa.mint(address(wrapper), 1_000_000e18);
        vm.prank(keeper);
        wrapper.confirmPurchase(1, 1_000_000e18);

        vm.prank(vault);
        wrapper.redeem(500_000e18, vault, vault);

        // 获取赎回 txId
        uint256[] memory txIds = wrapper.getActiveTransactions();
        assertEq(txIds.length, 1, "Should have redemption transaction");

        // 记录 vault USDT 余额
        uint256 usdtBefore = usdt.balanceOf(vault);

        // 模拟 USDT 到账（从 OTC 交易）
        usdt.mint(address(wrapper), 500_000e18);

        // keeper 确认
        vm.prank(keeper);
        wrapper.confirmRedemption(txIds[0], 500_000e18);

        // 验证 USDT 到账
        uint256 usdtAfter = usdt.balanceOf(vault);
        assertEq(usdtAfter - usdtBefore, 500_000e18, "USDT received");

        // 验证 pending 清除
        assertEq(wrapper.pendingRedemptionTokens(), 0, "Pending tokens cleared");
        assertEq(wrapper.pendingRedemptionUSDT(), 0, "Pending USDT cleared");
    }

    // ========== Oracle 测试 ==========

    function test_wrapper_oracle_price() public {
        uint256 depositAmount = 1_000_000e18;

        // deposit
        vm.startPrank(vault);
        usdt.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, vault);
        vm.stopPrank();

        // 获取 oracle 价格
        uint256 price = wrapperOracle.getPrice(address(wrapper));

        // 价格应该是 1:1（totalAssets = totalSupply）
        assertEq(price, PRECISION, "Price should be 1:1");

        // confirm purchase 后
        rwa.mint(address(wrapper), 1_000_000e18);
        vm.prank(keeper);
        wrapper.confirmPurchase(1, 1_000_000e18);

        price = wrapperOracle.getPrice(address(wrapper));
        assertEq(price, PRECISION, "Price still 1:1 after confirm");

        // 如果底层资产升值
        oracle.setPrice(1.1e18); // $1.10

        price = wrapperOracle.getPrice(address(wrapper));
        assertEq(price, 1.1e18, "Price reflects underlying appreciation");
    }

    // ========== Adapter 测试 ==========

    function test_adapter_purchase() public {
        uint256 purchaseAmount = 1_000_000e18;

        // vault approve adapter
        vm.startPrank(vault);
        usdt.approve(address(adapter), purchaseAmount);
        vm.stopPrank();

        // 记录状态
        uint256 sharesBefore = wrapper.balanceOf(vault);

        // adapter purchase
        adapter.purchase(vault, purchaseAmount);

        // 验证 shares 到账
        uint256 sharesAfter = wrapper.balanceOf(vault);
        assertEq(sharesAfter - sharesBefore, purchaseAmount, "Shares received via adapter");
    }

    // ========== 取消测试 ==========

    function test_cancel_purchase() public {
        uint256 depositAmount = 1_000_000e18;

        vm.startPrank(vault);
        usdt.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, vault);
        vm.stopPrank();

        uint256 usdtBefore = usdt.balanceOf(vault);

        // 取消
        vm.prank(keeper);
        wrapper.cancelPurchase(1, "Market conditions changed");

        // USDT 应该退还给 initiator (vault)
        uint256 usdtAfter = usdt.balanceOf(vault);
        assertEq(usdtAfter - usdtBefore, depositAmount, "USDT refunded");

        // pending 清除
        assertEq(wrapper.pendingPurchaseUSDT(), 0, "Pending cleared");
    }

    // ========== 边界情况测试 ==========

    function test_price_deviation_check() public {
        uint256 depositAmount = 1_000_000e18;

        vm.startPrank(vault);
        usdt.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, vault);
        vm.stopPrank();

        // 模拟价格大幅波动（超过 5%）
        // 正常价格下预期收到 1M tokens
        // 但实际只收到 0.9M tokens（相当于价格上涨 11%）
        rwa.mint(address(wrapper), 900_000e18);

        // 应该 revert
        vm.prank(keeper);
        vm.expectRevert();
        wrapper.confirmPurchase(1, 900_000e18);
    }

    function test_transaction_expiry() public {
        uint256 depositAmount = 1_000_000e18;

        vm.startPrank(vault);
        usdt.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, vault);
        vm.stopPrank();

        // 快进超过过期时间
        vm.warp(block.timestamp + 8 days);

        rwa.mint(address(wrapper), 1_000_000e18);

        // 应该 revert（已过期）
        vm.prank(keeper);
        vm.expectRevert();
        wrapper.confirmPurchase(1, 1_000_000e18);
    }
}
