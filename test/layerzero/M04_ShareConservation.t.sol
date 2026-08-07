// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {CreditManager} from "../../src/layerzero/hub/CreditManager.sol";
import {CrossChainNAVReporter} from "../../src/layerzero/hub/CrossChainNAVReporter.sol";
import {PPTOFTAdapter} from "../../src/layerzero/hub/PPTOFTAdapter.sol";
import {MessageCodec} from "../../src/layerzero/libraries/MessageCodec.sol";

/// @notice Minimal endpoint stub accepted by OApp constructor
contract MockEndpoint {
    address public delegate;
    function setDelegate(address _delegate) external { delegate = _delegate; }
}

contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

/// @notice Mock PPT exposing `sharePrice`, `lockShares`, `burnLockedShares`, `addRedemptionLiability`
/// @dev Intentionally narrow — only surfaces the operator interface the adapter uses
contract MockPPTWithLockBurn {
    MockToken public immutable share;
    uint256 public sharePrice;
    uint256 public lockedByOwner;
    uint256 public redemptionLiability;

    mapping(address => uint256) public lockedShares;

    constructor(address share_, uint256 sharePrice_) {
        share = MockToken(share_);
        sharePrice = sharePrice_;
    }

    function setSharePrice(uint256 newSharePrice) external { sharePrice = newSharePrice; }

    /// @notice Lock shares — mirrors real PPT semantics (no transfer, just accounting)
    function lockShares(address owner, uint256 shares) external {
        lockedShares[owner] += shares;
        lockedByOwner += shares;
    }

    function unlockShares(address owner, uint256 shares) external {
        lockedShares[owner] -= shares;
        lockedByOwner -= shares;
    }

    /// @notice Burn previously-locked shares from `owner` balance
    /// @dev Matches real PPT: burnLockedShares reduces owner's token balance and lock counter
    function burnLockedShares(address owner, uint256 shares) external {
        require(lockedShares[owner] >= shares, "not locked");
        lockedShares[owner] -= shares;
        lockedByOwner -= shares;
        share.burn(owner, shares);
    }

    function addRedemptionLiability(uint256 amount) external {
        redemptionLiability += amount;
    }
}

/// @notice Harness exposing internal handler and bypassing LayerZero fee/send
contract PPTOFTAdapterHarness is PPTOFTAdapter {
    constructor(address token_, address endpoint_, address delegate_)
        PPTOFTAdapter(token_, endpoint_, delegate_)
    {}

    function harnessReceiveInstantWithdraw(uint32 srcEid, bytes32 sender, uint256 shares, uint256 assets) external {
        bytes memory payload = MessageCodec.encodeInstantWithdrawSettled(shares, assets);
        this.harnessReceiveTyped(Origin({srcEid: srcEid, sender: sender, nonce: 0}), payload, "");
    }

    function harnessReceiveCreditRestored(uint32 srcEid, bytes32 sender, uint256 amount) external {
        bytes memory payload = MessageCodec.encodeCreditRestored(amount);
        this.harnessReceiveTyped(Origin({srcEid: srcEid, sender: sender, nonce: 0}), payload, "");
    }

    function harnessReceiveTyped(Origin calldata origin, bytes calldata payload, bytes calldata extraData)
        external
    {
        _lzReceive(origin, bytes32(0), payload, address(0), extraData);
    }

    function harnessIncrementMirrored(uint256 amount) external {
        totalMirroredShares += amount;
    }

    function _quote(uint32, bytes memory, bytes memory, bool)
        internal
        pure
        override
        returns (MessagingFee memory fee)
    {
        return MessagingFee({nativeFee: 0, lzTokenFee: 0});
    }

    function _lzSend(uint32 dstEid, bytes memory message, bytes memory, MessagingFee memory fee, address)
        internal
        pure
        override
        returns (MessagingReceipt memory receipt)
    {
        return MessagingReceipt({guid: bytes32(0), nonce: 0, fee: fee});
    }
}

contract RoleGrantingCreditManager is CreditManager {
    constructor(address endpoint_, address delegate_) CreditManager(endpoint_, delegate_) {}

    function _lzSend(uint32, bytes memory, bytes memory, MessagingFee memory fee, address)
        internal
        pure
        override
        returns (MessagingReceipt memory receipt)
    {
        return MessagingReceipt({guid: bytes32(0), nonce: 0, fee: fee});
    }
}

contract M04_ShareConservation is Test {
    uint32 internal constant REMOTE_EID = 30101;

    MockEndpoint internal endpoint;
    MockToken internal ppt;
    MockPPTWithLockBurn internal vault;
    RoleGrantingCreditManager internal creditManager;
    CrossChainNAVReporter internal navReporter;
    PPTOFTAdapterHarness internal adapter;
    bytes32 internal peer;

    function setUp() public {
        endpoint = new MockEndpoint();
        ppt = new MockToken("Hub PPT", "hPPT");
        vault = new MockPPTWithLockBurn(address(ppt), 1e18);

        creditManager = new RoleGrantingCreditManager(address(endpoint), address(this));
        navReporter = new CrossChainNAVReporter(address(this));
        adapter = new PPTOFTAdapterHarness(address(ppt), address(endpoint), address(this));
        peer = bytes32(uint256(0xBEEF));

        creditManager.addChain(REMOTE_EID, 100 ether);
        creditManager.setOperator(address(adapter), true);

        navReporter.addChain(REMOTE_EID);
        navReporter.grantRole(navReporter.REPORTER_ROLE(), address(adapter));
        // Satellite LP seeded with 100 ether so debit has something to drain
        navReporter.updateSatelliteBalance(REMOTE_EID, 100 ether);

        adapter.setCreditManager(address(creditManager));
        adapter.setVault(address(vault));
        adapter.setNavReporter(address(navReporter));
        adapter.setPeer(REMOTE_EID, peer);
    }

    // ============ Core invariant tests ============

    function test_InstantWithdraw_HubHandler_AtomicallyUpdatesThreeBooks() public {
        // Seed adapter with 50 PPT (mirroring 50 ether on satellite)
        ppt.mint(address(adapter), 50 ether);
        adapter.harnessIncrementMirrored(50 ether);

        uint256 preCredit = creditManager.getAvailableCredit(REMOTE_EID);
        uint256 preSatelliteBalance = navReporter.satelliteBalances(REMOTE_EID);
        uint256 preAdapterPPT = ppt.balanceOf(address(adapter));
        uint256 preMirrored = adapter.totalMirroredShares();

        // Instant withdraw: 10 shares burned on satellite, 10 USDT paid out
        adapter.harnessReceiveInstantWithdraw(REMOTE_EID, peer, 10 ether, 10 ether);

        // Book 1: Credit utilization advanced
        assertEq(creditManager.getAvailableCredit(REMOTE_EID), preCredit - 10 ether, "credit not reduced");

        // Book 2: NAV satellite balance decreased
        assertEq(navReporter.satelliteBalances(REMOTE_EID), preSatelliteBalance - 10 ether, "NAV not debited");

        // Book 3a: Mirror PPT burned from adapter
        assertEq(ppt.balanceOf(address(adapter)), preAdapterPPT - 10 ether, "mirror PPT not burned");

        // Book 3b: Explicit ledger kept in sync
        assertEq(adapter.totalMirroredShares(), preMirrored - 10 ether, "mirror ledger not decremented");
    }

    function test_InstantWithdraw_HubHandler_RevertsWhenNavReporterUnset() public {
        PPTOFTAdapterHarness freshAdapter =
            new PPTOFTAdapterHarness(address(ppt), address(endpoint), address(this));
        freshAdapter.setCreditManager(address(creditManager));
        freshAdapter.setVault(address(vault));
        freshAdapter.setPeer(REMOTE_EID, peer);
        // Intentionally skip setNavReporter

        ppt.mint(address(freshAdapter), 20 ether);

        vm.expectRevert(PPTOFTAdapter.ZeroAddress.selector);
        freshAdapter.harnessReceiveInstantWithdraw(REMOTE_EID, peer, 5 ether, 5 ether);
    }

    function test_InstantWithdraw_HubHandler_RevertsOnZeroShares() public {
        ppt.mint(address(adapter), 10 ether);
        adapter.harnessIncrementMirrored(10 ether);

        vm.expectRevert(PPTOFTAdapter.InvalidAmount.selector);
        adapter.harnessReceiveInstantWithdraw(REMOTE_EID, peer, 0, 10 ether);
    }

    function test_InstantWithdraw_HubHandler_RevertsOnZeroAssets() public {
        ppt.mint(address(adapter), 10 ether);
        adapter.harnessIncrementMirrored(10 ether);

        vm.expectRevert(PPTOFTAdapter.InvalidAmount.selector);
        adapter.harnessReceiveInstantWithdraw(REMOTE_EID, peer, 10 ether, 0);
    }

    // ============ Mirror ledger tests ============

    function test_TotalMirroredShares_StartsAtZero() public view {
        assertEq(adapter.totalMirroredShares(), 0);
    }

    function test_TotalMirroredShares_EmitsUpdateEvent() public {
        ppt.mint(address(adapter), 30 ether);
        adapter.harnessIncrementMirrored(30 ether);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit PPTOFTAdapter.MirroredSharesUpdated(30 ether, 25 ether);
        adapter.harnessReceiveInstantWithdraw(REMOTE_EID, peer, 5 ether, 5 ether);
    }

    function test_TotalMirroredShares_SaturatesToZero_EmitsDiscrepancyOnUnderflow() public {
        // Adapter has 10 ether PPT but ledger shows only 3 ether (drift scenario —
        // e.g. historical event missed, manual correction needed)
        ppt.mint(address(adapter), 10 ether);
        adapter.harnessIncrementMirrored(3 ether);

        // Handler must NOT revert — reverting would block LayerZero channel after
        // credit/NAV books are already mutated. Expect saturate + discrepancy event.
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PPTOFTAdapter.MirroredLedgerDiscrepancy(REMOTE_EID, 5 ether, 3 ether);
        adapter.harnessReceiveInstantWithdraw(REMOTE_EID, peer, 5 ether, 5 ether);

        // Ledger saturated to 0
        assertEq(adapter.totalMirroredShares(), 0, "ledger should saturate to zero");
        // Credit and NAV still updated (handler completed)
        assertEq(creditManager.getAvailableCredit(REMOTE_EID), 100 ether - 5 ether);
    }

    // ============ Replenish symmetry (M04 addendum) ============

    function test_CreditRestored_HubHandler_RecordsNavCreditDelta() public {
        // First simulate that satellite used some credit
        ppt.mint(address(adapter), 50 ether);
        adapter.harnessIncrementMirrored(50 ether);
        adapter.harnessReceiveInstantWithdraw(REMOTE_EID, peer, 10 ether, 10 ether);

        uint256 preSatelliteBalance = navReporter.satelliteBalances(REMOTE_EID);

        // Replenish: 10 USDT restored
        adapter.harnessReceiveCreditRestored(REMOTE_EID, peer, 10 ether);

        // NAV should reflect the inflow immediately
        assertEq(navReporter.satelliteBalances(REMOTE_EID), preSatelliteBalance + 10 ether);
        // Credit utilization decreased
        assertEq(creditManager.getAvailableCredit(REMOTE_EID), 100 ether); // back to full
    }

    // ============ Codec round-trip ============

    function test_MessageCodec_InstantWithdrawSettled_Encodes_PrefixPlusShareAndAsset() public pure {
        bytes memory encoded = MessageCodec.encodeInstantWithdrawSettled(42 ether, 37 ether);
        assertEq(uint8(encoded[0]), uint8(MessageCodec.MSG_INSTANT_WITHDRAW_SETTLED));

        bytes memory rest = new bytes(encoded.length - 1);
        for (uint256 i = 1; i < encoded.length; i++) {
            rest[i - 1] = encoded[i];
        }
        (uint256 s, uint256 a) = abi.decode(rest, (uint256, uint256));
        assertEq(s, 42 ether);
        assertEq(a, 37 ether);
    }
}
