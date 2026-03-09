# Paimon LayerZero Cross-Chain Technical Document

## 1. Document Purpose

This document is the technical specification for the Paimon Finance LayerZero cross-chain module, intended for:

- Audit teams
- Protocol engineering teams
- Deployment and operations teams

This document describes the current implementation, not historical designs or future plans.

Companion audit materials:

- `docs/LAYERZERO_AUDIT_PACKAGE.md`
- `src/layerzero/README.md`

## 2. Objectives and Scope

The LayerZero module must fully support the following business capabilities:

- Multi-chain subscription (deposit from any satellite chain)
- Local instant redemption
- Standard cross-chain redemption
- Cross-chain portfolio deploy
- Cross-chain portfolio withdraw / harvest
- Cross-chain liquidity replenishment and credit restoration

The module's goal is NOT to maintain independent Vaults on remote chains, but rather to:

- Centrally maintain the asset ledger and Vault on the Hub chain
- Provide user entry points and a liquidity layer on satellite chains
- Execute real asset deployment and return bridging on remote portfolio chains

## 3. Module Layers

### 3.1 Hub Layer

- `HubStargateComposer`
  - Hub-side Stargate compose receiver
  - Handles inbound deposits, portfolio return, and outbound settlement / deploy / replenish

- `PPTOFTAdapter`
  - Hub-side PPT lock/unlock adapter
  - Handles satellite withdraw / redeem / credit used / credit restored OApp messages
  - Sends back mint shares, share price, credit update

- `CrossChainAssetController`
  - Hub-side portfolio control plane
  - Initiates deploy, withdraw, harvest commands and tracks bridged principal accounting

- `CrossChainNAVReporter`
  - Aggregates cross-chain satellite balances and remote deployment values

- `CreditManager`
  - Manages per-satellite-chain credit allocation and utilization changes

### 3.2 Satellite Layer

- `PPTSatellite`
  - User entry point
  - Handles deposit, instant withdraw, cross-chain withdraw

- `SatelliteGateway`
  - Satellite chain Stargate gateway
  - Bridges user assets to Hub
  - Receives Hub settlement / replenish responses

- `LiquidityPool`
  - Provides local asset liquidity for instant withdrawals

- `PPTOFT`
  - Satellite chain PPT representation layer

### 3.3 Remote Portfolio Layer

- `RemoteAssetGateway`
  - Remote portfolio gateway
  - Receives Hub deploy compose messages
  - Receives Hub withdraw / harvest OApp commands
  - Bridges principal / yield back to Hub

- `IRemoteProtocolImplementation`
  - Remote protocol execution abstraction interface
  - Used to adapt Aave, Compound, or other strategy implementations

## 4. Overall Architecture

```text
                           +----------------------+
                           |     Hub Chain        |
                           |----------------------|
                           | Vault / Redemption   |
                           | CreditManager        |
                           | NAV Reporter         |
                           | PPTOFTAdapter        |
                           | HubStargateComposer  |
                           | CrossChainAssetCtrl  |
                           +----------+-----------+
                                      |
                    +-----------------+------------------+
                    |                                    |
             Stargate compose                      OApp messages
                    |                                    |
          +---------+----------+                 +-------+--------+
          | Satellite Chain    |                 | Remote Chain   |
          |--------------------|                 |----------------|
          | PPTSatellite       |                 | RemoteAssetGw  |
          | SatelliteGateway   |                 | Strategy Impl  |
          | LiquidityPool      |                 |                |
          | PPTOFT             |                 |                |
          +--------------------+                 +----------------+
```

Design principles:

- Asset bridging exclusively via Stargate V2
- Typed control messages exclusively via LayerZero OApp
- Hub is the master ledger for assets and shares
- Satellite is the user access and local liquidity layer
- Remote chain is responsible only for portfolio execution, not the share ledger

## 5. Cross-Chain Message Model

### 5.1 Stargate Compose Actions

Definition location:

- `src/layerzero/libraries/StargateComposeCodec.sol`

Action table:

| Action | Value | Direction | Purpose |
|---|---:|---|---|
| `ACTION_DEPOSIT` | `0x01` | Satellite -> Hub | Subscription asset inbound |
| `ACTION_SETTLEMENT` | `0x02` | Hub -> Satellite | Cross-chain redemption settlement |
| `ACTION_DEPLOY` | `0x03` | Hub -> Remote | Portfolio deploy |
| `ACTION_RETURN` | `0x04` | Remote -> Hub | Principal / yield return bridge |
| `ACTION_REPLENISH` | `0x05` | Hub -> Satellite | Replenish satellite liquidity |
| `ACTION_HARVEST_RETURN` | `0x06` | Reserved | Currently unused |

### 5.2 OApp Typed Messages

Definition location:

- `src/layerzero/libraries/MessageCodec.sol`

Message table:

| Msg | Value | Direction | Purpose |
|---|---:|---|---|
| `MSG_CREDIT_USED` | `0x10` | Satellite -> Hub | Instant withdraw consumes credit |
| `MSG_CREDIT_RESTORED` | `0x11` | Satellite -> Hub | Credit restored after replenish |
| `MSG_SHARE_PRICE_UPDATE` | `0x20` | Hub -> Satellite | Share price sync |
| `MSG_CREDIT_UPDATE` | `0x21` | Hub -> Satellite | Credit sync |
| `MSG_MINT_SHARES` | `0x22` | Hub -> Satellite | Mint shares after subscription |
| `MSG_DEPOSIT` | `0x30` | Legacy | Retained in library but not used by current production path |
| `MSG_WITHDRAW` | `0x31` | Satellite -> Hub | Standard cross-chain redemption |
| `MSG_REDEEM` | `0x32` | Satellite -> Hub | Share redemption request |
| `MSG_WITHDRAW_ASSET` | `0x41` | Hub -> Remote | Remote strategy withdrawal |
| `MSG_HARVEST` | `0x42` | Hub -> Remote | Remote strategy harvest |

Notes:

- `MSG_DEPOSIT` is still retained in `MessageCodec`, but `PPTOFTAdapter` no longer accepts it.
- The current official subscription path is exclusively: `PPTSatellite -> SatelliteGateway -> HubStargateComposer`.

## 6. Gateway Routing Model

### 6.1 Dual Gateway Design

`HubStargateComposer` currently maintains two sets of remote addresses:

- `satelliteGateways[eid]`
  - Used for `DEPOSIT / SETTLEMENT / REPLENISH`

- `remoteAssetGateways[eid]`
  - Used for `DEPLOY / RETURN`

These two addresses are maintained separately because:

- Satellite user gateways and remote portfolio gateways have entirely different responsibilities
- The same chain may need to support both user-side and portfolio-side scenarios simultaneously
- A single `trustedGateway` would cause primary path conflicts

### 6.2 Routing Rules

`HubStargateComposer` automatically selects based on `action`:

- Expected source address for inbound compose
- Target address for outbound Stargate sends

In other words, security verification and routing selection share the same action semantics.

## 7. Business Flows

### 7.1 Multi-Chain Subscription

#### Flow

1. User calls `PPTSatellite.deposit()` on the satellite chain.
2. `PPTSatellite` transfers assets to itself, then initiates Stargate bridging via `SatelliteGateway.depositFor()`.
3. `SatelliteGateway` bridges assets to Hub with `ACTION_DEPOSIT` compose.
4. `HubStargateComposer.lzCompose()` verifies:
   - Caller must be the local endpoint
   - `_from` must be the local Stargate pool
   - `srcEid` must match the remote chain
   - `composeFrom` must equal `satelliteGateways[srcEid]`
5. Hub receives assets and deposits into Vault.
6. `HubStargateComposer` calls `PPTOFTAdapter.mintSharesOnSatellite()`.
7. `PPTOFTAdapter` sends `MSG_MINT_SHARES` back to satellite via OApp.
8. `PPTSatellite` receives `MSG_MINT_SHARES` and calls `PPTOFT.mint()`, completing share issuance.

#### Core Properties

- Subscription assets physically cross-chain into Hub
- User shares are only sent back after Hub accounting is complete
- `minShares` protection is checked before Hub deposit
- Failed deposits enter the `failedDeposits` queue for keeper retry or refund

### 7.2 Instant Withdraw

#### Flow

1. User calls `PPTSatellite.instantWithdraw()`.
2. `PPTSatellite` burns local PPTOFT.
3. `LiquidityPool` pays assets directly to the user.
4. `PPTSatellite` sends `MSG_CREDIT_USED` to Hub.
5. `CreditManager` on Hub marks the chain's `utilized` as increased.

#### Core Properties

- User does not depend on Hub settlement
- Consumes satellite chain local liquidity
- `availableLiquidity()` and `credit/utilized` jointly constrain the withdrawable amount

### 7.3 Standard Cross-Chain Redemption

#### Flow

1. User calls `PPTSatellite.withdraw()` or `withdrawWithParams(CrossChain)`.
2. `PPTSatellite` burns local PPTOFT and sends `MSG_WITHDRAW` to Hub.
3. `PPTOFTAdapter` receives and creates a Hub redemption request.
4. `HubStargateComposer` as settlement registrar saves:
   - `requestId`
   - `dstEid`
   - `receiver`
5. After RedemptionManager settles on Hub, keeper calls `settleSatelliteRedemption()`.
6. `HubStargateComposer` acquires assets and initiates `ACTION_SETTLEMENT` via Stargate.
7. `SatelliteGateway` receives assets and transfers directly to `receiver`.

#### Minimum Asset Protection

- `withdrawWithParams(CrossChain)` only performs `previewWithdraw()` check before sending
- Does not re-verify during async return value phase
- Prevents erroneous revert due to cross-chain return value being fixed at `0`

### 7.4 Portfolio Deploy

#### Flow

1. Keeper calls `CrossChainAssetController.deployViaBridge()`.
2. Controller transfers assets to `HubStargateComposer`.
3. `HubStargateComposer.bridgeAndDeploy()` initiates `ACTION_DEPLOY` via Stargate.
4. `RemoteAssetGateway` receives compose and calls the corresponding `IRemoteProtocolImplementation.deploy()`.
5. Successfully deployed amount is recorded in:
   - `RemoteAssetGateway.protocolDeposits[protocol]`
   - `RemoteAssetGateway.totalDeposited`
   - `CrossChainAssetController.bridgedDeployedAssets[eid]`
   - `CrossChainAssetController.totalBridgedDeployed`
6. If deploy return value is less than inbound amount, undeployed remainder is bridged back to Hub.

### 7.5 Portfolio Withdraw / Harvest

#### Flow

1. Keeper initiates via `CrossChainAssetController`:
   - `withdrawFromRemote()`
   - `harvestYield()`
2. `RemoteAssetGateway` receives OApp typed command.
3. Remote strategy implementation executes withdraw or harvest.
4. `RemoteAssetGateway` bridges result back to Hub via Stargate `ACTION_RETURN`.
5. `HubStargateComposer` receives and:
   - Transfers assets into Vault
   - Updates NAV reporter
   - Updates bridged principal accounting

#### Accounting Rules

- Principal return reduces remote deployment accounting
- Yield return does NOT reduce remote deployment principal

### 7.6 Liquidity Replenish

#### Flow

1. Keeper calls `HubStargateComposer.replenishLiquidity()`.
2. Hub sends `ACTION_REPLENISH` to `SatelliteGateway` via Stargate.
3. `SatelliteGateway` injects received assets into `LiquidityPool`.
4. If `LiquidityPool.satellite()` is configured, notifies `PPTSatellite.notifyCreditRestored()`.
5. `PPTSatellite` sends `MSG_CREDIT_RESTORED` to Hub.
6. `CreditManager` reduces the chain's `utilized`.

#### Protection Rules

- `SatelliteGateway` must confirm `liquidityPool` is configured before executing replenish
- Reverts immediately if not configured; silent failure is not allowed

## 8. Accounting Model

### 8.1 Credit Accounting

`CreditManager` maintains per satellite chain:

- `credit`
- `utilized`
- `lastUpdate`

Semantics:

- `credit` is the allocated quota
- `utilized` is the consumed quota
- Available quota = `credit - utilized`

### 8.2 Satellite Liquidity Accounting

`LiquidityPool` is responsible for:

- Local withdrawable liquidity
- `minBuffer` protection
- Instant redemption settlement

### 8.3 Portfolio Accounting

`CrossChainAssetController` records principal bridged into remote portfolios:

- `bridgedDeployedAssets[eid]`
- `totalBridgedDeployed`

`CrossChainNAVReporter` provides a higher-level cross-chain value view:

- `satelliteBalances[eid]`
- `remoteDeployments[eid]`
- `totalCrossChainValue`

## 9. Permission Model

### 9.1 HubStargateComposer

- `DEFAULT_ADMIN_ROLE`
  - Set vault, adapter, NAV reporter, redemption manager
  - Set satellite / remote gateway
  - pause / unpause

- `KEEPER_ROLE`
  - `bridgeAndDeploy`
  - `replenishLiquidity`
  - `settleAndBridge`
  - `settleSatelliteRedemption`
  - `retryFailedDeposit`
  - `refundFailedDeposit`

### 9.2 CrossChainAssetController

- `DEFAULT_ADMIN_ROLE`
  - Add / remove supported chains
  - Set remote peer
  - Set hub composer

- `KEEPER_ROLE`
  - `deployViaBridge`
  - `withdrawFromRemote`
  - `harvestYield`

### 9.3 Satellite and Remote Owner Permissions

- `PPTSatellite`
  - `setSatelliteGateway`
  - `setInstantWithdrawFee`
  - `setPaused`

- `SatelliteGateway`
  - `setHubComposer`
  - `setLiquidityPool`
  - `setDepositForwarder`
  - `setSlippageBps`

- `RemoteAssetGateway`
  - `setHubComposer`
  - `setProtocolImplementation`
  - `setSlippageBps`

## 10. Failure Recovery and Pending Queues

### 10.1 `HubStargateComposer.failedDeposits`

Purpose:

- Handles Vault preview / deposit failures
- Retains `srcEid / receiver / assets / minShares`

Recovery methods:

- `retryFailedDeposit()`
- `refundFailedDeposit()`

### 10.2 `PPTOFTAdapter.pendingMints`

Purpose:

- When Hub sends satellite mint shares but the contract's native balance is insufficient, the mint is queued

Recovery method:

- `flushPendingMint()`

### 10.3 `PPTOFTAdapter.pendingSharePriceSyncs`

Purpose:

- Share price sync messages are queued when native fee is insufficient

Recovery method:

- `flushPendingSharePriceSync()`

### 10.4 `PPTSatellite.pendingCreditUsed / pendingCreditRestored`

Purpose:

- Satellite chain credit-related messages are queued when native balance is insufficient

Recovery methods:

- `flushPendingCreditUsed()`
- `flushPendingCreditRestored()`

### 10.5 `RemoteAssetGateway.pendingReturns`

Purpose:

- Remote principal / yield returns are stored when local native balance is insufficient for bridging back

Recovery method:

- `flushPendingReturn()`

## 11. Security Boundaries and Critical Invariants

### 11.1 Source Verification

All receive entry points must simultaneously satisfy:

- Endpoint verification
- Peer / Stargate pool verification
- `srcEid` verification
- `composeFrom` or `origin.sender` verification

### 11.2 Gateway Isolation

- `SatelliteGateway` handles only user-side asset flows
- `RemoteAssetGateway` handles only portfolio-side asset flows
- Hub enforces routing by action, preventing same-chain entry point misuse

### 11.3 Single Master Ledger

- Vault and Redemption execute only on Hub
- Satellite chains hold only local PPTOFT and liquidity pool assets
- Remote chains hold only deployed strategy assets

### 11.4 Legacy Path Disabled

`PPTOFTAdapter` no longer accepts:

- `MSG_DEPOSIT`
- compose deposit

Purpose: reduce legacy path attack surface and ensure production has only one official subscription path.

### 11.5 Async Settlement Semantics

Standard cross-chain redemption is an async business flow:

- Users do not receive final assets immediately upon request
- Contracts must not use async results as synchronous return values for secondary validation

## 12. Deployment and Configuration Dependencies

### 12.1 Recommended Deployment Order

1. Deploy Hub contracts
2. Deploy Satellite contracts
3. Deploy RemoteAssetGateway and remote strategy implementations
4. Configure all OApp `peer` settings
5. Configure all Stargate gateway addresses
6. Configure protocol implementations
7. Configure roles and keepers
8. Perform end-to-end rehearsal before opening production traffic

### 12.2 Required Configuration

Hub side:

- `HubStargateComposer.setVault`
- `HubStargateComposer.setPptOftAdapter`
- `HubStargateComposer.setRedemptionManager`
- `HubStargateComposer.setSatelliteGateway`
- `HubStargateComposer.setRemoteAssetGateway`
- `CrossChainAssetController.setHubStargateComposer`

Satellite side:

- `PPTSatellite.setSatelliteGateway`
- `SatelliteGateway.setHubComposer`
- `SatelliteGateway.setLiquidityPool`
- `SatelliteGateway.setDepositForwarder`

Remote side:

- `RemoteAssetGateway.setHubComposer`
- `RemoteAssetGateway.setProtocolImplementation`

OApp layer:

- `setPeer` for each contract

## 13. Test Coverage

Current LayerZero tests are located at:

- `test/layerzero/StargateBridgeFlows.t.sol`
- `test/layerzero/StargateCriticalFixes.t.sol`
- `test/layerzero/LayerZeroRuntimeFixes.t.sol`

Key areas covered:

- Dual gateway routing split
- Remote return source verification
- Failed deposit retry / refund
- Replenish configuration protection
- Cross-chain withdraw `minAssets`
- Legacy deposit path disabled

## 14. Build and Verification

Build command:

```bash
forge build
```

Test command:

```bash
forge test --match-path 'test/layerzero/*.t.sol'
```

## 15. Known Toolchain Limitations

In the current development environment:

- `forge build` passes normally
- `forge test --match-path 'test/layerzero/*.t.sol'` may be affected by a `system-configuration` panic on macOS + Foundry `1.4.3-Homebrew`

Therefore, before formal audit delivery, it is recommended to supplement with complete test success logs from a Linux CI or container environment.

## 16. Recommended Audit Reading Order

The following reading order is recommended for auditors:

1. `src/layerzero/hub/HubStargateComposer.sol`
2. `src/layerzero/satellite/SatelliteGateway.sol`
3. `src/layerzero/satellite/adapters/RemoteAssetGateway.sol`
4. `src/layerzero/satellite/PPTSatellite.sol`
5. `src/layerzero/hub/PPTOFTAdapter.sol`
6. `src/layerzero/hub/CrossChainAssetController.sol`
7. `src/layerzero/hub/CreditManager.sol`
8. `src/layerzero/hub/CrossChainNAVReporter.sol`
9. `src/layerzero/libraries/MessageCodec.sol`
10. `src/layerzero/libraries/StargateComposeCodec.sol`
