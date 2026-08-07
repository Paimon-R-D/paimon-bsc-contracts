// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";

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
    uint256 public amountReceivedLD;

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
        uint256 actualReceived = amountReceivedLD == 0 ? params.amountLD : amountReceivedLD;
        oftReceipt = IStargate.OFTReceipt({amountSentLD: params.amountLD, amountReceivedLD: actualReceived});
    }

    function quoteSend(IStargate.SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: quoteFee, lzTokenFee: 0});
    }

    function setQuoteFee(uint256 fee) external {
        quoteFee = fee;
    }

    function setAmountReceivedLD(uint256 amount) external {
        amountReceivedLD = amount;
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

    function setShareRate(uint256 newShareRate) external {
        shareRate = newShareRate;
    }

    function previewDeposit(uint256 assets) external view returns (uint256 shares) {
        shares = (assets * 1e18) / shareRate;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        shares = (assets * 1e18) / shareRate;
        receiver;
    }
}

contract MockPreviewRevertVault {
    function previewDeposit(uint256) external pure returns (uint256) {
        revert("stale nav");
    }

    function deposit(uint256, address) external pure returns (uint256) {
        revert("not used");
    }
}

contract MockMintSharesAdapter {
    uint32 public lastDstEid;
    address public lastReceiver;
    uint256 public lastShares;
    uint256 public callCount;

    function mintSharesOnSatellite(uint32 dstEid, address receiver, uint256 shares) external {
        lastDstEid = dstEid;
        lastReceiver = receiver;
        lastShares = shares;
        callCount++;
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

contract MockCreditManagerRecorder {
    uint32 public lastEid;
    uint256 public lastAmount;
    uint256 public callCount;

    function restoreCredit(uint32 eid, uint256 amount) external {
        lastEid = eid;
        lastAmount = amount;
        callCount++;
    }
}

contract MockBridgedReturnRecorder {
    uint32 public lastEid;
    uint256 public lastAmount;
    bool public lastIsYield;
    uint256 public callCount;

    function recordBridgedReturn(uint32 eid, uint256 amount, bool isYield) external {
        lastEid = eid;
        lastAmount = amount;
        lastIsYield = isYield;
        callCount++;
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
    address internal constant ETH_SATELLITE_GATEWAY = address(0x1234);
    address internal constant ETH_REMOTE_GATEWAY = address(0x5678);

    function test_Deposit_UsesGatewayFundsPathAndRefundsUser() public {
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
        gateway.setDepositForwarder(address(satellite));
        satellite.setSatelliteGateway(address(gateway));
        satellite.setSharePrice(1e18);

        uint256 amount = 1_000e6;
        usdt.mint(USER, amount);

        vm.startPrank(USER);
        usdt.approve(address(satellite), amount);
        vm.deal(USER, 1 ether);
        satellite.deposit{value: 0.1 ether}(amount, USER);
        vm.stopPrank();

        assertEq(stargatePool.sendCount(), 1);
        assertEq(stargatePool.lastSendDstEid(), HUB_EID);
        assertEq(stargatePool.lastSendAmountLD(), amount);
        assertEq(stargatePool.lastRefundAddress(), USER);
        assertEq(usdt.balanceOf(USER), 0);
    }

    function test_DepositFor_RevertsForUnauthorizedForwarder() public {
        MockEndpoint endpoint = new MockEndpoint();
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        SatelliteGateway gateway =
            new SatelliteGateway(address(endpoint), address(stargatePool), address(usdt), HUB_EID, address(this));

        gateway.setHubComposer(HUB_COMPOSER);

        uint256 amount = 250e6;
        usdt.mint(USER, amount);

        vm.startPrank(USER);
        usdt.approve(address(gateway), amount);
        vm.stopPrank();

        vm.deal(address(0xBADD), 1 ether);
        vm.prank(address(0xBADD));
        vm.expectRevert();
        gateway.depositFor{value: 0.1 ether}(USER, amount, address(0xBADD), 0, address(0xBADD));
    }

    function test_SatelliteGateway_Deposit_RevertsWhenHubComposerUnset() public {
        MockEndpoint endpoint = new MockEndpoint();
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        SatelliteGateway gateway =
            new SatelliteGateway(address(endpoint), address(stargatePool), address(usdt), HUB_EID, address(this));

        uint256 amount = 250e6;
        usdt.mint(USER, amount);
        stargatePool.setQuoteFee(0.01 ether);

        vm.startPrank(USER);
        usdt.approve(address(gateway), amount);
        vm.expectRevert(SatelliteGateway.ZeroAddress.selector);
        gateway.deposit{value: 0.01 ether}(amount, USER, 0);
        vm.stopPrank();
    }

    function test_SatelliteGateway_QuoteDeposit_RevertsWhenHubComposerUnset() public {
        MockEndpoint endpoint = new MockEndpoint();
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        SatelliteGateway gateway =
            new SatelliteGateway(address(endpoint), address(stargatePool), address(usdt), HUB_EID, address(this));

        vm.expectRevert(SatelliteGateway.ZeroAddress.selector);
        gateway.quoteDeposit(250e6, USER);
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
        composer.setRemoteAssetGateway(ETH_EID, ETH_REMOTE_GATEWAY);
        composer.setNavReporter(address(navReporter));

        navReporter.addChain(ETH_EID);
        navReporter.grantRole(navReporter.REPORTER_ROLE(), address(composer));
        navReporter.recordDeploy(ETH_EID, 500e6);

        uint256 amount = 200e6;
        usdt.mint(address(composer), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeReturn(false);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, amount, ETH_REMOTE_GATEWAY, composeMsg);

        vm.prank(endpoint);
        composer.lzCompose(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        assertEq(usdt.balanceOf(address(vault)), amount);
        assertEq(navReporter.remoteDeployments(ETH_EID), 300e6);
    }

    function test_HubDeposit_MinSharesMismatch_IsStoredForRecovery() public {
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        MockVault vault = new MockVault(address(usdt));
        address endpoint = makeAddr("endpoint");

        HubStargateComposer composer =
            new HubStargateComposer(endpoint, address(stargatePool), address(usdt), address(this));

        composer.setVault(address(vault));
        composer.setPptOftAdapter(address(0xBEEF));
        composer.setSatelliteGateway(ETH_EID, ETH_SATELLITE_GATEWAY);
        vault.setShareRate(2e18);

        uint256 amount = 100e6;
        uint256 minShares = 60e6;
        usdt.mint(address(composer), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeDeposit(USER, minShares);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, amount, ETH_SATELLITE_GATEWAY, composeMsg);

        vm.prank(endpoint);
        composer.lzCompose(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        assertEq(composer.failedDepositCount(), 1);
        (uint32 srcEid, address receiver, uint256 assets, uint256 storedMinShares, uint256 timestamp) =
            composer.failedDeposits(0);
        assertEq(srcEid, ETH_EID);
        assertEq(receiver, USER);
        assertEq(assets, amount);
        assertEq(storedMinShares, minShares);
        assertGt(timestamp, 0);
        assertEq(usdt.balanceOf(address(composer)), amount);
    }

    function test_HubDeposit_PreviewFailure_IsStoredForRecovery() public {
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        MockPreviewRevertVault vault = new MockPreviewRevertVault();
        address endpoint = makeAddr("endpoint");

        HubStargateComposer composer =
            new HubStargateComposer(endpoint, address(stargatePool), address(usdt), address(this));

        composer.setVault(address(vault));
        composer.setPptOftAdapter(address(0xBEEF));
        composer.setSatelliteGateway(ETH_EID, ETH_SATELLITE_GATEWAY);

        uint256 amount = 100e6;
        usdt.mint(address(composer), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeDeposit(USER, 1);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, amount, ETH_SATELLITE_GATEWAY, composeMsg);

        vm.prank(endpoint);
        composer.lzCompose(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        assertEq(composer.failedDepositCount(), 1);
        (, address receiver, uint256 assets,,) = composer.failedDeposits(0);
        assertEq(receiver, USER);
        assertEq(assets, amount);
        assertEq(usdt.balanceOf(address(composer)), amount);
    }

    function test_RetryFailedDeposit_DepositsAndSendsShares() public {
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        MockVault vault = new MockVault(address(usdt));
        MockMintSharesAdapter adapter = new MockMintSharesAdapter();
        address endpoint = makeAddr("endpoint");

        HubStargateComposer composer =
            new HubStargateComposer(endpoint, address(stargatePool), address(usdt), address(this));

        composer.setVault(address(vault));
        composer.setPptOftAdapter(address(adapter));
        composer.setSatelliteGateway(ETH_EID, ETH_SATELLITE_GATEWAY);
        vault.setShareRate(2e18);

        uint256 amount = 100e6;
        usdt.mint(address(composer), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeDeposit(USER, 60e6);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, amount, ETH_SATELLITE_GATEWAY, composeMsg);

        vm.prank(endpoint);
        composer.lzCompose(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        vault.setShareRate(1.5e18);
        composer.retryFailedDeposit(0, 0);

        assertEq(adapter.callCount(), 1);
        assertEq(adapter.lastDstEid(), ETH_EID);
        assertEq(adapter.lastReceiver(), USER);
        assertEq(adapter.lastShares(), 66_666_666);
        (, address receiver, uint256 assets,,) = composer.failedDeposits(0);
        assertEq(receiver, address(0));
        assertEq(assets, 0);
        assertEq(usdt.balanceOf(address(composer)), 0);
        assertEq(usdt.balanceOf(address(vault)), amount);
    }

    function test_RetryFailedDeposit_CannotBypassStoredMinShares() public {
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        MockVault vault = new MockVault(address(usdt));
        MockMintSharesAdapter adapter = new MockMintSharesAdapter();
        address endpoint = makeAddr("endpoint");

        HubStargateComposer composer =
            new HubStargateComposer(endpoint, address(stargatePool), address(usdt), address(this));

        composer.setVault(address(vault));
        composer.setPptOftAdapter(address(adapter));
        composer.setSatelliteGateway(ETH_EID, ETH_SATELLITE_GATEWAY);
        vault.setShareRate(2e18);

        uint256 amount = 100e6;
        usdt.mint(address(composer), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeDeposit(USER, 60e6);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, amount, ETH_SATELLITE_GATEWAY, composeMsg);

        vm.prank(endpoint);
        composer.lzCompose(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        vm.expectRevert(abi.encodeWithSelector(HubStargateComposer.SlippageTooHigh.selector, 50e6, 60e6));
        composer.retryFailedDeposit(0, 0);
    }

    function test_RefundFailedDeposit_BridgesAssetsBackToSatellite() public {
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        MockVault vault = new MockVault(address(usdt));
        address endpoint = makeAddr("endpoint");

        HubStargateComposer composer =
            new HubStargateComposer(endpoint, address(stargatePool), address(usdt), address(this));

        composer.setVault(address(vault));
        composer.setPptOftAdapter(address(0xBEEF));
        composer.setSatelliteGateway(ETH_EID, ETH_SATELLITE_GATEWAY);
        vault.setShareRate(2e18);

        uint256 amount = 100e6;
        usdt.mint(address(composer), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeDeposit(USER, 60e6);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, amount, ETH_SATELLITE_GATEWAY, composeMsg);

        vm.prank(endpoint);
        composer.lzCompose(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        composer.refundFailedDeposit{value: 0.01 ether}(0);

        assertEq(stargatePool.sendCount(), 1);
        assertEq(stargatePool.lastSendDstEid(), ETH_EID);
        assertEq(stargatePool.lastSendAmountLD(), amount);
        (, address receiver, uint256 assets,,) = composer.failedDeposits(0);
        assertEq(receiver, address(0));
        assertEq(assets, 0);
    }

    function test_ReplenishLiquidity_WorksWithRealLiquidityPool() public {
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        address endpoint = makeAddr("endpoint");

        LiquidityPool pool = new LiquidityPool(address(usdt), address(this));
        pool.setSatellite(address(this));

        SatelliteGateway gateway =
            new SatelliteGateway(endpoint, address(stargatePool), address(usdt), HUB_EID, address(this));
        gateway.setHubComposer(HUB_COMPOSER);
        gateway.setLiquidityPool(address(pool));
        pool.setLiquidityGateway(address(gateway));

        usdt.mint(address(this), 500e6);
        usdt.approve(address(pool), 500e6);
        pool.addLiquidity(500e6);
        pool.updateCredit(500e6);
        pool.withdrawForUser(USER, 120e6);

        uint256 amount = 300e6;
        usdt.mint(address(gateway), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeReplenish();
        bytes memory fullMessage = _buildComposeMessage(HUB_EID, amount, HUB_COMPOSER, composeMsg);

        vm.prank(endpoint);
        gateway.lzCompose(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        assertEq(usdt.balanceOf(address(pool)), 680e6);
        assertEq(pool.utilized(), 0);
    }

    function test_SatelliteGateway_Replenish_RevertsWhenLiquidityPoolUnset() public {
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        address endpoint = makeAddr("endpoint");

        SatelliteGateway gateway =
            new SatelliteGateway(endpoint, address(stargatePool), address(usdt), HUB_EID, address(this));
        gateway.setHubComposer(HUB_COMPOSER);

        uint256 amount = 300e6;
        usdt.mint(address(gateway), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeReplenish();
        bytes memory fullMessage = _buildComposeMessage(HUB_EID, amount, HUB_COMPOSER, composeMsg);

        vm.prank(endpoint);
        vm.expectRevert(SatelliteGateway.ZeroAddress.selector);
        gateway.lzCompose(address(stargatePool), bytes32(0), fullMessage, address(0), "");
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
        composer.setSatelliteGateway(ETH_EID, ETH_SATELLITE_GATEWAY);

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

    function test_ReplenishLiquidity_DoesNotRestoreCreditBeforeRemoteAck() public {
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        MockCreditManagerRecorder creditManager = new MockCreditManagerRecorder();

        HubStargateComposer composer =
            new HubStargateComposer(makeAddr("composer-endpoint"), address(stargatePool), address(usdt), address(this));

        composer.setSatelliteGateway(ETH_EID, ETH_SATELLITE_GATEWAY);
        composer.setCreditManager(address(creditManager));

        usdt.mint(address(composer), 300e6);
        stargatePool.setAmountReceivedLD(280e6);

        composer.replenishLiquidity{value: 0.01 ether}(ETH_EID, 300e6);

        assertEq(creditManager.callCount(), 0);
    }

    function test_HubReturn_UpdatesBridgedControllerAccounting() public {
        MockToken usdt = new MockToken("USDT", "USDT", 6);
        RecordingStargatePool stargatePool = new RecordingStargatePool(address(usdt));
        MockVault vault = new MockVault(address(usdt));
        MockBridgedReturnRecorder controller = new MockBridgedReturnRecorder();
        address endpoint = makeAddr("endpoint");

        HubStargateComposer composer =
            new HubStargateComposer(endpoint, address(stargatePool), address(usdt), address(this));

        composer.setVault(address(vault));
        composer.setRemoteAssetGateway(ETH_EID, ETH_REMOTE_GATEWAY);
        composer.setCrossChainAssetController(address(controller));

        uint256 amount = 90e6;
        usdt.mint(address(composer), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeReturn(false);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, amount, ETH_REMOTE_GATEWAY, composeMsg);

        vm.prank(endpoint);
        composer.lzCompose(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        assertEq(controller.callCount(), 1);
        assertEq(controller.lastEid(), ETH_EID);
        assertEq(controller.lastAmount(), amount);
        assertEq(controller.lastIsYield(), false);
        assertEq(usdt.balanceOf(address(vault)), amount);
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
