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
import {RemoteAssetAdapter} from "../../src/layerzero/satellite/adapters/RemoteAssetAdapter.sol";
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

contract MockRemoteProtocolImplementation {
    address public lastAsset;
    address public lastProtocol;
    uint256 public lastAmount;
    uint256 public harvestAmount;
    uint256 public withdrawAmount;

    function setWithdrawAmount(uint256 amount) external {
        withdrawAmount = amount;
    }

    function setHarvestAmount(uint256 amount) external {
        harvestAmount = amount;
    }

    function deploy(address asset, address protocol, uint256 amount) external returns (uint256 deployedAmount) {
        lastAsset = asset;
        lastProtocol = protocol;
        lastAmount = amount;
        return amount;
    }

    function withdraw(address asset, address protocol, uint256 amount) external returns (uint256 actualAmount) {
        lastAsset = asset;
        lastProtocol = protocol;
        lastAmount = amount;
        return withdrawAmount == 0 ? amount : withdrawAmount;
    }

    function harvest(address asset, address protocol) external returns (uint256 yieldAmount) {
        lastAsset = asset;
        lastProtocol = protocol;
        return harvestAmount;
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

contract PPTSatelliteHarness is PPTSatellite {
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
}

contract PPTOFTAdapterHarness is PPTOFTAdapter {
    constructor(address token_, address endpoint_, address delegate_) PPTOFTAdapter(token_, endpoint_, delegate_) {}

    function harnessHandleSatelliteRedemption(bytes calldata payload) external {
        this.harnessHandleSatelliteRedemptionCalldata(Origin({srcEid: 0, sender: bytes32(0), nonce: 0}), payload);
    }

    function harnessHandleSatelliteRedemptionCalldata(Origin calldata origin, bytes calldata payload) external {
        _handleSatelliteRedemption(origin, payload);
    }

    function _quote(
        uint32,
        bytes memory,
        bytes memory,
        bool
    ) internal pure override returns (MessagingFee memory fee) {
        return MessagingFee({nativeFee: 0, lzTokenFee: 0});
    }

    function _lzSend(
        uint32,
        bytes memory,
        bytes memory,
        MessagingFee memory _fee,
        address
    ) internal pure override returns (MessagingReceipt memory receipt) {
        return MessagingReceipt({guid: bytes32(0), nonce: 0, fee: _fee});
    }
}

contract RemoteAssetAdapterHarness is RemoteAssetAdapter {
    uint256 public sendCount;
    bytes public lastPayload;

    constructor(address endpoint_, address delegate_, address asset_, uint32 hubEid_)
        RemoteAssetAdapter(endpoint_, delegate_, asset_, hubEid_)
    {}

    function harnessReceive(bytes calldata payload) external {
        this.harnessReceiveCalldata(Origin({srcEid: hubEid, sender: bytes32(0), nonce: 0}), payload, "");
    }

    function harnessReceiveCalldata(Origin calldata origin, bytes calldata payload, bytes calldata extraData) external {
        _lzReceive(origin, bytes32(0), payload, address(0), extraData);
    }

    function _quote(
        uint32,
        bytes memory,
        bytes memory,
        bool
    ) internal pure override returns (MessagingFee memory fee) {
        return MessagingFee({nativeFee: 0, lzTokenFee: 0});
    }

    function _lzSend(
        uint32,
        bytes memory message,
        bytes memory,
        MessagingFee memory _fee,
        address
    ) internal override returns (MessagingReceipt memory receipt) {
        sendCount++;
        lastPayload = message;
        return MessagingReceipt({guid: bytes32(sendCount), nonce: uint64(sendCount), fee: _fee});
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

        assertEq(controller.pendingDeploys(REMOTE_EID), 82 ether);
        assertEq(controller.deployedAssets(REMOTE_EID), 82 ether);
        assertEq(controller.protocolAllocation(REMOTE_EID, protocol), 82 ether);
        assertEq(controller.getTotalDeployedAssets(), 82 ether);
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

    function test_PPTOFTAdapter_RoutesSatelliteRedemptionToRedemptionManager() public {
        MockToken ppt = new MockToken("Hub PPT", "hPPT");
        MockRedemptionManager redemptionManager = new MockRedemptionManager();
        PPTOFTAdapterHarness adapter = new PPTOFTAdapterHarness(address(ppt), address(endpoint), address(this));
        adapter.setRedemptionManager(address(redemptionManager));

        adapter.harnessHandleSatelliteRedemption(MessageCodec.encodeRedeem(address(0xCAFE), 25 ether));

        assertEq(redemptionManager.lastReceiver(), address(0xCAFE));
        assertEq(redemptionManager.lastShares(), 25 ether);
    }

    function test_RemoteAssetAdapter_UsesConfiguredProtocolImplementation() public {
        RemoteAssetAdapterHarness adapter =
            new RemoteAssetAdapterHarness(address(endpoint), address(this), address(asset), HUB_EID);
        MockRemoteProtocolImplementation implementation = new MockRemoteProtocolImplementation();
        address protocol = address(0xA11CE);

        adapter.setProtocolImplementation("aave", address(implementation));
        implementation.setWithdrawAmount(40 ether);
        implementation.setHarvestAmount(7 ether);

        adapter.harnessReceive(MessageCodec.encodeDeploy(50 ether, protocol, "aave"));
        assertEq(adapter.protocolDeposits(protocol), 50 ether);
        assertEq(adapter.totalDeposited(), 50 ether);
        assertEq(implementation.lastAmount(), 50 ether);

        adapter.harnessReceive(MessageCodec.encodeWithdrawAsset(40 ether, protocol, "aave"));
        assertEq(adapter.protocolDeposits(protocol), 10 ether);
        assertEq(adapter.totalDeposited(), 10 ether);
        assertEq(_decodeAmount(adapter.lastPayload()), 40 ether);

        adapter.harnessReceive(MessageCodec.encodeHarvest(protocol, "aave"));
        assertEq(adapter.sendCount(), 2);
        assertEq(_decodeAmount(adapter.lastPayload()), 7 ether);
    }
}
