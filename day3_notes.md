# Day 3: Uniswap V3 核心变革 - 集中流动性 (Concentrated Liquidity)

> **难度**: ⭐⭐⭐⭐⭐ (比 V2 复杂 10 倍)
> **核心文件**: `UniswapV3Pool.sol` (870 行 vs V2 Pair 的 261 行)

---

## 一、一句话理解 V3

**V3 = 把 V2 那个"一整条价格曲线的池子"，拆成了无数个"只在某个价格区间工作的子池子"**

LP 不再是：`"我支持 0 ～ ∞ 所有价格"`
而是：`"我只在 1800 ～ 2200 这个价格段做市"`

---

## 二、V2 vs V3 核心变化

| 维度 | V2 | V3 |
|------|----|----|
| 流动性分布 | 0 → ∞ 均匀分布 | LP 自选区间 [Pa, Pb] |
| 资本效率 | 低 (99%资金闲置) | 高 (最高 4000x 提升) |
| LP Token | ERC20 (可替代) | NFT (不可替代) |
| 状态变量 | `reserve0`, `reserve1` | `sqrtPriceX96`, `liquidity`, `tick` |
| Swap 算法 | 一次性 `x*y=k` | While 循环跨 Tick |

---

## 三、V3 三大核心概念

### 3.1 Tick (价格刻度)

**连续价格 → 离散化**

```
price = 1.0001^tick
```

| tick | price |
|------|-------|
| 0 | 1.0000 |
| 1 | 1.0001 (+0.01%) |
| 100 | 1.0100 (+1%) |
| -100 | 0.9900 (-1%) |

**代码位置**: `libraries/TickMath.sol`
```solidity
// 第 9-11 行
int24 internal constant MIN_TICK = -887272;
int24 internal constant MAX_TICK = -MIN_TICK;
// 第 23 行: tick → sqrtPriceX96
function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96)
```

### 3.2 sqrtPriceX96 (定点数价格)

**为什么存 √P 而不是 P？**
1. Swap 公式经常用到 √P，直接存储减少运算
2. 数学更稳定，防溢出

**格式**: Q64.96 定点数
```
sqrtPriceX96 = √P × 2^96
```

**代码位置**: `UniswapV3Pool.sol` 第 56-74 行
```solidity
struct Slot0 {
    uint160 sqrtPriceX96;    // 当前价格的平方根
    int24 tick;               // 当前 tick
    // ...预言机相关字段略
}
```

### 3.3 Position (LP 仓位)

**V3 的 LP 不再是"池子的份额"，而是一个"参数化的订单"**

```solidity
// 每个 Position 由 (owner, tickLower, tickUpper) 唯一确定
mapping(bytes32 => Position.Info) public positions;

struct Position.Info {
    uint128 liquidity;         // 流动性值 L
    uint256 feeGrowthInside0;  // 累积手续费
    uint256 feeGrowthInside1;
}
```

---

## 四、Pool 的核心状态变量 (只看这些！)

```solidity
// UniswapV3Pool.sol 第 56-99 行

Slot0 public slot0;
// 包含: sqrtPriceX96, tick, observationIndex, feeProtocol, unlocked

uint128 public liquidity;  // 当前价格点的活跃流动性

mapping(int24 => Tick.Info) public ticks;       // 每个 tick 的状态
mapping(int16 => uint256) public tickBitmap;    // tick 位图 (快速查找)
mapping(bytes32 => Position.Info) public positions;  // LP 仓位
```

---

## 五、Swap 的 While 循环 (核心逻辑!)

**代码位置**: `UniswapV3Pool.sol` 第 596-788 行

### 5.1 Swap 参数
```solidity
function swap(
    address recipient,
    bool zeroForOne,           // 交易方向
    int256 amountSpecified,    // 正=exactInput, 负=exactOutput
    uint160 sqrtPriceLimitX96, // 价格限制 (滑点保护)
    bytes calldata data
) external returns (int256 amount0, int256 amount1)
```

### 5.2 While 循环核心结构
```solidity
// 第 641-730 行
while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
    
    // Step 1: 找到下一个有流动性的 tick
    (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(...);
    
    // Step 2: 计算这一步能换多少
    (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = 
        SwapMath.computeSwapStep(...);
    
    // Step 3: 如果碰到了 tick 边界，跨越 tick
    if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
        if (step.initialized) {
            // 流动性变化！
            int128 liquidityNet = ticks.cross(step.tickNext, ...);
            state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
        }
        state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
    }
}
```

### 5.3 翻译成人话
```
while (还有钱没换完 && 价格没到限制) {
    1. 问 tickBitmap: "下一个有流动性的边界在哪？"
    2. 在当前区间内尽可能多地换
    3. 如果碰到边界:
       - 调用 ticks.cross() 更新流动性
       - 进入下一个 tick
}
```

---

## 六、V3 Swap 动图理解

```
价格轴 (sqrtPrice)
  │
  │     ┌────┐ LP3           
  │  ┌──┼────┼──┐ LP2        Legend:
  │  │  │ ★  │  │            ★ = 当前价格
  ├──┴──┴────┴──┴── LP1      箭头 = Swap 方向
  │                          
  └──────────────────────> tick
     T1  T2  T3  T4
     
Swap 过程 (zeroForOne = true, 价格下跌):
★ 从 T3 开始 → 在 LP3+LP2+LP1 区间内换 → 碰到 T2 边界 → LP3 退出 → 继续用 LP2+LP1 换 → ...
```

---

## 七、为什么 V3 比 V2 贵 Gas?

1. **While 循环**: 每跨一个 tick 都要执行一次
2. **Tick 跨越**: 每次 `ticks.cross()` 都要更新多个存储变量
3. **位图查找**: `tickBitmap.nextInitializedTickWithinOneWord()` 需要位运算

**最坏情况**: 如果一笔大单要跨越 100 个 tick，就要循环 100 次！

---

## 八、V3 LP 为什么会"失效"?

**当价格移出你的区间 [tickLower, tickUpper] 时:**

```
Case 1: price > tickUpper
  → 你的全部仓位变成 Token0 (被买空了 Token1)
  → 你的流动性从 liquidity 中扣除
  → 不再赚取手续费

Case 2: price < tickLower  
  → 你的全部仓位变成 Token1 (被买空了 Token0)
  → 同上
```

**这就是 V3 的"无常损失放大效应"**: 区间越窄，资本效率越高，但无常损失风险也越大！

---

## 九、学习代码的正确顺序

> ⚠️ **不要直接读 `Pool.swap()`，那是地狱！**

### Step 1: 数学库 (理解"为谁服务")
1. `TickMath.sol` - tick ↔ sqrtPriceX96 转换
2. `SqrtPriceMath.sol` - 根据 L 和 √P 计算 token 数量
3. `SwapMath.sol` - 单步交换计算

### Step 2: 状态变量 (只看结构，不看函数)
- `slot0`: sqrtPriceX96, tick
- `liquidity`: 当前活跃流动性
- `ticks[]`: 每个 tick 的 liquidityNet
- `positions[]`: LP 仓位

### Step 3: Swap 函数
现在你会发现: **swap = while 循环 + tick 跨越**

---

## 十、过关测验

| 问题 | 答案 |
|------|------|
| 为什么 V3 LP 会"失效"？ | 价格移出区间，流动性被扣除，不再赚手续费 |
| 为什么价格会"卡"在 tick 上？ | 离散化设计，价格只能在 tick 点跳跃 |
| 为什么 V3 swap 比 V2 贵 gas？ | While 循环 + 每次跨 tick 都要更新存储 |
| Tick 越窄意味着什么？ | 资本效率越高，但无常损失风险也越大 |


> **目标**: 理解 V3 最革命性的概念：集中流动性、Ticks、虚拟流动性。
> **难度**: ⭐⭐⭐⭐⭐ (比 V2 复杂 10 倍)

---

## 0. V2 的致命缺陷：资本效率低下

回顾 V2 的 `x * y = k` 曲线：

```
价格
  ^
  |     .
  |      .
  |        .        <-- 流动性均匀分布在 (0, ∞) 整条曲线上
  |          .
  |            .
  |               .
  +--------------------> 数量
```

**问题**：
- 假设 ETH/USDC 池子当前价格是 3000。
- 但 V2 的流动性均匀分布在 **0 到无穷大** 的所有价格点！
- 这意味着有一部分流动性永远在等待 ETH = 0.001 USDC 或 ETH = 1,000,000 USDC 这种不可能出现的价格。
- **结论**: 大量资本在"睡觉"，资本效率极低。

---

## 1. V3 的解决方案：集中流动性

### 1.1 核心思想

**让 LP 自己选择在哪个价格区间 [P_lower, P_upper] 提供流动性。**

```
价格
  ^
  |
  |     ┌─────┐      <-- LP1: 只在 2800-3200 提供流动性
  |     │█████│
  |   ┌─┴─────┴─┐    <-- LP2: 在 2500-3500 提供流动性
  |   │█████████│
  |   └─────────┘
  +--------------------> 数量
       2500  3000  3500
```

### 1.2 资本效率飞跃

如果你只在 2800-3200 这个窄区间提供流动性：
- 当价格在这个区间内时，你的资金**100%** 都在被使用。
- 相比 V2 的 0-∞ 满铺，资本效率可以提升 **4000倍**！

> **比喻**: V2 是在整个大海里撒网，V3 是在鱼群出没的地方精准投网。

---

## 2. Ticks (价格刻度)

### 2.1 什么是 Tick？

V3 把连续的价格轴**离散化**成了一个个"Tick"（刻度）。

```
          tick -2    tick -1    tick 0    tick 1    tick 2
             |          |          |          |          |
   价格: ... 0.9801    0.9900    1.0000    1.0100    1.0201 ...
```

**核心公式**:
```
price = 1.0001^tick
```

- `tick = 0` → price = 1.0001^0 = 1
- `tick = 1` → price = 1.0001^1 = 1.0001 (涨了 0.01%)
- `tick = 100` → price ≈ 1.01 (涨了约 1%)
- `tick = -100` → price ≈ 0.99

### 2.2 为什么用 Tick？

1. **离散化方便计算**: 不用处理无限精度的浮点数。
2. **高效存储**: 用 `int24` 存储 tick 范围 (-8388608 到 8388607)，覆盖天文数字的价格范围。
3. **LP 区间边界**: LP 只能选择 Tick 点作为区间边界（如 tick 100 到 tick 200）。

### 2.3 Tick Spacing

为了节省 gas，不是每个 tick 都可以作为边界：

| Fee Tier | Tick Spacing | 说明 |
|----------|--------------|------|
| 0.05%    | 10           | 稳定币对 |
| 0.30%    | 60           | 大多数交易对 |
| 1.00%    | 200          | 长尾资产 |

例如 Tick Spacing = 60 时，LP 只能选择 tick = ..., -120, -60, 0, 60, 120, ... 作为边界。

---

## 3. 虚拟流动性 (Virtual Liquidity)

### 3.1 V2 的公式

```
x * y = k  (全局流动性)
```

### 3.2 V3 的公式

在一个 **Tick 区间内**：
```
(x + L/√P_upper) * (y + L*√P_lower) = L^2
```

其中：
- `L` = 流动性 (Liquidity)
- `P_lower`, `P_upper` = 价格区间边界
- `x`, `y` = 该区间内的**虚拟**储备量

### 3.3 直观理解

V3 的 LP Position 可以这样理解：
- 你不是真的存了 x 个 Token0 和 y 个 Token1。
- 你存的是一个**流动性值 L**，系统根据当前价格 P 和你的区间边界 [P_lower, P_upper]，反推出你在当前价格点应该有多少"虚拟储备"。

```
当 P_lower < P < P_upper 时:
  - 你同时持有一部分 Token0 和 Token1
  
当 P >= P_upper 时:
  - 你的全部仓位变成了 Token0（被"买空"了 Token1）
  
当 P <= P_lower 时:
  - 你的全部仓位变成了 Token1（被"买空"了 Token0）
```

---

## 4. V3 Swap 流程 (关键！)

### 4.1 V2 vs V3 的 Swap 区别

| 特性 | V2 | V3 |
|------|----|----|
| 计算 | 一次性 `x*y=k` | 循环遍历多个 Tick |
| 流动性 | 全局恒定 | 每跨一个 Tick 可能变化 |
| 价格 | 连续曲线 | 分段线性 |

### 4.2 V3 Swap 的 While 循环

```
while (amountRemaining > 0) {
    1. 找到下一个有流动性的 Tick
    2. 在当前 Tick 区间内尽可能多地交换
    3. 如果 amountRemaining 还有剩余，跨入下一个 Tick
    4. 更新流动性 L（进入新区间可能有 LP 加入或离开）
}
```

### 4.3 图示

```
价格 P
  ^
  |         ┌────┐
  |    ┌────┤    ├────┐
  |    │    │    │    │
  |────┴────┴────┴────┴────
       T1   T2   T3   T4
       
交易路径: P 从 T1 → T2 → T3 → ...
每跨一个 Tick，流动性 L 可能变化（因为有 LP 的区间开始或结束）
```

---

## 5. 核心数据结构预览

### 5.1 Position (仓位)

```solidity
struct Position {
    uint128 liquidity;         // 流动性值 L
    uint256 feeGrowthInside0;  // 累积的 Token0 手续费
    uint256 feeGrowthInside1;  // 累积的 Token1 手续费
}
```

每个 Position 由 `(owner, tickLower, tickUpper)` 唯一确定。

### 5.2 Tick 状态

```solidity
struct Tick {
    uint128 liquidityGross;      // 该 Tick 上的总流动性
    int128 liquidityNet;         // 跨过该 Tick 时流动性的净变化
    uint256 feeGrowthOutside0X128;
    uint256 feeGrowthOutside1X128;
}
```

### 5.3 全局状态

```solidity
uint160 sqrtPriceX96;  // 当前价格的平方根 (定点数)
int24 tick;            // 当前价格对应的 Tick
uint128 liquidity;     // 当前活跃的总流动性
```

---

## 6. sqrtPriceX96 是什么？

V3 不直接存储价格 P，而是存储 **√P**（价格的平方根），并且使用 **Q64.96 定点数**格式。

**为什么存 √P？**
1. Swap 公式里经常出现 √P，直接存储减少运算。
2. 两个 Token 的换算更对称。

**Q64.96 格式**:
- 用 160 位无符号整数表示。
- 前 64 位是整数部分，后 96 位是小数部分。
- 转换: `sqrtPriceX96 = √P * 2^96`

---

## 7. Day 3 思考题

完成 Day 3 后，你应该能回答：

| 问题 | 提示 |
|------|------|
| V3 比 V2 资本效率高多少倍？ | 取决于区间宽度，理论上可达 4000x |
| 为什么 V3 的 Swap 是 while 循环？ | 因为跨 Tick 时流动性可能变化 |
| sqrtPriceX96 为什么存√P？ | Swap 公式需要，减少运算 |
| Tick 越窄，无常损失越大还是越小？ | **越大**，因为价格一出区间就全变成单一资产 |

---

## 下一步

1. 克隆 V3 源码仓库
2. 精读 `UniswapV3Pool.sol` 的 `swap()` 函数
3. 理解 `TickBitmap` 如何高效查找下一个活跃 Tick
