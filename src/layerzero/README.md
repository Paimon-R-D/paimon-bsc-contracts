# LayerZero Cross-Chain Module

## Overview

Paimon Finance 的 LayerZero V2 跨链模块，实现 PPT (Paimon Passive Treasury) 代币在多链之间的无缝转移和操作。

### Architecture

```
                    ┌──────────────────────────────────────────┐
                    │            BSC Hub Chain (30102)         │
                    │                                          │
                    │  ┌─────────────────┐  ┌───────────────┐  │
                    │  │   PPT Token     │  │ CreditManager │  │
                    │  │   (ERC-20)      │  │               │  │
                    │  └────────┬────────┘  └───────┬───────┘  │
                    │           │                   │          │
                    │  ┌────────┴────────┐          │          │
                    │  │  PPTOFTAdapter  │──────────┤          │
                    │  │  (Lock/Unlock)  │          │          │
                    │  └────────┬────────┘          │          │
                    │           │                   │          │
                    │  ┌────────┴───────────────────┴────────┐ │
                    │  │    CrossChainAssetController        │ │
                    │  │  (Bridge Deploy / OApp Control)     │ │
                    │  └───────────────┬─────────────────────┘ │
                    │                  │                       │
                    │  ┌───────────────┴───────────────┐       │
                    │  │      HubStargateComposer      │       │
                    │  │   (Deposit / Deploy Compose)  │       │
                    │  └───────────────────────────────┘       │
                    └───────────────────┼──────────────────────┘
                                        │
              ┌─────────────────────────┼─────────────────────────┐
              │                         │                         │
              ▼                         ▼                         ▼
┌─────────────────────────┐  ┌─────────────────────────┐  ┌─────────────────────────┐
│  ETH Chain (30101)      │  │  ARB Chain (30110)      │  │  Base Chain (30184)     │
│                         │  │                         │  │                         │
│  ┌───────────────────┐  │  │  ┌───────────────────┐  │  │  ┌───────────────────┐  │
│  │    PPTSatellite   │  │  │  │    PPTSatellite   │  │  │  │    PPTSatellite   │  │
│  │  (Entry Point)    │  │  │  │  (Entry Point)    │  │  │  │  (Entry Point)    │  │
│  └─────────┬─────────┘  │  │  └─────────┬─────────┘  │  │  └─────────┬─────────┘  │
│            │            │  │            │            │  │            │            │
│  ┌─────────┴─────────┐  │  │  ┌─────────┴─────────┐  │  │  ┌─────────┴─────────┐  │
│  │      PPTOFT       │  │  │  │      PPTOFT       │  │  │  │      PPTOFT       │  │
│  │   (Mint/Burn)     │  │  │  │   (Mint/Burn)     │  │  │  │   (Mint/Burn)     │  │
│  └───────────────────┘  │  │  └───────────────────┘  │  │  └───────────────────┘  │
│                         │  │                         │  │                         │
│  ┌───────────────────┐  │  │  ┌───────────────────┐  │  │  ┌───────────────────┐  │
│  │  LiquidityPool    │  │  │  │  LiquidityPool    │  │  │  │  LiquidityPool    │  │
│  │ (Instant Withdraw)│  │  │  │ (Instant Withdraw)│  │  │  │ (Instant Withdraw)│  │
│  └───────────────────┘  │  │  └───────────────────┘  │  │  └───────────────────┘  │
│                         │  │                         │  │                         │
│  ┌───────────────────┐  │  │  ┌───────────────────┐  │  │  ┌───────────────────┐  │
│  │ SatelliteGateway  │  │  │  │ SatelliteGateway  │  │  │  │ SatelliteGateway  │  │
│  │ (Bridge / Return) │  │  │  │ (Bridge / Return) │  │  │  │ (Bridge / Return) │  │
│  └───────────────────┘  │  │  └───────────────────┘  │  │  └───────────────────┘  │
│                         │  │                         │  │                         │
│  ┌───────────────────┐  │  │  ┌───────────────────┐  │  │  ┌───────────────────┐  │
│  │ RemoteAssetGateway│  │  │  │ RemoteAssetGateway│  │  │  │ RemoteAssetGateway│  │
│  │(Remote DeFi Exec) │  │  │  │(Remote DeFi Exec) │  │  │  │(Remote DeFi Exec) │  │
│  └───────────────────┘  │  │  └───────────────────┘  │  │  └───────────────────┘  │
└─────────────────────────┘  └─────────────────────────┘  └─────────────────────────┘
```

---

## Directory Structure

```
src/layerzero/
├── hub/                          # BSC Hub 链合约
│   ├── CreditManager.sol         # Delta 算法信用管理
│   ├── PPTOFTAdapter.sol         # OFT Adapter (Lock/Unlock)
│   └── CrossChainAssetController.sol  # 跨链资产部署控制
│
├── satellite/                    # 远程链合约
│   ├── PPTSatellite.sol          # 用户入口点
│   ├── PPTOFT.sol                # OFT 代币 (Mint/Burn)
│   ├── LiquidityPool.sol         # 即时提款流动性池
│   ├── SatelliteGateway.sol      # 申购/赎回 Stargate 网关
│   └── adapters/
│       └── RemoteAssetGateway.sol # 远程 DeFi 执行网关
│
├── interfaces/                   # 接口定义
│   ├── ICreditManager.sol
│   ├── ILiquidityPool.sol
│   ├── IRemoteProtocolImplementation.sol
│   ├── IPPTOFT.sol
│   ├── IPPTOFTAdapter.sol
│   └── IPPTSatellite.sol
│
└── libraries/
    ├── DeltaLib.sol              # Delta 算法计算库
    └── LzOptionsLib.sol          # LayerZero 选项构建库
```

---

## Chain Configuration

| Chain | EID (V2) | Role | Contracts |
|-------|----------|------|-----------|
| BSC | 30102 | Hub | PPTOFTAdapter, CreditManager, CrossChainAssetController, HubStargateComposer |
| Ethereum | 30101 | Satellite | PPTSatellite, PPTOFT, LiquidityPool, SatelliteGateway, RemoteAssetGateway |
| Arbitrum | 30110 | Satellite | PPTSatellite, PPTOFT, LiquidityPool, SatelliteGateway, RemoteAssetGateway |
| Base | 30184 | Satellite | PPTSatellite, PPTOFT, LiquidityPool, SatelliteGateway, RemoteAssetGateway |

### LayerZero V2 Endpoint

所有 EVM 链使用统一的 Endpoint 地址：

```solidity
address constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
```

---

## Hub Chain Contracts

### 1. CreditManager

**路径**: `hub/CreditManager.sol`

**功能**: 使用 Delta 算法管理跨链信用额度分配。

#### 状态变量

| 变量 | 类型 | 说明 |
|------|------|------|
| `_chainCredits` | `mapping(uint32 => ChainCredit)` | 每链信用状态 |
| `_supportedChains` | `uint32[]` | 支持的链 EID 列表 |
| `totalCredits` | `uint256` | 总信用额度 |

#### ChainCredit 结构

```solidity
struct ChainCredit {
    uint256 credit;      // 分配的信用额度
    uint256 utilized;    // 已使用额度
    uint256 lastUpdate;  // 最后更新时间戳
}
```

#### 消息类型

| 常量 | 值 | 方向 | 说明 |
|------|-----|------|------|
| `MSG_SEND_CREDIT` | `0x01` | Hub → Satellite | 发送信用额度 |
| `MSG_REDUCE_CREDIT` | `0x02` | Satellite → Hub | 减少信用额度 |

#### 核心函数

```solidity
// 添加支持的链
function addChain(uint32 eid, uint256 initialCredit) external onlyOwner;

// 发送信用到远程链
function sendCredits(uint32 dstEid, uint256 amount) external payable onlyOwner;

// 批量再平衡
function rebalance(uint32[] calldata eids, uint256[] calldata amounts) external payable onlyOwner;

// 查询可用信用
function getAvailableCredit(uint32 eid) external view returns (uint256);

// 获取信用利用率 (BPS: 0-10000)
function getCreditUtilization(uint32 eid) external view returns (uint256);

// 报价跨链费用
function quoteSendCredits(uint32 dstEid, uint256 amount) external view returns (uint256 nativeFee, uint256 lzTokenFee);
```

#### 事件

```solidity
event CreditsSent(uint32 indexed dstEid, uint256 amount);
event CreditsReceived(uint32 indexed srcEid, uint256 amount);
event CreditUpdated(uint32 indexed eid, uint256 oldCredit, uint256 newCredit);
event CreditUtilized(uint32 indexed eid, uint256 utilized);
event Rebalanced(uint32[] eids, uint256[] amounts);
```

---

### 2. PPTOFTAdapter

**路径**: `hub/PPTOFTAdapter.sol`

**功能**: OFT Adapter，使用 Lock/Unlock 机制包装现有 PPT ERC20。

#### 关键参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `SHARED_DECIMALS` | 6 | LayerZero 跨链精度标准 |
| `DEFAULT_GAS_LIMIT` | 200000 | 默认跨链 Gas |
| `localDecimals` | 18 | PPT 本地精度 |

#### 消息类型

| 常量 | 值 | 说明 |
|------|-----|------|
| `MSG_TYPE_SEND` | 1 | 标准 OFT 发送 |
| `MSG_TYPE_SEND_AND_CALL` | 2 | 发送 + Compose |
| `COMPOSE_MSG_REDEEM` | `0x01` | Compose: 赎回请求 |
| `COMPOSE_MSG_DEPOSIT` | `0x02` | Compose: 存款 |

#### 核心函数

```solidity
// 发送代币到远程链
function send(
    uint32 _dstEid,
    bytes32 _to,
    uint256 _amountLD,
    uint256 _minAmountLD,
    bytes calldata _options,
    address _refundAddress
) external payable returns (MessagingReceipt memory receipt);

// 报价发送费用
function quoteSend(
    uint32 _dstEid,
    uint256 _amountLD,
    bytes calldata _options,
    bool _payInLzToken
) external view returns (MessagingFee memory fee);

// 处理 Compose 消息 (赎回/存款)
function lzCompose(
    address _from,
    bytes32 _guid,
    bytes calldata _message,
    address _executor,
    bytes calldata _extraData
) external payable;

// 配置
function setCreditManager(address _creditManager) external onlyOwner;
function setVault(address _vault) external onlyOwner;
function setRedemptionManager(address _redemptionManager) external onlyOwner;
```

#### 精度转换

```solidity
// 移除跨链精度粉尘
// decimalConversionRate = 10^(18 - 6) = 10^12
function _removeDust(uint256 _amountLD) internal view returns (uint256) {
    return (_amountLD / decimalConversionRate) * decimalConversionRate;
}
```

---

### 3. CrossChainAssetController

**路径**: `hub/CrossChainAssetController.sol`

**功能**: 管理桥接部署，并向远程 `RemoteAssetGateway` 发送 withdraw / harvest 指令。

#### 角色

| 角色 | 权限 |
|------|------|
| `DEFAULT_ADMIN_ROLE` | 添加/移除链、紧急提款 |
| `KEEPER_ROLE` | 执行 deploy/withdraw/harvest |

#### 消息类型

| 常量 | 值 | 方向 | 说明 |
|------|-----|------|------|
| `MSG_WITHDRAW_ASSET` | `0x41` | Hub → RemoteGateway | 提取资产 |
| `MSG_HARVEST` | `0x42` | Hub → RemoteGateway | 收获收益 |

#### 核心函数

```solidity
// 通过 Stargate 桥接 USDT 并在远程链部署
function deployViaBridge(
    uint32 dstEid,
    uint256 amount,
    address protocol,
    string calldata protocolName  // e.g., "aave", "compound"
) external payable onlyRole(KEEPER_ROLE);

// 从远程协议提款
function withdrawFromRemote(
    uint32 dstEid,
    uint256 amount,
    address protocol,
    string calldata protocolName
) external payable onlyRole(KEEPER_ROLE);

// 收获收益
function harvestYield(
    uint32 dstEid,
    address protocol,
    string calldata protocolName
) external payable onlyRole(KEEPER_ROLE);

// 链管理
function addSupportedChain(uint32 eid, address gateway) external onlyRole(DEFAULT_ADMIN_ROLE);
function removeSupportedChain(uint32 eid) external onlyRole(DEFAULT_ADMIN_ROLE);
```

---

## Satellite Chain Contracts

### 4. PPTSatellite

**路径**: `satellite/PPTSatellite.sol`

**功能**: 远程链用户入口点，集成 PPTOFT、LiquidityPool，并通过 `SatelliteGateway` 发起桥接申购。

#### 关键参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `MAX_INSTANT_WITHDRAW_FEE` | 1000 (10%) | 最大即时提款费率 |
| `DEFAULT_GAS_LIMIT` | 300000 | 默认跨链 Gas |
| `sharePrice` | 1e18 | 默认份额价格 (1:1) |

#### 消息类型

**Satellite → Hub:**

| 常量 | 值 | 说明 |
|------|-----|------|
| `MSG_DEPOSIT` | `0x01` | 跨链存款 |
| `MSG_WITHDRAW` | `0x02` | 跨链提款 |
| `MSG_CREDIT_USED` | `0x10` | 信用使用通知 |

**Hub → Satellite:**

| 常量 | 值 | 说明 |
|------|-----|------|
| `MSG_SHARE_PRICE_UPDATE` | `0x20` | 份额价格更新 |
| `MSG_CREDIT_UPDATE` | `0x21` | 信用额度更新 |
| `MSG_MINT_SHARES` | `0x22` | 铸造份额给用户 |

#### 核心函数

```solidity
// ========== 用户操作 ==========

// 跨链申购 - 资产通过 SatelliteGateway 桥接到 Hub
function deposit(uint256 assets, address receiver) external payable returns (uint256 shares);

// 即时提款 - 使用本地流动性池，收取费用
function instantWithdraw(uint256 shares, address receiver) external returns (uint256 assets);

// 标准跨链提款 - 发送消息到 Hub 处理
function withdraw(uint256 shares, address receiver) external payable returns (uint256 assets);

// ========== 预览函数 ==========

// 预览存款获得的份额
function previewDeposit(uint256 assets) public view returns (uint256 shares);

// 预览提款获得的资产
function previewWithdraw(uint256 shares) public view returns (uint256 assets);

// 预览即时提款 (包含可用性和费用)
function previewInstantWithdraw(uint256 shares) public view returns (
    bool available,
    uint256 assets,
    uint256 fee
);

// ========== 费用报价 ==========

function quoteDeposit(uint256 assets, address receiver) external view returns (uint256 nativeFee, uint256 lzTokenFee);
function quoteWithdraw(uint256 shares, address receiver) external view returns (uint256 nativeFee, uint256 lzTokenFee);

// ========== 管理函数 ==========

function setSatelliteGateway(address _gateway) external onlyOwner;
function setInstantWithdrawFee(uint256 _feeBps) external onlyOwner;
function setSharePrice(uint256 _sharePrice) external onlyOwner;
```

#### 事件

```solidity
event CrossChainDeposit(address indexed user, uint256 assets, uint256 shares, uint64 nonce);
event CrossChainWithdraw(address indexed user, uint256 shares, uint256 assets, uint64 nonce);
event InstantWithdraw(address indexed user, uint256 shares, uint256 assets, uint256 fee);
event SharePriceUpdated(uint256 oldPrice, uint256 newPrice);
```

---

### 5. PPTOFT

**路径**: `satellite/PPTOFT.sol`

**功能**: LayerZero OFT 代币，使用 Mint/Burn 机制。

#### 关键参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `SHARED_DECIMALS` | 6 | LayerZero 标准 |
| `localDecimals` | 18 | 本地精度 |
| `hubEid` | immutable | Hub 链 EID |
| `minter` | `address` | 授权铸币地址 (通常为 PPTSatellite) |

#### 核心函数

```solidity
// Mint (仅 minter 或 owner)
function mint(address _to, uint256 _amount) external;

// 设置授权 minter
function setMinter(address _minter) external onlyOwner;

// Burn (任何人可以销毁自己的代币)
function burn(uint256 _amount) external;

// 跨链发送
function send(
    uint32 _dstEid,
    bytes32 _to,
    uint256 _amountLD,
    uint256 _minAmountLD,
    bytes calldata _options,
    address _refundAddress
) external payable returns (MessagingReceipt memory receipt);

// 请求跨链赎回 (销毁代币 + 发送消息到 Hub)
function requestCrossChainRedemption(
    uint256 _shares,
    bytes calldata _options
) external payable returns (MessagingReceipt memory receipt);

// 报价
function quoteSend(uint32 _dstEid, uint256 _amountLD, bytes calldata _options, bool _payInLzToken)
    external view returns (MessagingFee memory fee);

function quoteRedemptionFee(uint256 _shares, bytes calldata _options)
    external view returns (MessagingFee memory fee);
```

---

### 6. LiquidityPool

**路径**: `satellite/LiquidityPool.sol`

**功能**: 提供即时提款流动性，信用由 Hub CreditManager 管理。

#### 状态变量

| 变量 | 类型 | 说明 |
|------|------|------|
| `_asset` | `IERC20` | 底层资产 (USDT) |
| `satellite` | `address` | 授权的 Satellite 合约 |
| `credit` | `uint256` | 从 Hub 分配的信用额度 |
| `utilized` | `uint256` | 已使用的信用额度 |
| `minBuffer` | `uint256` | 最小流动性缓冲 |

#### 核心函数

```solidity
// ========== 视图函数 ==========

// 可用流动性 = min(池余额, 剩余信用)
function availableLiquidity() public view returns (uint256);

// 剩余信用 = credit - utilized
function remainingCredit() public view returns (uint256);

// 利用率 (BPS: 0-10000)
function utilizationRatio() external view returns (uint256);

// 检查是否可即时提款
function canInstantWithdraw(uint256 amount) external view returns (bool);

// ========== 流动性提供者 ==========

function addLiquidity(uint256 amount) external;
function removeLiquidity(uint256 amount) external;

// ========== Satellite 操作 (仅 Satellite) ==========

function withdrawForUser(address user, uint256 amount) external onlySatellite returns (uint256);

// ========== 信用管理 (仅 Owner) ==========

function updateCredit(uint256 newCredit) external onlyOwner;
function increaseCredit(uint256 amount) external onlyOwner;
function decreaseCredit(uint256 amount) external onlyOwner;
function replenish(uint256 amount) external onlyOwner;  // 补充后减少 utilized
```

#### 事件

```solidity
event LiquidityAdded(address indexed provider, uint256 amount);
event LiquidityRemoved(address indexed provider, uint256 amount);
event LiquidityWithdrawn(address indexed user, uint256 amount);
event CreditUpdated(uint256 oldCredit, uint256 newCredit);
event CreditUsed(uint256 amount, uint256 remainingCredit);
```

---

### 7. RemoteAssetGateway

**路径**: `satellite/adapters/RemoteAssetGateway.sol`

**功能**: 接收 Hub 通过 Stargate compose 发送的 deploy 指令，以及通过 OApp 发送的 withdraw / harvest 指令，并把资产回桥到 Hub。

#### 处理面

```solidity
// Stargate compose: deploy
function lzCompose(...) external payable override;

// OApp: withdraw / harvest
function _lzReceive(...) internal override;
```

#### 配置

```solidity
function setHubComposer(address _hubComposer) external onlyOwner;
function setProtocolImplementation(string calldata protocolName, address implementation) external onlyOwner;
function setSlippageBps(uint256 _bps) external onlyOwner;
```

---

## Libraries

### DeltaLib

**路径**: `libraries/DeltaLib.sol`

**功能**: Delta 算法计算库。

```solidity
library DeltaLib {
    uint256 constant BPS_DENOMINATOR = 10000;
    uint256 constant PRECISION = 1e18;

    // 错误定义
    error EmptyArray();
    error LengthMismatch(uint256 expected, uint256 actual);
    error IntegerOverflow();

    // 基于权重计算信用分配
    function calculateCredit(uint256 totalLiquidity, uint256 chainWeight) internal pure returns (uint256);

    // 基于历史使用量计算最优权重 (空数组检查)
    function calculateOptimalWeights(uint256[] memory usages, uint256 totalUsage) internal pure returns (uint256[] memory);

    // 计算利用率
    function calculateUtilization(uint256 used, uint256 allocated) internal pure returns (uint256);

    // 检查是否需要再平衡
    function isRebalanceNeeded(uint256 utilization, uint256 threshold) internal pure returns (bool);

    // 计算再平衡增量 (含溢出保护)
    function calculateRebalanceDeltas(
        uint256[] memory currentCredits,
        uint256[] memory targetWeights,
        uint256 totalLiquidity
    ) internal pure returns (int256[] memory deltas);

    // 验证权重总和 = 100%
    function validateWeights(uint256[] memory weights) internal pure returns (bool);

    // 计算含滑点的最小信用需求
    function calculateMinCredit(uint256 withdrawAmount, uint256 slippageBps) internal pure returns (uint256);
}
```

---

### LzOptionsLib

**路径**: `libraries/LzOptionsLib.sol`

**功能**: LayerZero executor options 构建库，消除代码重复。

```solidity
library LzOptionsLib {
    /// @notice 构建 lzReceive 执行选项
    /// @param gasLimit 目标链执行 Gas 限制
    /// @return options 编码后的选项字节
    function buildLzReceiveOptions(uint128 gasLimit) internal pure returns (bytes memory);

    /// @notice 构建带原生代币转移的执行选项
    /// @param gasLimit 目标链执行 Gas 限制
    /// @param nativeValue 随消息转移的原生代币数量
    function buildLzReceiveOptionsWithValue(uint128 gasLimit, uint128 nativeValue) internal pure returns (bytes memory);
}
```

**使用示例**:
```solidity
import {LzOptionsLib} from "../libraries/LzOptionsLib.sol";

bytes memory options = LzOptionsLib.buildLzReceiveOptions(200000);
```

---

## User Flows

### Flow 1: Cross-Chain Deposit

```
用户 (ETH) → PPTSatellite.deposit()
    │
    ├── 1. 转移 USDT 到 PPTSatellite
    ├── 2. SatelliteGateway 通过 Stargate 桥接到 Hub
    │
    ▼
Hub (BSC) ← HubStargateComposer.lzCompose()
    │
    ├── 3. Hub Vault.deposit() 执行
    ├── 4. PPTOFTAdapter 向卫星链铸造份额
    │
    ▼
用户在卫星链收到 PPTOFT 份额
```

### Flow 2: Instant Withdrawal

```
用户 (ETH) → PPTSatellite.instantWithdraw()
    │
    ├── 1. 检查 LiquidityPool 可用流动性
    ├── 2. 销毁用户 PPTOFT
    ├── 3. 计算费用 (instantWithdrawFeeBps)
    ├── 4. LiquidityPool.withdrawForUser()
    │
    ▼
用户获得 USDT (扣除费用)
Pool 更新 utilized 计数
```

### Flow 3: Standard Cross-Chain Withdrawal

```
用户 (ETH) → PPTSatellite.withdraw()
    │
    ├── 1. 销毁用户 PPTOFT
    ├── 2. 发送 LZ 消息到 Hub
    │
    ▼
Hub (BSC) ← PPTOFTAdapter / RedemptionManager
    │
    ├── 3. 处理赎回请求
    ├── 4. 通过 HubStargateComposer + SatelliteGateway 回桥结算
    │
    ▼
资产稍后桥接回卫星链用户
```

### Flow 4: Credit Rebalancing

```
Admin → CreditManager.rebalance()
    │
    ├── 1. 计算各链目标信用额度
    ├── 2. 发送批量 LZ 消息
    │
    ▼
各远程链 ← _lzReceive()
    │
    ├── 3. LiquidityPool.updateCredit()
    ├── 4. 更新可用流动性
```

---

## Deployment

### Prerequisites

```bash
# 环境变量
export BSC_RPC_URL=https://bsc-dataseed.binance.org
export ETH_RPC_URL=https://eth.llamarpc.com
export ARB_RPC_URL=https://arb1.arbitrum.io/rpc
export PRIVATE_KEY=<deployer_private_key>
```

### Deploy Hub (BSC)

```bash
forge script script/layerzero/DeployHub.s.sol \
    --rpc-url $BSC_RPC_URL \
    --broadcast \
    --legacy
```

### Deploy Satellite (ETH/ARB)

```bash
forge script script/layerzero/DeploySatellite.s.sol \
    --rpc-url $ETH_RPC_URL \
    --broadcast
```

### Configure Peers

```bash
forge script script/layerzero/ConfigurePeers.s.sol \
    --rpc-url $BSC_RPC_URL \
    --broadcast \
    --legacy
```

---

## Testing

### Unit Tests

```bash
# 全部 LayerZero 测试
forge test --match-path "test/layerzero/*" -vvv

# 单个合约测试
forge test --match-contract CreditManagerTest -vvv
forge test --match-contract PPTSatelliteTest -vvv
```

### Fork Tests

```bash
# BSC Fork
BSC_RPC_URL=... forge test --match-path "test/layerzero/fork/BSCForkTest.t.sol" -vvv

# 多链 Fork
BSC_RPC_URL=... ETH_RPC_URL=... ARB_RPC_URL=... \
    forge test --match-path "test/layerzero/fork/MultiChainForkTest.t.sol" -vvv
```

### Integration Tests

```bash
forge test --match-contract CrossChainIntegrationTest -vvv
```

---

## Security

### Access Control

| 合约 | 角色 | 权限 |
|------|------|------|
| CreditManager | Owner | 信用管理、链配置 |
| PPTOFTAdapter | Owner | 配置、紧急提款 |
| CrossChainAssetController | KEEPER_ROLE | DeFi 操作 |
| PPTSatellite | Owner | 配置、暂停 |
| PPTOFT | Owner | 设置 minter、配置 |
| PPTOFT | Minter | 铸造代币 |
| LiquidityPool | Owner | 信用管理 |
| LiquidityPool | Satellite | 用户提款 |

### Security Features

1. **ReentrancyGuard**: 所有状态修改函数
2. **Pausable**: 紧急暂停能力
3. **SafeERC20**: 安全代币转移
4. **Peer 验证**: `_lzReceive` 验证消息来源 EID 和 sender 地址
5. **未知消息拒绝**: 未知消息类型触发 `revert UnknownMessageType()`
6. **零地址检查**: 所有 setter 函数验证非零地址
7. **整数溢出保护**: `DeltaLib` 在 int256 转换前检查边界
8. **Minter 角色**: `PPTOFT` 仅允许授权 minter 铸币

### Known Limitations

1. **Quote Tests**: Fork 测试中 quote 函数可能因 DVN 未配置而跳过
2. **Compose Messages**: 需要正确的 LZ Executor 与 Stargate compose 配置

---

## Gas Estimates

| 操作 | Gas (估算) |
|------|-----------|
| deposit (local) | ~150,000 |
| deposit (cross-chain msg) | ~200,000 + LZ fee |
| instantWithdraw | ~180,000 |
| withdraw (cross-chain) | ~200,000 + LZ fee |
| rebalance (per chain) | ~250,000 + LZ fee |

---

## Events Summary

### Hub Events

```solidity
// CreditManager
event CreditsSent(uint32 indexed dstEid, uint256 amount);
event CreditsReceived(uint32 indexed srcEid, uint256 amount);
event CreditUpdated(uint32 indexed eid, uint256 oldCredit, uint256 newCredit);
event Rebalanced(uint32[] eids, uint256[] amounts);

// PPTOFTAdapter
event OFTSent(bytes32 indexed guid, uint32 dstEid, address indexed from, uint256 amountSentLD, uint256 amountReceivedLD);
event OFTReceived(bytes32 indexed guid, uint32 srcEid, address indexed to, uint256 amountReceivedLD);

// CrossChainAssetController
event AssetDeployed(uint32 indexed dstEid, address indexed protocol, string protocolName, uint256 amount, bytes32 guid);
event WithdrawalRequested(uint32 indexed dstEid, address indexed protocol, string protocolName, uint256 amount, bytes32 guid);
event HarvestRequested(uint32 indexed dstEid, address indexed protocol, string protocolName, bytes32 guid);
event BridgedReturnRecorded(uint32 indexed srcEid, uint256 amount, bool isYield);
```

### Satellite Events

```solidity
// PPTSatellite
event CrossChainDeposit(address indexed user, uint256 assets, uint256 shares, uint64 nonce);
event CrossChainWithdraw(address indexed user, uint256 shares, uint256 assets, uint64 nonce);
event InstantWithdraw(address indexed user, uint256 shares, uint256 assets, uint256 fee);

// PPTOFT
event OFTSent(bytes32 indexed guid, uint32 dstEid, address indexed from, uint256 amountSentLD, uint256 amountReceivedLD);
event CrossChainRedemptionRequested(address indexed owner, uint256 shares, bytes32 guid);

// LiquidityPool
event LiquidityAdded(address indexed provider, uint256 amount);
event LiquidityWithdrawn(address indexed user, uint256 amount);
event CreditUpdated(uint256 oldCredit, uint256 newCredit);
```

---

## Error Reference

| Error | Contract | Cause |
|-------|----------|-------|
| `InvalidAmount()` | Multiple | 金额为 0 |
| `InvalidPeer(uint32, bytes32)` | PPTOFTAdapter | 消息来源未授权 |
| `UnknownMessageType(bytes1)` | Multiple | 未知消息类型 |
| `ZeroAddress()` | Multiple | 地址参数为零 |
| `InvalidRecipient()` | PPTOFT | 接收者地址无效 |
| `OnlyMinter()` | PPTOFT | 非授权 minter |
| `SlippageExceeded(amount, min)` | OFT | 滑点超限 |
| `InsufficientLiquidity()` | LiquidityPool | 流动性不足 |
| `InsufficientFee()` | PPTSatellite | LZ 费用不足 |
| `InsufficientCredit(uint256, uint256)` | Multiple | 信用额度不足 |
| `OnlyHub()` | Satellite | 非 Hub 来源消息 |
| `OnlySatellite()` | LiquidityPool | 非 Satellite 调用 |
| `ChainNotSupported(uint32)` | CreditManager | 链未配置 |
| `ChainAlreadySupported(uint32)` | CreditManager | 链已存在 |
| `ChainHasUtilizedCredit(uint32)` | CreditManager | 链有未清信用 |
| `CreditBelowUtilized()` | LiquidityPool | 信用低于已用 |
| `RestoreExceedsUtilized(uint256, uint256)` | CreditManager | 恢复超过已用 |
| `CannotReduceBelowUtilized(uint256, uint256)` | CreditManager | 不能减至已用以下 |
| `EmptyArray()` | DeltaLib | 空数组参数 |
| `LengthMismatch(uint256, uint256)` | DeltaLib | 数组长度不匹配 |
| `IntegerOverflow()` | DeltaLib | 整数溢出 |

---

## License

MIT
