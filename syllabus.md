# Uniswap 深度代码学习大纲 (4天)

这是一个深入代码层面的学习计划，旨在帮助你从零开始拆解并掌握 Uniswap V2 和 V3 的核心逻辑。

## Day 1: Uniswap V2 核心引擎 (The Engine)
**目标**: 彻底理解 AMM 的数学原理 (`x * y = k`) 以及它是如何在 Solidity 中最简实现的。
- **理论热身**:
  - 恒定乘积公式推导。
  - 什么是 Liquidity Provider (LP) Token。
- **代码拆解**:
  - `UniswapV2Factory.sol`: 它是如何像工厂一样生产交易对的？`createPair` 的 `create2`黑魔法。
  - `UniswapV2Pair.sol`: 这是心脏。
    - `mint()`: 添加流动性，计算 LP token 数量。
    - `burn()`: 移除流动性，销毁 LP token。
    - `swap()`: 核心交换逻辑，手续费扣除，k值校验。
    - `_update()`: 价格预言机 (TWAP) 的底层累加器逻辑。

## Day 2: Uniswap V2 外围设施 (The Periphery)
**目标**: 理解用户通过什么入口与核心合约交互，以及“路由”的作用。
- **理论热身**:
  - 为什么不能直接和 Pair 合约交互？(滑点保护、多跳路由的需求)。
- **代码拆解**:
  - `UniswapV2Router02.sol`:
    - `addLiquidity` / `removeLiquidity`: 如何计算最优添加比例？
    - `swapExactTokensForTokens`: 路径寻找与链式交换。
  - `UniswapV2Library.sol`: 极其重要的工具库。
    - `getAmountOut()`: 给定输入算输出（含手续费）。
    - `quote()`: 纯粹的比例计算。
  - **Flash Loan (闪电贷)**: V2 的 `swap` 函数掩藏的功能。

## Day 3: Uniswap V3 核心变革 (Concentrated Liquidity)
**目标**: 攻克 V3 最难的“集中流动性”和“Tick”概念。这部分代码复杂度是 V2 的 10 倍。
- **理论热身**:
  - 什么是“虚拟流动性” (Virtual Liquidity)？
  - Ticks (价格刻度) 与 Ranges (价格区间)。
- **代码拆解**:
  - `UniswapV3Pool.sol`: V3 的 Pair 变体。
    - Storage 结构变化: `Constraint Liquidity`, `Ticks Bitmap`。
  - **Tick 管理**: `TickBitmap.sol` 和 `Tick.sol`。如何在一个 `int24` 空间里高效查找下一个可用流动性点。
  - **Swap 逻辑**: 不再是一次性计算 `x*y=k`，而是一个 `while` 循环，跨越一个个 Tick 进行分段交换。

## Day 4: Uniswap V3 NFT 与 仓位管理
**目标**: 理解为什么 LP Token 变成了 NFT，以及 V3 的复杂外围交互。
- **理论热身**:
  - 每一个 LP 的仓位都是独一无二的（因为区间不同），所以必须是 ERC721。
- **代码拆解**:
  - `NonfungiblePositionManager.sol`: 负责铸造、增加、减少流动性 NFT。
  - `SwapRouter.sol`: V3 的路由，支持单跳和多跳 (`ExactInput`, `ExactOutput`)。
  - `Quoter.sol`: 它是如何模拟交易来给出预估价格的？（不同于 V2 的纯数学公式，V3 需要链上模拟）。

---
## 准备工作 (Prerequisites)
- [ ] 确保环境安装了 `foundry` (推荐) 或 `hardhat`。虽然我们主要是读代码，但最好能跑通测试。
- [ ] 我们将直接分析 Uniswap 官方源码。
