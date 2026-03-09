// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {OFTComposeMsgCodec} from "@layerzero-v2/oapp/contracts/oft/libs/OFTComposeMsgCodec.sol";

import {IStargate} from "../../src/layerzero/interfaces/IStargateIntegration.sol";
import {MessageCodec} from "../../src/layerzero/libraries/MessageCodec.sol";
import {StargateComposeCodec} from "../../src/layerzero/libraries/StargateComposeCodec.sol";
import {PPTSatellite} from "../../src/layerzero/satellite/PPTSatellite.sol";
import {PPTOFT} from "../../src/layerzero/satellite/PPTOFT.sol";
import {LiquidityPool} from "../../src/layerzero/satellite/LiquidityPool.sol";
import {SatelliteGateway} from "../../src/layerzero/satellite/SatelliteGateway.sol";
import {HubStargateComposer} from "../../src/layerzero/hub/HubStargateComposer.sol";
import {PPTOFTAdapter} from "../../src/layerzero/hub/PPTOFTAdapter.sol";
import {CrossChainNAVReporter} from "../../src/layerzero/hub/CrossChainNAVReporter.sol";

contract MockEndpoint {
    address public delegate;

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }
}

contract MockToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RecordingStargatePool {
    struct LastSend {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes composeMsg;
        uint256 nativeFee;
        address refundAddress;
    }

    LastSend internal _lastSend;
    IERC20 public immutable token;
    uint256 public quoteFee = 0.01 ether;
    uint256 public sendCount;

    constructor(address token_) {
        token = IERC20(token_);
    }

    function send(
        IStargate.SendParam calldata params,
        MessagingFee calldata,
        address refundAddress
    ) external payable returns (MessagingReceipt memory receipt, IStargate.OFTReceipt memory oftReceipt) {
        token.transferFrom(msg.sender, address(this), params.amountLD);
        _lastSend = LastSend({
            dstEid: params.dstEid,
            to: params.to,
            amountLD: params.amountLD,
            minAmountLD: params.minAmountLD,
            composeMsg: params.composeMsg,
            nativeFee: msg.value,
            refundAddress: refundAddress
        });
        sendCount++;
        receipt = MessagingReceipt({
            guid: bytes32(sendCount),
            nonce: uint64(sendCount),
            fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})
        });
        oftReceipt = IStargate.OFTReceipt({amountSentLD: params.amountLD, amountReceivedLD: params.amountLD});
    }

    function quoteSend(IStargate.SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: quoteFee, lzTokenFee: 0});
    }

    function setQuoteFee(uint256 fee) external {
        quoteFee = fee;
    }

    function lastSendDstEid() external view returns (uint32) {
        return _lastSend.dstEid;
    }

    function lastSendAmountLD() external view returns (uint256) {
        return _lastSend.amountLD;
    }

    function lastRefundAddress() external view returns (address) {
        return _lastSend.refundAddress;
    }

    function lastComposeMsg() external view returns (bytes memory) {
        return _lastSend.composeMsg;
    }
}

contract MockVault {
    IERC20 public immutable asset;
    uint256 public shareRate = 1e18;

    constructor(address asset_) {
        asset = IERC20(asset_);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        shares = (assets * 1e18) / shareRate;
        receiver;
    }
}

contract MockRedemptionManager {
    IERC20 public immutable asset;
    uint256 public nextRequestId = 1;
    address public lastReceiver;
    uint256 public lastShares;

    struct Request {
        address receiver;
        uint256 amount;
    }

    mapping(uint256 => Request) public requests;

    constructor(address asset_) {
        asset = IERC20(asset_);
    }

    function requestRedemption(uint256 shares, address receiver) external returns (uint256 requestId) {
        lastReceiver = receiver;
        lastShares = shares;
        requestId = nextRequestId++;
        requests[requestId] = Request({receiver: receiver, amount: shares});
    }

    function settleRedemption(uint256 requestId) external {
        Request memory request = requests[requestId];
        asset.transfer(request.receiver, request.amount);
        delete requests[requestId];
    }
}

contract PPTOFTAdapterHarness is PPTOFTAdapter {
    constructor(address token_, address endpoint_, address delegate_) PPTOFTAdapter(token_, endpoint_, delegate_) {}

    function harnessHandleSatelliteWithdraw(Origin calldata origin, bytes calldata payload) external {
        _handleSatelliteWithdraw(origin, payload);
    }
}

contract StargateCriticalFixesTest is Test {
    uint32 internal constant HUB_EID = 30102;
    uint32 internal constant ETH_EID = 30101;

    address internal constant USER = address(0xCAFE);
    address internal constant HUB_COMPOSER = address(0xBEEF);
    address internal constant ETH_GATEWAY = address(0x1234);

    function test_DepositViaBridge_UsesGatewayFundsPathAndRefundsUser() public {
        MockEndpoint endpoint = new MockEndpoint();
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        PPTOFT pptOft = new PPTOFT("Satellite PPT", "spPPT", address(endpoint), address(this), HUB_EID);
        LiquidityPool pool = new LiquidityPool(address(usdt), address(this));
        PPTSatellite satellite =
            new PPTSatellite(address(endpoint), address(this), address(pptOft), address(pool), address(usdt), HUB_EID);
        SatelliteGateway gateway =
            new SatelliteGateway(address(endpoint), address(stargatePool), address(usdt), HUB_EID, address(this));

        gateway.setHubComposer(HUB_COMPOSER);
        satellite.setSatelliteGateway(address(gateway));

        uint256 amount = 1_000e6;
        usdt.mint(USER, amount);

        vm.startPrank(USER);
        usdt.approve(address(satellite), amount);
        vm.deal(USER, 1 ether);
        satellite.depositViaBridge{value: 0.1 ether}(amount, USER, 0);
        vm.stopPrank();

        assertEq(stargatePool.sendCount(), 1);
        assertEq(stargatePool.lastSendDstEid(), HUB_EID);
        assertEq(stargatePool.lastSendAmountLD(), amount);
        assertEq(stargatePool.lastRefundAddress(), USER);
        assertEq(usdt.balanceOf(USER), 0);
    }

    function test_HubReturn_ComposesAssetsBackIntoVaultBalance() public {
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        MockVault vault = new MockVault(address(usdt));
        CrossChainNAVReporter navReporter = new CrossChainNAVReporter(address(this));
        address endpoint = makeAddr("endpoint");

        HubStargateComposer composer =
            new HubStargateComposer(endpoint, address(stargatePool), address(usdt), address(this));

        composer.setVault(address(vault));
        composer.setTrustedGateway(ETH_EID, ETH_GATEWAY);
        composer.setNavReporter(address(navReporter));

        navReporter.addChain(ETH_EID);
        navReporter.grantRole(navReporter.REPORTER_ROLE(), address(composer));
        navReporter.recordDeploy(ETH_EID, 500e6);

        uint256 amount = 200e6;
        usdt.mint(address(composer), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeReturn(ETH_EID, false);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, amount, ETH_GATEWAY, composeMsg);

        vm.prank(endpoint);
        composer.lzCompose(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        assertEq(usdt.balanceOf(address(vault)), amount);
        assertEq(navReporter.remoteDeployments(ETH_EID), 300e6);
    }

    function test_ReplenishLiquidity_WorksWithRealLiquidityPool() public {
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        address endpoint = makeAddr("endpoint");

        LiquidityPool pool = new LiquidityPool(address(usdt), address(this));
        pool.setSatellite(address(0xAAAA));

        SatelliteGateway gateway =
            new SatelliteGateway(endpoint, address(stargatePool), address(usdt), HUB_EID, address(this));
        gateway.setHubComposer(HUB_COMPOSER);
        gateway.setLiquidityPool(address(pool));
        pool.setLiquidityGateway(address(gateway));

        uint256 amount = 300e6;
        usdt.mint(address(gateway), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeReplenish();
        bytes memory fullMessage = _buildComposeMessage(HUB_EID, amount, HUB_COMPOSER, composeMsg);

        vm.prank(endpoint);
        gateway.lzCompose(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        assertEq(usdt.balanceOf(address(pool)), amount);
    }

    function test_SatelliteWithdraw_RegistersComposerSettlementAndBridgesOnSettle() public {
        MockEndpoint endpoint = new MockEndpoint();
        MockToken hubPpt = new MockToken("Hub PPT", "hPPT", 18);
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        MockRedemptionManager redemptionManager = new MockRedemptionManager(address(usdt));

        HubStargateComposer composer =
            new HubStargateComposer(makeAddr("composer-endpoint"), address(stargatePool), address(usdt), address(this));
        PPTOFTAdapterHarness adapter = new PPTOFTAdapterHarness(address(hubPpt), address(endpoint), address(this));

        adapter.setRedemptionManager(address(redemptionManager));
        adapter.setHubStargateComposer(address(composer));
        composer.setPptOftAdapter(address(adapter));
        composer.setTrustedGateway(ETH_EID, ETH_GATEWAY);

        (bool setManagerOk,) =
            address(composer).call(abi.encodeWithSignature("setRedemptionManager(address)", address(redemptionManager)));
        assertTrue(setManagerOk, "composer missing redemption manager setter");

        adapter.harnessHandleSatelliteWithdraw(
            Origin({srcEid: ETH_EID, sender: bytes32(0), nonce: 0}),
            MessageCodec.encodeWithdraw(USER, 250e6)
        );

        assertEq(redemptionManager.lastReceiver(), address(composer));

        usdt.mint(address(redemptionManager), 250e6);
        vm.deal(address(this), 1 ether);

        (bool settleOk,) = address(composer).call{value: 0.01 ether}(
            abi.encodeWithSignature("settleSatelliteRedemption(uint256)", 1)
        );
        assertTrue(settleOk, "satellite settlement bridge failed");

        assertEq(stargatePool.sendCount(), 1);
        assertEq(stargatePool.lastSendDstEid(), ETH_EID);
        assertEq(stargatePool.lastSendAmountLD(), 250e6);
    }

    function _buildComposeMessage(
        uint32 srcEid,
        uint256 amountLD,
        address composeFrom,
        bytes memory composeMsg
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint64(1),
            srcEid,
            amountLD,
            bytes32(uint256(uint160(composeFrom))),
            composeMsg
        );
    }
}
