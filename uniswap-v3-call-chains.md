# Uniswap V3 核心调用链详解

本文档通过时序图的方式，详细展示 Uniswap V3 核心操作的函数调用链，帮助理解合约之间的交互逻辑。

---

## 1. Mint (添加流动性) 调用链

用户通过 `NonfungiblePositionManager` 铸造 NFT 头寸，添加流动性。

```mermaid
sequenceDiagram
    participant User
    participant NFTPositionManager as NonfungiblePositionManager
    participant LiquidityMgmt as LiquidityManagement
    participant Pool as UniswapV3Pool
    participant TickMath
    participant LiquidityAmounts

    User->>NFTPositionManager: mint(MintParams)
    NFTPositionManager->>LiquidityMgmt: addLiquidity(params)
    
    Note over LiquidityMgmt: 计算 Pool 地址
    LiquidityMgmt->>Pool: slot0() 获取当前价格
    Pool-->>LiquidityMgmt: (sqrtPriceX96, tick, ...)
    
    LiquidityMgmt->>TickMath: getSqrtRatioAtTick(tickLower)
    TickMath-->>LiquidityMgmt: sqrtRatioAX96
    LiquidityMgmt->>TickMath: getSqrtRatioAtTick(tickUpper)
    TickMath-->>LiquidityMgmt: sqrtRatioBX96
    
    LiquidityMgmt->>LiquidityAmounts: getLiquidityForAmounts(...)
    Note over LiquidityAmounts: 根据价格和期望代币量<br/>计算最优流动性 L
    LiquidityAmounts-->>LiquidityMgmt: liquidity
    
    LiquidityMgmt->>Pool: mint(recipient, tickLower, tickUpper, liquidity, data)
    
    Note over Pool: 内部调用 _modifyPosition
    Pool->>Pool: _modifyPosition(params)
    Pool->>Pool: _updatePosition(...)
    Note over Pool: 更新 ticks mapping<br/>更新 positions mapping<br/>更新 tickBitmap
    
    Pool-->>LiquidityMgmt: (amount0, amount1) 需要的代币量
    
    Note over Pool: 回调要求支付代币
    Pool->>LiquidityMgmt: uniswapV3MintCallback(amount0, amount1, data)
    LiquidityMgmt->>User: transferFrom(token0, amount0)
    LiquidityMgmt->>User: transferFrom(token1, amount1)
    LiquidityMgmt-->>Pool: 支付完成
    
    Pool-->>LiquidityMgmt: mint 完成
    LiquidityMgmt-->>NFTPositionManager: (liquidity, amount0, amount1, pool)
    
    Note over NFTPositionManager: 铸造 NFT (ERC721)<br/>记录 Position 信息
    NFTPositionManager-->>User: (tokenId, liquidity, amount0, amount1)
```

### 关键点

1. **NFT 作为头寸凭证**: V3 用 ERC-721 NFT 代表每个流动性头寸，替代 V2 的 LP Token
2. **流动性计算**: `LiquidityAmounts` 库根据当前价格和期望代币量，计算最优的流动性值 L
3. **回调模式**: Pool 不直接转账，而是通过回调让调用者支付代币（乐观转账）

---

## 2. Burn (移除流动性) 调用链

用户减少或移除头寸的流动性。

```mermaid
sequenceDiagram
    participant User
    participant NFTPositionManager as NonfungiblePositionManager
    participant Pool as UniswapV3Pool

    User->>NFTPositionManager: decreaseLiquidity(tokenId, liquidity, ...)
    
    Note over NFTPositionManager: 验证 tokenId 权限
    NFTPositionManager->>NFTPositionManager: 获取 Position 信息
    NFTPositionManager->>NFTPositionManager: 计算 Pool 地址
    
    NFTPositionManager->>Pool: burn(tickLower, tickUpper, liquidity)
    
    Note over Pool: 内部调用 _modifyPosition<br/>liquidityDelta 为负数
    Pool->>Pool: _modifyPosition(params)
    Pool->>Pool: _updatePosition(...)
    
    Note over Pool: 更新 ticks<br/>更新 positions.tokensOwed<br/>可能清理空 tick
    
    Pool-->>NFTPositionManager: (amount0, amount1) 可提取的代币量
    
    Note over NFTPositionManager: 更新本地 Position.tokensOwed<br/>计算累积的手续费
    
    NFTPositionManager-->>User: (amount0, amount1)
    
    Note over User: 代币此时还在 Pool 中<br/>需要调用 collect 提取
```

### 关键点

1. **两步操作**: `decreaseLiquidity` 只计算可提取量，实际提取需调用 `collect`
2. **Tick 清理**: 如果流动性减为 0 且 tick 翻转，会清除该 tick 数据以节省 Gas
3. **负向 Delta**: `liquidityDelta` 为负数时表示移除流动性

---

## 3. Collect (领取手续费) 调用链

用户领取累积的手续费和移除流动性后的代币。

```mermaid
sequenceDiagram
    participant User
    participant NFTPositionManager as NonfungiblePositionManager
    participant Pool as UniswapV3Pool

    User->>NFTPositionManager: collect(tokenId, recipient, amount0Max, amount1Max)
    
    Note over NFTPositionManager: 验证 tokenId 权限
    NFTPositionManager->>NFTPositionManager: 获取 Position 信息
    
    Note over NFTPositionManager: 先调用 burn(0) 触发手续费结算
    NFTPositionManager->>Pool: burn(tickLower, tickUpper, 0)
    Pool-->>NFTPositionManager: (0, 0)
    Note over Pool: 虽然 liquidity=0<br/>但会更新 position.tokensOwed
    
    NFTPositionManager->>Pool: collect(recipient, tickLower, tickUpper, amount0, amount1)
    
    Note over Pool: 从 position.tokensOwed 中扣除
    Pool->>User: transfer(token0, amount0)
    Pool->>User: transfer(token1, amount1)
    
    Pool-->>NFTPositionManager: (amount0, amount1) 实际领取量
    
    Note over NFTPositionManager: 更新本地 tokensOwed
    NFTPositionManager-->>User: (amount0, amount1)
```

### 关键点

1. **burn(0) 技巧**: 在 collect 前先调用 `burn(0)` 以结算最新的手续费
2. **tokensOwed**: 代币先记录在 `position.tokensOwed` 中，collect 时才真正转账
3. **双重记账**: NFTPositionManager 和 Pool 都有各自的 tokensOwed 记录

---

## 4. Swap (exactInput) 调用链

用户通过 SwapRouter 进行固定输入量的代币交换。

```mermaid
sequenceDiagram
    participant User
    participant SwapRouter
    participant Pool as UniswapV3Pool
    participant TickBitmap
    participant SwapMath
    participant TickMath

    User->>SwapRouter: exactInputSingle(tokenIn, tokenOut, fee, amountIn, ...)
    
    SwapRouter->>SwapRouter: 计算 Pool 地址
    SwapRouter->>Pool: swap(recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96, data)
    
    Note over Pool: 初始化 SwapCache 和 SwapState
    
    loop 循环直到金额耗尽或达到价格限制
        Pool->>TickBitmap: nextInitializedTickWithinOneWord(tick, tickSpacing, zeroForOne)
        TickBitmap-->>Pool: (tickNext, initialized)
        
        Pool->>TickMath: getSqrtRatioAtTick(tickNext)
        TickMath-->>Pool: sqrtPriceNextX96
        
        Pool->>SwapMath: computeSwapStep(sqrtPrice, sqrtPriceTarget, liquidity, amountRemaining, fee)
        Note over SwapMath: 计算本步骤的<br/>amountIn, amountOut, feeAmount
        SwapMath-->>Pool: (newSqrtPrice, amountIn, amountOut, feeAmount)
        
        Note over Pool: 更新 state 变量<br/>累积手续费
        
        alt 到达 tickNext 且 tick 已初始化
            Pool->>Pool: ticks.cross(tickNext, ...)
            Note over Pool: 更新流动性 L<br/>liquidityNet 变化
        end
    end
    
    Note over Pool: 更新 slot0 (价格, tick)<br/>写入 Oracle 观察记录
    
    Pool-->>SwapRouter: (amount0, amount1)
    
    Note over Pool: 回调要求支付输入代币
    Pool->>SwapRouter: uniswapV3SwapCallback(amount0, amount1, data)
    SwapRouter->>User: transferFrom(tokenIn, amountIn)
    SwapRouter-->>Pool: 支付完成
    
    Note over Pool: 先输出再收款（乐观转账）
    Pool->>User: transfer(tokenOut, amountOut)
    
    SwapRouter-->>User: amountOut
```

### 关键点

1. **循环交换**: Swap 是一个 while 循环，逐步穿越多个 tick 区间
2. **TickBitmap 优化**: 通过 bitmap 快速跳过无流动性的 tick 区域
3. **computeSwapStep**: 每步计算能交换的数量，可能被 tick 边界、价格限制或金额耗尽终止
4. **流动性变化**: 穿越初始化的 tick 时，全局流动性 L 会变化

---

## 5. Swap (exactOutput) 调用链

用户指定期望的输出量进行交换。

```mermaid
sequenceDiagram
    participant User
    participant SwapRouter
    participant Pool as UniswapV3Pool

    User->>SwapRouter: exactOutputSingle(tokenIn, tokenOut, fee, amountOut, amountInMaximum, ...)
    
    SwapRouter->>SwapRouter: 计算 Pool 地址
    
    Note over SwapRouter: amountSpecified 为负数<br/>表示期望输出量
    SwapRouter->>Pool: swap(recipient, zeroForOne, -amountOut, sqrtPriceLimitX96, data)
    
    Note over Pool: exactOutput 模式<br/>amountSpecifiedRemaining < 0
    
    loop 循环直到输出金额满足
        Note over Pool: computeSwapStep 计算<br/>本步可输出多少
        Note over Pool: amountSpecifiedRemaining += amountOut<br/>向 0 逼近
    end
    
    Pool-->>SwapRouter: (amount0, amount1)
    
    Pool->>SwapRouter: uniswapV3SwapCallback(amount0, amount1, data)
    
    Note over SwapRouter: 缓存实际输入量到 amountInCached
    SwapRouter->>User: transferFrom(tokenIn, amountIn)
    SwapRouter-->>Pool: 支付完成
    
    Pool->>User: transfer(tokenOut, amountOut)
    
    Note over SwapRouter: 检查 amountIn <= amountInMaximum
    SwapRouter-->>User: amountIn
```

### 关键点

1. **负数表示输出**: `amountSpecified < 0` 表示固定输出模式
2. **滑点保护**: `amountInMaximum` 限制最大输入量，防止被套利
3. **amountInCached**: 用于在回调中缓存计算出的输入量

---

## 6. Flash (闪电贷) 调用链

无需抵押的即时借贷，必须在同一交易内归还本金+手续费。

```mermaid
sequenceDiagram
    participant User as User Contract
    participant Pool as UniswapV3Pool

    User->>Pool: flash(recipient, amount0, amount1, data)
    
    Note over Pool: 检查 liquidity > 0
    Note over Pool: 计算手续费<br/>fee0 = amount0 * fee / 1e6<br/>fee1 = amount1 * fee / 1e6
    
    Note over Pool: 记录借贷前余额
    Pool->>Pool: balance0Before = balance0()
    Pool->>Pool: balance1Before = balance1()
    
    Note over Pool: 先转出代币（乐观转账）
    Pool->>User: transfer(token0, amount0)
    Pool->>User: transfer(token1, amount1)
    
    Pool->>User: uniswapV3FlashCallback(fee0, fee1, data)
    
    Note over User: 用户合约执行套利逻辑<br/>...<br/>归还本金 + 手续费
    User->>Pool: transfer(token0, amount0 + fee0)
    User->>Pool: transfer(token1, amount1 + fee1)
    User-->>Pool: callback 返回
    
    Note over Pool: 检查余额增加是否满足要求
    Pool->>Pool: require(balance0After >= balance0Before + fee0)
    Pool->>Pool: require(balance1After >= balance1Before + fee1)
    
    Note over Pool: 分配手续费<br/>协议费 + LP 费
    Pool->>Pool: 更新 feeGrowthGlobal
    Pool->>Pool: 更新 protocolFees
    
    Pool-->>User: flash 完成
```

### 关键点

1. **零抵押借贷**: 先给钱后检查，失败则整个交易回滚
2. **手续费计算**: 与 swap 相同的费率，向上取整
3. **协议费分成**: 手续费按比例分配给 LP 和协议方

---

## 7. Oracle (价格预言机) 调用链

外部合约查询历史 TWAP 价格。

```mermaid
sequenceDiagram
    participant External as 外部合约
    participant Pool as UniswapV3Pool
    participant Oracle as Oracle Library

    External->>Pool: observe(secondsAgos[])
    
    Pool->>Oracle: observe(observations, time, secondsAgos, tick, index, liquidity, cardinality)
    
    loop 对每个 secondsAgo
        Note over Oracle: 二分查找目标时间点的观察记录
        alt 目标时间恰好有记录
            Oracle-->>Oracle: 直接返回该记录
        else 目标时间在两个记录之间
            Oracle-->>Oracle: 线性插值计算
        end
    end
    
    Oracle-->>Pool: (tickCumulatives[], secondsPerLiquidityCumulativeX128s[])
    
    Pool-->>External: (tickCumulatives[], secondsPerLiquidityCumulativeX128s[])
    
    Note over External: 计算 TWAP:<br/>avgTick = (tickCumulative2 - tickCumulative1) / (time2 - time1)<br/>avgPrice = 1.0001^avgTick
```

### 关键点

1. **累积值**: 存储的是累积值，需要两个时间点相减才能得到平均值
2. **环形缓冲区**: observations 是固定大小的环形数组，旧数据会被覆盖
3. **cardinality**: 可扩展的观察槽位数量，初始为 1，可通过 `increaseObservationCardinalityNext` 扩展

---

## 核心数据结构关系图

```mermaid
graph TB
    subgraph NFTPositionManager
        NPM_Position["Position (NFT)<br/>- poolId<br/>- tickLower/Upper<br/>- liquidity<br/>- tokensOwed"]
    end
    
    subgraph UniswapV3Pool
        Slot0["slot0<br/>- sqrtPriceX96<br/>- tick<br/>- observationIndex<br/>- feeProtocol<br/>- unlocked"]
        
        Ticks["ticks mapping<br/>- liquidityGross<br/>- liquidityNet<br/>- feeGrowthOutside"]
        
        Positions["positions mapping<br/>- liquidity<br/>- feeGrowthInside<br/>- tokensOwed"]
        
        TickBitmap["tickBitmap<br/>256位压缩位图"]
        
        Observations["observations[]<br/>- blockTimestamp<br/>- tickCumulative<br/>- secondsPerLiquidityCumulative<br/>- initialized"]
    end
    
    NPM_Position --> Positions
    Slot0 --> Ticks
    Ticks --> TickBitmap
    Slot0 --> Observations
```

---

## 总结

| 操作 | 入口合约 | 核心合约 | 关键函数 |
|------|----------|----------|----------|
| 添加流动性 | NonfungiblePositionManager | UniswapV3Pool | `mint` → `_modifyPosition` |
| 移除流动性 | NonfungiblePositionManager | UniswapV3Pool | `decreaseLiquidity` → `burn` |
| 领取手续费 | NonfungiblePositionManager | UniswapV3Pool | `collect` |
| 代币交换 | SwapRouter | UniswapV3Pool | `swap` → `computeSwapStep` |
| 闪电贷 | 任意合约 | UniswapV3Pool | `flash` |
| 价格查询 | 任意合约 | UniswapV3Pool | `observe` |

### V3 vs V2 核心差异

1. **集中流动性**: LP 可选择特定价格区间，资金效率大幅提升
2. **NFT 头寸**: 每个头寸是独立的 NFT，不再是同质化的 LP Token
3. **Tick 机制**: 价格空间离散化为 tick，便于高效管理流动性边界
4. **多费率池**: 同一交易对可有多个不同费率的池子 (0.05%, 0.3%, 1%)
5. **内置 Oracle**: 无需外部合约即可获取 TWAP 价格
