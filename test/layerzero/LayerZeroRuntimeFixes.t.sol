// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {CreditManager} from "../../src/layerzero/hub/CreditManager.sol";
import {CrossChainAssetController} from "../../src/layerzero/hub/CrossChainAssetController.sol";
import {PPTOFTAdapter} from "../../src/layerzero/hub/PPTOFTAdapter.sol";
import {PPTSatellite} from "../../src/layerzero/satellite/PPTSatellite.sol";
import {PPTOFT} from "../../src/layerzero/satellite/PPTOFT.sol";
import {LiquidityPool} from "../../src/layerzero/satellite/LiquidityPool.sol";
import {MessageCodec} from "../../src/layerzero/libraries/MessageCodec.sol";

contract MockEndpoint {
    address public delegate;

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }
}

contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockRedemptionManager {
    uint256 public nextRequestId = 1;
    address public lastReceiver;
    uint256 public lastShares;

    function requestRedemption(uint256 shares, address receiver) external returns (uint256 requestId) {
        lastShares = shares;
        lastReceiver = receiver;
        requestId = nextRequestId++;
    }
}

contract MockCreditSyncAdapter {
    uint256 public sendCount;
    uint32 public lastDstEid;
    uint256 public lastCredit;
    address public lastRefundAddress;
    uint256 public lastNativeFee;

    function syncCreditToSatellite(uint32 dstEid, uint256 newCredit, address refundAddress) external payable {
        sendCount++;
        lastDstEid = dstEid;
        lastCredit = newCredit;
        lastRefundAddress = refundAddress;
        lastNativeFee = msg.value;
    }
}

contract MockPPTVault {
    uint256 public sharePrice;

    constructor(uint256 sharePrice_) {
        sharePrice = sharePrice_;
    }

    function setSharePrice(uint256 newSharePrice) external {
        sharePrice = newSharePrice;
    }
}

contract MockAssetVaultWithSharePrice {
    MockToken public immutable asset;
    uint256 public sharePrice;
    uint256 public sharesPerAsset;

    constructor(address asset_, uint256 sharePrice_, uint256 sharesPerAsset_) {
        asset = MockToken(asset_);
        sharePrice = sharePrice_;
        sharesPerAsset = sharesPerAsset_;
    }

    function deposit(uint256 assets, address) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets * sharesPerAsset;
    }
}

contract RecordingCreditManager is CreditManager {
    uint256 public sendCount;
    uint32 public lastDstEid;
    bytes public lastPayload;

    constructor(address endpoint_, address delegate_) CreditManager(endpoint_, delegate_) {}

    function _lzSend(
        uint32 _dstEid,
        bytes memory _message,
        bytes memory,
        MessagingFee memory _fee,
        address
    ) internal override returns (MessagingReceipt memory receipt) {
        sendCount++;
        lastDstEid = _dstEid;
        lastPayload = _message;
        return MessagingReceipt({guid: bytes32(sendCount), nonce: uint64(sendCount), fee: _fee});
    }
}

contract MockHubStargateComposer {
    uint256 public bridgedAmount;
    uint32 public lastDstEid;
    uint256 public lastAmount;
    address public lastProtocol;
    string public lastProtocolName;

    function setBridgedAmount(uint256 amount) external {
        bridgedAmount = amount;
    }

    function bridgeAndDeploy(uint32 dstEid, uint256 amount, address protocol, string calldata protocolName)
        external
        payable
        returns (uint256)
    {
        lastDstEid = dstEid;
        lastAmount = amount;
        lastProtocol = protocol;
        lastProtocolName = protocolName;
        return bridgedAmount == 0 ? amount : bridgedAmount;
    }
}

contract CrossChainAssetControllerHarness is CrossChainAssetController {
    uint256 public sendCount;
    uint32 public lastDstEid;
    bytes public lastPayload;
    uint256 public quotedNativeFee;

    constructor(address endpoint_, address delegate_, address asset_)
        CrossChainAssetController(endpoint_, delegate_, asset_)
    {}

    function setQuotedNativeFee(uint256 fee) external {
        quotedNativeFee = fee;
    }

    function harnessReceive(Origin calldata origin, bytes calldata payload) external {
        this.harnessReceiveCalldata(origin, payload, "");
    }

    function harnessReceiveCalldata(Origin calldata origin, bytes calldata payload, bytes calldata extraData)
        external
        pure
    {
        _lzReceive(origin, bytes32(0), payload, address(0), extraData);
    }

    function _quote(
        uint32,
        bytes memory,
        bytes memory,
        bool
    ) internal view override returns (MessagingFee memory fee) {
        return MessagingFee({nativeFee: quotedNativeFee, lzTokenFee: 0});
    }

    function _lzSend(
        uint32 dstEid,
        bytes memory message,
        bytes memory,
        MessagingFee memory fee,
        address
    ) internal override returns (MessagingReceipt memory receipt) {
        sendCount++;
        lastDstEid = dstEid;
        lastPayload = message;
        return MessagingReceipt({guid: bytes32(sendCount), nonce: uint64(sendCount), fee: fee});
    }
}

contract PPTSatelliteHarness is PPTSatellite {
    uint256 public quotedNativeFee;
    uint256 public sendCount;
    uint32 public lastDstEid;
    bytes public lastPayload;

    constructor(
        address endpoint_,
        address delegate_,
        address pptOft_,
        address liquidityPool_,
        address asset_,
        uint32 hubEid_
    ) PPTSatellite(endpoint_, delegate_, pptOft_, liquidityPool_, asset_, hubEid_) {}

    function harnessReceive(uint32 srcEid, bytes calldata payload) external {
        this.harnessReceiveCalldata(Origin({srcEid: srcEid, sender: bytes32(0), nonce: 0}), payload, "");
    }

    function harnessReceiveCalldata(Origin calldata origin, bytes calldata payload, bytes calldata extraData) external {
        _lzReceive(origin, bytes32(0), payload, address(0), extraData);
    }

    function setQuotedNativeFee(uint256 fee) external {
        quotedNativeFee = fee;
    }

    function _quote(
        uint32,
        bytes memory,
        bytes memory,
        bool
    ) internal view override returns (MessagingFee memory fee) {
        return MessagingFee({nativeFee: quotedNativeFee, lzTokenFee: 0});
    }

    function _lzSend(
        uint32 dstEid,
        bytes memory message,
        bytes memory,
        MessagingFee memory fee,
        address
    ) internal override returns (MessagingReceipt memory receipt) {
        sendCount++;
        lastDstEid = dstEid;
        lastPayload = message;
        return MessagingReceipt({guid: bytes32(sendCount), nonce: uint64(sendCount), fee: fee});
    }
}

contract PPTOFTAdapterHarness is PPTOFTAdapter {
    uint256 public sendCount;
    uint32 public lastDstEid;
    bytes public lastPayload;
    uint256 public quotedNativeFee;

    constructor(address token_, address endpoint_, address delegate_) PPTOFTAdapter(token_, endpoint_, delegate_) {}

    function harnessHandleSatelliteRedemption(bytes calldata payload) external {
        this.harnessHandleSatelliteRedemptionCalldata(Origin({srcEid: 0, sender: bytes32(0), nonce: 0}), payload);
    }

    function harnessHandleSatelliteRedemptionCalldata(Origin calldata origin, bytes calldata payload) external {
        _handleSatelliteRedemption(origin, payload);
    }

    function harnessReceiveTyped(uint32 srcEid, bytes32 sender, bytes calldata payload) external {
        this.harnessReceiveTypedCalldata(Origin({srcEid: srcEid, sender: sender, nonce: 0}), payload, "");
    }

    function harnessReceiveTypedCalldata(Origin calldata origin, bytes calldata payload, bytes calldata extraData)
        external
    {
        _lzReceive(origin, bytes32(0), payload, address(0), extraData);
    }

    function setQuotedNativeFee(uint256 fee) external {
        quotedNativeFee = fee;
    }

    function _quote(
        uint32,
        bytes memory,
        bytes memory,
        bool
    ) internal view override returns (MessagingFee memory fee) {
        return MessagingFee({nativeFee: quotedNativeFee, lzTokenFee: 0});
    }

    function _lzSend(
        uint32 dstEid,
        bytes memory message,
        bytes memory,
        MessagingFee memory fee,
        address
    ) internal override returns (MessagingReceipt memory receipt) {
        sendCount++;
        lastDstEid = dstEid;
        lastPayload = message;
        return MessagingReceipt({guid: bytes32(sendCount), nonce: uint64(sendCount), fee: fee});
    }
}

contract LayerZeroRuntimeFixesTest is Test {
    uint32 internal constant REMOTE_EID = 30101;
    uint32 internal constant HUB_EID = 30102;

    MockEndpoint internal endpoint;
    MockToken internal asset;

    function setUp() public {
        endpoint = new MockEndpoint();
        asset = new MockToken("Mock Asset", "MA");
    }

    function _decodeAmount(bytes memory payload) internal pure returns (uint256 amount) {
        bytes memory data = new bytes(payload.length - 1);
        for (uint256 i = 1; i < payload.length; i++) {
            data[i - 1] = payload[i];
        }
        return abi.decode(data, (uint256));
    }

    function test_SendCredits_EncodesAbsoluteCreditAfterMultipleIncrements() public {
        RecordingCreditManager manager = new RecordingCreditManager(address(endpoint), address(this));
        manager.addChain(REMOTE_EID, 100);

        manager.sendCredits(REMOTE_EID, 50);

        assertEq(manager.sendCount(), 1);
        assertEq(_decodeAmount(manager.lastPayload()), 150);
    }

    function test_SendCredits_UsesConfiguredSatelliteSyncAdapter() public {
        RecordingCreditManager manager = new RecordingCreditManager(address(endpoint), address(this));
        MockCreditSyncAdapter syncAdapter = new MockCreditSyncAdapter();
        manager.addChain(REMOTE_EID, 100);
        manager.setSatelliteSyncAdapter(address(syncAdapter));

        manager.sendCredits{value: 0.05 ether}(REMOTE_EID, 50);

        assertEq(manager.sendCount(), 0);
        assertEq(syncAdapter.sendCount(), 1);
        assertEq(syncAdapter.lastDstEid(), REMOTE_EID);
        assertEq(syncAdapter.lastCredit(), 150);
        assertEq(syncAdapter.lastRefundAddress(), address(this));
        assertEq(syncAdapter.lastNativeFee(), 0.05 ether);
    }

    function test_Rebalance_DecreaseSendsAbsoluteCreditUpdate() public {
        RecordingCreditManager manager = new RecordingCreditManager(address(endpoint), address(this));
        manager.addChain(REMOTE_EID, 150);

        uint32[] memory eids = new uint32[](1);
        uint256[] memory credits = new uint256[](1);
        eids[0] = REMOTE_EID;
        credits[0] = 80;

        manager.rebalance(eids, credits);

        assertEq(manager.sendCount(), 1);
        assertEq(_decodeAmount(manager.lastPayload()), 80);
    }

    function test_SetCredit_SendsAbsoluteCreditUpdate() public {
        RecordingCreditManager manager = new RecordingCreditManager(address(endpoint), address(this));
        manager.addChain(REMOTE_EID, 120);

        manager.setCredit(REMOTE_EID, 75);

        assertEq(manager.sendCount(), 1);
        assertEq(_decodeAmount(manager.lastPayload()), 75);
    }

    function test_CrossChainAssetController_DeployViaBridge_RecordsActualBridgedAmount() public {
        CrossChainAssetController controller = new CrossChainAssetController(address(endpoint), address(this), address(asset));
        MockHubStargateComposer composer = new MockHubStargateComposer();
        address protocol = address(0xA11CE);

        controller.addSupportedChain(REMOTE_EID, address(0xBEEF));
        controller.setHubStargateComposer(address(composer));

        asset.mint(address(controller), 100 ether);
        composer.setBridgedAmount(82 ether);

        controller.deployViaBridge(REMOTE_EID, 100 ether, protocol, "aave");

        assertEq(controller.bridgedDeployedAssets(REMOTE_EID), 82 ether);
        assertEq(controller.totalBridgedDeployed(), 82 ether);
    }

    function test_CrossChainAssetController_UsesGatewayControlPlaneForSupportedChains() public {
        CrossChainAssetControllerHarness controller =
            new CrossChainAssetControllerHarness(address(endpoint), address(this), address(asset));
        address protocol = address(0xA11CE);

        controller.addSupportedChain(REMOTE_EID, address(0xBEEF));
        controller.setQuotedNativeFee(0.05 ether);

        controller.withdrawFromRemote{value: 0.05 ether}(REMOTE_EID, 10 ether, protocol, "aave");
        assertEq(controller.sendCount(), 1);
        assertEq(controller.lastDstEid(), REMOTE_EID);
        assertEq(controller.lastPayload(), MessageCodec.encodeWithdrawAsset(10 ether, protocol, "aave"));

        controller.harvestYield{value: 0.05 ether}(REMOTE_EID, protocol, "aave");
        assertEq(controller.sendCount(), 2);
        assertEq(controller.lastDstEid(), REMOTE_EID);
        assertEq(controller.lastPayload(), MessageCodec.encodeHarvest(protocol, "aave"));
    }

    function test_CrossChainAssetController_RecordBridgedReturn_ReducesBridgeAccounting() public {
        CrossChainAssetController controller = new CrossChainAssetController(address(endpoint), address(this), address(asset));
        MockHubStargateComposer composer = new MockHubStargateComposer();
        address protocol = address(0xA11CE);

        controller.addSupportedChain(REMOTE_EID, address(0xBEEF));
        controller.setHubStargateComposer(address(composer));

        asset.mint(address(controller), 100 ether);
        composer.setBridgedAmount(90 ether);
        controller.deployViaBridge(REMOTE_EID, 100 ether, protocol, "aave");

        vm.prank(address(composer));
        controller.recordBridgedReturn(REMOTE_EID, 25 ether, false);

        assertEq(controller.bridgedDeployedAssets(REMOTE_EID), 65 ether);
        assertEq(controller.totalBridgedDeployed(), 65 ether);
    }

    function test_CrossChainAssetController_DisablesLegacyInboundMessages() public {
        CrossChainAssetControllerHarness controller =
            new CrossChainAssetControllerHarness(address(endpoint), address(this), address(asset));

        controller.addSupportedChain(REMOTE_EID, address(0xBEEF));
        vm.expectRevert(CrossChainAssetController.InboundMessagesDisabled.selector);
        controller.harnessReceive(
            Origin({srcEid: REMOTE_EID, sender: bytes32(0), nonce: 0}),
            MessageCodec.encodeHarvest(address(0xA11CE), "aave")
        );
    }

    function test_CrossChainAssetController_RemoveSupportedChain_RevertsWhenBridgedAssetsExist() public {
        CrossChainAssetController controller = new CrossChainAssetController(address(endpoint), address(this), address(asset));
        MockHubStargateComposer composer = new MockHubStargateComposer();

        controller.addSupportedChain(REMOTE_EID, address(0xBEEF));
        controller.setHubStargateComposer(address(composer));

        asset.mint(address(controller), 100 ether);
        composer.setBridgedAmount(80 ether);
        controller.deployViaBridge(REMOTE_EID, 100 ether, address(0xA11CE), "aave");

        vm.expectRevert(CrossChainAssetController.ChainHasDeployedAssets.selector);
        controller.removeSupportedChain(REMOTE_EID);
    }

    function test_PPTSatellite_CreditUpdateSetsAbsoluteValue() public {
        PPTOFT pptOft = new PPTOFT("Satellite PPT", "spPPT", address(endpoint), address(this), HUB_EID);
        LiquidityPool pool = new LiquidityPool(address(asset), address(this));
        PPTSatelliteHarness satellite =
            new PPTSatelliteHarness(address(endpoint), address(this), address(pptOft), address(pool), address(asset), HUB_EID);

        pool.setSatellite(address(satellite));

        satellite.harnessReceive(HUB_EID, MessageCodec.encodeCreditUpdate(100));
        satellite.harnessReceive(HUB_EID, MessageCodec.encodeCreditUpdate(80));

        assertEq(pool.credit(), 80);
    }

    function test_PPTSatellite_InstantWithdraw_SendsCreditUsedMessageWhenFunded() public {
        address user = address(0xCAFE);
        PPTOFT pptOft = new PPTOFT("Satellite PPT", "spPPT", address(endpoint), address(this), HUB_EID);
        LiquidityPool pool = new LiquidityPool(address(asset), address(this));
        PPTSatelliteHarness satellite =
            new PPTSatelliteHarness(address(endpoint), address(this), address(pptOft), address(pool), address(asset), HUB_EID);
        satellite.setSharePrice(1e18);

        pool.setSatellite(address(satellite));
        asset.mint(address(this), 100 ether);
        asset.approve(address(pool), 100 ether);
        pool.addLiquidity(100 ether);
        pool.updateCredit(100 ether);

        pptOft.mint(user, 10 ether);
        vm.prank(user);
        pptOft.approve(address(satellite), 10 ether);

        satellite.setQuotedNativeFee(0.05 ether);
        vm.deal(address(satellite), 1 ether);

        vm.prank(user);
        satellite.instantWithdraw(10 ether, user);

        assertEq(satellite.sendCount(), 1);
        assertEq(satellite.lastDstEid(), HUB_EID);
        assertEq(satellite.lastPayload(), MessageCodec.encodeCreditUsed(10 ether));
        assertEq(pool.utilized(), 10 ether);
    }

    function test_PPTSatellite_InstantWithdraw_QueuesCreditUsedWhenUnfunded() public {
        address user = address(0xCAFE);
        PPTOFT pptOft = new PPTOFT("Satellite PPT", "spPPT", address(endpoint), address(this), HUB_EID);
        LiquidityPool pool = new LiquidityPool(address(asset), address(this));
        PPTSatelliteHarness satellite =
            new PPTSatelliteHarness(address(endpoint), address(this), address(pptOft), address(pool), address(asset), HUB_EID);
        satellite.setSharePrice(1e18);

        pool.setSatellite(address(satellite));
        asset.mint(address(this), 100 ether);
        asset.approve(address(pool), 100 ether);
        pool.addLiquidity(100 ether);
        pool.updateCredit(100 ether);

        pptOft.mint(user, 15 ether);
        vm.prank(user);
        pptOft.approve(address(satellite), 15 ether);

        satellite.setQuotedNativeFee(0.25 ether);

        vm.prank(user);
        satellite.instantWithdraw(15 ether, user);

        assertEq(satellite.sendCount(), 0);
        assertEq(satellite.pendingCreditUsedCount(), 1);
        assertEq(satellite.pendingCreditUsed(0), 15 ether);
    }

    function test_PPTSatellite_NotifyCreditRestored_SendsRestoreMessageWhenFunded() public {
        PPTOFT pptOft = new PPTOFT("Satellite PPT", "spPPT", address(endpoint), address(this), HUB_EID);
        LiquidityPool pool = new LiquidityPool(address(asset), address(this));
        PPTSatelliteHarness satellite =
            new PPTSatelliteHarness(address(endpoint), address(this), address(pptOft), address(pool), address(asset), HUB_EID);
        address gateway = address(0xBEEF);

        satellite.setSatelliteGateway(gateway);
        satellite.setQuotedNativeFee(0.05 ether);
        vm.deal(address(satellite), 1 ether);

        vm.prank(gateway);
        satellite.notifyCreditRestored(12 ether);

        assertEq(satellite.sendCount(), 1);
        assertEq(satellite.lastDstEid(), HUB_EID);
        assertEq(satellite.lastPayload(), MessageCodec.encodeCreditRestored(12 ether));
    }

    function test_PPTSatellite_WithdrawWithParams_CrossChainOnlyChecksPreviewMinAssets() public {
        address user = address(0xCAFE);
        PPTOFT pptOft = new PPTOFT("Satellite PPT", "spPPT", address(endpoint), address(this), HUB_EID);
        LiquidityPool pool = new LiquidityPool(address(asset), address(this));
        PPTSatelliteHarness satellite =
            new PPTSatelliteHarness(address(endpoint), address(this), address(pptOft), address(pool), address(asset), HUB_EID);

        pptOft.mint(user, 10 ether);
        vm.prank(user);
        pptOft.approve(address(satellite), 10 ether);

        satellite.setQuotedNativeFee(0.05 ether);
        vm.deal(user, 1 ether);

        PPTSatellite.WithdrawParams memory params = PPTSatellite.WithdrawParams({
            shares: 10 ether,
            receiver: user,
            minAssets: 10 ether,
            mode: PPTSatellite.WithdrawMode.CrossChain
        });

        vm.prank(user);
        uint256 assetsReceived = satellite.withdrawWithParams{value: 0.05 ether}(params);

        assertEq(assetsReceived, 0);
        assertEq(satellite.sendCount(), 1);
        assertEq(satellite.lastDstEid(), HUB_EID);
        assertEq(satellite.lastPayload(), MessageCodec.encodeWithdraw(user, 10 ether));
    }

    function test_PPTSatellite_DepositRequiresBridgeGateway() public {
        PPTOFT pptOft = new PPTOFT("Satellite PPT", "spPPT", address(endpoint), address(this), HUB_EID);
        LiquidityPool pool = new LiquidityPool(address(asset), address(this));
        PPTSatelliteHarness satellite =
            new PPTSatelliteHarness(address(endpoint), address(this), address(pptOft), address(pool), address(asset), HUB_EID);
        address user = address(0xCAFE);

        pool.setSatellite(address(satellite));
        satellite.setQuotedNativeFee(0.01 ether);
        asset.mint(user, 25 ether);

        vm.startPrank(user);
        asset.approve(address(satellite), 25 ether);
        vm.expectRevert(PPTSatellite.ZeroAddress.selector);
        satellite.deposit{value: 0.01 ether}(25 ether, user);
        vm.stopPrank();
    }

    function test_PPTSatellite_InstantWithdraw_RevertsWhenSharePriceUninitialized() public {
        address user = address(0xCAFE);
        PPTOFT pptOft = new PPTOFT("Satellite PPT", "spPPT", address(endpoint), address(this), HUB_EID);
        LiquidityPool pool = new LiquidityPool(address(asset), address(this));
        PPTSatelliteHarness satellite =
            new PPTSatelliteHarness(address(endpoint), address(this), address(pptOft), address(pool), address(asset), HUB_EID);

        pool.setSatellite(address(satellite));
        asset.mint(address(this), 100 ether);
        asset.approve(address(pool), 100 ether);
        pool.addLiquidity(100 ether);
        pool.updateCredit(100 ether);
        pptOft.mint(user, 10 ether);
        vm.prank(user);
        pptOft.approve(address(satellite), 10 ether);

        vm.expectRevert(PPTSatellite.SharePriceUninitialized.selector);
        vm.prank(user);
        satellite.instantWithdraw(10 ether, user);
    }

    function test_PPTSatellite_InstantWithdraw_RevertsWhenSharePriceStale() public {
        address user = address(0xCAFE);
        PPTOFT pptOft = new PPTOFT("Satellite PPT", "spPPT", address(endpoint), address(this), HUB_EID);
        LiquidityPool pool = new LiquidityPool(address(asset), address(this));
        PPTSatelliteHarness satellite =
            new PPTSatelliteHarness(address(endpoint), address(this), address(pptOft), address(pool), address(asset), HUB_EID);
        satellite.setSharePrice(1e18);

        pool.setSatellite(address(satellite));
        asset.mint(address(this), 100 ether);
        asset.approve(address(pool), 100 ether);
        pool.addLiquidity(100 ether);
        pool.updateCredit(100 ether);
        pptOft.mint(user, 10 ether);
        vm.prank(user);
        pptOft.approve(address(satellite), 10 ether);

        uint256 staleness = satellite.maxSharePriceStaleness();
        vm.warp(block.timestamp + staleness + 1);

        vm.expectRevert();
        vm.prank(user);
        satellite.instantWithdraw(10 ether, user);
    }

    function test_PPTSatellite_IsSharePriceFresh_TracksInitializationAndStaleness() public {
        PPTOFT pptOft = new PPTOFT("Satellite PPT", "spPPT", address(endpoint), address(this), HUB_EID);
        LiquidityPool pool = new LiquidityPool(address(asset), address(this));
        PPTSatelliteHarness satellite =
            new PPTSatelliteHarness(address(endpoint), address(this), address(pptOft), address(pool), address(asset), HUB_EID);

        assertFalse(satellite.isSharePriceFresh());

        satellite.setSharePrice(1e18);
        assertTrue(satellite.isSharePriceFresh());

        uint256 staleness = satellite.maxSharePriceStaleness();
        vm.warp(block.timestamp + staleness + 1);
        assertFalse(satellite.isSharePriceFresh());
    }

    function test_PPTSatelliteDepositFlow_DoesNotAllowArbitraryLiquidityProviders() public {
        LiquidityPool pool = new LiquidityPool(address(asset), address(this));
        pool.setSatellite(address(0xBEEF));
        address outsider = address(0xCAFE);

        asset.mint(outsider, 100 ether);
        vm.prank(outsider);
        asset.approve(address(pool), 100 ether);

        vm.expectRevert(LiquidityPool.OnlySatellite.selector);
        vm.prank(outsider);
        pool.addLiquidity(100 ether);
    }

    function test_LiquidityPool_AllowsOwnerAndSatelliteToAddLiquidity() public {
        LiquidityPool pool = new LiquidityPool(address(asset), address(this));
        address satellite = address(0xBEEF);
        pool.setSatellite(satellite);

        asset.mint(address(this), 10 ether);
        asset.approve(address(pool), 10 ether);
        pool.addLiquidity(10 ether);
        assertEq(asset.balanceOf(address(pool)), 10 ether);

        asset.mint(satellite, 15 ether);
        vm.prank(satellite);
        asset.approve(address(pool), 15 ether);
        vm.prank(satellite);
        pool.addLiquidity(15 ether);
        assertEq(asset.balanceOf(address(pool)), 25 ether);
    }

    function test_LiquidityPool_AvailableLiquidity_RespectsMinBuffer() public {
        LiquidityPool pool = new LiquidityPool(address(asset), address(this));
        pool.setSatellite(address(0xBEEF));

        asset.mint(address(this), 100 ether);
        asset.approve(address(pool), 100 ether);
        pool.addLiquidity(100 ether);
        pool.updateCredit(100 ether);
        pool.setMinBuffer(30 ether);

        assertEq(pool.availableLiquidity(), 70 ether);
    }

    function test_PPTOFTAdapter_RoutesSatelliteRedemptionToRedemptionManager() public {
        MockToken ppt = new MockToken("Hub PPT", "hPPT");
        MockRedemptionManager redemptionManager = new MockRedemptionManager();
        PPTOFTAdapterHarness adapter = new PPTOFTAdapterHarness(address(ppt), address(endpoint), address(this));
        adapter.setRedemptionManager(address(redemptionManager));

        adapter.harnessHandleSatelliteRedemption(MessageCodec.encodeRedeem(address(0xCAFE), 25 ether));

        assertEq(redemptionManager.lastReceiver(), address(0xCAFE));
        assertEq(redemptionManager.lastShares(), 25 ether);
    }

    function test_PPTOFTAdapter_DisablesLegacySatelliteDepositMessages() public {
        MockToken assetToken = new MockToken("Hub Asset", "hUSDT");
        MockAssetVaultWithSharePrice vault = new MockAssetVaultWithSharePrice(address(assetToken), 1.125 ether, 1);
        PPTOFTAdapterHarness adapter = new PPTOFTAdapterHarness(address(assetToken), address(endpoint), address(this));
        bytes32 peer = bytes32(uint256(0xBEEF));
        address receiver = address(0xCAFE);

        adapter.setPeer(REMOTE_EID, peer);
        adapter.setVault(address(vault));
        adapter.setQuotedNativeFee(0.01 ether);
        vm.deal(address(adapter), 1 ether);
        assetToken.mint(address(adapter), 50 ether);

        vm.expectRevert(abi.encodeWithSelector(PPTOFTAdapter.UnknownMessageType.selector, MessageCodec.MSG_DEPOSIT));
        adapter.harnessReceiveTyped(REMOTE_EID, peer, MessageCodec.encodeDeposit(receiver, 25 ether));
    }

    function test_PPTOFTAdapter_RoutesCreditUsedMessagesIntoCreditManager() public {
        MockToken ppt = new MockToken("Hub PPT", "hPPT");
        RecordingCreditManager manager = new RecordingCreditManager(address(endpoint), address(this));
        PPTOFTAdapterHarness adapter = new PPTOFTAdapterHarness(address(ppt), address(endpoint), address(this));
        bytes32 peer = bytes32(uint256(0xBEEF));

        manager.addChain(REMOTE_EID, 100 ether);
        manager.setOperator(address(adapter), true);
        adapter.setCreditManager(address(manager));
        adapter.setPeer(REMOTE_EID, peer);

        adapter.harnessReceiveTyped(REMOTE_EID, peer, MessageCodec.encodeCreditUsed(25 ether));

        assertEq(manager.credits(REMOTE_EID), 100 ether);
        assertEq(manager.getAvailableCredit(REMOTE_EID), 75 ether);
    }

    function test_PPTOFTAdapter_RoutesCreditRestoredMessagesIntoCreditManager() public {
        MockToken ppt = new MockToken("Hub PPT", "hPPT");
        RecordingCreditManager manager = new RecordingCreditManager(address(endpoint), address(this));
        PPTOFTAdapterHarness adapter = new PPTOFTAdapterHarness(address(ppt), address(endpoint), address(this));
        bytes32 peer = bytes32(uint256(0xBEEF));

        manager.addChain(REMOTE_EID, 100 ether);
        manager.reduceCredit(REMOTE_EID, 25 ether);
        manager.setOperator(address(adapter), true);
        adapter.setCreditManager(address(manager));
        adapter.setPeer(REMOTE_EID, peer);

        adapter.harnessReceiveTyped(REMOTE_EID, peer, MessageCodec.encodeCreditRestored(10 ether));

        assertEq(manager.credits(REMOTE_EID), 100 ether);
        assertEq(manager.getAvailableCredit(REMOTE_EID), 85 ether);
    }

    function test_PPTOFTAdapter_SyncSharePrice_EncodesHubVaultPrice() public {
        MockToken ppt = new MockToken("Hub PPT", "hPPT");
        MockPPTVault vault = new MockPPTVault(1.25 ether);
        PPTOFTAdapterHarness adapter = new PPTOFTAdapterHarness(address(ppt), address(endpoint), address(this));

        adapter.setVault(address(vault));
        adapter.setQuotedNativeFee(0.01 ether);
        vm.deal(address(adapter), 1 ether);

        adapter.syncSharePrice(REMOTE_EID);

        assertEq(adapter.sendCount(), 1);
        assertEq(adapter.lastDstEid(), REMOTE_EID);
        assertEq(adapter.lastPayload(), MessageCodec.encodeSharePriceUpdate(1.25 ether));
    }

    function test_PPTOFTAdapter_SyncSharePrice_QueuesWhenUnfunded() public {
        MockToken ppt = new MockToken("Hub PPT", "hPPT");
        MockPPTVault vault = new MockPPTVault(1.25 ether);
        PPTOFTAdapterHarness adapter = new PPTOFTAdapterHarness(address(ppt), address(endpoint), address(this));

        adapter.setVault(address(vault));
        adapter.setQuotedNativeFee(0.02 ether);

        adapter.syncSharePrice(REMOTE_EID);

        assertEq(adapter.sendCount(), 0);
        assertEq(adapter.pendingSharePriceSyncCount(), 1);
        (uint32 dstEid, uint256 sharePrice) = adapter.pendingSharePriceSyncs(0);
        assertEq(dstEid, REMOTE_EID);
        assertEq(sharePrice, 1.25 ether);
    }

    function test_PPTOFTAdapter_SyncSharePrice_ReusesPendingSlotPerChain() public {
        MockToken ppt = new MockToken("Hub PPT", "hPPT");
        MockPPTVault vault = new MockPPTVault(1.25 ether);
        PPTOFTAdapterHarness adapter = new PPTOFTAdapterHarness(address(ppt), address(endpoint), address(this));

        adapter.setVault(address(vault));
        adapter.setQuotedNativeFee(0.02 ether);

        adapter.syncSharePrice(REMOTE_EID);
        vault.setSharePrice(1.4 ether);
        adapter.syncSharePrice(REMOTE_EID);

        assertEq(adapter.sendCount(), 0);
        assertEq(adapter.pendingSharePriceSyncCount(), 1);
        (uint32 dstEid, uint256 sharePrice) = adapter.pendingSharePriceSyncs(0);
        assertEq(dstEid, REMOTE_EID);
        assertEq(sharePrice, 1.4 ether);
    }

}
