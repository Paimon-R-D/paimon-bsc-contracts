// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LiquidityPool} from "../../src/layerzero/satellite/LiquidityPool.sol";

contract MockToken is ERC20 {
    constructor() ERC20("USDT", "USDT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice [M03] LiquidityPool.updateCredit split-path behavior
/// @dev - owner path: strict `newCredit >= utilized`, else revert (local admin mistake)
///      - satellite path: clamp to max(newCredit, utilized) + emit CreditSyncClamped
///        (cross-chain race, don't block LayerZero channel)
contract M03_CreditClamp is Test {
    LiquidityPool internal pool;
    MockToken internal asset;
    address internal satellite = address(0xCAFE);

    function setUp() public {
        asset = new MockToken();
        pool = new LiquidityPool(address(asset), address(this));
        pool.setSatellite(satellite);

        // Seed with 100 credit, 40 utilized
        asset.mint(address(this), 100 ether);
        asset.approve(address(pool), 100 ether);
        pool.addLiquidity(100 ether);
        pool.updateCredit(100 ether); // owner sets initial credit

        vm.prank(satellite);
        // Consume 40 ether via withdrawForUser to bump utilized
        pool.withdrawForUser(address(0xBEEF), 40 ether);

        assertEq(pool.utilized(), 40 ether);
        assertEq(pool.credit(), 100 ether);
    }

    // ============ Owner path: strict ============

    function test_OwnerPath_Revert_WhenNewCreditBelowUtilized() public {
        vm.expectRevert(LiquidityPool.CreditBelowUtilized.selector);
        pool.updateCredit(30 ether); // owner called, 30 < 40 utilized
    }

    function test_OwnerPath_Success_WhenNewCreditAboveUtilized() public {
        pool.updateCredit(80 ether);
        assertEq(pool.credit(), 80 ether);
    }

    function test_OwnerPath_Success_WhenNewCreditEqualsUtilized() public {
        pool.updateCredit(40 ether);
        assertEq(pool.credit(), 40 ether);
    }

    // ============ Satellite path: clamp ============

    function test_SatellitePath_ClampsToUtilized_WhenBelow() public {
        vm.expectEmit(true, true, true, true, address(pool));
        emit LiquidityPool.CreditSyncClamped(30 ether, 40 ether, 40 ether);

        vm.prank(satellite);
        pool.updateCredit(30 ether);

        assertEq(pool.credit(), 40 ether, "credit should be clamped to utilized");
    }

    function test_SatellitePath_DoesNotClamp_WhenAboveUtilized() public {
        vm.prank(satellite);
        pool.updateCredit(60 ether);
        assertEq(pool.credit(), 60 ether);
    }

    function test_SatellitePath_InvariantHolds_AfterClamp() public {
        vm.prank(satellite);
        pool.updateCredit(10 ether); // below utilized

        // credit >= utilized invariant preserved
        assertGe(pool.credit(), pool.utilized(), "invariant violated");
        // availableLiquidity is 0 (credit == utilized)
        assertEq(pool.remainingCredit(), 0);
    }

    function test_SatellitePath_DoesNotBlockMessage_DocumentsLiveness() public {
        // If we had used `revert`, this `updateCredit` would throw on satellite path
        // and LayerZero retry queue would fill up. Clamp preserves liveness:
        vm.prank(satellite);
        pool.updateCredit(0); // extreme case: Hub says zero credit
        assertEq(pool.credit(), pool.utilized());
    }
}
