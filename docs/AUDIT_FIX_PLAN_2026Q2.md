# Paimon LayerZero Audit Fix Plan (2026/04/17)

**Audit source**: `Paimon_Finance_Due_Diligence_Report.pdf` (2026/04/13-17)
**Branch**: `feat/layerzero-cross-chain`
**Analysis basis**: Claude + Codex + third-opinion cross-verification

---

## Executive Summary

| Finding | Audit Severity | Actual Status | Action |
|---------|---------------|---------------|--------|
| [M01] sharePrice staleness → arbitrage | Medium | **Partial fix exists** (freshness guard present) | Harden with Hub-side broadcast |
| [M02] Strict equality on withdraw return | Medium | **Already fixed** (commit 64692c8) | Optional: balance-delta upgrade |
| [M03] updateCredit() < utilized | Medium | **Unfixed, real bug** | Clamp on satellite path, strict on owner path |
| [M04] Instant withdraw orphan mirror PPT | Medium | **Unfixed, share-conservation invariant broken** | New message type + atomic 3-book update |

**Baseline**: `forge test` currently 76/79 pass. 3 pre-existing failures unrelated to audit items.

---

## [M01] Share Price Staleness

### Current state (partially fixed)

`PPTSatellite.sol`:
- L55-67: `sharePriceInitialized`, `sharePriceLastUpdate`, `maxSharePriceStaleness` (default 1h)
- L197-216: `_instantWithdraw()` calls `_requireFreshSharePrice()` at L199
- L323-345: `_depositThroughBridge()` also gated at L330
- L317-321: `_requireFreshSharePrice()` reverts if uninitialized or stale

### Remaining gap

Hub only pushes sharePrice reactively:
- After satellite cross-chain withdraw: `PPTOFTAdapter.sol:337`
- After redemption: `PPTOFTAdapter.sol:354`
- After mint-shares-on-satellite: `PPTOFTAdapter.sol:425`
- Manual single-chain `syncSharePrice(dstEid)`: `PPTOFTAdapter.sol:443`

`CrossChainNAVReporter` NAV updates (L116, L147, L166) do NOT trigger broadcast.

### Fix: batch broadcast + threshold-driven keeper

**Add to `PPTOFTAdapter`**:
```solidity
mapping(uint32 => uint256) public lastSharePriceSyncedAt;
mapping(uint32 => uint256) public lastSharePriceSyncedValue;
uint256 public sharePriceSyncThresholdBps = 50;      // 0.5%
uint256 public maxSharePriceSyncInterval = 10 minutes;

function broadcastSharePriceToSupportedChains() external payable onlyOwner whenNotPaused {
    if (vault == address(0) || address(creditManager) == address(0)) revert ZeroAddress();
    uint256 currentPrice = IPPT(vault).sharePrice();
    uint32[] memory eids = creditManager.getSupportedChains();
    for (uint256 i = 0; i < eids.length; ++i) {
        _queueOrSendSharePrice(eids[i]);
    }
}

function quoteBroadcastSharePrice(uint32[] calldata dstEids)
    external view returns (uint256 totalNativeFee);
```

**Also**: lower satellite `maxSharePriceStaleness` default to 5-10 minutes (align with keeper SLA).

### Compatibility
- Reuses existing `MSG_SHARE_PRICE_UPDATE` (0x20) — no new message type
- Reuses existing per-chain pending dedup at `PPTOFTAdapter.sol:495`
- Reuses existing `creditManager.getSupportedChains()` — no second chain registry

---

## [M02] Withdraw Return Validation

### Current state (already fixed for core issue)

`RemoteAssetGateway.sol:211-215`:
```solidity
uint256 withdrawnAmount = IRemoteProtocolImplementation(implementation).withdraw(...);
// Accept withdrawnAmount <= amount to tolerate 1-wei rounding in
// index-based protocols (Aave liquidityIndex, Compound exchangeRate, Curve fees).
// Only over-withdrawal signals an adapter bug or unauthorized withdrawal.
if (withdrawnAmount > amount) revert InvalidProtocolAmount(amount, withdrawnAmount);
```

Commit `64692c8` addressed the strict-equality DoS. Rounding tolerance is now implicit (`<= amount`).

### Remaining weakness

`protocolDeposits -= withdrawnAmount` and bridge amount use `reported`, not `actual`. If adapter lies or misbehaves, accounting drifts silently.

### Fix: balance-delta as source of truth

```solidity
uint256 public defaultWithdrawDust = 2;
mapping(bytes32 => uint256) public withdrawDustByProtocolKey;

error InvalidWithdrawDelta(uint256 requested, uint256 reported, uint256 actual, uint256 dust);

function _handleWithdrawCommand(bytes calldata _payload) internal {
    (uint256 amount, address protocol, string memory protocolName) =
        MessageCodec.decodeAmountProtocolCommand(_payload);
    if (amount == 0) revert ZeroAmount();
    if (protocolDeposits[protocol] < amount) revert InsufficientDeposit();

    address implementation = protocolImplementations[protocolName];
    if (implementation == address(0)) revert ProtocolNotSupported();

    uint256 before = asset.balanceOf(address(this));
    uint256 reported = IRemoteProtocolImplementation(implementation).withdraw(
        address(asset), protocol, amount
    );
    uint256 actual = asset.balanceOf(address(this)) - before;

    if (actual > amount) revert InvalidProtocolAmount(amount, actual);

    uint256 dust = _withdrawDust(protocolName);
    uint256 diff = reported > actual ? reported - actual : actual - reported;
    if (diff > dust) revert InvalidWithdrawDelta(amount, reported, actual, dust);
    if (amount - actual > dust) revert InvalidProtocolAmount(amount, actual);

    protocolDeposits[protocol] -= actual;
    totalDeposited -= actual;

    _bridgeOrQueueReturn(actual, false);
    emit WithdrawAndBridged(protocol, protocolName, actual);
}
```

Apply symmetric treatment to `_handleDeploy()` (also trusts `deployedAmount` return).

---

## [M03] Credit Below Utilized

### Current state (unfixed)

`LiquidityPool.sol:167-170`:
```solidity
function updateCredit(uint256 newCredit) external override onlySatelliteOrOwner {
    emit CreditUpdated(credit, newCredit);
    credit = newCredit;    // no invariant check
}
```

vs `decreaseCredit` L184: `if (credit - amount < utilized) revert CreditBelowUtilized();`

### Why simple `revert` is wrong

`PPTSatellite._lzReceive` at L297 calls `liquidityPool.updateCredit(newCredit)` directly when `MSG_CREDIT_UPDATE` arrives. Normal 1-10 min LayerZero race window can produce `newCredit < satellite.utilized` → LayerZero message enters retry/blocked state.

### Fix: split paths by caller

```solidity
event CreditSyncClamped(uint256 requestedCredit, uint256 appliedCredit, uint256 utilized);

function updateCredit(uint256 newCredit) external override onlySatelliteOrOwner {
    uint256 oldCredit = credit;

    if (msg.sender == owner()) {
        // Local admin path — strict
        if (newCredit < utilized) revert CreditBelowUtilized();
        credit = newCredit;
        emit CreditUpdated(oldCredit, newCredit);
        return;
    }

    // Cross-chain satellite path — clamp + alert
    uint256 applied = newCredit < utilized ? utilized : newCredit;
    credit = applied;
    emit CreditUpdated(oldCredit, applied);
    if (applied != newCredit) {
        emit CreditSyncClamped(newCredit, applied, utilized);
    }
}
```

Keeper subscribes to `CreditSyncClamped` → Hub triggers `setCredit(eid, appliedCredit)` resync after in-flight `MSG_CREDIT_USED` drains.

### Why NOT plain revert

- LayerZero execution options retry, but after gas exhaustion the message enters `Blocked` state requiring manual `lzReceive` or channel clear.
- Instant withdrawals would freeze on that satellite.
- Monitoring would spike on message retry but the root cause (normal race) is benign.
- Clamp maintains invariant **and** message liveness.

---

## [M04] Orphan Mirror PPT — THE CRITICAL ONE

### Current state (unfixed, invariant-breaking)

Satellite path (`PPTSatellite.sol:197-216`):
1. `pptOft.burn(shares)` — satellite totalSupply ↓
2. `liquidityPool.withdrawForUser(receiver, assets)` — satellite LP pays USDT
3. `_notifyCreditUsed(assets)` — sends `MSG_CREDIT_USED(amount)` (amount only!)

Hub path (`PPTOFTAdapter.sol:383-390`):
```solidity
function _handleSatelliteCreditUsed(Origin calldata _origin, bytes calldata _payload) internal {
    uint256 amount = MessageCodec.decodeAmount(_payload);
    creditManager.reduceCredit(_origin.srcEid, amount);
    // No mirror burn, no NAV update
}
```

**Three books drift**:
- Credit: ✅ updated
- NAV (satellite balance): ❌ stale until manual `updateSatelliteBalance`
- Share mirror: ❌ never updated — Hub PPTOFTAdapter still holds `shares` PPT

**Invariant broken**: `Σ satellite PPTOFT.totalSupply ≠ Hub lockedPPT`

### Fix: new message type + atomic 3-book update

**Step 1: New message type** (`MessageCodec.sol`):
```solidity
bytes1 internal constant MSG_INSTANT_WITHDRAW_SETTLED = 0x12;

function encodeInstantWithdrawSettled(uint256 shares, uint256 assets)
    internal pure returns (bytes memory)
{
    return abi.encodePacked(MSG_INSTANT_WITHDRAW_SETTLED, abi.encode(shares, assets));
}

function decodeInstantWithdrawSettled(bytes calldata payload)
    internal pure returns (uint256 shares, uint256 assets)
{
    return abi.decode(payload[1:], (uint256, uint256));
}
```

**Step 2: Satellite sends shares + assets** (`PPTSatellite.sol`):

Change pending queue:
```solidity
struct PendingInstantWithdraw {
    uint256 shares;
    uint256 assets;
}
mapping(uint256 => PendingInstantWithdraw) public pendingInstantWithdraws;
```

Replace `_notifyCreditUsed(assets)` with:
```solidity
function _notifyInstantWithdrawSettled(uint256 shares, uint256 assets) internal {
    bytes memory payload = MessageCodec.encodeInstantWithdrawSettled(shares, assets);
    // ... lzSend logic, fallback to pending queue
}
```

**Step 3: Hub atomic handler** (`PPTOFTAdapter.sol`):
```solidity
function _handleSatelliteInstantWithdraw(Origin calldata _origin, bytes calldata _payload) internal {
    if (address(creditManager) == address(0)) revert ZeroAddress();
    if (vault == address(0)) revert ZeroAddress();
    if (address(navReporter) == address(0)) revert ZeroAddress();

    (uint256 shares, uint256 assets) = MessageCodec.decodeInstantWithdrawSettled(_payload);

    // Book 1: Credit
    creditManager.reduceCredit(_origin.srcEid, assets);

    // Book 2: NAV delta (keeps sharePrice accurate until next global sync)
    navReporter.recordSatelliteDebit(_origin.srcEid, assets);

    // Book 3: Mirror share via PPT operator interface
    IPPT(vault).lockShares(address(this), shares);
    IPPT(vault).burnLockedShares(address(this), shares);

    emit SatelliteInstantWithdrawProcessed(_origin.srcEid, shares, assets);
}
```

**Why `lockShares + burnLockedShares` instead of `innerToken.burn`**:
- PPT operator interface has permission control and sharePrice hooks centralized (`IPPTContracts.sol:44, 46`)
- Adapter becomes a first-class PPT operator alongside `RedemptionManager`
- Avoids bypassing PPT's internal accounting

**Step 4: NAV reporter delta interface** (`CrossChainNAVReporter.sol`):
```solidity
function recordSatelliteDebit(uint32 eid, uint256 amount) external onlyRole(REPORTER_ROLE) {
    if (!_isChain[eid]) revert ChainNotSupported(eid);
    uint256 old = satelliteBalances[eid];
    if (amount > old) {
        emit AccountingDiscrepancy(eid, amount, old);
        totalCrossChainValue -= old;
        satelliteBalances[eid] = 0;
    } else {
        satelliteBalances[eid] = old - amount;
        totalCrossChainValue -= amount;
    }
    lastUpdateTime[eid] = block.timestamp;
}

function recordSatelliteCredit(uint32 eid, uint256 amount) external onlyRole(REPORTER_ROLE) {
    if (!_isChain[eid]) revert ChainNotSupported(eid);
    satelliteBalances[eid] += amount;
    totalCrossChainValue += amount;
    lastUpdateTime[eid] = block.timestamp;
}
```

**Step 5: Symmetric replenish handling** (`PPTOFTAdapter._handleSatelliteCreditRestored`):
```solidity
function _handleSatelliteCreditRestored(Origin calldata _origin, bytes calldata _payload) internal {
    uint256 amount = MessageCodec.decodeAmount(_payload);
    creditManager.restoreCredit(_origin.srcEid, amount);
    navReporter.recordSatelliteCredit(_origin.srcEid, amount);  // NEW
    emit SatelliteCreditRestored(_origin.srcEid, amount);
}
```

**Step 6 (recommended): Explicit mirror-share ledger**:
```solidity
uint256 public totalMirroredShares;
```
Maintain on: `send()` (+amountSentLD), `_credit()` (-amountLD), `mintSharesOnSatellite()` (+shares), `_handleSatelliteWithdraw/Redemption` (-shares), new instant-withdraw handler (-shares).

Observability rule: `innerToken.balanceOf(adapter) > totalMirroredShares` means unexpected deposit — owner can sweep separately.

### Permissions required

- Adapter needs `PPT.OPERATOR_ROLE` (see `PPT.sol:139, 420`)
- Adapter needs `CrossChainNAVReporter.REPORTER_ROLE`

### Migration risk

- Old `pendingCreditUsed` queue has `uint256 amount` — drain before upgrading, cannot carry forward.

---

## PR Split Recommendation

### PR1: Cross-Chain Share Accounting (M04 core fix)
- MessageCodec: add `MSG_INSTANT_WITHDRAW_SETTLED`
- PPTSatellite: replace `_notifyCreditUsed` path, migrate pending queue to struct
- PPTOFTAdapter: new handler, add `navReporter` reference, add `totalMirroredShares`
- CrossChainNAVReporter: `recordSatelliteDebit/Credit`
- Role grants: adapter → PPT.OPERATOR_ROLE, REPORTER_ROLE
- Migration script for existing pending queue

### PR2: Share Price Sync Hardening (M01)
- `PPTOFTAdapter.broadcastSharePriceToSupportedChains()`
- Per-chain `lastSharePriceSyncedAt/Value`
- Satellite `maxSharePriceStaleness` default 10 min

### PR3: Async Credit + Gateway Robustness (M03 + M02)
- `LiquidityPool.updateCredit` satellite-clamp vs owner-strict split
- `CreditSyncClamped` event + keeper monitoring hook
- `RemoteAssetGateway` balance-delta with per-protocol dust
- `_handleDeploy` symmetric treatment

---

## Test Matrix

```bash
cd /Users/rocky243/paimon.finance/paimon-bsc-contracts

# PR1 targeted
forge test --match-test "test_InstantWithdraw_BurnsRemoteAndHubMirrorAtomically|test_InstantWithdraw_UpdatesSatelliteNavDelta|test_Replenish_RestoresCreditAndSatelliteNav|test_Adapter_UnexpectedPPTTransfer_DoesNotPolluteTrackedMirroredShares" -vvv

# PR2 targeted
forge test --match-test "test_PPTOFTAdapter_BroadcastSharePrice|test_PPTSatellite_InstantWithdraw_RevertsWhenPriceStale" -vvv

# PR3 targeted
forge test --match-test "test_LiquidityPool_UpdateCredit_ClampsWhenSatelliteSyncBelowUtilized|test_LiquidityPool_UpdateCredit_RevertsWhenOwnerSetsBelowUtilized|test_RemoteAssetGateway_Withdraw_AcceptsDustShortfall|test_RemoteAssetGateway_Withdraw_RevertsOnReportedActualMismatch" -vvv

# Full regression (must handle 3 pre-existing failures separately)
forge test
```

---

## Known Baseline

`forge test` baseline: **76/79 pass**. 3 pre-existing failures are unrelated to audit items; fix in a separate chore commit, don't conflate with audit PRs.

---

## PR1 Deployment / Upgrade Checklist (M04)

PR1 changes 5 contracts and introduces a new LayerZero message type. Deploy order matters.

### Pre-upgrade (satellite chains)

1. **Drain legacy pending queues** on every satellite `PPTSatellite`:
   - `flushPendingCreditUsed(pendingId)` for any entries in `pendingCreditUsed` mapping
   - `flushPendingCreditRestored(pendingId)` for any entries in `pendingCreditRestored` mapping
   - After drain, confirm `pendingCreditUsedCount` equals number of flushed IDs (no stragglers)

### Hub deployment order

1. Deploy new `CrossChainNAVReporter` (if not yet deployed, else keep existing) — no storage layout change, so redeploy not required
2. Deploy new `PPTOFTAdapter` (new slots: `navReporter`, `totalMirroredShares`; cannot hot-swap state)
3. **Grant roles** (requires DEFAULT_ADMIN of each):
   - `PPT.grantRole(OPERATOR_ROLE, newPPTOFTAdapter)`
   - `CrossChainNAVReporter.grantRole(REPORTER_ROLE, newPPTOFTAdapter)`
4. **Wire new adapter**:
   - `newPPTOFTAdapter.setCreditManager(creditManager)`
   - `newPPTOFTAdapter.setVault(pptVault)`
   - `newPPTOFTAdapter.setRedemptionManager(redemptionManager)`
   - `newPPTOFTAdapter.setHubStargateComposer(composer)`
   - `newPPTOFTAdapter.setNavReporter(crossChainNAVReporter)` ← **new**
   - `newPPTOFTAdapter.setPeer(satelliteEid, bytes32(newPPTSatellite))` for each satellite
5. **Migrate balance** (if old adapter holds PPT): transfer `innerToken.balanceOf(oldAdapter)` to `newPPTOFTAdapter` via owner multisig call, then initialize `totalMirroredShares` to the migrated amount
6. **Revoke old adapter roles**: `PPT.revokeRole(OPERATOR_ROLE, oldAdapter)` after migration verified

### Satellite deployment order

1. Deploy new `PPTSatellite` (new slots: `pendingInstantWithdraws`, `pendingInstantWithdrawCount`)
2. Wire: `setSatelliteGateway`, `setInstantWithdrawFee`, `setMaxSharePriceStaleness`, `setPeer(hubEid, newPPTOFTAdapter)`
3. Migrate `credit` / `sharePrice` via `owner` calls if storage was reset
4. Update `LiquidityPool.setSatellite(newPPTSatellite)`
5. Update `SatelliteGateway` wiring if applicable

### Verification after upgrade

```bash
# Hub side invariant
cast call $PPTOFTAdapter "totalMirroredShares()" --rpc-url $BSC_RPC
cast call $PPT "balanceOf(address)" $PPTOFTAdapter --rpc-url $BSC_RPC
# Expected: totalMirroredShares == balanceOf(PPTOFTAdapter) at t=0 (no pending redemption)

# Satellite side
cast call $PPTSatellite "pendingInstantWithdrawCount()" --rpc-url $ETH_RPC
# Expected: 0 on fresh deploy

# End-to-end: trigger a small instantWithdraw on satellite, confirm within 1-10 min:
# 1. Hub CreditManager.utilized increased by assets
# 2. CrossChainNAVReporter.satelliteBalances[srcEid] decreased by assets
# 3. PPTOFTAdapter.innerToken.balanceOf decreased by shares
# 4. PPTOFTAdapter.totalMirroredShares decreased by shares
```

### Rollback plan

If `MSG_INSTANT_WITHDRAW_SETTLED` handler fails repeatedly (e.g. missing `OPERATOR_ROLE`):
- LayerZero message sits in retry state — grant role, then retry via LZ scanner
- Do NOT rollback adapter: the `totalMirroredShares` ledger is authoritative after migration
- Emergency: `PPTSatellite.setPaused(true)` on the affected chain to stop new instant withdraws
