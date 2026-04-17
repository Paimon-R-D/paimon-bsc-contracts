// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {PPTOFTAdapter} from "../../src/layerzero/hub/PPTOFTAdapter.sol";
import {CreditManager} from "../../src/layerzero/hub/CreditManager.sol";
import {PPTSatellite} from "../../src/layerzero/satellite/PPTSatellite.sol";
import {PPTOFT} from "../../src/layerzero/satellite/PPTOFT.sol";
import {LiquidityPool} from "../../src/layerzero/satellite/LiquidityPool.sol";
import {MessageCodec} from "../../src/layerzero/libraries/MessageCodec.sol";

contract MockEndpoint {
    address public delegate;
    function setDelegate(address _delegate) external { delegate = _delegate; }
}

contract MockToken is ERC20 {
    constructor() ERC20("PPT", "PPT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockVaultPriced {
    uint256 public sharePrice;
    constructor(uint256 p) { sharePrice = p; }
    function setSharePrice(uint256 p) external { sharePrice = p; }
}

/// @notice Records every lzSend target for broadcast assertions
contract PPTOFTAdapterBroadcastHarness is PPTOFTAdapter {
    uint32[] public sends;

    constructor(address token_, address endpoint_, address delegate_)
        PPTOFTAdapter(token_, endpoint_, delegate_)
    {}

    function sendCount() external view returns (uint256) { return sends.length; }
    function sendAt(uint256 i) external view returns (uint32) { return sends[i]; }

    function _quote(uint32, bytes memory, bytes memory, bool)
        internal
        pure
        override
        returns (MessagingFee memory fee)
    {
        return MessagingFee({nativeFee: 0, lzTokenFee: 0});
    }

    function _lzSend(uint32 dstEid, bytes memory, bytes memory, MessagingFee memory fee, address)
        internal
        override
        returns (MessagingReceipt memory receipt)
    {
        sends.push(dstEid);
        return MessagingReceipt({guid: bytes32(0), nonce: 0, fee: fee});
    }
}

contract CreditManagerNoOp is CreditManager {
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

contract M01_BroadcastSharePrice is Test {
    MockEndpoint internal endpoint;
    MockToken internal ppt;
    MockVaultPriced internal vault;
    CreditManagerNoOp internal creditManager;
    PPTOFTAdapterBroadcastHarness internal adapter;

    function setUp() public {
        endpoint = new MockEndpoint();
        ppt = new MockToken();
        vault = new MockVaultPriced(1.2e18);
        creditManager = new CreditManagerNoOp(address(endpoint), address(this));
        adapter = new PPTOFTAdapterBroadcastHarness(address(ppt), address(endpoint), address(this));

        adapter.setCreditManager(address(creditManager));
        adapter.setVault(address(vault));
    }

    // ============ broadcastSharePriceToSupportedChains ============

    function test_Broadcast_DispatchesToAllRegisteredEids() public {
        creditManager.addChain(30101, 100 ether);
        creditManager.addChain(30102, 100 ether);
        creditManager.addChain(30103, 100 ether);

        adapter.broadcastSharePriceToSupportedChains();

        assertEq(adapter.sendCount(), 3);
        assertEq(adapter.sendAt(0), 30101);
        assertEq(adapter.sendAt(1), 30102);
        assertEq(adapter.sendAt(2), 30103);
    }

    function test_Broadcast_UpdatesPerChainTelemetry() public {
        creditManager.addChain(30101, 100 ether);

        uint256 tsBefore = block.timestamp;
        adapter.broadcastSharePriceToSupportedChains();

        assertEq(adapter.lastSharePriceSyncedAt(30101), tsBefore);
        assertEq(adapter.lastSharePriceSyncedValue(30101), vault.sharePrice());
    }

    function test_Broadcast_RevertsWhenVaultUnset() public {
        PPTOFTAdapterBroadcastHarness a2 =
            new PPTOFTAdapterBroadcastHarness(address(ppt), address(endpoint), address(this));
        a2.setCreditManager(address(creditManager));
        // vault intentionally unset

        vm.expectRevert(PPTOFTAdapter.ZeroAddress.selector);
        a2.broadcastSharePriceToSupportedChains();
    }

    function test_Broadcast_RevertsWhenCreditManagerUnset() public {
        PPTOFTAdapterBroadcastHarness a2 =
            new PPTOFTAdapterBroadcastHarness(address(ppt), address(endpoint), address(this));
        a2.setVault(address(vault));
        // creditManager intentionally unset

        vm.expectRevert(PPTOFTAdapter.ZeroAddress.selector);
        a2.broadcastSharePriceToSupportedChains();
    }

    function test_Broadcast_EmptyChainList_NoSends() public {
        // No chains added
        adapter.broadcastSharePriceToSupportedChains();
        assertEq(adapter.sendCount(), 0);
    }

    function test_Broadcast_ReflectsCurrentSharePrice() public {
        creditManager.addChain(30101, 100 ether);

        vault.setSharePrice(1.5e18);
        adapter.broadcastSharePriceToSupportedChains();
        assertEq(adapter.lastSharePriceSyncedValue(30101), 1.5e18);
    }

    // ============ Satellite staleness default ============

    function test_PPTSatellite_DefaultMaxStaleness_Is10Minutes() public {
        MockEndpoint ep = new MockEndpoint();
        MockToken asset_ = new MockToken();
        PPTOFT pptOft = new PPTOFT("sPPT", "sPPT", address(ep), address(this), 30102);
        LiquidityPool pool = new LiquidityPool(address(asset_), address(this));
        PPTSatellite satellite =
            new PPTSatellite(address(ep), address(this), address(pptOft), address(pool), address(asset_), 30102);

        assertEq(satellite.DEFAULT_MAX_SHARE_PRICE_STALENESS(), 10 minutes);
        assertEq(satellite.maxSharePriceStaleness(), 10 minutes);
    }
}
