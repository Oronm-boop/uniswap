# Day 2: Uniswap V2 Periphery (周边合约)

今天我们学习 Uniswap V2 的“大脑”和“四肢”——`v2-periphery`。
Day 1 的 Core 合约虽然由于安全性和简洁性的要求，只能提供最基础的 `swap`、`mint`、`burn`，但对于普通用户来说，直接计算滑点、输入路径太难了。
所以需要 **Router (路由)** 合约来帮我们处理这些脏活累活。

核心仓库地址: [Uniswap/v2-periphery](https://github.com/Uniswap/v2-periphery)

## 1. UniswapV2Router02.sol - 真正的用户入口

这是我们在前端（如 Uniswap 网页版）交互的那个合约。它对 Core 合约进行了深度的封装。

### 1.1 为什么要用 Router？
1.  **用户友好**: 用户只想输入“我不想亏超过 1%”，Router 负责算出具体的 `amountOutMin`。
2.  **ETH 与 WETH 的自动转换**: Core 只认 ERC20 (WETH)，不认原生 ETH。Router 帮用户自动 wrap (存款) 和 unwrap (取款)。
3.  **多跳路由 (Multihop)**: 想把 ETH 换成 LINK，但没有直连池子？Router 自动帮你走 ETH -> USDT -> LINK 的路径。

### 1.2 核心函数深度解析

#### A. 添加流动性 (`addLiquidity`)
Router 在这里做了一个非常重要的计算：**最优比例**。
*   如果不通过 Router，你直接向 Pair 转账，比例不对的部分会被人 `skim` 拿走，或者导致价格剧烈波动。
*   Router 会先计算当前池子的比例，确保你存入的 Token A 和 Token B 是完美匹配当前价格的。

#### B. 交换 (`swapExactTokensForTokens`)
*   **输入**: 输入具体的 Input 数量，和最小期望获得的 Output 数量 (slippage protection)。
*   **路径**: 用户可以传入 `[TokenA, TokenB, TokenC]` 这样的路径数组。
*   **执行**: Router 会遍历路径，依次调用每个 Pair 的 `swap` 函数。

---

## 2. UniswapV2Library.sol - 数学工具箱

Router 里的数学计算（如“给 1 个 A 能换多少 B”）都依赖这个库。

### 核心函数
1.  `getAmountOut(amountIn, reserveIn, reserveOut)`:
    *   应用恒定乘积公式 + 0.3% 手续费，计算能换多少币。
    *   公式: `AmountOut = (AmountIn * 997 * ReserveOut) / (ReserveIn * 1000 + AmountIn * 997)`

2.  `quote(amountA, reserveA, reserveB)`:
    *   不含手续费的纯比例计算。通常用于添加流动性时计算两个币的比例。

---

## 3. WETH (Wrapped Ether)

### 3.1 什么是 WETH？
WETH 全称是 **Wrapped Ether**（包装过的以太币）。它是以太坊原生代币 ETH 的 ERC20 版本。

*   **1 ETH = 1 WETH**: 它们的价值是 1:1 锚定的。
*   **Deposit (存款)**: 发送 ETH 给 WETH 合约，你会收到等量的 WETH。
*   **Withdraw (取款)**: 销毁 WETH，你会收回等量的 ETH。

### 3.2 为什么要用 WETH？
Uniswap V2 的核心合约 (`UniswapV2Pair`) 设计非常简洁，只支持 **ERC20 对 ERC20** 的交易。
*   它**不**原生支持 ETH。
*   如果硬要支持 ETH，Pair 合约的代码会变得非常复杂（因为 ETH 的转账逻辑和 ERC20 不同）。

**解决方案**:
*   Core 合约（Pair）只处理 ERC20。
*   Router 合约负责“脏活累活”：用户传入 ETH，Router 自动把它换成 WETH，然后再去和 Pair 交互。
*   这就是为什么 Router 里会有 `addLiquidityETH` 和 `swapExactETHForTokens` 这样的函数。

### 3.3 代码位置
*   **接口**: `contracts/interfaces/IWETH.sol`
*   **实现**: `contracts/test/WETH9.sol` (这是一个标准的 WETH 实现，通常测试网使用)

```solidity
// WETH9.sol 核心逻辑简化
function deposit() public payable {
    balanceOf[msg.sender] += msg.value; // 增加 WETH 余额
    emit Deposit(msg.sender, msg.value);
}

function withdraw(uint wad) public {
    require(balanceOf[msg.sender] >= wad, "");
    balanceOf[msg.sender] -= wad; // 减少 WETH 余额
    msg.sender.transfer(wad);     // 返还原生 ETH
    emit Withdrawal(msg.sender, wad);
}
```

---

## Day 2 学习流程 (Plan)
1.  阅读 `UniswapV2Library.sol`: 作为基础工具，先看懂它的数学实现。
2.  阅读 `UniswapV2Router02.sol`: 重点看 `addLiquidity` 和 `swapXXX` 系列函数。
3.  **中文注释实战**: 给这两个文件加上详细的中文注释。

---
### ❓ 思考题 (预习)
如果我要把 ETH 换成 USDT，路径是 `ETH -> WETH -> USDT`。 Router 需要先把用户的 ETH 变成 WETH，然后转给 Pair。
那么，是谁最后负责把 USDT 转给用户？是 Router 拿回来再转给用户，还是 Pair 直接转给用户？
*(答案将在分析 swap 代码通过参数说明揭晓)*
