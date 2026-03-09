# LayerZero Audit Package

This document serves as the audit deliverable for the Paimon Finance LayerZero module.
It is recommended to bundle this document together with the corresponding commit, deployment address table, configuration table, test report, and business description for the audit firm.

## 1. Audit Objective

This audit covers only the cross-chain module under `src/layerzero/`, with a focus on verifying the following capabilities meet production-grade quality:

- Multi-chain subscription (deposit)
- Cross-chain redemption
- Cross-chain portfolio deploy / withdraw / harvest
- LayerZero V2 / Stargate V2 integration security
- Permission boundaries, error paths, accounting consistency, message source verification

## 2. Current Code Snapshot

- Branch: `feat/layerzero-cross-chain`
- Working commit base: `36aea69047a1323e789e0a8a4635d4c6ece44079`
- Solidity compiler: `0.8.24`
- Foundry: `forge 1.4.3-Homebrew`

Build configuration:

- `foundry.toml`
- `remappings.txt`

LayerZero dependency sources:

- `@layerzero-v2/=lib/LayerZero-v2/packages/layerzero-v2/evm/`
- `@layerzerolabs/lz-evm-protocol-v2/=lib/LayerZero-v2/packages/layerzero-v2/evm/protocol/`

## 3. Audit Scope

### In Scope

Core contracts:

- `src/layerzero/hub/CreditManager.sol`
- `src/layerzero/hub/CrossChainAssetController.sol`
- `src/layerzero/hub/CrossChainNAVReporter.sol`
- `src/layerzero/hub/HubStargateComposer.sol`
- `src/layerzero/hub/PPTOFTAdapter.sol`
- `src/layerzero/satellite/LiquidityPool.sol`
- `src/layerzero/satellite/PPTOFT.sol`
- `src/layerzero/satellite/PPTSatellite.sol`
- `src/layerzero/satellite/SatelliteGateway.sol`
- `src/layerzero/satellite/adapters/RemoteAssetGateway.sol`

Interfaces and libraries:

- `src/layerzero/interfaces/ICreditManager.sol`
- `src/layerzero/interfaces/ICrossChainNAVReporter.sol`
- `src/layerzero/interfaces/ILiquidityPool.sol`
- `src/layerzero/interfaces/IPPTOFT.sol`
- `src/layerzero/interfaces/IPPTOFTAdapter.sol`
- `src/layerzero/interfaces/IPPTSatellite.sol`
- `src/layerzero/interfaces/IRemoteProtocolImplementation.sol`
- `src/layerzero/interfaces/IStargateIntegration.sol`
- `src/layerzero/libraries/DeltaLib.sol`
- `src/layerzero/libraries/LzOptionsLib.sol`
- `src/layerzero/libraries/MessageCodec.sol`
- `src/layerzero/libraries/StargateComposeCodec.sol`

Tests:

- `test/layerzero/StargateBridgeFlows.t.sol`
- `test/layerzero/StargateCriticalFixes.t.sol`
- `test/layerzero/LayerZeroRuntimeFixes.t.sol`

### Out Of Scope

- Non-LayerZero business modules under `src/ppt/`
- Governance process security of upgrade scripts
- Implementation details of third-party on-chain protocols
- Non-LayerZero / non-Stargate infrastructure

## 4. System Architecture Summary

### 4.1 Hub Side

- `HubStargateComposer`
  - Unified Stargate compose receive and send entry point on Hub
  - Receives satellite deposits
  - Receives remote portfolio return / harvest return
  - Sends settlement / deploy / replenish to satellites

- `PPTOFTAdapter`
  - Hub-side PPT lock/unlock adapter
  - Handles satellite withdraw / redeem / credit used / credit restored messages
  - Sends back share mint / share price / credit sync

- `CrossChainAssetController`
  - Hub-side portfolio control plane
  - Initiates deploy / withdraw / harvest commands
  - Tracks bridged deploy accounting

- `CrossChainNAVReporter`
  - Cross-chain asset value aggregator
  - Aggregates satellite balances and remote deployment values

- `CreditManager`
  - Satellite liquidity credit allocation and utilization management

### 4.2 Satellite Side

- `PPTSatellite`
  - User entry point on satellite chains
  - Supports deposit, instant withdraw, cross-chain withdraw

- `SatelliteGateway`
  - Satellite chain subscription bridge entry point
  - Receives Hub settlement / replenish compose messages

- `PPTOFT`
  - Satellite chain PPT OFT representation layer

- `LiquidityPool`
  - Local liquidity pool for instant withdrawals

### 4.3 Remote Portfolio Side

- `RemoteAssetGateway`
  - Receives Hub deploy compose via Stargate
  - Receives Hub withdraw / harvest commands via OApp
  - Bridges principal / yield returns back to Hub

## 5. Key Design Points

### 5.1 Dual Gateway Routing

`HubStargateComposer` currently maintains two types of remote routing:

- `satelliteGateways[eid]`
  - Used for `DEPOSIT / SETTLEMENT / REPLENISH`
- `remoteAssetGateways[eid]`
  - Used for `DEPLOY / RETURN`

Audit focus:

- Whether action-to-gateway role mapping is one-to-one
- Whether inbound compose source verification is consistent with outbound targets
- Whether simultaneous subscription / redemption / portfolio operations on the same chain conflict

### 5.2 Cross-Chain Redemption `minAssets`

`PPTSatellite.withdrawWithParams()` currently only performs:

- Final asset check on the `Instant` path
- Pre-send preview check on the `CrossChain` path

Audit focus:

- Whether the minimum asset protection semantics under async cross-chain settlement are reasonable
- Whether the deviation tolerance between estimated and final settlement values meets business requirements

### 5.3 Legacy Deposit Path Disabled

`PPTOFTAdapter` has disabled the legacy `MSG_DEPOSIT` / compose deposit entries, retaining only:

- `MSG_WITHDRAW`
- `MSG_REDEEM`
- `MSG_CREDIT_USED`
- `MSG_CREDIT_RESTORED`
- compose redemption

Audit focus:

- Whether the legacy entries are truly unreachable
- Whether production has only one official subscription path: `PPTSatellite -> SatelliteGateway -> HubStargateComposer`

## 6. Core Business Flows

### 6.1 Multi-Chain Subscription

```
User
  -> PPTSatellite.deposit()
  -> SatelliteGateway.depositFor()
  -> Stargate bridge to HubStargateComposer
  -> Hub vault deposit
  -> PPTOFTAdapter.mintSharesOnSatellite()
  -> User receives PPTOFT on source chain
```

### 6.2 Cross-Chain Redemption

```
User
  -> PPTSatellite.withdraw() / withdrawWithParams(CrossChain)
  -> OApp message to PPTOFTAdapter
  -> Hub redemption request
  -> HubStargateComposer settles and bridges settlement back
  -> SatelliteGateway receives settlement and transfers asset to receiver
```

### 6.3 Cross-Chain Portfolio

```
Keeper
  -> CrossChainAssetController.deployViaBridge()
  -> HubStargateComposer.bridgeAndDeploy()
  -> Stargate compose to RemoteAssetGateway
  -> Remote protocol implementation deploys assets

Keeper
  -> CrossChainAssetController.withdrawFromRemote() / harvestYield()
  -> OApp message to RemoteAssetGateway
  -> RemoteAssetGateway bridges return/yield back to HubStargateComposer
  -> Hub vault / accounting updated
```

## 7. Critical Security Invariants

The following invariants are recommended for auditor verification:

- Only the LayerZero endpoint can call compose / receive entry points
- Only the configured Stargate pool can serve as compose `_from`
- All inbound compose messages must satisfy triple matching: `srcEid + action + expected gateway`
- `SatelliteGateway` must never receive `DEPLOY`
- `RemoteAssetGateway` must never receive `SETTLEMENT / REPLENISH`
- Cross-chain withdraw must not erroneously revert due to async return value being `0`
- `replenish` must hard-fail when `liquidityPool` is not configured
- `PPTOFTAdapter` legacy deposit must be unreachable
- Remote return accounting must not confuse principal with yield
- Credit reduce / restore must only apply to supported chains
- Pending mint / pending return / pending credit queues must not cause asset loss or permanent deadlock

## 8. Roles and Permission Matrix

### Admin / Owner Permissions

- `HubStargateComposer`
  - Set vault, adapter, NAV reporter, redemption manager
  - Set satellite / remote gateway
  - pause / unpause

- `CrossChainAssetController`
  - Add / remove supported chain
  - Update remote gateway peer
  - Set hub composer
  - Emergency withdraw

- `SatelliteGateway`
  - Set hub composer
  - Set liquidity pool
  - Set deposit forwarder
  - pause / unpause

- `RemoteAssetGateway`
  - Set hub composer
  - Set protocol implementation
  - pause / unpause

- `PPTSatellite`
  - Set satellite gateway
  - Set instant withdraw fee
  - Set pause state

### Keeper Permissions

- `HubStargateComposer`
  - Retry failed deposit
  - Refund failed deposit
  - Settle satellite redemption
  - bridgeAndDeploy
  - replenishLiquidity

- `CrossChainAssetController`
  - deployViaBridge
  - withdrawFromRemote
  - harvestYield

## 9. Testing and Verification

Local build commands:

```bash
forge build
forge test --match-path 'test/layerzero/*.t.sol'
```

Current LayerZero regression test coverage:

- Gateway routing split
- Remote return source verification
- Failed deposit retry / refund
- Replenish configuration protection
- Cross-chain withdraw `minAssets`
- Legacy deposit entry point disabled
