// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Origin, MessagingFee, MessagingReceipt} from "@layerzero-v2/oapp/contracts/oapp/OApp.sol";
import {RemoteAssetGateway} from "../../src/layerzero/satellite/adapters/RemoteAssetGateway.sol";
import {MessageCodec} from "../../src/layerzero/libraries/MessageCodec.sol";
import {IStargate} from "../../src/layerzero/interfaces/IStargateIntegration.sol";

contract MockEndpoint {
    address public delegate;
    function setDelegate(address _delegate) external { delegate = _delegate; }
}

contract MockToken is ERC20 {
    constructor() ERC20("USDT", "USDT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

/// @notice Configurable mock protocol adapter for M02 scenarios
/// @dev Allows decoupling "what the protocol reports" from "what it actually transfers"
contract DecoupledProtocolAdapter {
    MockToken public immutable asset;
    uint256 public reportedDeploy;   // value returned by deploy()
    uint256 public actualConsumed;   // assets actually transferred from caller
    uint256 public reportedWithdraw; // value returned by withdraw()
    uint256 public actualReturned;   // assets actually transferred to caller

    // When false, uses full amount; when true, uses pre-configured values
    bool public decoupled;

    constructor(address asset_) {
        asset = MockToken(asset_);
    }

    function setDecoupled(bool _decoupled) external { decoupled = _decoupled; }

    function setDeployValues(uint256 reported_, uint256 consumed_) external {
        reportedDeploy = reported_;
        actualConsumed = consumed_;
    }

    function setWithdrawValues(uint256 reported_, uint256 returned_) external {
        reportedWithdraw = reported_;
        actualReturned = returned_;
    }

    function deploy(address, address, uint256 amount) external returns (uint256) {
        if (!decoupled) {
            // Default: pull full amount, report full amount
            asset.transferFrom(msg.sender, address(this), amount);
            return amount;
        }
        if (actualConsumed > 0) {
            asset.transferFrom(msg.sender, address(this), actualConsumed);
        }
        return reportedDeploy;
    }

    function withdraw(address, address, uint256 amount) external returns (uint256) {
        if (!decoupled) {
            asset.transfer(msg.sender, amount);
            return amount;
        }
        if (actualReturned > 0) {
            asset.transfer(msg.sender, actualReturned);
        }
        return reportedWithdraw;
    }

    function harvest(address, address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Mock Stargate pool for bridge paths (no-op send/quote matching IStargate)
contract NoOpStargate {
    function send(IStargate.SendParam calldata, MessagingFee calldata fee, address)
        external
        payable
        returns (MessagingReceipt memory receipt, IStargate.OFTReceipt memory)
    {
        receipt = MessagingReceipt({guid: bytes32(0), nonce: 0, fee: fee});
    }

    function quoteSend(IStargate.SendParam calldata, bool) external pure returns (MessagingFee memory) {
        return MessagingFee({nativeFee: 0, lzTokenFee: 0});
    }
}

/// @notice Harness exposing _handleWithdrawCommand and lzCompose entry for tests
contract RemoteAssetGatewayHarness is RemoteAssetGateway {
    constructor(
        address endpoint_,
        address stargatePool_,
        address asset_,
        uint32 hubEid_,
        uint32 thisEid_,
        address owner_
    ) RemoteAssetGateway(endpoint_, stargatePool_, asset_, hubEid_, thisEid_, owner_) {}

    function harnessHandleWithdraw(bytes calldata payload) external {
        _handleWithdrawCommand(payload);
    }

    function harnessHandleDeploy(uint256 amount, bytes memory composeMsg) external {
        _handleDeploy(amount, composeMsg);
    }

    function _quote(uint32, bytes memory, bytes memory, bool)
        internal
        pure
        override
        returns (MessagingFee memory fee)
    {
        return MessagingFee({nativeFee: 0, lzTokenFee: 0});
    }

    function _lzSend(uint32, bytes memory, bytes memory, MessagingFee memory fee, address)
        internal
        pure
        override
        returns (MessagingReceipt memory receipt)
    {
        return MessagingReceipt({guid: bytes32(0), nonce: 0, fee: fee});
    }
}

/// @notice [M02] balance-delta withdraw/deploy validation in RemoteAssetGateway
contract M02_BalanceDelta is Test {
    uint32 internal constant HUB_EID = 30102;
    uint32 internal constant THIS_EID = 30101;
    address internal constant AAVE_POOL = address(0xA11CE);

    MockEndpoint internal endpoint;
    MockToken internal usdt;
    NoOpStargate internal stargatePool;
    DecoupledProtocolAdapter internal protocolImpl;
    RemoteAssetGatewayHarness internal gateway;

    function setUp() public {
        endpoint = new MockEndpoint();
        usdt = new MockToken();
        stargatePool = new NoOpStargate();
        protocolImpl = new DecoupledProtocolAdapter(address(usdt));

        gateway = new RemoteAssetGatewayHarness(
            address(endpoint),
            address(stargatePool),
            address(usdt),
            HUB_EID,
            THIS_EID,
            address(this)
        );
        gateway.setHubComposer(address(0xBEEF));
        gateway.setProtocolImplementation("aave", address(protocolImpl));
    }

    // ============ Withdraw path ============

    function test_HandleWithdraw_BaselineFullWithdrawSucceeds() public {
        uint256 amount = 1000e6;
        // Deploy first so gateway has a deposit record
        usdt.mint(address(gateway), amount);
        gateway.harnessHandleDeploy(amount, _encodeDeployMsg(AAVE_POOL, "aave"));
        assertEq(gateway.protocolDeposits(AAVE_POOL), amount);

        // Protocol returns full amount
        bytes memory withdrawPayload = MessageCodec.encodeWithdrawAsset(amount, AAVE_POOL, "aave");
        gateway.harnessHandleWithdraw(withdrawPayload);
        assertEq(gateway.protocolDeposits(AAVE_POOL), 0);
    }

    function test_HandleWithdraw_AcceptsOneWeiRoundingDownWithinDust() public {
        uint256 amount = 1000e6;
        usdt.mint(address(gateway), amount);
        gateway.harnessHandleDeploy(amount, _encodeDeployMsg(AAVE_POOL, "aave"));

        // Simulate Aave 1-wei rounding: reported == actualReturned == amount - 1
        protocolImpl.setDecoupled(true);
        protocolImpl.setWithdrawValues(amount - 1, amount - 1);

        bytes memory payload = MessageCodec.encodeWithdrawAsset(amount, AAVE_POOL, "aave");
        gateway.harnessHandleWithdraw(payload);

        // Accepts because shortfall (1 wei) <= defaultDust (2)
        assertEq(gateway.protocolDeposits(AAVE_POOL), 1, "1-wei shortfall should leave 1-wei residual");
    }

    function test_HandleWithdraw_RevertsWhenReportedMismatchesActualBeyondDust() public {
        uint256 amount = 1000e6;
        usdt.mint(address(gateway), amount);
        gateway.harnessHandleDeploy(amount, _encodeDeployMsg(AAVE_POOL, "aave"));

        // Protocol lies: reports 1000e6, actually returns only 500e6
        protocolImpl.setDecoupled(true);
        protocolImpl.setWithdrawValues(amount, 500e6);

        bytes memory payload = MessageCodec.encodeWithdrawAsset(amount, AAVE_POOL, "aave");
        vm.expectRevert(
            abi.encodeWithSelector(RemoteAssetGateway.ReportedActualMismatch.selector, amount, 500e6, 2)
        );
        gateway.harnessHandleWithdraw(payload);
    }

    function test_HandleWithdraw_RevertsOnShortfallExceedingDust() public {
        uint256 amount = 1000e6;
        usdt.mint(address(gateway), amount);
        gateway.harnessHandleDeploy(amount, _encodeDeployMsg(AAVE_POOL, "aave"));

        // Reported and actual consistent, but both 100 wei below requested — > dust
        protocolImpl.setDecoupled(true);
        protocolImpl.setWithdrawValues(amount - 100, amount - 100);

        bytes memory payload = MessageCodec.encodeWithdrawAsset(amount, AAVE_POOL, "aave");
        vm.expectRevert(
            abi.encodeWithSelector(RemoteAssetGateway.ShortfallExceedsDust.selector, amount, amount - 100, 2)
        );
        gateway.harnessHandleWithdraw(payload);
    }

    function test_HandleWithdraw_RevertsOnOverWithdrawal() public {
        uint256 amount = 1000e6;
        usdt.mint(address(gateway), amount);
        gateway.harnessHandleDeploy(amount, _encodeDeployMsg(AAVE_POOL, "aave"));

        // Protocol over-pays
        protocolImpl.setDecoupled(true);
        protocolImpl.setWithdrawValues(amount + 1, amount + 1);
        // Give protocolImpl an extra wei so it can over-send
        usdt.mint(address(protocolImpl), 10);

        bytes memory payload = MessageCodec.encodeWithdrawAsset(amount, AAVE_POOL, "aave");
        vm.expectRevert(
            abi.encodeWithSelector(RemoteAssetGateway.InvalidProtocolAmount.selector, amount, amount + 1)
        );
        gateway.harnessHandleWithdraw(payload);
    }

    // ============ Deploy path ============

    function test_HandleDeploy_UsesActualConsumedForAccounting() public {
        uint256 amount = 1000e6;
        usdt.mint(address(gateway), amount);
        vm.deal(address(gateway), 1 ether);

        // Protocol only consumes 700, returns 700
        protocolImpl.setDecoupled(true);
        protocolImpl.setDeployValues(700e6, 700e6);

        gateway.harnessHandleDeploy(amount, _encodeDeployMsg(AAVE_POOL, "aave"));
        assertEq(gateway.protocolDeposits(AAVE_POOL), 700e6);
        assertEq(gateway.totalDeposited(), 700e6);
    }

    function test_HandleDeploy_RevertsOnReportedMismatch() public {
        uint256 amount = 1000e6;
        usdt.mint(address(gateway), amount);

        // Protocol reports 1000, actually consumes 500
        protocolImpl.setDecoupled(true);
        protocolImpl.setDeployValues(amount, 500e6);

        vm.expectRevert(
            abi.encodeWithSelector(RemoteAssetGateway.ReportedActualMismatch.selector, amount, 500e6, 2)
        );
        gateway.harnessHandleDeploy(amount, _encodeDeployMsg(AAVE_POOL, "aave"));
    }

    // ============ Dust configuration ============

    function test_ProtocolDustOverride_TakesPrecedenceOverDefault() public {
        uint256 amount = 1000e6;
        usdt.mint(address(gateway), amount);
        gateway.harnessHandleDeploy(amount, _encodeDeployMsg(AAVE_POOL, "aave"));

        // Default dust = 2, but for "aave" we allow 100
        gateway.setProtocolDust("aave", 100);

        // 50-wei shortfall — passes with override, would fail with default
        protocolImpl.setDecoupled(true);
        protocolImpl.setWithdrawValues(amount - 50, amount - 50);

        bytes memory payload = MessageCodec.encodeWithdrawAsset(amount, AAVE_POOL, "aave");
        gateway.harnessHandleWithdraw(payload);
    }

    function test_DefaultDust_CanBeUpdated() public {
        vm.expectEmit(true, true, true, true, address(gateway));
        emit RemoteAssetGateway.DefaultDustUpdated(2, 10);
        gateway.setDefaultDust(10);
        assertEq(gateway.defaultDust(), 10);
    }

    // ============ Helpers ============

    function _encodeDeployMsg(address pool, string memory name) internal pure returns (bytes memory) {
        // Mirrors StargateComposeCodec.encodeDeploy: first byte = ACTION_DEPLOY (0x01)
        return abi.encodePacked(uint8(0x01), abi.encode(pool, name));
    }
}
