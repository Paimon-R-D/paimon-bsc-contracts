// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";

import {IStargate} from "../../src/layerzero/interfaces/IStargateIntegration.sol";
import {StargateComposeCodec} from "../../src/layerzero/libraries/StargateComposeCodec.sol";
import {LzOptionsLib} from "../../src/layerzero/libraries/LzOptionsLib.sol";
import {MessageCodec} from "../../src/layerzero/libraries/MessageCodec.sol";
import {CrossChainNAVReporter} from "../../src/layerzero/hub/CrossChainNAVReporter.sol";
import {HubStargateComposer} from "../../src/layerzero/hub/HubStargateComposer.sol";
import {SatelliteGateway} from "../../src/layerzero/satellite/SatelliteGateway.sol";
import {RemoteAssetGateway} from "../../src/layerzero/satellite/adapters/RemoteAssetGateway.sol";

// ========== Mock Contracts ==========

contract MockToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock Stargate pool that stores sends and allows simulating compose callbacks
contract MockStargatePool {
    struct LastSend {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes composeMsg;
        uint256 nativeFee;
    }

    LastSend public lastSend;
    uint256 public sendCount;
    IERC20 public token;
    uint256 public quoteFee = 0.01 ether;
    uint256 public amountReceivedLD;

    constructor(address _token) {
        token = IERC20(_token);
    }

    function send(
        IStargate.SendParam calldata params,
        MessagingFee calldata,
        address
    ) external payable returns (MessagingReceipt memory receipt, IStargate.OFTReceipt memory oftReceipt) {
        token.transferFrom(msg.sender, address(this), params.amountLD);
        lastSend = LastSend({
            dstEid: params.dstEid,
            to: params.to,
            amountLD: params.amountLD,
            minAmountLD: params.minAmountLD,
            composeMsg: params.composeMsg,
            nativeFee: msg.value
        });
        sendCount++;
        receipt = MessagingReceipt({guid: bytes32(sendCount), nonce: uint64(sendCount), fee: MessagingFee(msg.value, 0)});
        uint256 actualReceived = amountReceivedLD == 0 ? params.amountLD : amountReceivedLD;
        oftReceipt = IStargate.OFTReceipt({amountSentLD: params.amountLD, amountReceivedLD: actualReceived});
    }

    function quoteSend(IStargate.SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: quoteFee, lzTokenFee: 0});
    }

    function setQuoteFee(uint256 _fee) external {
        quoteFee = _fee;
    }

    function setAmountReceivedLD(uint256 _amount) external {
        amountReceivedLD = _amount;
    }

    function getLastSendDstEid() external view returns (uint32) {
        return lastSend.dstEid;
    }

    function getLastSendAmountLD() external view returns (uint256) {
        return lastSend.amountLD;
    }

    function getLastSendTo() external view returns (bytes32) {
        return lastSend.to;
    }
}

/// @dev Mock Vault (ERC4626-like) that records deposits
contract MockVault {
    IERC20 public asset;
    uint256 public shareRate = 1e18; // 1:1 default
    uint256 public lastDepositAssets;
    address public lastDepositReceiver;

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        lastDepositAssets = assets;
        lastDepositReceiver = receiver;
        shares = (assets * 1e18) / shareRate;
        return shares;
    }

    function setShareRate(uint256 _rate) external {
        shareRate = _rate;
    }
}

/// @dev Mock PPTOFTAdapter to capture mintSharesOnSatellite calls
contract MockPPTOFTAdapter {
    uint32 public lastDstEid;
    address public lastReceiver;
    uint256 public lastShares;
    uint256 public mintCallCount;

    function mintSharesOnSatellite(uint32 dstEid, address receiver, uint256 shares) external {
        lastDstEid = dstEid;
        lastReceiver = receiver;
        lastShares = shares;
        mintCallCount++;
    }
}

/// @dev Mock LiquidityPool for SatelliteGateway tests
contract MockLiquidityPool {
    IERC20 public asset;
    uint256 public lastLiquidityAdded;
    uint256 public lastReplenished;
    address public satellite;

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    function addLiquidity(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        lastLiquidityAdded = amount;
    }

    function replenish(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        lastReplenished = amount;
        lastLiquidityAdded = amount;
    }

    function setSatellite(address _satellite) external {
        satellite = _satellite;
    }
}

/// @dev Mock protocol implementation for RemoteAssetGateway
contract MockProtocolImpl {
    IERC20 public asset;
    uint256 public lastDeployAmount;
    uint256 public lastWithdrawAmount;
    uint256 public harvestReturn;
    uint256 public deployReturn;

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    function deploy(address, address, uint256 amount) external returns (uint256) {
        uint256 deployedAmount = deployReturn == 0 ? amount : deployReturn;
        asset.transferFrom(msg.sender, address(this), deployedAmount);
        lastDeployAmount = deployedAmount;
        return deployedAmount;
    }

    function withdraw(address, address, uint256 amount) external returns (uint256) {
        asset.transfer(msg.sender, amount);
        lastWithdrawAmount = amount;
        return amount;
    }

    function harvest(address, address) external returns (uint256) {
        if (harvestReturn > 0) {
            asset.transfer(msg.sender, harvestReturn);
        }
        return harvestReturn;
    }

    function setHarvestReturn(uint256 _amount) external {
        harvestReturn = _amount;
    }

    function setDeployReturn(uint256 _amount) external {
        deployReturn = _amount;
    }
}

contract RemoteAssetGatewayHarness is RemoteAssetGateway {
    constructor(
        address endpoint_,
        address stargatePool_,
        address asset_,
        uint32 hubEid_,
        uint32 thisEid_,
        address owner_
    ) RemoteAssetGateway(endpoint_, stargatePool_, asset_, hubEid_, thisEid_, owner_) {}

    function harnessReceive(Origin calldata origin, bytes calldata payload) external {
        this.harnessReceiveCalldata(origin, payload, "");
    }

    function harnessReceiveCalldata(Origin calldata origin, bytes calldata payload, bytes calldata extraData) external {
        _lzReceive(origin, bytes32(0), payload, address(0), extraData);
    }
}

// ========== Test Suite ==========

contract StargateCodecTest is Test {
    // ========== StargateComposeCodec Round-Trip Tests ==========

    function test_EncodeDecodeDeposit() public pure {
        address receiver = address(0xCAFE);
        uint256 minShares = 100e18;

        bytes memory encoded = StargateComposeCodec.encodeDeposit(receiver, minShares);
        uint8 action = StargateComposeCodec.decodeAction(encoded);
        (address decodedReceiver, uint256 decodedMinShares) = StargateComposeCodec.decodeDeposit(encoded);

        assertEq(action, StargateComposeCodec.ACTION_DEPOSIT);
        assertEq(decodedReceiver, receiver);
        assertEq(decodedMinShares, minShares);
    }

    function test_EncodeDecodeSettlement() public pure {
        address receiver = address(0xBEEF);
        uint256 requestId = 42;

        bytes memory encoded = StargateComposeCodec.encodeSettlement(receiver, requestId);
        uint8 action = StargateComposeCodec.decodeAction(encoded);
        (address decodedReceiver, uint256 decodedRequestId) = StargateComposeCodec.decodeSettlement(encoded);

        assertEq(action, StargateComposeCodec.ACTION_SETTLEMENT);
        assertEq(decodedReceiver, receiver);
        assertEq(decodedRequestId, requestId);
    }

    function test_EncodeDecodeDeploy() public pure {
        address protocol = address(0xA11CE);
        string memory protocolName = "aave-v3";

        bytes memory encoded = StargateComposeCodec.encodeDeploy(protocol, protocolName);
        uint8 action = StargateComposeCodec.decodeAction(encoded);
        (address decodedProtocol, string memory decodedName) = StargateComposeCodec.decodeDeploy(encoded);

        assertEq(action, StargateComposeCodec.ACTION_DEPLOY);
        assertEq(decodedProtocol, protocol);
        assertEq(decodedName, protocolName);
    }

    function test_EncodeDecodeReturn() public pure {
        bool isYield = true;

        bytes memory encoded = StargateComposeCodec.encodeReturn(isYield);
        uint8 action = StargateComposeCodec.decodeAction(encoded);
        bool decodedIsYield = StargateComposeCodec.decodeReturn(encoded);

        assertEq(action, StargateComposeCodec.ACTION_RETURN);
        assertEq(decodedIsYield, isYield);
    }

    function test_EncodeDecodeReplenish() public pure {
        bytes memory encoded = StargateComposeCodec.encodeReplenish();
        uint8 action = StargateComposeCodec.decodeAction(encoded);

        assertEq(action, StargateComposeCodec.ACTION_REPLENISH);
    }

    // ========== LzOptionsLib Tests ==========

    function test_BuildLzReceiveOptions_Type3Format() public pure {
        bytes memory options = LzOptionsLib.buildLzReceiveOptions(200_000);

        // Type 3 header
        assertEq(uint16(bytes2(abi.encodePacked(options[0], options[1]))), 3);
        assertTrue(options.length > 2);
    }

    function test_BuildComposeOptions_ContainsBothReceiveAndCompose() public pure {
        bytes memory options = LzOptionsLib.buildComposeOptions(65_000, 300_000);

        // Type 3 header
        assertEq(uint16(bytes2(abi.encodePacked(options[0], options[1]))), 3);
        // Should contain both receive and compose options (larger than simple receive)
        assertTrue(options.length > 21); // receive option = 21 bytes, compose adds more
    }
}

contract CrossChainNAVReporterTest is Test {
    CrossChainNAVReporter reporter;
    uint32 constant ETH_EID = 30101;
    uint32 constant ARB_EID = 30110;

    function setUp() public {
        reporter = new CrossChainNAVReporter(address(this));
        reporter.addChain(ETH_EID);
        reporter.addChain(ARB_EID);
    }

    function test_GetCrossChainValue_SumsAllChains() public {
        reporter.updateSatelliteBalance(ETH_EID, 100e6);
        reporter.updateRemoteDeployment(ETH_EID, 500e6);
        reporter.updateSatelliteBalance(ARB_EID, 50e6);
        reporter.updateRemoteDeployment(ARB_EID, 200e6);

        uint256 total = reporter.getCrossChainValue();
        assertEq(total, 850e6);
    }

    function test_RecordDeploy_IncreasesRemoteDeployment() public {
        reporter.recordDeploy(ETH_EID, 100e6);
        reporter.recordDeploy(ETH_EID, 50e6);

        assertEq(reporter.remoteDeployments(ETH_EID), 150e6);
    }

    function test_RecordReturn_ReducesRemoteDeployment() public {
        reporter.recordDeploy(ETH_EID, 100e6);
        reporter.recordReturn(ETH_EID, 40e6, false);

        assertEq(reporter.remoteDeployments(ETH_EID), 60e6);
    }

    function test_RecordReturn_Yield_DoesNotReduceDeployment() public {
        reporter.recordDeploy(ETH_EID, 100e6);
        reporter.recordReturn(ETH_EID, 10e6, true);

        assertEq(reporter.remoteDeployments(ETH_EID), 100e6);
    }

    function test_IsStale_ReturnsTrueWhenExpired() public {
        reporter.updateSatelliteBalance(ETH_EID, 100e6);

        assertFalse(reporter.isStale(ETH_EID));

        vm.warp(block.timestamp + 7201); // > 2 hours
        assertTrue(reporter.isStale(ETH_EID));
    }

    function test_RemoveChain_ClearsData() public {
        reporter.updateSatelliteBalance(ETH_EID, 100e6);
        reporter.recordDeploy(ETH_EID, 200e6);

        reporter.removeChain(ETH_EID);

        assertEq(reporter.satelliteBalances(ETH_EID), 0);
        assertEq(reporter.remoteDeployments(ETH_EID), 0);

        uint32[] memory chains = reporter.getChains();
        assertEq(chains.length, 1);
        assertEq(chains[0], ARB_EID);
    }

    function test_ChainPosition_ReturnsCompleteData() public {
        reporter.updateSatelliteBalance(ETH_EID, 100e6);
        reporter.recordDeploy(ETH_EID, 200e6);

        (uint256 satellite, uint256 deployed, , uint256 lastUpdate) = reporter.getChainPosition(ETH_EID);
        assertEq(satellite, 100e6);
        assertEq(deployed, 200e6);
        assertEq(lastUpdate, block.timestamp);
    }

    function test_GetCrossChainValue_TracksReplacementDeltasAndRemoval() public {
        reporter.updateSatelliteBalance(ETH_EID, 100e6);
        reporter.recordDeploy(ETH_EID, 200e6);
        assertEq(reporter.getCrossChainValue(), 300e6);

        reporter.updateSatelliteBalance(ETH_EID, 40e6);
        assertEq(reporter.getCrossChainValue(), 240e6);

        reporter.updateRemoteDeployment(ETH_EID, 150e6);
        assertEq(reporter.getCrossChainValue(), 190e6);

        reporter.removeChain(ETH_EID);
        assertEq(reporter.getCrossChainValue(), 0);
    }

    function test_GetCrossChainValue_RevertsWhenGlobalSyncIsStaleAndEnforced() public {
        reporter.setEnforceGlobalFreshness(true);

        vm.expectRevert(abi.encodeWithSelector(CrossChainNAVReporter.StaleCrossChainValue.selector, 0, 7200));
        reporter.getCrossChainValue();
    }

    function test_BatchSyncChainPositions_CommitsFreshSnapshot() public {
        uint32[] memory eids = new uint32[](2);
        uint256[] memory satelliteBalances = new uint256[](2);
        uint256[] memory remoteDeployments = new uint256[](2);

        eids[0] = ETH_EID;
        eids[1] = ARB_EID;
        satelliteBalances[0] = 100e6;
        satelliteBalances[1] = 50e6;
        remoteDeployments[0] = 500e6;
        remoteDeployments[1] = 200e6;

        reporter.batchSyncChainPositions(eids, satelliteBalances, remoteDeployments);
        reporter.setEnforceGlobalFreshness(true);

        assertEq(reporter.getCrossChainValue(), 850e6);

        uint256 lastGlobalSyncTime = reporter.lastGlobalSyncTime();
        vm.warp(block.timestamp + 7201);
        vm.expectRevert(
            abi.encodeWithSelector(CrossChainNAVReporter.StaleCrossChainValue.selector, lastGlobalSyncTime, 7200)
        );
        reporter.getCrossChainValue();
    }
}

contract HubStargateComposerTest is Test {
    HubStargateComposer composer;
    MockToken usdt;
    MockVault vault;
    MockPPTOFTAdapter pptAdapter;
    CrossChainNAVReporter navReporter;
    MockStargatePool stargatePool;
    address mockEndpoint;

    uint32 constant ETH_EID = 30101;
    address constant SATELLITE_GATEWAY = address(0x1234);
    address constant REMOTE_GATEWAY = address(0x5678);
    address constant USER = address(0xCAFE);

    function setUp() public {
        usdt = new MockToken("USDT", "USDT", 6);
        stargatePool = new MockStargatePool(address(usdt));
        mockEndpoint = makeAddr("endpoint");
        vault = new MockVault(address(usdt));
        pptAdapter = new MockPPTOFTAdapter();
        navReporter = new CrossChainNAVReporter(address(this));

        composer = new HubStargateComposer(
            mockEndpoint,
            address(stargatePool),
            address(usdt),
            address(this)
        );

        composer.setVault(address(vault));
        composer.setPptOftAdapter(address(pptAdapter));
        composer.setNavReporter(address(navReporter));
        composer.setSatelliteGateway(ETH_EID, SATELLITE_GATEWAY);
        composer.setRemoteAssetGateway(ETH_EID, REMOTE_GATEWAY);

        navReporter.addChain(ETH_EID);
        navReporter.grantRole(navReporter.REPORTER_ROLE(), address(composer));
    }

    function test_HandleDeposit_ViaCompose() public {
        uint256 depositAmount = 1000e6;
        usdt.mint(address(composer), depositAmount);

        // Build the OFTComposeMsgCodec-style message
        bytes memory composeMsg = StargateComposeCodec.encodeDeposit(USER, 0);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, depositAmount, SATELLITE_GATEWAY, composeMsg);

        vm.prank(mockEndpoint);
        composer.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        // Vault should have received USDT
        assertEq(vault.lastDepositAssets(), depositAmount);

        // PPTOFTAdapter should have been asked to send shares back
        assertEq(pptAdapter.mintCallCount(), 1);
        assertEq(pptAdapter.lastDstEid(), ETH_EID);
        assertEq(pptAdapter.lastReceiver(), USER);
        assertEq(pptAdapter.lastShares(), depositAmount); // 1:1 rate
    }

    function test_HandleReturn_UpdatesNAVReporter() public {
        navReporter.recordDeploy(ETH_EID, 500e6);

        uint256 returnAmount = 200e6;
        usdt.mint(address(composer), returnAmount);

        bytes memory composeMsg = StargateComposeCodec.encodeReturn(false);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, returnAmount, REMOTE_GATEWAY, composeMsg);

        vm.prank(mockEndpoint);
        composer.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        assertEq(navReporter.remoteDeployments(ETH_EID), 300e6);
    }

    function test_HandleReturn_UsesOuterSrcEidForAccounting_NotInnerPayload() public {
        uint32 ARB_EID = 30110;
        address ARB_GATEWAY = address(0x9ABC);
        navReporter.addChain(ARB_EID);
        composer.setRemoteAssetGateway(ARB_EID, ARB_GATEWAY);
        navReporter.recordDeploy(ETH_EID, 500e6);
        navReporter.recordDeploy(ARB_EID, 700e6);

        uint256 returnAmount = 200e6;
        usdt.mint(address(composer), returnAmount);

        // Return originates from ARB's authenticated gateway and outer srcEid.
        // After bug_001 fix, the payload no longer carries a srcEid: the composer
        // credits ARB solely from the LayerZero-authenticated outer header.
        bytes memory composeMsg = StargateComposeCodec.encodeReturn(false);
        bytes memory fullMessage = _buildComposeMessage(ARB_EID, returnAmount, ARB_GATEWAY, composeMsg);

        vm.prank(mockEndpoint);
        composer.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        assertEq(navReporter.remoteDeployments(ARB_EID), 500e6);
        assertEq(navReporter.remoteDeployments(ETH_EID), 500e6);
    }

    function test_SettleAndBridge_SendsViaSargate() public {
        uint256 amount = 500e6;
        usdt.mint(address(composer), amount);

        vm.deal(address(this), 1 ether);
        composer.settleAndBridge{value: 0.01 ether}(ETH_EID, USER, amount, 42);

        assertEq(stargatePool.sendCount(), 1);
        assertEq(stargatePool.getLastSendDstEid(), ETH_EID);
        assertEq(stargatePool.getLastSendAmountLD(), amount);
        assertEq(stargatePool.getLastSendTo(), bytes32(uint256(uint160(SATELLITE_GATEWAY))));
    }

    function test_BridgeAndDeploy_UpdatesNAVReporter() public {
        uint256 amount = 300e6;
        usdt.mint(address(composer), amount);

        vm.deal(address(this), 1 ether);
        composer.bridgeAndDeploy{value: 0.01 ether}(ETH_EID, amount, address(0xA11CE), "aave");

        assertEq(stargatePool.sendCount(), 1);
        assertEq(navReporter.remoteDeployments(ETH_EID), 300e6);
        assertEq(stargatePool.getLastSendTo(), bytes32(uint256(uint160(REMOTE_GATEWAY))));
    }

    function test_BridgeAndDeploy_UsesActualReceivedAmountForNAV() public {
        uint256 amount = 300e6;
        uint256 actualReceived = 287e6;
        usdt.mint(address(composer), amount);
        stargatePool.setAmountReceivedLD(actualReceived);

        vm.deal(address(this), 1 ether);
        composer.bridgeAndDeploy{value: 0.01 ether}(ETH_EID, amount, address(0xA11CE), "aave");

        assertEq(navReporter.remoteDeployments(ETH_EID), actualReceived);
    }

    function test_ReplenishLiquidity_BridgesViaSargate() public {
        uint256 amount = 100e6;
        usdt.mint(address(composer), amount);

        vm.deal(address(this), 1 ether);
        composer.replenishLiquidity{value: 0.01 ether}(ETH_EID, amount);

        assertEq(stargatePool.sendCount(), 1);
        assertEq(stargatePool.getLastSendAmountLD(), amount);
        assertEq(stargatePool.getLastSendTo(), bytes32(uint256(uint160(SATELLITE_GATEWAY))));
    }

    function test_RevertOnReturnFromSatelliteGateway() public {
        bytes memory composeMsg = StargateComposeCodec.encodeReturn(false);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, 100e6, SATELLITE_GATEWAY, composeMsg);

        vm.prank(mockEndpoint);
        vm.expectRevert(
            abi.encodeWithSelector(HubStargateComposer.UntrustedSource.selector, ETH_EID, SATELLITE_GATEWAY)
        );
        composer.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");
    }

    function test_RevertOnUntrustedGateway() public {
        bytes memory composeMsg = StargateComposeCodec.encodeDeposit(USER, 0);
        address untrusted = address(0xDEAD);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, 100e6, untrusted, composeMsg);

        vm.prank(mockEndpoint);
        vm.expectRevert(abi.encodeWithSelector(HubStargateComposer.UntrustedSource.selector, ETH_EID, untrusted));
        composer.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");
    }

    function test_RevertOnNonEndpoint() public {
        bytes memory composeMsg = StargateComposeCodec.encodeDeposit(USER, 0);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, 100e6, SATELLITE_GATEWAY, composeMsg);

        vm.expectRevert(HubStargateComposer.OnlyEndpoint.selector);
        composer.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");
    }

    function test_RevertOnNonStargate() public {
        bytes memory composeMsg = StargateComposeCodec.encodeDeposit(USER, 0);
        bytes memory fullMessage = _buildComposeMessage(ETH_EID, 100e6, SATELLITE_GATEWAY, composeMsg);

        vm.prank(mockEndpoint);
        vm.expectRevert(HubStargateComposer.OnlyStargate.selector);
        composer.lzCompose{value: 0}(address(0xBAD), bytes32(0), fullMessage, address(0), "");
    }

    // Helper to build OFTComposeMsgCodec-formatted message
    function _buildComposeMessage(
        uint32 srcEid,
        uint256 amountLD,
        address composeFrom,
        bytes memory composeMsg
    ) internal pure returns (bytes memory) {
        // OFTComposeMsgCodec layout:
        // [nonce (8B)][srcEid (4B)][amountLD (32B)][composeFrom (32B)][composeMsg (variable)]
        return abi.encodePacked(
            uint64(1), // nonce
            srcEid,
            amountLD,
            bytes32(uint256(uint160(composeFrom))),
            composeMsg
        );
    }
}

contract SatelliteGatewayTest is Test {
    SatelliteGateway gateway;
    MockToken usdt;
    MockStargatePool stargatePool;
    MockLiquidityPool liquidityPool;
    address mockEndpoint;

    uint32 constant HUB_EID = 30102;
    address constant HUB_COMPOSER = address(0x4455BB);
    address constant USER = address(0xCAFE);

    function setUp() public {
        usdt = new MockToken("USDT", "USDT", 6);
        stargatePool = new MockStargatePool(address(usdt));
        mockEndpoint = makeAddr("endpoint");
        liquidityPool = new MockLiquidityPool(address(usdt));

        gateway = new SatelliteGateway(
            mockEndpoint,
            address(stargatePool),
            address(usdt),
            HUB_EID,
            address(this)
        );

        gateway.setHubComposer(HUB_COMPOSER);
        gateway.setLiquidityPool(address(liquidityPool));
    }

    function test_HandleSettlement_TransfersToReceiver() public {
        uint256 amount = 500e6;
        usdt.mint(address(gateway), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeSettlement(USER, 42);
        bytes memory fullMessage = _buildComposeMessage(HUB_EID, amount, HUB_COMPOSER, composeMsg);

        vm.prank(mockEndpoint);
        gateway.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        assertEq(usdt.balanceOf(USER), amount);
    }

    function test_HandleReplenish_AddsToLiquidityPool() public {
        uint256 amount = 200e6;
        usdt.mint(address(gateway), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeReplenish();
        bytes memory fullMessage = _buildComposeMessage(HUB_EID, amount, HUB_COMPOSER, composeMsg);

        vm.prank(mockEndpoint);
        gateway.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        assertEq(liquidityPool.lastLiquidityAdded(), amount);
    }

    function test_Deposit_BridgesViaSargate() public {
        uint256 amount = 1000e6;
        usdt.mint(USER, amount);
        stargatePool.setQuoteFee(0.01 ether);

        vm.startPrank(USER);
        usdt.approve(address(gateway), amount);
        vm.deal(USER, 1 ether);
        gateway.deposit{value: 0.1 ether}(amount, USER, 0);
        vm.stopPrank();

        assertEq(stargatePool.sendCount(), 1);
        assertEq(stargatePool.getLastSendAmountLD(), amount);
        assertEq(stargatePool.getLastSendDstEid(), HUB_EID);
    }

    function test_RevertOnUntrustedCompose() public {
        bytes memory composeMsg = StargateComposeCodec.encodeSettlement(USER, 1);
        address untrusted = address(0xBAD);
        bytes memory fullMessage = _buildComposeMessage(HUB_EID, 100e6, untrusted, composeMsg);

        vm.prank(mockEndpoint);
        vm.expectRevert(abi.encodeWithSelector(SatelliteGateway.UntrustedSource.selector, untrusted));
        gateway.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");
    }

    function test_RevertOnUnexpectedComposeSourceEid() public {
        bytes memory composeMsg = StargateComposeCodec.encodeSettlement(USER, 1);
        bytes memory fullMessage = _buildComposeMessage(HUB_EID + 1, 100e6, HUB_COMPOSER, composeMsg);

        vm.prank(mockEndpoint);
        vm.expectRevert(abi.encodeWithSelector(SatelliteGateway.UnexpectedSourceEid.selector, HUB_EID + 1));
        gateway.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");
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

contract RemoteAssetGatewayTest is Test {
    RemoteAssetGatewayHarness gateway;
    MockToken usdt;
    MockStargatePool stargatePool;
    MockProtocolImpl aaveImpl;
    address mockEndpoint;

    uint32 constant HUB_EID = 30102;
    uint32 constant THIS_EID = 30101;
    address constant HUB_COMPOSER = address(0x4455BB);
    address constant AAVE_POOL = address(0xA11CE);

    function setUp() public {
        usdt = new MockToken("USDT", "USDT", 6);
        stargatePool = new MockStargatePool(address(usdt));
        mockEndpoint = makeAddr("endpoint");
        aaveImpl = new MockProtocolImpl(address(usdt));

        gateway = new RemoteAssetGatewayHarness(
            mockEndpoint,
            address(stargatePool),
            address(usdt),
            HUB_EID,
            THIS_EID,
            address(this)
        );

        gateway.setHubComposer(HUB_COMPOSER);
        gateway.setProtocolImplementation("aave", address(aaveImpl));
    }

    function test_HandleDeploy_DepositsToProtocol() public {
        uint256 amount = 1000e6;
        usdt.mint(address(gateway), amount);

        bytes memory composeMsg = StargateComposeCodec.encodeDeploy(AAVE_POOL, "aave");
        bytes memory fullMessage = _buildComposeMessage(HUB_EID, amount, HUB_COMPOSER, composeMsg);

        vm.prank(mockEndpoint);
        gateway.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        assertEq(aaveImpl.lastDeployAmount(), amount);
        assertEq(gateway.protocolDeposits(AAVE_POOL), amount);
        assertEq(gateway.totalDeposited(), amount);
    }

    function test_HandleDeploy_PartialDeploy_ReturnsUndeployedRemainder() public {
        uint256 amount = 1000e6;
        uint256 deployedAmount = 700e6;
        usdt.mint(address(gateway), amount);
        aaveImpl.setDeployReturn(deployedAmount);
        vm.deal(address(gateway), 1 ether);

        bytes memory composeMsg = StargateComposeCodec.encodeDeploy(AAVE_POOL, "aave");
        bytes memory fullMessage = _buildComposeMessage(HUB_EID, amount, HUB_COMPOSER, composeMsg);

        vm.prank(mockEndpoint);
        gateway.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        assertEq(aaveImpl.lastDeployAmount(), deployedAmount);
        assertEq(gateway.protocolDeposits(AAVE_POOL), deployedAmount);
        assertEq(gateway.totalDeposited(), deployedAmount);
        assertEq(stargatePool.sendCount(), 1);
        assertEq(stargatePool.getLastSendAmountLD(), amount - deployedAmount);
        assertEq(stargatePool.getLastSendDstEid(), HUB_EID);
    }

    function test_RevertOnUnknownAction() public {
        bytes memory composeMsg = abi.encodePacked(uint8(0xFF)); // unknown action
        bytes memory fullMessage = _buildComposeMessage(HUB_EID, 100e6, HUB_COMPOSER, composeMsg);

        vm.prank(mockEndpoint);
        vm.expectRevert(abi.encodeWithSelector(RemoteAssetGateway.UnknownAction.selector, 0xFF));
        gateway.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");
    }

    function test_RevertOnUnexpectedComposeSourceEid() public {
        bytes memory composeMsg = StargateComposeCodec.encodeDeploy(AAVE_POOL, "aave");
        bytes memory fullMessage = _buildComposeMessage(HUB_EID + 1, 100e6, HUB_COMPOSER, composeMsg);

        vm.prank(mockEndpoint);
        vm.expectRevert(abi.encodeWithSelector(RemoteAssetGateway.UnexpectedSourceEid.selector, HUB_EID + 1));
        gateway.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");
    }

    function test_HubReceive_WithdrawCommand_BridgesBackToHub() public {
        uint256 deployAmount = 1000e6;
        uint256 withdrawAmount = 400e6;
        usdt.mint(address(gateway), deployAmount);

        bytes memory composeMsg = StargateComposeCodec.encodeDeploy(AAVE_POOL, "aave");
        bytes memory fullMessage = _buildComposeMessage(HUB_EID, deployAmount, HUB_COMPOSER, composeMsg);

        vm.prank(mockEndpoint);
        gateway.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        usdt.mint(address(aaveImpl), withdrawAmount);
        vm.deal(address(gateway), 1 ether);
        gateway.harnessReceive(Origin({srcEid: HUB_EID, sender: bytes32(0), nonce: 0}), MessageCodec.encodeWithdrawAsset(withdrawAmount, AAVE_POOL, "aave"));

        assertEq(gateway.protocolDeposits(AAVE_POOL), deployAmount - withdrawAmount);
        assertEq(gateway.totalDeposited(), deployAmount - withdrawAmount);
        assertEq(stargatePool.sendCount(), 1);
        assertEq(stargatePool.getLastSendDstEid(), HUB_EID);
        assertEq(stargatePool.getLastSendAmountLD(), withdrawAmount);
    }

    function test_HubReceive_HarvestCommand_BridgesYieldToHub() public {
        uint256 deployAmount = 1000e6;
        uint256 yieldAmount = 75e6;
        usdt.mint(address(gateway), deployAmount);

        bytes memory composeMsg = StargateComposeCodec.encodeDeploy(AAVE_POOL, "aave");
        bytes memory fullMessage = _buildComposeMessage(HUB_EID, deployAmount, HUB_COMPOSER, composeMsg);

        vm.prank(mockEndpoint);
        gateway.lzCompose{value: 0}(address(stargatePool), bytes32(0), fullMessage, address(0), "");

        usdt.mint(address(aaveImpl), yieldAmount);
        aaveImpl.setHarvestReturn(yieldAmount);
        vm.deal(address(gateway), 1 ether);
        gateway.harnessReceive(Origin({srcEid: HUB_EID, sender: bytes32(0), nonce: 0}), MessageCodec.encodeHarvest(AAVE_POOL, "aave"));

        assertEq(gateway.protocolDeposits(AAVE_POOL), deployAmount);
        assertEq(gateway.totalDeposited(), deployAmount);
        assertEq(stargatePool.sendCount(), 1);
        assertEq(stargatePool.getLastSendDstEid(), HUB_EID);
        assertEq(stargatePool.getLastSendAmountLD(), yieldAmount);
    }

    function test_HubReceive_RevertsWhenSourceIsNotHub() public {
        vm.expectRevert(RemoteAssetGateway.OnlyHub.selector);
        gateway.harnessReceive(Origin({srcEid: THIS_EID, sender: bytes32(0), nonce: 0}), MessageCodec.encodeHarvest(AAVE_POOL, "aave"));
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
