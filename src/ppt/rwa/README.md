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
│   heldTokens × price     │    │   heldTokens × price     │
│   + pendingPurchaseUSDT  │    │   + pendingPurchaseUSDT  │
└────────────┬─────────────┘    └────────────┬─────────────┘
             │                               │
             ▼                               ▼
┌──────────────────────────┐    ┌──────────────────────────┐
│   Actual T-Bill Token    │    │   Actual aUSDC Token     │
└──────────────────────────┘    └──────────────────────────┘
```

## 三、关键设计：NAV 计算

### 成本价模式（推荐）

在 pending 期间使用 **USDT 成本价**，而非预估 token 价值：

```solidity
// WrappedRWA.totalAssets()
function totalAssets() public view returns (uint256) {
    // 1. 实际持有的 RWA token 价值
    uint256 heldValue = underlyingAsset.balanceOf(address(this)) * price;

    // 2. pending 购买的 USDT（成本价，确定的）
    return heldValue + pendingPurchaseUSDT;
}
```

### 为什么用成本价？

```
场景：购买 100万 T-Bill

T0: 发起购买，价格 $1.00
    如果用"预估 token 价值"：NAV = 100万 × $1.00 = 100万
    如果用"成本价"：NAV = 100万 USDT = 100万
    → 此时两者相同

T+15min: 价格跌到 $0.95
    如果用"预估 token 价值"：NAV = 100万 × $0.95 = 95万 ← 波动！
    如果用"成本价"：NAV = 100万 USDT = 100万 ← 稳定！

T+30min: 交易完成，实际收到 105万 T-Bill（因为价格低买到更多）
    NAV = 105万 × $0.95 = 99.75万

    成本价模式的"跳变"：100万 → 99.75万（-0.25%）
    实时价格模式的"跳变"：95万 → 99.75万（+5%）
```

**结论**：成本价模式的跳变更小、更可预测。

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
    │                           │                     │                      │ record pending      │
    │                           │                     │                      │ pendingPurchaseUSDT │
    │                           │                     │<─────────────────────│   += usdtAmount     │
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
    │                           │                     │                      │ clear pending       │
    │                           │                     │                      │ verify token balance│
    │                           │                     │                      │                     │
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
    │                           │                     │                      │ lock tokens         │
    │                           │                     │                      │ record pending      │
    │                           │                     │                      │ pendingRedemption   │
    │                           │                     │<─────────────────────│   Tokens += amt     │
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
    │                           │                     │                      │ transfer USDT       │
    │                           │                     │                      │ clear pending       │
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
                         │    其中 wrapper.totalAssets() 已包含 pending
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
// 确认交易时检查价格偏差
function confirmPurchase(uint256 txId, uint256 actualTokens) {
    uint256 actualPrice = usdtAmount / actualTokens;
    uint256 deviation = abs(actualPrice - lockedPrice) / lockedPrice;

    require(deviation <= maxPriceDeviationBps, "Price deviation too high");
}
```

### 2. 过期保护

```solidity
// 交易超时自动失效
require(block.timestamp <= tx.expiresAt, "Transaction expired");
```

### 3. 紧急机制

```solidity
// 管理员可以取消 pending 交易
function cancelPurchase(uint256 txId, string reason) onlyKeeper;
function cancelRedemption(uint256 txId, string reason) onlyKeeper;

// 紧急提取
function emergencyWithdraw(token, amount, to) onlyAdmin;
```

## 十、文件结构

```
src/ppt/rwa/
├── IWrappedRWA.sol          # 接口定义
├── WrappedRWA.sol           # 核心实现
├── WrappedRWAAdapter.sol    # AssetController 适配器
├── WrappedRWAOracle.sol     # 价格预言机（可选）
└── README.md                # 本文档
```

## 十一、测试用例

```solidity
// 1. 购买流程测试
function test_purchase_flow() {
    // deposit USDT, 立即获得 shares
    // 验证 pendingPurchaseUSDT 增加
    // 验证 totalAssets 包含 pending
    // confirm 后验证 pending 清零
}

// 2. NAV 稳定性测试
function test_nav_stability_during_purchase() {
    // 记录初始 NAV
    // 执行购买
    // 模拟价格波动
    // 验证 NAV 保持稳定（成本价模式）
}

// 3. 赎回流程测试
function test_redemption_flow() {
    // redeem shares
    // 验证 pendingRedemptionTokens 增加
    // confirm 后验证 USDT 到账
}

// 4. 取消测试
function test_cancel_purchase() {
    // 取消购买，验证 USDT 返还
}
```
