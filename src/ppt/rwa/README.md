# WrappedRWA 系统设计文档

## 一、问题与解决方案

### 核心问题

1. **非原子化交易**：RWA 资产的购买/赎回可能需要数分钟到数天
2. **NAV 波动**：交易期间资产已转出但新资产未到账，导致 NAV 暴跌
3. **价格延迟**：某些 RWA 的价格在交易完成时才确定

### 解决方案

**在 RWA 层封装**，而不是在 Vault 层处理：

```
之前：PPT Vault → 直接持有 RWA → 问题暴露给 Vault
之后：PPT Vault → 持有 WrappedRWA → WrappedRWA 内部处理
```

## 二、架构概览

```
┌─────────────────────────────────────────────────────────────────┐
│                         PPT Vault                                │
│   totalAssets() = USDT + WrappedRWA.totalAssets() + ...         │
│   (不需要知道底层交易是否原子化)                                  │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      AssetController                             │
│   持有 WrappedRWA（而非原始 RWA）                                │
│   purchaseAdapter = WrappedRWASingleAdapter                      │
└─────────────────────────────┬───────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
┌──────────────────────────┐    ┌──────────────────────────┐
│ WrappedRWASingleAdapter  │    │ WrappedRWASingleAdapter  │
│ (for T-Bill)             │    │ (for aUSDC)              │
└────────────┬─────────────┘    └────────────┬─────────────┘
             │                               │
             ▼                               ▼
┌──────────────────────────┐    ┌──────────────────────────┐
│     WrappedTBill         │    │     WrappedAUSDC         │
│     (ERC4626)            │    │     (ERC4626)            │
│                          │    │                          │
│ totalAssets() =          │    │ totalAssets() =          │
│   confirmedTokenBalance  │    │   confirmedTokenBalance  │
│   × price                │    │   × price                │
│   + pendingPurchaseUSDT  │    │   + pendingPurchaseUSDT  │
└────────────┬─────────────┘    └────────────┬─────────────┘
             │                               │
             ▼                               ▼
┌──────────────────────────┐    ┌──────────────────────────┐
│   Actual T-Bill Token    │    │   Actual aUSDC Token     │
└──────────────────────────┘    └──────────────────────────┘
```

## 三、关键设计：NAV 计算

### 成本价模式 + 已确认余额追踪

核心创新：使用 `confirmedTokenBalance` 追踪已确认的 token 余额，而非实时读取合约余额。

```solidity
// WrappedRWA.totalAssets()
function totalAssets() public view returns (uint256) {
    // 1. 已确认 tokens 的市场价值（扣除已锁定待赎回的）
    uint256 availableConfirmed = confirmedTokenBalance > pendingRedemptionTokens
        ? confirmedTokenBalance - pendingRedemptionTokens
        : 0;
    uint256 confirmedValue = _tokenToUsdt(availableConfirmed);

    // 2. pending 购买的 USDT（成本价，确定的）
    return confirmedValue + pendingPurchaseUSDT;
}
```

### 关键状态变量

| 变量 | 说明 |
|------|------|
| `pendingPurchaseUSDT` | 待完成购买的 USDT 总额 |
| `pendingPurchaseTokens` | 预期收到的 token 数量（用于内部计算） |
| `confirmedTokenBalance` | 已确认的 token 余额（通过 confirmPurchase 确认的） |
| `pendingRedemptionTokens` | 已锁定待赎回的 token 数量 |
| `pendingRedemptionUSDT` | 预期要支付的赎回 USDT |

### 为什么用 confirmedTokenBalance？

```
场景：购买 100万 T-Bill

T0: 发起购买，价格 $1.00
    pendingPurchaseUSDT = 100万
    confirmedTokenBalance = 0
    totalAssets = 0 + 100万 = 100万 ✓

T+15min: 价格跌到 $0.95，RWA 到账（但还没 confirm）
    实际收到 1,052,631 tokens（价格低买到更多）
    pendingPurchaseUSDT = 100万（未变）
    confirmedTokenBalance = 0（未 confirm）
    totalAssets = 0 + 100万 = 100万 ✓ NAV 稳定！

T+30min: Keeper 调用 confirmPurchase
    pendingPurchaseUSDT = 0（清除）
    confirmedTokenBalance = 1,052,631
    totalAssets = 1,052,631 × $0.95 ≈ 99.75万

    NAV 变化：100万 → 99.75万（-0.25%）← 可接受的市场波动
```

**对比实时余额模式**：如果使用 `underlyingAsset.balanceOf()`，RWA 到账时会立即影响 NAV，导致波动。

## 四、完整交易流程

### 4.1 购买流程

```
REBALANCER                AssetController           Adapter              WrappedRWA              Keeper
    │                           │                     │                      │                     │
    │ purchaseAsset(wrapper, $) │                     │                      │                     │
    │──────────────────────────>│                     │                      │                     │
    │                           │                     │                      │                     │
    │                           │ vault.approveAsset()│                      │                     │
    │                           │ adapter.purchase()  │                      │                     │
    │                           │────────────────────>│                      │                     │
    │                           │                     │                      │                     │
    │                           │                     │ transfer USDT        │                     │
    │                           │                     │ wrapper.deposit()    │                     │
    │                           │                     │─────────────────────>│                     │
    │                           │                     │                      │                     │
    │                           │                     │                      │ mint shares to Vault│
    │                           │                     │                      │ pendingPurchaseUSDT │
    │                           │                     │                      │   += usdtAmount     │
    │                           │                     │                      │ pendingPurchaseTokens│
    │                           │                     │<─────────────────────│   += expectedTokens │
    │                           │                     │                      │                     │
    │<──────────────────────────│ return shares       │                      │                     │
    │                           │                     │                      │                     │
    │                           │                     │      (OTC 交易进行中，可能需要 T+1)          │
    │                           │                     │                      │                     │
    │                           │                     │                      │   RWA 到账         │
    │                           │                     │                      │<────────────────────│
    │                           │                     │                      │                     │
    │                           │                     │                      │ confirmPurchase()   │
    │                           │                     │                      │<────────────────────│
    │                           │                     │                      │                     │
    │                           │                     │                      │ pendingPurchaseUSDT │
    │                           │                     │                      │   -= usdtAmount     │
    │                           │                     │                      │ confirmedTokenBalance│
    │                           │                     │                      │   += actualTokens   │
```

### 4.2 赎回流程

```
REBALANCER                AssetController           Adapter              WrappedRWA              Keeper
    │                           │                     │                      │                     │
    │ redeemAsset(wrapper, amt) │                     │                      │                     │
    │──────────────────────────>│                     │                      │                     │
    │                           │                     │                      │                     │
    │                           │ adapter.redeem()    │                      │                     │
    │                           │────────────────────>│                      │                     │
    │                           │                     │                      │                     │
    │                           │                     │ wrapper.redeem()     │                     │
    │                           │                     │─────────────────────>│                     │
    │                           │                     │                      │                     │
    │                           │                     │                      │ burn shares         │
    │                           │                     │                      │ pendingRedemption   │
    │                           │                     │                      │   Tokens += amt     │
    │                           │                     │<─────────────────────│                     │
    │                           │                     │                      │                     │
    │<──────────────────────────│ (USDT 会延迟到账)   │                      │                     │
    │                           │                     │                      │                     │
    │                           │                     │      (OTC 卖出进行中，可能需要 T+1)         │
    │                           │                     │                      │                     │
    │                           │                     │                      │   USDT 到账        │
    │                           │                     │                      │<────────────────────│
    │                           │                     │                      │                     │
    │                           │                     │                      │ confirmRedemption() │
    │                           │                     │                      │<────────────────────│
    │                           │                     │                      │                     │
    │                           │                     │                      │ pendingRedemption   │
    │                           │                     │                      │   Tokens -= amt     │
    │                           │                     │                      │ confirmedTokenBalance│
    │                           │                     │                      │   -= tokenAmount    │
    │                           │                     │                      │ transfer USDT       │
    │                           │                     │                      │─────────────────────>│ Vault
```

## 五、集成步骤（零修改现有合约）

### Step 1: 部署 WrappedRWA

```solidity
// 为每个 RWA 资产部署一个 wrapper
WrappedRWA wrappedTBill = new WrappedRWA(
    tBillToken,      // underlying
    usdt,            // USDT
    oracleAdapter,   // 价格预言机
    "Wrapped T-Bill",
    "wTBILL",
    admin
);
```

### Step 2: 部署 Adapter

```solidity
// 为每个 wrapper 部署一个 adapter
WrappedRWASingleAdapter adapter = new WrappedRWASingleAdapter(
    usdt,
    address(wrappedTBill),
    admin
);
```

### Step 3: 配置 AssetController

```solidity
// 使用现有的 addAsset 函数，将 wrapper 作为资产添加
// purchaseAdapter 设置为新部署的 adapter
assetController.addAsset(
    address(wrappedTBill),      // token = wrapper 地址
    PPTTypes.LiquidityTier.TIER_2_MMF,
    address(adapter),           // purchaseAdapter
    PPTTypes.PurchaseMethod.OTC,
    100                         // maxSlippage 1%
);
```

### Step 4: 配置权限

```solidity
// 授予 wrapper 相关权限
wrappedTBill.grantRole(KEEPER_ROLE, keeper);
wrappedTBill.grantRole(VAULT_ROLE, vault);
```

## 六、NAV 计算链路

```
PPT.totalAssets()
    │
    ├─ USDT 余额：IERC20(usdt).balanceOf(vault)
    │
    └─ 资产价值：assetController.calculateAssetValue()
                    │
                    └─ for each asset:
                         │
                         ├─ 如果是 WrappedRWA：
                         │    balance = wrapper.balanceOf(vault)
                         │    price = oracle.getPrice(wrapper)
                         │    value = balance × price
                         │
                         │    其中 wrapper.totalAssets() 使用 confirmedTokenBalance
                         │
                         └─ 如果是普通资产：
                              balance × price

关键：Oracle 返回的 WrappedRWA 价格 = wrapper.totalAssets() / wrapper.totalSupply()
```

## 七、Oracle 配置

为 WrappedRWA 配置专用 Oracle：

```solidity
// WrappedRWAOracle.sol
contract WrappedRWAOracle {
    function getPrice(address wrapper) external view returns (uint256) {
        IERC4626 w = IERC4626(wrapper);
        uint256 totalAssets = w.totalAssets();
        uint256 totalSupply = w.totalSupply();

        if (totalSupply == 0) return 1e18;

        // 每个 share 的价值
        return (totalAssets * 1e18) / totalSupply;
    }
}
```

## 八、对比分析

| 方面 | 之前（直接持有 RWA） | 之后（WrappedRWA） |
|------|---------------------|-------------------|
| PPT 代码修改 | 需要 | **不需要** |
| AssetController 修改 | 需要 | **不需要** |
| NAV 波动 | 严重（交易期间暴跌） | **可控（成本价稳定）** |
| 审计范围 | 核心合约 | **仅 Wrapper** |
| 复杂度位置 | Vault 层 | **RWA 层** |
| 可复用性 | 低 | **高（每个 RWA 独立）** |

## 九、风险控制

### 1. 价格偏差保护

```solidity
// 确认交易时检查价格偏差（默认 5%）
function confirmPurchase(uint256 txId, uint256 actualTokens) {
    uint256 actualPrice = usdtAmount * PRECISION / actualTokens;
    _validatePriceDeviation(tx_.lockedPrice, actualPrice);
}

function _validatePriceDeviation(uint256 expected, uint256 actual) {
    uint256 deviation = abs(actual - expected) * BASIS_POINTS / expected;
    if (deviation > maxPriceDeviationBps) {
        revert PriceDeviationTooHigh(expected, actual, maxPriceDeviationBps);
    }
}
```

### 2. 过期保护

```solidity
// 交易超时自动失效（默认 7 天）
require(block.timestamp <= tx.expiresAt, "Transaction expired");
```

### 3. 紧急机制

```solidity
// 管理员可以取消 pending 交易
function cancelPurchase(uint256 txId, string reason) onlyKeeper;
function cancelRedemption(uint256 txId, string reason) onlyKeeper;

// 紧急提取
function emergencyWithdraw(token, amount, to) onlyAdmin;

// 暂停/恢复
function pause() external onlyAdmin;
function unpause() external onlyAdmin;
```

## 十、文件结构

```
src/ppt/rwa/
├── IWrappedRWA.sol          # 接口定义
├── WrappedRWA.sol           # 核心实现
├── WrappedRWAAdapter.sol    # AssetController 适配器
├── WrappedRWAOracle.sol     # 价格预言机
└── README.md                # 本文档

test/
└── WrappedRWA.t.sol         # 测试套件
```

## 十一、测试覆盖

已实现的测试用例（全部通过）：

| 测试 | 说明 |
|------|------|
| `test_deposit_creates_pending_purchase` | 存款创建 pending 购买 |
| `test_nav_stable_during_pending_purchase` | pending 期间 NAV 稳定 |
| `test_confirm_purchase` | 确认购买流程 |
| `test_nav_change_after_confirm_with_price_movement` | 确认后 NAV 变化（市场波动） |
| `test_redeem_creates_pending_redemption` | 赎回创建 pending |
| `test_confirm_redemption` | 确认赎回流程 |
| `test_wrapper_oracle_price` | Oracle 价格计算 |
| `test_adapter_purchase` | Adapter 购买集成 |
| `test_cancel_purchase` | 取消购买 |
| `test_price_deviation_check` | 价格偏差保护 |
| `test_transaction_expiry` | 交易过期机制 |

运行测试：
```bash
forge test --match-contract WrappedRWATest -vvv
```

## 十二、角色权限

| 角色 | 权限 |
|------|------|
| `ADMIN_ROLE` | 配置参数、设置 Oracle、授权角色、紧急提取、暂停/恢复 |
| `KEEPER_ROLE` | confirmPurchase、confirmRedemption、cancelPurchase、cancelRedemption |
| `VAULT_ROLE` | deposit、withdraw、redeem（可选，用于限制调用方） |
