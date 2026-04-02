# Paimon Finance LayerZero Cross-Chain Module - Detailed Audit Specification

## Document Metadata

| Field | Value |
|-------|-------|
| **Protocol** | Paimon Finance |
| **Module** | LayerZero Cross-Chain |
| **Branch** | `feat/layerzero-cross-chain` |
| **Commit** | `d8af8fd` |
| **Solidity** | `0.8.24` |
| **Toolchain** | Foundry `1.4.3` |
| **Network** | BSC Mainnet (Hub), multi-chain satellites |
| **Dependencies** | OpenZeppelin 5.x, LayerZero V2, Stargate V2 |
| **Total LOC** | ~4,987 Solidity |
| **Date** | 2026-04-02 |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Scope Definition](#2-scope-definition)
3. [System Architecture](#3-system-architecture)
4. [Contract Inventory](#4-contract-inventory)
5. [Cross-Chain Message Protocol](#5-cross-chain-message-protocol)
6. [Business Flow Specifications](#6-business-flow-specifications)
7. [Access Control Matrix](#7-access-control-matrix)
8. [Security Invariants and Properties](#8-security-invariants-and-properties)
9. [Attack Surface Analysis](#9-attack-surface-analysis)
10. [Accounting Model](#10-accounting-model)
11. [Failure Recovery Mechanisms](#11-failure-recovery-mechanisms)
12. [External Dependencies](#12-external-dependencies)
13. [Gas and Fee Model](#13-gas-and-fee-model)
14. [Deployment and Configuration](#14-deployment-and-configuration)
15. [Testing Coverage](#15-testing-coverage)
16. [Recommended Audit Reading Order](#16-recommended-audit-reading-order)
17. [Appendix A: Full Function Signatures](#appendix-a-full-function-signatures)
18. [Appendix B: Event Catalog](#appendix-b-event-catalog)
19. [Appendix C: Error Catalog](#appendix-c-error-catalog)

---

## 1. Executive Summary

Paimon Finance's LayerZero module implements a **Hub-Spoke cross-chain architecture** for an RWA (Real World Asset) fund. The BSC Hub chain hosts the primary PPT Vault (ERC-4626) and serves as the single source of truth for share accounting. Satellite chains provide user entry points for deposit/withdrawal, while remote chains execute DeFi portfolio strategies.

**Core capabilities:**
- **Multi-chain Subscription**: Users deposit USDT on any satellite chain; assets bridge to Hub via Stargate V2; PPT shares are minted back on the satellite via LayerZero OApp.
- **Instant Withdrawal**: Users burn PPTOFT and receive USDT from a local LiquidityPool, constrained by credit allocation.
- **Cross-Chain Redemption**: Shares are burned on satellite; Hub processes redemption; settled USDT bridges back to the user via Stargate.
- **Portfolio Management**: Hub keeper deploys USDT to remote DeFi protocols via Stargate compose; withdrawals/harvests return via the same path.
- **Credit System**: Hub-managed credit allocation controls instant withdrawal capacity per satellite chain.

**Transport layers:**
- **Stargate V2** (compose pattern): All real USDT bridging (deposit, settlement, deploy, return, replenish).
- **LayerZero V2 OApp**: All typed control messages (credit updates, share price sync, mint commands, withdraw requests).

**Key design principle:** The Hub chain is the master ledger. Satellite chains hold only local PPTOFT tokens and liquidity pool assets. Remote chains hold only deployed strategy positions. No satellite or remote chain can unilaterally alter the global accounting.

---

## 2. Scope Definition

### 2.1 In Scope

**Core Contracts (10):**

| # | Contract | Path | LOC |
|---|----------|------|-----|
| 1 | HubStargateComposer | `src/layerzero/hub/HubStargateComposer.sol` | 617 |
| 2 | PPTOFTAdapter | `src/layerzero/hub/PPTOFTAdapter.sol` | 533 |
| 3 | CreditManager | `src/layerzero/hub/CreditManager.sol` | 386 |
| 4 | CrossChainAssetController | `src/layerzero/hub/CrossChainAssetController.sol` | 258 |
| 5 | CrossChainNAVReporter | `src/layerzero/hub/CrossChainNAVReporter.sol` | 239 |
| 6 | PPTSatellite | `src/layerzero/satellite/PPTSatellite.sol` | 421 |
| 7 | SatelliteGateway | `src/layerzero/satellite/SatelliteGateway.sol` | 327 |
| 8 | PPTOFT | `src/layerzero/satellite/PPTOFT.sol` | 249 |
| 9 | LiquidityPool | `src/layerzero/satellite/LiquidityPool.sol` | 245 |
| 10 | RemoteAssetGateway | `src/layerzero/satellite/adapters/RemoteAssetGateway.sol` | 354 |

**Libraries (4):**

| # | Library | Path | LOC |
|---|---------|------|-----|
| 1 | MessageCodec | `src/layerzero/libraries/MessageCodec.sol` | 123 |
| 2 | StargateComposeCodec | `src/layerzero/libraries/StargateComposeCodec.sol` | 108 |
| 3 | LzOptionsLib | `src/layerzero/libraries/LzOptionsLib.sol` | 105 |
| 4 | DeltaLib | `src/layerzero/libraries/DeltaLib.sol` | 142 |

**Interfaces (8):**

| # | Interface | Path |
|---|-----------|------|
| 1 | ICreditManager | `src/layerzero/interfaces/ICreditManager.sol` |
| 2 | ICrossChainNAVReporter | `src/layerzero/interfaces/ICrossChainNAVReporter.sol` |
| 3 | ILiquidityPool | `src/layerzero/interfaces/ILiquidityPool.sol` |
| 4 | IPPTOFT | `src/layerzero/interfaces/IPPTOFT.sol` |
| 5 | IPPTOFTAdapter | `src/layerzero/interfaces/IPPTOFTAdapter.sol` |
| 6 | IPPTSatellite | `src/layerzero/interfaces/IPPTSatellite.sol` |
| 7 | IRemoteProtocolImplementation | `src/layerzero/interfaces/IRemoteProtocolImplementation.sol` |
| 8 | IStargateIntegration | `src/layerzero/interfaces/IStargateIntegration.sol` |

**Tests (3):**

| # | Test | Path |
|---|------|------|
| 1 | StargateBridgeFlows | `test/layerzero/StargateBridgeFlows.t.sol` |
| 2 | StargateCriticalFixes | `test/layerzero/StargateCriticalFixes.t.sol` |
| 3 | LayerZeroRuntimeFixes | `test/layerzero/LayerZeroRuntimeFixes.t.sol` |

### 2.2 Out of Scope

- Hub-chain PPT Vault implementation (`src/ppt/PPT.sol`)
- RedemptionManager implementation (`src/ppt/RedemptionManager.sol`)
- AssetController L1/L2/L3 (non-cross-chain)
- Upgrade scripts and governance
- Third-party protocol adapters behind `IRemoteProtocolImplementation`
- LayerZero/Stargate infrastructure contracts

---

## 3. System Architecture

### 3.1 Component Topology

```
                    ┌──────────────────────────────────────────────────────┐
                    │                   HUB CHAIN (BSC)                    │
                    │                                                      │
                    │  ┌─────────────┐     ┌──────────────────┐           │
                    │  │  PPT Vault  │◄────│  PPTOFTAdapter   │           │
                    │  │  (ERC-4626) │     │  (OApp + Compose)│           │
                    │  └──────┬──────┘     └────────┬─────────┘           │
                    │         │                     │                      │
                    │  ┌──────┴──────┐     ┌────────┴─────────┐           │
                    │  │ Redemption  │     │  CreditManager   │           │
                    │  │  Manager    │     │  (OApp)          │           │
                    │  └─────────────┘     └──────────────────┘           │
                    │                                                      │
                    │  ┌──────────────────┐  ┌────────────────────────┐   │
                    │  │ HubStargate      │  │ CrossChainAsset        │   │
                    │  │ Composer         │  │ Controller (OApp)      │   │
                    │  │ (Compose recv/   │  │                        │   │
                    │  │  send)           │  │                        │   │
                    │  └────────┬─────────┘  └────────────┬───────────┘   │
                    │           │                         │               │
                    │  ┌────────┴─────────┐               │               │
                    │  │ CrossChainNAV    │               │               │
                    │  │ Reporter         │               │               │
                    │  └──────────────────┘               │               │
                    └──────────┬──────────────────────────┼───────────────┘
                               │                          │
              ┌────────────────┼──────────────────────────┼──────────┐
              │                │                          │          │
    ┌─────────▼────────┐    Stargate V2             OApp Messages   │
    │  SATELLITE CHAIN │    (USDT bridge)           (typed msgs)    │
    │  (e.g., ARB)     │       │                       │            │
    │                  │       │                       │            │
    │ ┌──────────────┐ │       │               ┌──────▼──────────┐ │
    │ │ PPTSatellite │ │       │               │ REMOTE CHAIN    │ │
    │ │ (OApp)       │ │       │               │ (e.g., ETH)     │ │
    │ └──────┬───────┘ │       │               │                 │ │
    │        │         │       │               │ ┌─────────────┐ │ │
    │ ┌──────▼───────┐ │       │               │ │ RemoteAsset │ │ │
    │ │ Satellite    │ │       │               │ │ Gateway     │ │ │
    │ │ Gateway      │◄├───────┘               │ │ (OApp +     │ │ │
    │ │ (Compose)    │ │                       │ │  Compose)   │ │ │
    │ └──────────────┘ │                       │ └──────┬──────┘ │ │
    │                  │                       │        │        │ │
    │ ┌──────────────┐ │                       │ ┌──────▼──────┐ │ │
    │ │ LiquidityPool│ │                       │ │ Protocol    │ │ │
    │ └──────────────┘ │                       │ │ Impl        │ │ │
    │                  │                       │ │ (Aave, etc.)│ │ │
    │ ┌──────────────┐ │                       │ └─────────────┘ │ │
    │ │ PPTOFT       │ │                       └─────────────────┘ │
    │ │ (ERC-20 OFT) │ │                                           │
    │ └──────────────┘ │                                           │
    └──────────────────┘                                           │
                                                                   │
```

### 3.2 Transport Layer Split

| Transport | Direction | Use Case | Contract Endpoints |
|-----------|-----------|----------|-------------------|
| **Stargate V2 Compose** | Satellite -> Hub | Deposit (USDT + instruction) | SatelliteGateway -> HubStargateComposer |
| **Stargate V2 Compose** | Hub -> Satellite | Settlement, Replenish (USDT + instruction) | HubStargateComposer -> SatelliteGateway |
| **Stargate V2 Compose** | Hub -> Remote | Deploy (USDT + instruction) | HubStargateComposer -> RemoteAssetGateway |
| **Stargate V2 Compose** | Remote -> Hub | Return (USDT + metadata) | RemoteAssetGateway -> HubStargateComposer |
| **OApp _lzReceive** | Satellite -> Hub | Withdraw, Redeem, CreditUsed, CreditRestored | PPTSatellite -> PPTOFTAdapter |
| **OApp _lzReceive** | Hub -> Satellite | MintShares, SharePriceUpdate, CreditUpdate | PPTOFTAdapter -> PPTSatellite |
| **OApp _lzReceive** | Hub -> Remote | WithdrawAsset, Harvest | CrossChainAssetController -> RemoteAssetGateway |
| **OApp _lzReceive** | Satellite -> Hub | CreditUsed, CreditRestored | PPTSatellite -> CreditManager |

### 3.3 Design Principles

1. **Single Master Ledger**: All authoritative share/asset accounting lives on Hub (BSC). Satellite and remote chains are execution layers only.
2. **Physical Asset Bridging**: USDT actually moves cross-chain via Stargate V2. No virtual balances or IOU tokens.
3. **Dual Gateway Routing**: `HubStargateComposer` distinguishes `satelliteGateways[eid]` (user flows) from `remoteAssetGateways[eid]` (portfolio flows) to prevent routing conflicts when a chain is both a satellite and a remote portfolio target.
4. **Compose Pattern**: All Stargate bridge operations use `oftCmd: ""` (Taxi mode) to enable compose callbacks on the destination.
5. **Fail-Safe Queues**: Operations that require native gas for cross-chain messaging fall back to pending queues when `address(this).balance` is insufficient, preventing irreversible loss.

---

## 4. Contract Inventory

### 4.1 Hub Contracts

#### 4.1.1 HubStargateComposer

**File:** `src/layerzero/hub/HubStargateComposer.sol` (617 LOC)
**Inherits:** `ILayerZeroComposer`, `AccessControl`, `ReentrancyGuard`, `Pausable`
**Role:** Central Stargate compose handler on Hub. Receives all inbound USDT from satellites and remotes. Sends all outbound USDT settlements, deploys, and replenishments.

**Key State:**
```solidity
address public immutable endpoint;           // LayerZero endpoint
address public immutable stargatePool;       // Stargate USDT pool
IERC20 public immutable asset;               // USDT
IERC4626 public vault;                       // PPT Vault
address public pptOftAdapter;                // PPTOFTAdapter address
address public navReporter;                  // CrossChainNAVReporter
address public redemptionManager;            // Hub RedemptionManager
address public creditManager;               // CreditManager
address public crossChainAssetController;    // CrossChainAssetController

mapping(uint32 => address) public satelliteGateways;     // eid => satellite gateway
mapping(uint32 => address) public remoteAssetGateways;   // eid => remote portfolio gateway
mapping(uint32 => uint256) public slippageBps;           // per-chain slippage

mapping(uint256 => FailedDeposit) public failedDeposits;
uint256 public failedDepositCount;

mapping(uint256 => PendingSatelliteRedemption) public pendingSatelliteRedemptions;
```

**Inbound compose handler (`lzCompose`):**
- Verifies `msg.sender == endpoint`
- Verifies `_from == stargatePool`
- Extracts `srcEid`, `composeFrom`, `action` from compose message
- Routes to `_gatewayForAction(srcEid, action)` for source verification
- Dispatches to `_handleDeposit` (ACTION_DEPOSIT) or `_handleReturn` (ACTION_RETURN)

**Critical security check in `_gatewayForAction`:**
```solidity
function _gatewayForAction(uint32 eid, uint8 action) internal view returns (address gateway) {
    if (action == ACTION_DEPOSIT || action == ACTION_SETTLEMENT || action == ACTION_REPLENISH) {
        gateway = satelliteGateways[eid];
    } else if (action == ACTION_DEPLOY || action == ACTION_RETURN) {
        gateway = remoteAssetGateways[eid];
    } else {
        revert UnknownAction(action);
    }
    if (gateway == address(0)) revert ZeroAddress();
}
```

**Outbound functions (KEEPER_ROLE):**
- `settleAndBridge()` - Bridge settlement USDT to satellite
- `settleSatelliteRedemption()` - Settle on Hub then bridge to satellite
- `bridgeAndDeploy()` - Bridge USDT + deploy command to remote
- `replenishLiquidity()` - Bridge USDT to satellite LiquidityPool
- `retryFailedDeposit()` / `refundFailedDeposit()` - Handle failed deposits

**Constants:**
```solidity
uint128 STARGATE_RECEIVE_GAS = 65_000;
uint128 COMPOSE_GAS_DEPOSIT = 300_000;
uint128 COMPOSE_GAS_SETTLEMENT = 100_000;
uint128 COMPOSE_GAS_DEPLOY = 350_000;
uint128 COMPOSE_GAS_REPLENISH = 150_000;
uint256 DEFAULT_SLIPPAGE_BPS = 50;  // 0.5%
```

---

#### 4.1.2 PPTOFTAdapter

**File:** `src/layerzero/hub/PPTOFTAdapter.sol` (533 LOC)
**Inherits:** `OApp`, `Pausable`, `ReentrancyGuard`, `ILayerZeroComposer`
**Role:** Hub-side PPT lock/unlock adapter. Handles OApp messages from satellites (withdraw, redeem, credit changes). Sends OApp messages to satellites (mint shares, share price, credit updates).

**Key State:**
```solidity
IERC20 public immutable innerToken;          // PPT token
ICreditManager public creditManager;
address public vault;
address public redemptionManager;
address public hubStargateComposer;

mapping(uint256 => PendingMint) public pendingMints;
uint256 public pendingMintCount;

mapping(uint256 => PendingSharePriceSync) public pendingSharePriceSyncs;
mapping(uint32 => uint256) public pendingSharePriceSyncIdByDstEid;
mapping(uint32 => bool) public hasPendingSharePriceSync;
uint256 public pendingSharePriceSyncCount;
```

**Inbound OApp (`_lzReceive`) dispatch:**

| Payload Length | Dispatch |
|----------------|----------|
| 64 bytes | Standard OFT message: `abi.decode(address, uint256)` -> `_credit()` |
| Other | Typed message: `payload[0]` determines type |

| Message Type | Handler |
|-------------|---------|
| `MSG_WITHDRAW` (0x31) | `_handleSatelliteWithdraw` -> creates redemption on Hub |
| `MSG_REDEEM` (0x32) | `_handleSatelliteRedemption` -> creates redemption on Hub |
| `MSG_CREDIT_USED` (0x10) | `_handleSatelliteCreditUsed` -> `creditManager.reduceCredit()` |
| `MSG_CREDIT_RESTORED` (0x11) | `_handleSatelliteCreditRestored` -> `creditManager.restoreCredit()` |

**Inbound compose (`lzCompose`):**
- Restricted to `msg.sender == endpoint` and `_from == address(this)` (self-compose for redemptions)
- Only handles `COMPOSE_MSG_REDEEM` (0x01)

**Outbound functions:**
- `mintSharesOnSatellite()` - Called by HubStargateComposer after deposit; queues to `pendingMints` if gas insufficient
- `syncCreditToSatellite()` - Send credit update to satellite
- `syncSharePrice()` - Send share price update to satellite

**Share price auto-sync:** After every withdraw/redeem/mint operation, `_queueOrSendSharePrice()` is called to propagate the latest share price back to the satellite chain.

**`_payNative` override:** Uses `address(this).balance` instead of `msg.value` since the contract needs to send LZ messages inside `_lzReceive` callbacks where `msg.value == 0`.

---

#### 4.1.3 CreditManager

**File:** `src/layerzero/hub/CreditManager.sol` (386 LOC)
**Inherits:** `OApp`, `Pausable`, `ICreditManager`
**Role:** Manages per-satellite credit allocation and utilization tracking. Supports Delta-algorithm-based rebalancing.

**Key State:**
```solidity
mapping(uint32 => ChainCredit) internal _chainCredits;
uint32[] internal _supportedChains;
mapping(uint32 => bool) internal _isSupported;
uint256 public totalCredits;
address public satelliteSyncAdapter;          // Optional PPTOFTAdapter for credit sync
mapping(address => bool) public operators;
```

**ChainCredit struct:**
```solidity
struct ChainCredit {
    uint256 credit;       // Allocated quota
    uint256 utilized;     // Consumed quota
    uint256 lastUpdate;   // Timestamp
}
```

**Credit semantics:**
- `credit` = total allocated amount for a chain
- `utilized` = amount currently consumed by instant withdrawals
- `available` = `credit - utilized`
- `reduceCredit()` increases `utilized` (does NOT reduce `credit`)
- `restoreCredit()` decreases `utilized`
- `sendCredits()` increases `credit` allocation

**Credit sync path:** When credit allocation changes, `_syncCreditAllocation()` either:
1. Delegates to `satelliteSyncAdapter.syncCreditToSatellite()` (if configured) -> PPTOFTAdapter handles LZ send
2. Falls back to direct `_lzSend()` from CreditManager itself

**Inbound OApp (`_lzReceive`):**
- Handles `MSG_CREDIT_USED` (0x10) -> `_reduceCredit()`
- Handles `MSG_CREDIT_RESTORED` (0x11) -> `_restoreCredit()`

**Rebalance function:** `rebalance()` accepts arrays of `(eids, amounts)` and redistributes credit across all chains in a single transaction, with gas fee allocation split per-chain.

---

#### 4.1.4 CrossChainAssetController

**File:** `src/layerzero/hub/CrossChainAssetController.sol` (258 LOC)
**Inherits:** `OApp`, `AccessControl`, `Pausable`
**Role:** Hub-side portfolio control plane. Initiates deploy/withdraw/harvest commands via bridge or OApp.

**Key State:**
```solidity
IERC20 public immutable asset;
mapping(uint32 => uint256) public bridgedDeployedAssets;  // Principal per chain
uint256 public totalBridgedDeployed;
address public hubStargateComposer;
```

**Keeper functions:**
- `deployViaBridge()` - Transfer USDT to HubStargateComposer, call `bridgeAndDeploy()` via Stargate
- `withdrawFromRemote()` - Send `MSG_WITHDRAW_ASSET` via OApp
- `harvestYield()` - Send `MSG_HARVEST` via OApp

**Return accounting:**
- `recordBridgedReturn()` called by HubStargateComposer when assets return
- Principal returns reduce `bridgedDeployedAssets[eid]` and `totalBridgedDeployed`
- Yield returns do NOT reduce principal tracking (additive)

**Inbound messages disabled:** `_lzReceive` always reverts with `InboundMessagesDisabled()`.

---

#### 4.1.5 CrossChainNAVReporter

**File:** `src/layerzero/hub/CrossChainNAVReporter.sol` (239 LOC)
**Inherits:** `AccessControl`
**Role:** Aggregates cross-chain asset positions for PPT vault NAV calculation.

**Key State:**
```solidity
mapping(uint32 => uint256) public satelliteBalances;
mapping(uint32 => uint256) public remoteDeployments;
mapping(uint32 => uint256) public pendingTransits;
mapping(uint32 => uint256) public lastUpdateTime;
uint256 public totalCrossChainValue;        // Cached total
uint256 public lastGlobalSyncTime;
uint256 public stalePeriod = 7200;          // 2 hours
bool public enforceGlobalFreshness;
```

**Data freshness:** `getCrossChainValue()` can optionally revert if `lastGlobalSyncTime` exceeds `stalePeriod`, preventing stale NAV from being used in share pricing.

**Reporter functions (REPORTER_ROLE):**
- `updateSatelliteBalance()` - Manual satellite balance sync
- `updateRemoteDeployment()` - Manual remote value sync
- `recordDeploy()` - Called by HubStargateComposer on deploy
- `recordReturn()` - Called by HubStargateComposer on return
- `batchSyncChainPositions()` - Batch update + commit global sync timestamp

---

### 4.2 Satellite Contracts

#### 4.2.1 PPTSatellite

**File:** `src/layerzero/satellite/PPTSatellite.sol` (421 LOC)
**Inherits:** `OApp`, `ReentrancyGuard`, `Pausable`
**Role:** User entry point on satellite chains for deposit, instant withdraw, and cross-chain withdraw.

**Key State:**
```solidity
PPTOFT public immutable pptOft;
LiquidityPool public immutable liquidityPool;
IERC20 public immutable asset;
uint32 public immutable hubEid;
address public satelliteGateway;
uint256 public instantWithdrawFeeBps;
uint256 public sharePrice = 1e18;           // Updated via cross-chain

mapping(uint256 => uint256) public pendingCreditUsed;
uint256 public pendingCreditUsedCount;
mapping(uint256 => uint256) public pendingCreditRestored;
uint256 public pendingCreditRestoredCount;
```

**User functions:**
- `deposit()` / `depositWithParams()` -> USDT transferred to SatelliteGateway -> bridged to Hub
- `instantWithdraw()` -> Burns PPTOFT, pays from LiquidityPool, notifies Hub credit used
- `withdraw()` / `withdrawWithParams(CrossChain)` -> Burns PPTOFT, sends OApp `MSG_WITHDRAW` to Hub

**Instant withdraw flow:**
1. Calculate `grossAssets = shares * sharePrice / 1e18`
2. Deduct `fee = grossAssets * instantWithdrawFeeBps / 10000`
3. Check `assets <= liquidityPool.availableLiquidity()`
4. `pptOft.transferFrom(user, this)` then `pptOft.burn()`
5. `liquidityPool.withdrawForUser(receiver, assets)`
6. `_notifyCreditUsed(assets)` -> OApp to Hub (or queue if gas insufficient)

**Inbound OApp (`_lzReceive`):**

| Message Type | Action |
|-------------|--------|
| `MSG_SHARE_PRICE_UPDATE` (0x20) | Update `sharePrice` |
| `MSG_CREDIT_UPDATE` (0x21) | `liquidityPool.updateCredit(newCredit)` |
| `MSG_MINT_SHARES` (0x22) | `pptOft.mint(receiver, shares)` |

**Cross-chain withdraw minAssets semantics:**
- `WithdrawMode.Instant`: `minAssets` is checked against actual payout; reverts if not met.
- `WithdrawMode.CrossChain`: `minAssets` is only checked against `previewWithdraw()` before sending the OApp message. The actual settlement amount is determined asynchronously on Hub. This prevents erroneous revert due to the cross-chain return value being `0`.

---

#### 4.2.2 SatelliteGateway

**File:** `src/layerzero/satellite/SatelliteGateway.sol` (327 LOC)
**Inherits:** `ILayerZeroComposer`, `Ownable`, `ReentrancyGuard`, `Pausable`
**Role:** Bridges user deposits to Hub via Stargate. Receives Hub settlements and replenishments via Stargate compose.

**Key State:**
```solidity
address public immutable endpoint;
address public immutable stargatePool;
IERC20 public immutable asset;
uint32 public immutable hubEid;
address public hubComposer;
ILiquidityPool public liquidityPool;
address public depositForwarder;
uint256 public slippageBps;
```

**Deposit flow:**
1. `asset.safeTransferFrom(payer, address(this), assets)`
2. Encode `StargateComposeCodec.encodeDeposit(receiver, minShares)`
3. Build Type 3 compose options: `receiveGas=65_000 + composeGas=300_000`
4. `IStargate(stargatePool).send{value: msg.value}(...)` with `oftCmd: ""` (Taxi mode)

**Inbound compose (`lzCompose`):**
- Verifies: `msg.sender == endpoint`, `_from == stargatePool`, `srcEid == hubEid`, `composeFrom == hubComposer`
- `ACTION_SETTLEMENT` -> `asset.safeTransfer(receiver, amount)` (direct to user)
- `ACTION_REPLENISH` -> `liquidityPool.replenish(amount)` + optional `notifyCreditRestored()`

**Replenish credit restore notification:**
```solidity
try IPPTSatelliteCreditNotifier(satellite).notifyCreditRestored(amount) {
    emit CreditRestoreNotified(satellite, amount);
} catch {
    emit CreditRestoreNotificationFailed(satellite, amount);
}
```
The `try/catch` prevents replenishment from reverting if credit notification fails.

---

#### 4.2.3 PPTOFT

**File:** `src/layerzero/satellite/PPTOFT.sol` (249 LOC)
**Inherits:** `OApp`, `ERC20`, `Pausable`
**Role:** ERC-20 OFT representation of PPT on satellite chains.

**Key State:**
```solidity
uint32 public immutable hubEid;
address public minter;
```

**Mint/burn:**
- `mint()` restricted to `minter` or `owner` (PPTSatellite is set as minter)
- `burn()` callable by any holder
- Transfers are paused when contract is paused (`_update` override)

**Cross-chain redemption:**
- `requestCrossChainRedemption()` -> burns shares locally, sends `MSG_REDEEM` to Hub
- This is an alternative path to `PPTSatellite.withdraw()` -> `MSG_WITHDRAW`

**Standard OFT transfers:**
- `send()` burns on source, `_lzReceive` mints on destination
- Message format: `abi.encode(address to, uint256 amountLD)` = 64 bytes

---

#### 4.2.4 LiquidityPool

**File:** `src/layerzero/satellite/LiquidityPool.sol` (245 LOC)
**Inherits:** `ILiquidityPool`, `Ownable`, `ReentrancyGuard`, `Pausable`
**Role:** Provides instant withdrawal liquidity on satellite chains, governed by Hub credit.

**Key State:**
```solidity
IERC20 internal immutable _asset;
address public satellite;                // PPTSatellite
address public liquidityGateway;         // SatelliteGateway
uint256 public credit;                   // Hub-allocated quota
uint256 public utilized;                 // Consumed quota
uint256 public minBuffer;                // Reserved balance
```

**Available liquidity calculation:**
```solidity
function availableLiquidity() public view returns (uint256) {
    uint256 poolBalance = _asset.balanceOf(address(this));
    if (poolBalance <= minBuffer) return 0;
    uint256 bufferedBalance = poolBalance - minBuffer;
    uint256 remaining = remainingCredit();     // credit - utilized
    return bufferedBalance < remaining ? bufferedBalance : remaining;
}
```
The available amount is the **minimum** of (pool balance minus buffer) and (remaining credit). This is the key constraint: instant withdrawals are bounded by both physical liquidity and Hub-allocated credit.

**Access control:**
- `withdrawForUser()` -> `onlySatellite` (PPTSatellite)
- `updateCredit()` / `increaseCredit()` / `decreaseCredit()` -> `onlySatelliteOrOwner`
- `addLiquidity()` / `replenish()` -> `onlyLiquidityManagerOrOwner` (satellite, gateway, or owner)
- `removeLiquidity()` -> `onlyOwner`

**Replenish logic:**
```solidity
function replenish(uint256 amount) external {
    _asset.safeTransferFrom(msg.sender, address(this), amount);
    uint256 released = amount >= utilized ? utilized : amount;
    utilized -= released;
}
```
Replenishment reduces `utilized` by up to the replenished amount, effectively restoring credit capacity.

---

### 4.3 Remote Portfolio Contracts

#### 4.3.1 RemoteAssetGateway

**File:** `src/layerzero/satellite/adapters/RemoteAssetGateway.sol` (354 LOC)
**Inherits:** `OApp`, `ILayerZeroComposer`, `ReentrancyGuard`, `Pausable`
**Role:** Receives deploy commands from Hub via Stargate compose. Executes DeFi operations via pluggable `IRemoteProtocolImplementation`. Bridges returns back to Hub.

**Key State:**
```solidity
address public immutable stargatePool;
IERC20 public immutable asset;
uint32 public immutable hubEid;
uint32 public immutable thisEid;
address public hubComposer;
mapping(string => address) public protocolImplementations;
mapping(address => uint256) public protocolDeposits;
uint256 public totalDeposited;
uint256 public slippageBps;

mapping(uint256 => PendingReturn) public pendingReturns;
uint256 public pendingReturnCount;
```

**Inbound compose (`lzCompose`):**
- Verifies: `msg.sender == endpoint`, `_from == stargatePool`, `srcEid == hubEid`, `composeFrom == hubComposer`
- Only handles `ACTION_DEPLOY` -> `_handleDeploy()`

**Inbound OApp (`_lzReceive`):**
- Verifies: `_origin.srcEid == hubEid`
- `MSG_WITHDRAW_ASSET` (0x41) -> `_handleWithdrawCommand()`
- `MSG_HARVEST` (0x42) -> `_handleHarvestCommand()`

**Deploy flow:**
1. Resolve `protocolImplementations[protocolName]`
2. `asset.forceApprove(implementation, amount)`
3. `deployedAmount = IRemoteProtocolImplementation(implementation).deploy(asset, protocol, amount)`
4. Validate `deployedAmount <= amount`
5. Track in `protocolDeposits[protocol]` and `totalDeposited`
6. If `undeployedAmount > 0`, bridge remainder back to Hub

**Return bridging:**
```solidity
function _bridgeOrQueueReturn(uint256 amount, bool isYield) internal {
    uint256 nativeFee = _quoteBridgeFee(amount, isYield);
    if (address(this).balance >= nativeFee) {
        _bridgeToHub(amount, isYield, nativeFee);
    } else {
        // Queue for later flush
        pendingReturns[pendingReturnCount++] = PendingReturn(amount, isYield);
    }
}
```

**Withdraw command handling:**
- Validates `protocolDeposits[protocol] >= amount`
- Calls `IRemoteProtocolImplementation(implementation).withdraw()`
- Requires exact amount: `if (withdrawnAmount != amount) revert InvalidProtocolAmount()`
- Reduces `protocolDeposits[protocol]` and `totalDeposited`

---

### 4.4 Libraries

#### 4.4.1 MessageCodec

Defines 10 message types with prefix-based routing:

```
0x10 MSG_CREDIT_USED         Satellite -> Hub     uint256 amount
0x11 MSG_CREDIT_RESTORED     Satellite -> Hub     uint256 amount
0x20 MSG_SHARE_PRICE_UPDATE  Hub -> Satellite     uint256 price
0x21 MSG_CREDIT_UPDATE       Hub -> Satellite     uint256 credit
0x22 MSG_MINT_SHARES         Hub -> Satellite     (address receiver, uint256 shares)
0x30 MSG_DEPOSIT             Legacy (unused)      (address receiver, uint256 assets)
0x31 MSG_WITHDRAW            Satellite -> Hub     (address receiver, uint256 shares)
0x32 MSG_REDEEM              Satellite -> Hub     (address owner, uint256 shares)
0x41 MSG_WITHDRAW_ASSET      Hub -> Remote        (uint256 amount, address protocol, string name)
0x42 MSG_HARVEST             Hub -> Remote        (address protocol, string name)
```

**Encoding format:** `abi.encodePacked(bytes1(msgType), abi.encode(data...))`
**Decoding:** `bytes1 msgType = payload[0]; abi.decode(payload[1:], (types...))`

#### 4.4.2 StargateComposeCodec

Defines 6 compose action types:

```
0x01 ACTION_DEPOSIT          Satellite -> Hub     (address receiver, uint256 minShares)
0x02 ACTION_SETTLEMENT       Hub -> Satellite     (address receiver, uint256 requestId)
0x03 ACTION_DEPLOY           Hub -> Remote        (address protocol, string protocolName)
0x04 ACTION_RETURN           Remote -> Hub        (uint32 srcEid, bool isYield)
0x05 ACTION_REPLENISH        Hub -> Satellite     (no params)
0x06 ACTION_HARVEST_RETURN   Reserved             (unused)
```

**Encoding format:** `abi.encodePacked(uint8(action), abi.encode(params...))`

#### 4.4.3 LzOptionsLib

Builds LayerZero V2 Type 3 executor options:

- `buildLzReceiveOptions(gas)` - Single-phase receive
- `buildLzReceiveOptionsWithValue(gas, value)` - Receive with native value
- `buildComposeOptions(receiveGas, composeGas)` - Two-phase: token credit + business logic
- `buildComposeOptionsWithValue(receiveGas, composeGas, value)` - Two-phase with native value

**Type 3 format:**
```
[uint16 TYPE_3] [uint8 workerID] [uint16 optionSize] [uint8 optionType] [data...]
```

#### 4.4.4 DeltaLib

Utility library for credit allocation algorithms:
- `calculateCredit()` - Weight-based allocation
- `calculateOptimalWeights()` - Usage-based weight derivation
- `calculateUtilization()` - Utilization ratio
- `calculateRebalanceDeltas()` - Required credit changes per chain
- `validateWeights()` - Ensure weights sum to 100%

---

## 5. Cross-Chain Message Protocol

### 5.1 Message Flow Diagrams

#### 5.1.1 Multi-Chain Subscription (Deposit)

```
User (Satellite)
  │
  ├─1─► PPTSatellite.deposit(assets, receiver) {msg.value: LZ fee}
  │       ├─ asset.safeTransferFrom(user, this, assets)
  │       ├─ asset.forceApprove(satelliteGateway, assets)
  │       └─► SatelliteGateway.depositFor()
  │             ├─ asset.safeTransferFrom(satellite, this, assets)
  │             ├─ asset.forceApprove(stargatePool, assets)
  │             └─► Stargate.send(hubEid, hubComposer, composeMsg=DEPOSIT)
  │                   │
  │  ── Stargate V2 bridge (USDT physically moves to BSC) ──
  │                   │
  ├─2─► HubStargateComposer.lzCompose()  [called by LZ endpoint]
  │       ├─ verify: msg.sender == endpoint
  │       ├─ verify: _from == stargatePool
  │       ├─ verify: composeFrom == satelliteGateways[srcEid]
  │       ├─ action = ACTION_DEPOSIT
  │       ├─ vault.deposit(assets, pptOftAdapter) -> shares
  │       │   └─ on failure: _storeFailedDeposit()
  │       └─► PPTOFTAdapter.mintSharesOnSatellite(srcEid, receiver, shares)
  │             ├─ quote LZ fee
  │             ├─ if balance >= fee: _lzSend(MSG_MINT_SHARES)
  │             └─ else: store in pendingMints[]
  │
  │  ── LayerZero OApp message ──
  │
  └─3─► PPTSatellite._lzReceive(MSG_MINT_SHARES)
          └─ pptOft.mint(receiver, shares)
```

#### 5.1.2 Instant Withdrawal

```
User (Satellite)
  │
  ├─1─► PPTSatellite.instantWithdraw(shares, receiver)
  │       ├─ grossAssets = shares * sharePrice / 1e18
  │       ├─ fee = grossAssets * instantWithdrawFeeBps / 10000
  │       ├─ assets = grossAssets - fee
  │       ├─ check: assets <= liquidityPool.availableLiquidity()
  │       ├─ pptOft.transferFrom(user, this, shares)
  │       ├─ pptOft.burn(shares)
  │       ├─► liquidityPool.withdrawForUser(receiver, assets)
  │       │     ├─ check: assets <= availableLiquidity()
  │       │     ├─ utilized += assets
  │       │     └─ asset.safeTransfer(user, assets)
  │       └─► _notifyCreditUsed(assets)
  │             ├─ quote LZ fee
  │             ├─ if balance >= fee: _lzSend(MSG_CREDIT_USED)
  │             └─ else: store in pendingCreditUsed[]
  │
  │  ── LayerZero OApp message ──
  │
  └─2─► PPTOFTAdapter._lzReceive(MSG_CREDIT_USED)
          └─► creditManager.reduceCredit(srcEid, amount)
                ├─ check: available >= amount
                └─ utilized += amount
```

#### 5.1.3 Standard Cross-Chain Redemption

```
User (Satellite)
  │
  ├─1─► PPTSatellite.withdraw(shares, receiver) {msg.value: LZ fee}
  │       ├─ pptOft.transferFrom(user, this, shares)
  │       ├─ pptOft.burn(shares)
  │       └─► _lzSend(hubEid, MSG_WITHDRAW(receiver, shares))
  │
  │  ── LayerZero OApp message ──
  │
  ├─2─► PPTOFTAdapter._lzReceive(MSG_WITHDRAW)
  │       ├─ _requestSatelliteRedemption(srcEid, receiver, shares)
  │       │     ├─ requestId = redemptionManager.requestRedemption(shares, hubStargateComposer)
  │       │     └─► hubStargateComposer.registerSatelliteRedemption(requestId, srcEid, receiver)
  │       └─ _queueOrSendSharePrice(srcEid)
  │
  │  ── Hub processes redemption (async) ──
  │
  ├─3─► HubStargateComposer.settleSatelliteRedemption(requestId) {msg.value: Stargate fee}
  │       ├─ redemptionManager.settleRedemption(requestId)
  │       ├─ settledAmount = balance_after - balance_before
  │       └─► _bridgeSettlement(dstEid, receiver, settledAmount)
  │             └─ Stargate.send(ACTION_SETTLEMENT)
  │
  │  ── Stargate V2 bridge (USDT physically moves to satellite) ──
  │
  └─4─► SatelliteGateway.lzCompose(ACTION_SETTLEMENT)
          └─ asset.safeTransfer(receiver, amount)
```

#### 5.1.4 Portfolio Deploy / Withdraw / Harvest

```
Keeper (Hub)
  │
  ├─── DEPLOY ───
  │ CrossChainAssetController.deployViaBridge(dstEid, amount, protocol, name)
  │   ├─ asset.safeTransfer(hubStargateComposer, amount)
  │   └─► hubStargateComposer.bridgeAndDeploy() -> Stargate.send(ACTION_DEPLOY)
  │         │
  │  ── Stargate V2 bridge ──
  │         │
  │         └─► RemoteAssetGateway.lzCompose(ACTION_DEPLOY)
  │               ├─ implementation.deploy(asset, protocol, amount)
  │               ├─ update protocolDeposits[protocol], totalDeposited
  │               └─ bridge undeployed remainder back (if any)
  │
  ├─── WITHDRAW ───
  │ CrossChainAssetController.withdrawFromRemote(dstEid, amount, protocol, name)
  │   └─► _lzSend(MSG_WITHDRAW_ASSET)
  │         │
  │  ── LayerZero OApp message ──
  │         │
  │         └─► RemoteAssetGateway._lzReceive(MSG_WITHDRAW_ASSET)
  │               ├─ implementation.withdraw(asset, protocol, amount)
  │               └─ _bridgeOrQueueReturn(amount, isYield=false)
  │                     └─ Stargate.send(ACTION_RETURN) or pendingReturns[]
  │
  └─── HARVEST ───
    CrossChainAssetController.harvestYield(dstEid, protocol, name)
      └─► _lzSend(MSG_HARVEST)
            │
            └─► RemoteAssetGateway._lzReceive(MSG_HARVEST)
                  ├─ yieldAmount = implementation.harvest(asset, protocol)
                  └─ _bridgeOrQueueReturn(yieldAmount, isYield=true)

  ── Stargate V2 bridge (return) ──

  HubStargateComposer.lzCompose(ACTION_RETURN)
    ├─ asset.safeTransfer(vault, amount)
    ├─ navReporter.recordReturn(srcEid, amount, isYield)
    └─ crossChainAssetController.recordBridgedReturn(srcEid, amount, isYield)
```

#### 5.1.5 Liquidity Replenishment

```
Keeper (Hub)
  │
  └─► HubStargateComposer.replenishLiquidity(dstEid, amount) {msg.value: Stargate fee}
        └─► Stargate.send(ACTION_REPLENISH)
              │
  ── Stargate V2 bridge ──
              │
              └─► SatelliteGateway.lzCompose(ACTION_REPLENISH)
                    ├─ liquidityPool.replenish(amount)
                    │     ├─ asset.safeTransferFrom(gateway, pool, amount)
                    │     └─ utilized -= min(amount, utilized)
                    └─ PPTSatellite.notifyCreditRestored(amount)
                          └─► _lzSend(hubEid, MSG_CREDIT_RESTORED(amount))
                                │
  ── LayerZero OApp message ──
                                │
                                └─► CreditManager._lzReceive(MSG_CREDIT_RESTORED)
                                      └─ _restoreCredit(srcEid, amount)
```

---

## 6. Business Flow Specifications

### 6.1 Deposit Flow Invariants

1. USDT physically moves from satellite to Hub via Stargate V2.
2. Vault deposit occurs on Hub chain; shares are minted to `pptOftAdapter`.
3. PPT shares are then sent back to receiver on satellite via OApp `MSG_MINT_SHARES`.
4. Failed deposits (slippage, Vault revert) are stored in `failedDeposits[]` for keeper retry or refund.
5. `minShares` protection is checked via `vault.previewDeposit()` before actual deposit.
6. If `minShares = 0`, no slippage check is performed.

### 6.2 Instant Withdraw Invariants

1. User must hold sufficient PPTOFT.
2. Available liquidity = min(poolBalance - minBuffer, credit - utilized).
3. PPTOFT is burned on satellite; no cross-chain message is required for asset payout.
4. Credit utilization notification (`MSG_CREDIT_USED`) is sent to Hub asynchronously.
5. If gas is insufficient for OApp send, credit notification is queued in `pendingCreditUsed[]`.
6. Instant withdraw fee (max 10% = 1000 BPS) is deducted from gross assets.

### 6.3 Cross-Chain Redemption Invariants

1. PPTOFT is burned on satellite before the cross-chain message is sent.
2. On Hub, `PPTOFTAdapter` creates a redemption request via `RedemptionManager`.
3. The redemption owner is set to `hubStargateComposer` (not the user), so settlement can be initiated by the keeper.
4. After Hub settlement, keeper calls `settleSatelliteRedemption()` which settles and bridges USDT back.
5. `SatelliteGateway` receives the settlement and transfers USDT directly to the user's `receiver` address.
6. `minAssets` on the cross-chain path is a preview-only check; no re-validation occurs at settlement time.

### 6.4 Portfolio Invariants

1. Only KEEPER_ROLE can initiate deploy/withdraw/harvest.
2. Deploy: USDT is transferred from `CrossChainAssetController` to `HubStargateComposer` before bridging.
3. `RemoteAssetGateway` validates `deployedAmount <= amount` and bridges any undeployed remainder back.
4. Withdraw: `protocolDeposits[protocol] >= amount` is required.
5. Withdraw requires exact return: `withdrawnAmount == amount`, otherwise reverts.
6. Harvest yield does NOT reduce `protocolDeposits` (yield is additive).
7. Returns are bridged back as `ACTION_RETURN` with `isYield` flag.
8. Hub distinguishes principal returns (reduce NAV deployment tracking) from yield returns (no reduction).

---

## 7. Access Control Matrix

### 7.1 HubStargateComposer

| Function | Role | Notes |
|----------|------|-------|
| `lzCompose` | **LZ Endpoint only** | `msg.sender == endpoint && _from == stargatePool` |
| `settleAndBridge` | `KEEPER_ROLE` | |
| `settleSatelliteRedemption` | `KEEPER_ROLE` | |
| `bridgeAndDeploy` | `KEEPER_ROLE` | |
| `replenishLiquidity` | `KEEPER_ROLE` | |
| `retryFailedDeposit` | `KEEPER_ROLE` | |
| `refundFailedDeposit` | `KEEPER_ROLE` | |
| `registerSatelliteRedemption` | **pptOftAdapter only** | `msg.sender == pptOftAdapter` |
| `setVault` | `DEFAULT_ADMIN_ROLE` | |
| `setPptOftAdapter` | `DEFAULT_ADMIN_ROLE` | |
| `setNavReporter` | `DEFAULT_ADMIN_ROLE` | |
| `setRedemptionManager` | `DEFAULT_ADMIN_ROLE` | |
| `setCreditManager` | `DEFAULT_ADMIN_ROLE` | |
| `setCrossChainAssetController` | `DEFAULT_ADMIN_ROLE` | |
| `setSatelliteGateway` | `DEFAULT_ADMIN_ROLE` | |
| `setRemoteAssetGateway` | `DEFAULT_ADMIN_ROLE` | |
| `setSlippageBps` | `DEFAULT_ADMIN_ROLE` | |
| `pause` / `unpause` | `DEFAULT_ADMIN_ROLE` | |
| `emergencyWithdraw` | `DEFAULT_ADMIN_ROLE` | |

### 7.2 PPTOFTAdapter

| Function | Role | Notes |
|----------|------|-------|
| `_lzReceive` | **LZ OApp** | Peer-verified via `peers[srcEid]` |
| `lzCompose` | **LZ Endpoint only** | `msg.sender == endpoint && _from == address(this)` |
| `send` | **Any user** | Public OFT send (lock/unlock) |
| `mintSharesOnSatellite` | **hubStargateComposer only** | `msg.sender == hubStargateComposer` |
| `syncCreditToSatellite` | `owner` or `creditManager` | |
| `syncSharePrice` | `owner` | |
| `flushPendingMint` | **Any caller** | Requires `msg.value` for LZ fee |
| `flushPendingSharePriceSync` | **Any caller** | Requires `msg.value` for LZ fee |
| `setCreditManager` | `owner` | |
| `setVault` | `owner` | |
| `setRedemptionManager` | `owner` | |
| `setHubStargateComposer` | `owner` | |
| `pause` / `unpause` | `owner` | |
| `emergencyWithdraw` | `owner` | |

### 7.3 CreditManager

| Function | Role | Notes |
|----------|------|-------|
| `_lzReceive` | **LZ OApp** | Source must be `_isSupported[srcEid]` |
| `sendCredits` | `owner` | |
| `setCredit` | `owner` | |
| `rebalance` | `owner` | |
| `reduceCredit` | `owner` or `operator` | |
| `restoreCredit` | `owner` or `operator` | |
| `addChain` | `owner` | |
| `removeChain` | `owner` | |
| `setSatelliteSyncAdapter` | `owner` | |
| `setOperator` | `owner` | |
| `pause` / `unpause` | `owner` | |

### 7.4 CrossChainAssetController

| Function | Role | Notes |
|----------|------|-------|
| `deployViaBridge` | `KEEPER_ROLE` | |
| `withdrawFromRemote` | `KEEPER_ROLE` | |
| `harvestYield` | `KEEPER_ROLE` | |
| `recordBridgedReturn` | **hubStargateComposer only** | `msg.sender == hubStargateComposer` |
| `addSupportedChain` | `DEFAULT_ADMIN_ROLE` | |
| `removeSupportedChain` | `DEFAULT_ADMIN_ROLE` | |
| `updateRemoteGateway` | `DEFAULT_ADMIN_ROLE` | |
| `setHubStargateComposer` | `DEFAULT_ADMIN_ROLE` | |
| `emergencyWithdraw` | `DEFAULT_ADMIN_ROLE` | |
| `pause` / `unpause` | `DEFAULT_ADMIN_ROLE` | |

### 7.5 Satellite Contracts

| Contract | Function | Role |
|----------|----------|------|
| **PPTSatellite** | `deposit`, `withdraw`, `instantWithdraw` | Any user |
| | `setSatelliteGateway` | `owner` |
| | `setInstantWithdrawFee` | `owner` |
| | `setSharePrice` | `owner` |
| | `setPaused` | `owner` |
| | `flushPendingCreditUsed` | `owner` |
| | `flushPendingCreditRestored` | `owner` |
| | `notifyCreditRestored` | **satelliteGateway only** |
| **SatelliteGateway** | `deposit` | Any user |
| | `depositFor` | Payer self or `depositForwarder` |
| | `lzCompose` | **LZ Endpoint only** |
| | `setHubComposer` | `owner` |
| | `setLiquidityPool` | `owner` |
| | `setDepositForwarder` | `owner` |
| | `emergencyWithdraw` | `owner` |
| **PPTOFT** | `mint` | `minter` or `owner` |
| | `burn` | Any holder |
| | `send` | Any holder |
| | `requestCrossChainRedemption` | Any holder |
| | `setMinter` | `owner` |
| **LiquidityPool** | `withdrawForUser` | `satellite` only |
| | `addLiquidity` | `satellite`, `liquidityGateway`, or `owner` |
| | `replenish` | `satellite`, `liquidityGateway`, or `owner` |
| | `removeLiquidity` | `owner` |
| | `updateCredit` | `satellite` or `owner` |
| | `setSatellite` | `owner` |
| | `setLiquidityGateway` | `owner` |
| | `emergencyWithdraw` | `owner` |

### 7.6 RemoteAssetGateway

| Function | Role | Notes |
|----------|------|-------|
| `lzCompose` | **LZ Endpoint only** | `msg.sender == endpoint && _from == stargatePool` |
| `_lzReceive` | **LZ OApp** | `_origin.srcEid == hubEid` |
| `flushPendingReturn` | `owner` | |
| `setHubComposer` | `owner` | |
| `setProtocolImplementation` | `owner` | |
| `setSlippageBps` | `owner` | |
| `emergencyWithdraw` | `owner` | |
| `pause` / `unpause` | `owner` | |

---

## 8. Security Invariants and Properties

### 8.1 Source Verification Invariants

| Entry Point | Verification Requirements |
|-------------|--------------------------|
| `HubStargateComposer.lzCompose` | `msg.sender == endpoint` AND `_from == stargatePool` AND `_gatewayForAction(srcEid, action) == composeFrom` |
| `SatelliteGateway.lzCompose` | `msg.sender == endpoint` AND `_from == stargatePool` AND `srcEid == hubEid` AND `composeFrom == hubComposer` |
| `RemoteAssetGateway.lzCompose` | `msg.sender == endpoint` AND `_from == stargatePool` AND `srcEid == hubEid` AND `composeFrom == hubComposer` |
| `PPTOFTAdapter._lzReceive` | `peers[_origin.srcEid] == _origin.sender` |
| `PPTOFTAdapter.lzCompose` | `msg.sender == endpoint` AND `_from == address(this)` |
| `PPTSatellite._lzReceive` | `_origin.srcEid == hubEid` |
| `CreditManager._lzReceive` | `_isSupported[origin.srcEid]` |
| `RemoteAssetGateway._lzReceive` | `_origin.srcEid == hubEid` |

### 8.2 Gateway Isolation Invariants

1. `SatelliteGateway` must NEVER receive `ACTION_DEPLOY` or `ACTION_RETURN`.
2. `RemoteAssetGateway` must NEVER receive `ACTION_SETTLEMENT` or `ACTION_REPLENISH`.
3. `HubStargateComposer._gatewayForAction()` enforces this mapping:
   - `DEPOSIT | SETTLEMENT | REPLENISH` -> `satelliteGateways[eid]`
   - `DEPLOY | RETURN` -> `remoteAssetGateways[eid]`
4. If a chain functions as both satellite and remote portfolio target, the two gateways must be separate contract addresses.

### 8.3 Accounting Invariants

1. **Share conservation:** Total PPT minted (via `PPTOFT.mint`) on all satellite chains must equal total locked PPT in `PPTOFTAdapter` on Hub.
2. **Credit balance:** For every chain: `credit >= utilized`. Enforced by `_reduceCredit()`.
3. **Credit restoration:** `_restoreCredit()` enforces `utilized >= amount` to prevent underflow.
4. **Portfolio accounting:** `bridgedDeployedAssets[eid]` tracks actual principal deployed. Returns reduce it; yield does not.
5. **NAV integrity:** `totalCrossChainValue = sum(satelliteBalances) + sum(remoteDeployments)`.
6. **Deposit idempotency:** Failed deposits are stored exactly once with a unique `failedId`. Retry or refund deletes the record.
7. **Redemption uniqueness:** Each `requestId` maps to exactly one `PendingSatelliteRedemption`. Settlement deletes the record.

### 8.4 Critical Safety Properties

1. **No double spend on settlement:** After `settleSatelliteRedemption`, `delete pendingSatelliteRedemptions[requestId]` prevents re-settlement.
2. **No double retry/refund:** After `retryFailedDeposit` or `refundFailedDeposit`, `delete failedDeposits[failedId]` prevents re-processing.
3. **Shares burned before cross-chain request:** `PPTSatellite.withdraw()` and `PPTOFT.requestCrossChainRedemption()` both burn shares BEFORE sending the OApp message.
4. **Assets transferred before bridge call:** `SatelliteGateway._depositFor()` transfers USDT from user before initiating Stargate send.
5. **Vault deposit to correct recipient:** Assets are deposited into vault with `pptOftAdapter` as receiver, ensuring shares are held by the adapter until sent cross-chain.
6. **Approval cleanup:** All `forceApprove()` calls are followed by `forceApprove(0)` after the operation completes or fails.

### 8.5 Legacy Path Disabled

The following legacy message paths are explicitly disabled:

1. `PPTOFTAdapter._lzReceive` does NOT handle `MSG_DEPOSIT` (0x30). If received, `revert UnknownMessageType`.
2. `PPTOFTAdapter.lzCompose` only handles `COMPOSE_MSG_REDEEM`. All other compose types revert.
3. The official deposit path is exclusively: `PPTSatellite -> SatelliteGateway -> Stargate -> HubStargateComposer`.

---

## 9. Attack Surface Analysis

### 9.1 Cross-Chain Message Spoofing

**Risk:** An attacker sends a crafted LayerZero message to simulate a deposit, mint, or credit change.

**Mitigations:**
- All OApp `_lzReceive` handlers verify `peers[srcEid] == origin.sender`
- All Stargate compose handlers verify `msg.sender == endpoint && _from == stargatePool`
- Compose messages additionally verify `composeFrom` matches the expected gateway address
- Peer configuration is admin-only

**Audit focus:** Verify there is no code path that processes a message without full source verification.

### 9.2 Credit System Manipulation

**Risk:** Attacker drains LiquidityPool by manipulating credit or bypassing utilization tracking.

**Mitigations:**
- `LiquidityPool.withdrawForUser()` is restricted to `onlySatellite`
- Available liquidity is bounded by both physical balance and remaining credit
- Credit changes require `owner` or `operator` role on CreditManager
- `reduceCredit` reverts if `available < amount`
- `restoreCredit` reverts if `utilized < amount`

**Audit focus:**
- Can `utilized` be decreased without actual replenishment?
- Can credit notification messages be replayed?
- What happens if `MSG_CREDIT_USED` arrives out of order or is delayed?

### 9.3 Failed Deposit Exploitation

**Risk:** Attacker exploits `failedDeposits` to steal funds via retry or refund.

**Mitigations:**
- Only `KEEPER_ROLE` can retry or refund
- Both operations delete the record to prevent re-processing
- Retry performs slippage check before vault deposit
- Refund bridges back to original `receiver` on original `srcEid`

**Audit focus:**
- Can a keeper be tricked into refunding to a wrong address?
- What if `receiver` is a contract that can re-enter?

### 9.4 Share Price Manipulation

**Risk:** Stale or manipulated `sharePrice` on satellite causes incorrect instant withdraw amounts.

**Mitigations:**
- `sharePrice` is updated via cross-chain message from Hub (trusted source)
- Admin can manually set share price via `setSharePrice()`
- Share price sync is automatically triggered after every mint/redeem operation

**Audit focus:**
- What is the maximum staleness period for share price?
- Can a flash loan attack exploit the delay between Hub price change and satellite sync?
- Can the admin `setSharePrice()` be used to drain the LiquidityPool?

### 9.5 Reentrancy

**Mitigations:**
- `HubStargateComposer`: `nonReentrant` on `lzCompose` and all outbound functions
- `PPTOFTAdapter`: `nonReentrant` on `_lzReceive` and compose
- `PPTSatellite`: `nonReentrant` on `deposit`, `instantWithdraw`, `withdraw`
- `SatelliteGateway`: `nonReentrant` on `lzCompose` and deposit functions
- `RemoteAssetGateway`: `nonReentrant` on `lzCompose` and `_lzReceive`
- `LiquidityPool`: `nonReentrant` on `addLiquidity`, `removeLiquidity`, `withdrawForUser`, `replenish`

**Audit focus:** Verify no cross-contract callback can bypass reentrancy guards. In particular, the `_handleDeposit` -> `vault.deposit()` -> potential callback path.

### 9.6 Denial of Service

**Risk:** Intentional blocking of cross-chain message processing.

**Vectors:**
- Stargate compose reverts -> message is stored by LZ DVN for retry
- Pending queues grow unboundedly
- Native gas depletion on contract

**Mitigations:**
- `failedDeposits` and pending queues provide recovery paths
- Admin can pause/unpause contracts
- `emergencyWithdraw` on all contracts
- Anyone can call `flushPendingMint()` / `flushPendingSharePriceSync()` (permissionless flushing)

### 9.7 Fund Loss Scenarios

| Scenario | Risk Level | Mitigation |
|----------|-----------|------------|
| Vault deposit fails | Medium | Stored in `failedDeposits[]`; keeper retry or refund |
| Mint shares OApp fails | Low | Stored in `pendingMints[]`; anyone can flush |
| Settlement bridge fails | Low | Stargate handles retry at protocol level |
| Remote deploy fails | Medium | Undeployed remainder bridged back to Hub |
| Return bridge gas insufficient | Medium | Stored in `pendingReturns[]`; owner can flush |
| Credit notification fails | Low | Stored in `pendingCreditUsed[]`; owner can flush |
| Share price sync fails | Low | Stored in `pendingSharePriceSyncs[]`; anyone can flush |

---

## 10. Accounting Model

### 10.1 Credit Accounting (Hub-side)

```
CreditManager per chain:
  credit (allocation) ─┐
                        ├─ available = credit - utilized
  utilized (consumed) ──┘

Invariant: credit >= utilized (enforced by _reduceCredit)
```

**State transitions:**
| Operation | Effect |
|-----------|--------|
| `sendCredits(eid, amount)` | `credit += amount` |
| `setCredit(eid, amount)` | `credit = amount` (must be >= utilized) |
| `reduceCredit(eid, amount)` | `utilized += amount` (must have available >= amount) |
| `restoreCredit(eid, amount)` | `utilized -= amount` (must have utilized >= amount) |
| `removeChain(eid)` | Requires `utilized == 0` |

### 10.2 Liquidity Pool Accounting (Satellite-side)

```
LiquidityPool:
  balance = asset.balanceOf(this)
  credit (from Hub)
  utilized (local tracking)
  minBuffer (reserved)

  availableLiquidity = min(balance - minBuffer, credit - utilized)
```

**State transitions:**
| Operation | Effect |
|-----------|--------|
| `withdrawForUser(amount)` | `utilized += amount`, `balance -= amount` |
| `replenish(amount)` | `balance += amount`, `utilized -= min(amount, utilized)` |
| `updateCredit(newCredit)` | `credit = newCredit` |
| `addLiquidity(amount)` | `balance += amount` |
| `removeLiquidity(amount)` | `balance -= amount` |

### 10.3 Portfolio Accounting (Hub-side)

```
CrossChainAssetController per chain:
  bridgedDeployedAssets[eid] ─ principal deployed via Stargate
  totalBridgedDeployed ─ sum across all chains

CrossChainNAVReporter per chain:
  satelliteBalances[eid] ─ satellite pool USDT
  remoteDeployments[eid] ─ remote protocol value
  totalCrossChainValue ─ cached sum
```

**State transitions for returns:**
| Return Type | CrossChainAssetController | CrossChainNAVReporter |
|-------------|--------------------------|----------------------|
| Principal return | `bridgedDeployedAssets[eid] -= amount` | `remoteDeployments[eid] -= amount` |
| Yield return | No change | No change (yield goes to vault) |

### 10.4 NAV Staleness Protection

`CrossChainNAVReporter` implements optional staleness enforcement:
- `stalePeriod` (default 7200s = 2 hours)
- `enforceGlobalFreshness` toggle
- When enabled, `getCrossChainValue()` reverts if `lastGlobalSyncTime` is stale
- `batchSyncChainPositions()` automatically commits `lastGlobalSyncTime`

---

## 11. Failure Recovery Mechanisms

### 11.1 Summary Table

| Queue | Contract | Stored Data | Recovery Function | Permissioned? |
|-------|----------|-------------|-------------------|---------------|
| `failedDeposits[]` | HubStargateComposer | srcEid, receiver, assets, minShares, timestamp | `retryFailedDeposit()` / `refundFailedDeposit()` | KEEPER_ROLE |
| `pendingMints[]` | PPTOFTAdapter | dstEid, receiver, shares | `flushPendingMint()` | Permissionless |
| `pendingSharePriceSyncs[]` | PPTOFTAdapter | dstEid, sharePrice | `flushPendingSharePriceSync()` | Permissionless |
| `pendingCreditUsed[]` | PPTSatellite | amount | `flushPendingCreditUsed()` | Owner |
| `pendingCreditRestored[]` | PPTSatellite | amount | `flushPendingCreditRestored()` | Owner |
| `pendingReturns[]` | RemoteAssetGateway | amount, isYield | `flushPendingReturn()` | Owner |

### 11.2 Share Price Sync Deduplication

`PPTOFTAdapter` deduplicates pending share price syncs per destination chain:
- `hasPendingSharePriceSync[dstEid]` tracks if a pending sync exists
- `pendingSharePriceSyncIdByDstEid[dstEid]` maps to the pending ID
- If a new sync is needed and one already exists for the same chain, the existing entry is updated in-place
- If gas becomes available, existing pending syncs are cleaned up before sending fresh data

### 11.3 Circuit Breakers

All contracts implement `Pausable`:
- Admin/owner can `pause()` to halt all state-changing operations
- `whenNotPaused` modifier is applied to all critical functions
- `emergencyWithdraw()` is available on all contracts to rescue stuck funds

---

## 12. External Dependencies

### 12.1 OpenZeppelin Contracts

| Contract | Version | Usage |
|----------|---------|-------|
| `AccessControl` | 5.x | Role-based access (Hub contracts) |
| `Ownable` | 5.x | Single-owner access (Satellite contracts) |
| `ReentrancyGuard` | 5.x | Reentrancy protection |
| `Pausable` | 5.x | Circuit breaker |
| `SafeERC20` | 5.x | Safe token operations |
| `ERC20` | 5.x | PPTOFT token |
| `IERC4626` | 5.x | Vault interface |

### 12.2 LayerZero V2

| Component | Usage |
|-----------|-------|
| `OApp` | Base contract for typed message send/receive |
| `ILayerZeroComposer` | Interface for Stargate compose callbacks |
| `OFTComposeMsgCodec` | Decode compose message fields (amountLD, srcEid, composeFrom, composeMsg) |
| `MessagingFee` | Fee structure for LZ sends |
| `Origin` | Source chain identification |

### 12.3 Stargate V2

| Component | Usage |
|-----------|-------|
| `IStargate` (custom interface) | Bridge send operations |
| Stargate Pool | USDT pool on each chain |
| Taxi mode (`oftCmd: ""`) | Required for compose support |
| `SendParam` | Bridge parameters struct |
| `OFTReceipt` | Bridge receipt with `amountReceivedLD` |

### 12.4 Trust Assumptions

1. **LayerZero DVN/Executor**: Assumed to deliver messages correctly and atomically.
2. **Stargate V2**: Assumed to bridge exact or near-exact USDT amounts (slippage bounded by `minAmountLD`).
3. **PPT Vault (ERC-4626)**: Assumed to correctly implement deposit/withdraw with accurate share accounting.
4. **RedemptionManager**: Assumed to correctly process redemption requests and settle with accurate asset amounts.
5. **IRemoteProtocolImplementation**: Assumed to correctly implement deploy/withdraw/harvest. This is user-provided code and should be audited separately.

---

## 13. Gas and Fee Model

### 13.1 Gas Constants

| Constant | Value | Usage |
|----------|-------|-------|
| `STARGATE_RECEIVE_GAS` | 65,000 | Gas for Stargate lzReceive (token credit) |
| `COMPOSE_GAS_DEPOSIT` | 300,000 | Gas for deposit compose (Hub vault deposit + mint shares) |
| `COMPOSE_GAS_SETTLEMENT` | 100,000 | Gas for settlement compose (simple transfer) |
| `COMPOSE_GAS_DEPLOY` | 350,000 | Gas for deploy compose (protocol interaction) |
| `COMPOSE_GAS_REPLENISH` | 150,000 | Gas for replenish compose (pool replenish + credit notify) |
| `COMPOSE_GAS_RETURN` | 100,000 | Gas for return compose (vault transfer + NAV update) |
| `DEFAULT_GAS_LIMIT` (OApp) | 200,000-300,000 | Gas for OApp lzReceive messages |

### 13.2 Slippage Model

- Default: 50 BPS (0.5%)
- Per-chain configurable via `slippageBps[eid]` (HubStargateComposer) or `slippageBps` (SatelliteGateway, RemoteAssetGateway)
- Applied to Stargate `minAmountLD`: `amount * (10000 - slippageBps) / 10000`

### 13.3 Fee Sources

| Fee | Source | Recipient |
|-----|--------|-----------|
| Stargate bridge fee | `msg.value` from caller | LayerZero/Stargate |
| LayerZero OApp fee | `address(this).balance` (contracts) or `msg.value` (user calls) | LayerZero |
| Instant withdraw fee | Deducted from gross assets | Remains in LiquidityPool |

### 13.4 `_payNative` Override Pattern

Three contracts override `_payNative()` to use `address(this).balance` instead of `msg.value`:
- `PPTOFTAdapter` - Needs to send LZ messages inside `_lzReceive` (where `msg.value == 0`)
- `CreditManager` - Needs to send multiple LZ messages in `rebalance()` (single `msg.value`)
- `PPTSatellite` - Needs to send credit notifications inside `instantWithdraw` (where `msg.value == 0`)

**Audit focus:** Verify that all three overrides correctly handle the case where `address(this).balance` is insufficient (should revert, not silently fail).

---

## 14. Deployment and Configuration

### 14.1 Deployment Order

```
Phase 1: Hub Contracts
  1. Deploy CreditManager(endpoint, admin)
  2. Deploy CrossChainNAVReporter(admin)
  3. Deploy PPTOFTAdapter(pptToken, endpoint, admin)
  4. Deploy HubStargateComposer(endpoint, stargatePool, usdt, admin)
  5. Deploy CrossChainAssetController(endpoint, admin, usdt)

Phase 2: Satellite Contracts (per chain)
  6. Deploy PPTOFT(name, symbol, endpoint, admin, hubEid)
  7. Deploy LiquidityPool(usdt, admin)
  8. Deploy PPTSatellite(endpoint, admin, pptoft, liquidityPool, usdt, hubEid)
  9. Deploy SatelliteGateway(endpoint, stargatePool, usdt, hubEid, admin)

Phase 3: Remote Portfolio Contracts (per chain)
  10. Deploy RemoteAssetGateway(endpoint, stargatePool, usdt, hubEid, thisEid, admin)
  11. Deploy IRemoteProtocolImplementation implementations

Phase 4: Cross-Reference Configuration
  Hub:
    12. HubStargateComposer.setVault(pptVault)
    13. HubStargateComposer.setPptOftAdapter(pptOftAdapter)
    14. HubStargateComposer.setRedemptionManager(redemptionManager)
    15. HubStargateComposer.setNavReporter(navReporter)
    16. HubStargateComposer.setCreditManager(creditManager)
    17. HubStargateComposer.setCrossChainAssetController(assetController)
    18. HubStargateComposer.setSatelliteGateway(eid, satelliteGateway)
    19. HubStargateComposer.setRemoteAssetGateway(eid, remoteGateway)
    20. PPTOFTAdapter.setHubStargateComposer(hubComposer)
    21. PPTOFTAdapter.setCreditManager(creditManager)
    22. PPTOFTAdapter.setVault(pptVault)
    23. PPTOFTAdapter.setRedemptionManager(redemptionManager)
    24. CrossChainAssetController.setHubStargateComposer(hubComposer)
    25. CrossChainAssetController.addSupportedChain(eid, remoteGateway)
    26. CreditManager.addChain(eid, initialCredit)
    27. CreditManager.setSatelliteSyncAdapter(pptOftAdapter)
    28. CreditManager.setOperator(pptOftAdapter, true)
    29. CrossChainNAVReporter.addChain(eid)
    30. Grant REPORTER_ROLE to HubStargateComposer on CrossChainNAVReporter

  Satellite:
    31. PPTSatellite.setSatelliteGateway(satelliteGateway)
    32. SatelliteGateway.setHubComposer(hubComposer)
    33. SatelliteGateway.setLiquidityPool(liquidityPool)
    34. SatelliteGateway.setDepositForwarder(pptSatellite)
    35. LiquidityPool.setSatellite(pptSatellite)
    36. LiquidityPool.setLiquidityGateway(satelliteGateway)
    37. PPTOFT.setMinter(pptSatellite)

  Remote:
    38. RemoteAssetGateway.setHubComposer(hubComposer)
    39. RemoteAssetGateway.setProtocolImplementation(name, implementation)

Phase 5: OApp Peer Configuration
    40. PPTOFTAdapter.setPeer(satelliteEid, pptSatellite)
    41. PPTSatellite.setPeer(hubEid, pptOftAdapter)
    42. CreditManager.setPeer(satelliteEid, pptSatellite)  // or via adapter
    43. CrossChainAssetController peers (already set in addSupportedChain)
    44. RemoteAssetGateway.setPeer(hubEid, crossChainAssetController)

Phase 6: Funding
    45. Fund PPTOFTAdapter with native token for OApp messages
    46. Fund PPTSatellite with native token for credit notifications
    47. Fund RemoteAssetGateway with native token for return bridging
    48. Seed LiquidityPool with initial USDT liquidity

Phase 7: Verification
    49. End-to-end deposit test
    50. End-to-end instant withdrawal test
    51. End-to-end cross-chain redemption test
    52. End-to-end portfolio deploy/withdraw test
```

### 14.2 Configuration Dependency Graph

```
HubStargateComposer
  ├── vault (PPT Vault)
  ├── pptOftAdapter (PPTOFTAdapter)
  ├── navReporter (CrossChainNAVReporter)
  ├── redemptionManager (RedemptionManager)
  ├── creditManager (CreditManager)
  ├── crossChainAssetController (CrossChainAssetController)
  ├── satelliteGateways[eid] (SatelliteGateway per chain)
  └── remoteAssetGateways[eid] (RemoteAssetGateway per chain)

PPTOFTAdapter
  ├── innerToken (PPT)
  ├── hubStargateComposer (HubStargateComposer)
  ├── creditManager (CreditManager)
  ├── vault (PPT Vault)
  ├── redemptionManager (RedemptionManager)
  └── peers[eid] (PPTSatellite per chain)

CreditManager
  ├── satelliteSyncAdapter (PPTOFTAdapter)
  ├── operators[address] (PPTOFTAdapter)
  └── peers[eid] (PPTSatellite per chain)

CrossChainAssetController
  ├── hubStargateComposer (HubStargateComposer)
  └── peers[eid] (RemoteAssetGateway per chain)

PPTSatellite
  ├── pptOft (PPTOFT)
  ├── liquidityPool (LiquidityPool)
  ├── satelliteGateway (SatelliteGateway)
  └── peers[hubEid] (PPTOFTAdapter)

SatelliteGateway
  ├── hubComposer (HubStargateComposer address on Hub)
  ├── liquidityPool (LiquidityPool)
  └── depositForwarder (PPTSatellite)

LiquidityPool
  ├── satellite (PPTSatellite)
  └── liquidityGateway (SatelliteGateway)

RemoteAssetGateway
  ├── hubComposer (HubStargateComposer address on Hub)
  ├── protocolImplementations[name] (IRemoteProtocolImplementation)
  └── peers[hubEid] (CrossChainAssetController)
```

---

## 15. Testing Coverage

### 15.1 Test Files

| File | Description |
|------|-------------|
| `test/layerzero/StargateBridgeFlows.t.sol` | 30 E2E tests covering 5 business flows |
| `test/layerzero/StargateCriticalFixes.t.sol` | Critical fix regression tests |
| `test/layerzero/LayerZeroRuntimeFixes.t.sol` | 8 unit tests (codec, credit, protocol) |

### 15.2 Covered Areas

- Dual gateway routing split (satellite vs remote)
- Remote return source verification
- Failed deposit retry and refund
- Replenish configuration protection (revert when LiquidityPool not set)
- Cross-chain withdraw `minAssets` semantics
- Legacy deposit entry point disabled
- Credit used/restored message encoding/decoding
- Share price sync queueing and deduplication
- Protocol implementation routing

### 15.3 Build and Test Commands

```bash
# Build
forge build

# Run all LayerZero tests
forge test --match-path 'test/layerzero/*.t.sol'

# Verbose output
forge test --match-path 'test/layerzero/*.t.sol' -vvv

# Single test
forge test --match-test testDepositBridgeFlow -vvv
```

---

## 16. Recommended Audit Reading Order

For auditors unfamiliar with the codebase, the following reading order provides optimal understanding:

### Phase 1: Libraries and Protocol (understand the message types)
1. `src/layerzero/libraries/MessageCodec.sol`
2. `src/layerzero/libraries/StargateComposeCodec.sol`
3. `src/layerzero/libraries/LzOptionsLib.sol`

### Phase 2: Hub Core (understand the central coordinator)
4. `src/layerzero/hub/HubStargateComposer.sol` - Start here; this is the central hub
5. `src/layerzero/hub/PPTOFTAdapter.sol` - OApp message handler

### Phase 3: Satellite Side (understand user interactions)
6. `src/layerzero/satellite/PPTSatellite.sol` - User entry point
7. `src/layerzero/satellite/SatelliteGateway.sol` - Bridge gateway
8. `src/layerzero/satellite/LiquidityPool.sol` - Instant withdrawal pool
9. `src/layerzero/satellite/PPTOFT.sol` - Share token

### Phase 4: Remote Portfolio
10. `src/layerzero/satellite/adapters/RemoteAssetGateway.sol` - Portfolio gateway

### Phase 5: Credit and NAV
11. `src/layerzero/hub/CreditManager.sol` - Credit allocation
12. `src/layerzero/hub/CrossChainAssetController.sol` - Portfolio control
13. `src/layerzero/hub/CrossChainNAVReporter.sol` - NAV aggregation

### Phase 6: Supporting Library
14. `src/layerzero/libraries/DeltaLib.sol` - Credit algorithm utilities

---

## Appendix A: Full Function Signatures

### HubStargateComposer

```solidity
// Stargate Compose
function lzCompose(address _from, bytes32 _guid, bytes calldata _message, address, bytes calldata) external payable

// Outbound (KEEPER_ROLE)
function settleAndBridge(uint32 dstEid, address receiver, uint256 amount, uint256 requestId) external payable
function settleSatelliteRedemption(uint256 requestId) external payable
function bridgeAndDeploy(uint32 dstEid, uint256 amount, address protocol, string calldata protocolName) external payable returns (uint256)
function replenishLiquidity(uint32 dstEid, uint256 amount) external payable
function retryFailedDeposit(uint256 failedId, uint256 minSharesOverride) external
function refundFailedDeposit(uint256 failedId) external payable

// Registration
function registerSatelliteRedemption(uint256 requestId, uint32 dstEid, address receiver) external

// Quoting
function quoteBridge(uint32 dstEid, uint256 amount, bytes calldata composeMsg, uint128 composeGas) external view returns (uint256)
function quoteDeposit(uint32 srcEid, uint256 amount) external view returns (uint256)

// Configuration (DEFAULT_ADMIN_ROLE)
function setVault(address) external
function setPptOftAdapter(address) external
function setNavReporter(address) external
function setRedemptionManager(address) external
function setCreditManager(address) external
function setCrossChainAssetController(address) external
function setSatelliteGateway(uint32, address) external
function setRemoteAssetGateway(uint32, address) external
function setSlippageBps(uint32, uint256) external
function pause() external
function unpause() external
function emergencyWithdraw(address token, address to, uint256 amount) external
```

### PPTOFTAdapter

```solidity
// OFT
function send(uint32 _dstEid, bytes32 _to, uint256 _amountLD, uint256 _minAmountLD, bytes calldata _options, address _refundAddress) external payable returns (MessagingReceipt memory)
function quoteSend(uint32 _dstEid, uint256 _amountLD, bytes calldata _options, bool _payInLzToken) external view returns (MessagingFee memory)

// Hub integration
function mintSharesOnSatellite(uint32 dstEid, address receiver, uint256 shares) external
function syncCreditToSatellite(uint32 dstEid, uint256 newCredit, address refundAddress) external payable
function syncSharePrice(uint32 dstEid) external payable

// Flush
function flushPendingMint(uint256 mintId) external payable
function flushPendingSharePriceSync(uint256 syncId) external payable

// Configuration (owner)
function setCreditManager(address) external
function setVault(address) external
function setRedemptionManager(address) external
function setHubStargateComposer(address) external
function pause() external
function unpause() external
function emergencyWithdraw(address, address, uint256) external
```

### PPTSatellite

```solidity
// User actions
function deposit(uint256 assets, address receiver) external payable returns (uint256)
function depositWithParams(DepositParams calldata params) external payable returns (uint256)
function withdraw(uint256 shares, address receiver) external payable returns (uint256)
function withdrawWithParams(WithdrawParams calldata params) external payable returns (uint256)
function instantWithdraw(uint256 shares, address receiver) external returns (uint256)

// Views
function previewDeposit(uint256 assets) public view returns (uint256)
function previewWithdraw(uint256 shares) public view returns (uint256)
function previewInstantWithdraw(uint256 shares) public view returns (bool, uint256, uint256)
function quoteDeposit(uint256 assets, address receiver) external view returns (uint256, uint256)
function quoteWithdraw(uint256 shares, address receiver) external view returns (uint256, uint256)

// Notifications
function notifyCreditRestored(uint256 amount) external

// Flush (owner)
function flushPendingCreditUsed(uint256 pendingId) external payable
function flushPendingCreditRestored(uint256 pendingId) external payable

// Configuration (owner)
function setSatelliteGateway(address) external
function setInstantWithdrawFee(uint256) external
function setSharePrice(uint256) external
function setPaused(bool) external
```

---

## Appendix B: Event Catalog

### HubStargateComposer Events
```solidity
event DepositReceived(uint32 indexed srcEid, address indexed receiver, uint256 assets, uint256 shares)
event SettlementBridged(uint32 indexed dstEid, address indexed receiver, uint256 amount, uint256 requestId)
event DeployBridged(uint32 indexed dstEid, address indexed protocol, uint256 amount)
event ReturnReceived(uint32 indexed srcEid, uint256 amount, bool isYield)
event ReplenishBridged(uint32 indexed dstEid, uint256 amount)
event DepositFailed(uint256 indexed failedId, uint32 srcEid, address receiver, uint256 assets, string reason)
event FailedDepositRetried(uint256 indexed failedId, uint256 shares)
event FailedDepositRefunded(uint256 indexed failedId, uint32 indexed dstEid, address indexed receiver, uint256 assets)
event SatelliteRedemptionRegistered(uint256 indexed requestId, uint32 indexed dstEid, address indexed receiver)
event SatelliteRedemptionSettled(uint256 indexed requestId, uint32 indexed dstEid, address indexed receiver, uint256 amount)
```

### PPTOFTAdapter Events
```solidity
event OFTSent(bytes32 indexed guid, uint32 dstEid, address indexed from, uint256 amountSentLD, uint256 amountReceivedLD)
event OFTReceived(bytes32 indexed guid, uint32 srcEid, address indexed to, uint256 amountReceivedLD)
event CrossChainRedemptionProcessed(bytes32 indexed guid, address indexed owner, uint256 shares, uint256 requestId)
event SatelliteWithdrawProcessed(uint32 indexed srcEid, address indexed receiver, uint256 shares)
event SatelliteCreditUsed(uint32 indexed srcEid, uint256 amount)
event SatelliteCreditRestored(uint32 indexed srcEid, uint256 amount)
event CreditSynced(uint32 indexed dstEid, uint256 credit)
event SharePriceSynced(uint32 indexed dstEid, uint256 sharePrice)
event PendingMintStored(uint256 indexed mintId, uint32 dstEid, address receiver, uint256 shares)
event PendingMintFlushed(uint256 indexed mintId, uint32 dstEid, address receiver, uint256 shares)
event PendingSharePriceSyncStored(uint256 indexed syncId, uint32 dstEid, uint256 sharePrice)
event PendingSharePriceSyncFlushed(uint256 indexed syncId, uint32 dstEid, uint256 sharePrice)
```

### PPTSatellite Events
```solidity
event CrossChainDeposit(address indexed user, uint256 assets, uint256 shares, uint64 nonce)
event CrossChainWithdraw(address indexed user, uint256 shares, uint256 assets, uint64 nonce)
event InstantWithdraw(address indexed user, uint256 shares, uint256 assets, uint256 fee)
event SharePriceUpdated(uint256 oldPrice, uint256 newPrice)
event PendingCreditUsedStored(uint256 indexed pendingId, uint256 amount)
event PendingCreditUsedFlushed(uint256 indexed pendingId, uint256 amount)
event PendingCreditRestoredStored(uint256 indexed pendingId, uint256 amount)
event PendingCreditRestoredFlushed(uint256 indexed pendingId, uint256 amount)
```

### CreditManager Events
```solidity
event CreditsSent(uint32 indexed dstEid, uint256 amount)
event CreditUpdated(uint32 indexed eid, uint256 oldCredit, uint256 newCredit)
event CreditUtilized(uint32 indexed eid, uint256 utilized)
event CreditsReceived(uint32 indexed srcEid, uint256 amount)
event Rebalanced(uint32[] eids, uint256[] amounts)
```

---

## Appendix C: Error Catalog

### HubStargateComposer Errors
```solidity
error OnlyEndpoint()
error OnlyStargate()
error UntrustedSource(uint32 srcEid, address composeFrom)
error UnknownAction(uint8 action)
error ZeroAddress()
error ZeroAmount()
error SlippageTooHigh(uint256 sharesReceived, uint256 minShares)
error InsufficientBalance(uint256 available, uint256 required)
error UnauthorizedRegistrar(address caller)
error UnknownSatelliteRedemption(uint256 requestId)
error UnknownFailedDeposit(uint256 failedId)
```

### PPTOFTAdapter Errors
```solidity
error InvalidAmount()
error SlippageExceeded(uint256 amountLD, uint256 minAmountLD)
error InsufficientBalance()
error InvalidComposer()
error InvalidComposeMessage()
error InvalidPeer(uint32 srcEid, bytes32 sender)
error UnknownMessageType(bytes1 msgType)
error ZeroAddress()
```

### CreditManager Errors
```solidity
error InvalidAmount()
error ChainNotSupported(uint32 eid)
error ChainAlreadySupported(uint32 eid)
error ChainHasUtilizedCredit(uint32 eid)
error InsufficientCredit(uint256 available, uint256 required)
error RestoreExceedsUtilized(uint256 utilized, uint256 amount)
error CannotReduceBelowUtilized(uint256 utilized, uint256 newCredit)
error LengthMismatch(uint256 expected, uint256 actual)
error EmptyArray()
error NoCreditChange()
error UnknownMessageType(bytes1 msgType)
error UnauthorizedSource(uint32 srcEid)
```

### PPTSatellite Errors
```solidity
error InvalidAmount()
error InsufficientFee()
error InsufficientLiquidity()
error FeeTooHigh()
error OnlyHub()
error ZeroAddress()
error UnknownMessageType(bytes1 msgType)
error InvalidSharePrice()
error MinAssetsNotMet(uint256 expected, uint256 minimum)
error UnexpectedNativeValue()
error UnknownPendingCredit(uint256 pendingId)
error UnknownPendingCreditRestore(uint256 pendingId)
error OnlySatelliteGateway(address caller)
```

### SatelliteGateway Errors
```solidity
error OnlyEndpoint()
error OnlyStargate()
error UnexpectedSourceEid(uint32 srcEid)
error UntrustedSource(address composeFrom)
error UnknownAction(uint8 action)
error ZeroAddress()
error ZeroAmount()
error InsufficientFee(uint256 provided, uint256 required)
error UnauthorizedForwarder(address caller)
```

### RemoteAssetGateway Errors
```solidity
error OnlyStargate()
error OnlyHub()
error UnexpectedSourceEid(uint32 srcEid)
error UntrustedSource(address composeFrom)
error UnknownAction(uint8 action)
error UnknownMessageType(bytes1 msgType)
error ZeroAddress()
error ZeroAmount()
error ProtocolNotSupported()
error InsufficientDeposit()
error InvalidProtocolAmount(uint256 requested, uint256 actual)
```

### LiquidityPool Errors
```solidity
error InvalidAmount()
error InsufficientLiquidity()
error OnlySatellite()
error CreditBelowUtilized()
error InsufficientCredit(uint256 available, uint256 required)
error ZeroAddress()
```

---

*End of Detailed Audit Specification*
