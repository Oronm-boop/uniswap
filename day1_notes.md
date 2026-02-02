# Day 1: Uniswap V2 Core (核心引擎)

今天我们深入 Uniswap V2 系统的“心脏”。`v2-core` 仓库虽然只有两个主要合约，但它们承载了数十亿美元的交易量。

核心仓库地址: [Uniswap/v2-core](https://github.com/Uniswap/v2-core)

## 1. UniswapV2Factory.sol - 交易对的兵工厂

这个合约非常短（约 50 行），它的唯一职责就是**创建新的交易对 (Pair)** 并记录它们。

### 核心函数：`createPair`
```solidity
function createPair(address tokenA, address tokenB) external returns (address pair) {
    // 1. 排序: 确保 token0 < token1，保证同一个配对地址唯一
    (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    
    // 2. 检查: 不能是零地址，且该配对之前没创建过
    require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
    require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS');

    // 3. 准备 Create2: 获取 Pair 合约的字节码
    bytes memory bytecode = type(UniswapV2Pair).creationCode;
    
    // 4. 计算 Salt: 使用两个 token 地址生成的唯一盐
    bytes32 salt = keccak256(abi.encodePacked(token0, token1));
    
    // 5. Create2 部署: 确定性的地址部署
    assembly {
        pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
    }
    
    // 6. 初始化 & 记录
    IUniswapV2Pair(pair).initialize(token0, token1);
    getPair[token0][token1] = pair;
    getPair[token1][token0] = pair; // 双向记录
    allPairs.push(pair);
    emit PairCreated(token0, token1, pair, allPairs.length);
}
```
> **思考**: 为什么要用 `create2`？
> 答: `create2` 允许我们在合约部署**之前**就计算出它的地址。这对于 Router (路由) 合约非常重要，因为它需要能在不查询 Factory 的情况下，直接通过 `tokenA` 和 `tokenB` 计算出 Pair 合约的地址，从而节省 Gas。

---

## 2. UniswapV2Pair.sol - 真正的自动化做市商 (AMM)

这是 V2 的灵魂。每个交易对（如 ETH/USDT）都是这样一个独立的合约。

### 2.1 核心公式实现
Uniswap V2 的核心公式是 `x * y = k` (恒定乘积)。
在 `swap` 函数中，这一点得到了严苛的执行：

```solidity
// swap 函数片段精讲
{ 
    // balance0Adjusted 是“扣除手续费后的有效余额”
    // 公式推导：
    // 我们在这个交易中收到了 amount0In，但这笔钱不能全算进 K 值计算，必须先扣除 0.3% 的手续费。
    // 有效金额 = balance0 - (amount0In * 0.003)
    // 为了避免浮点数，两边同时乘以 1000：
    // balance0Adjusted * 1000 = balance0 * 1000 - amount0In * 3
    uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
    uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
    
    // 核心检查: 新的 K 值必须 >= 旧的 K 值
    // 原始公式: (x_new - fee) * (y_new - fee) >= x_old * y_old
    // 变成整数代码:
    // balance0Adjusted * balance1Adjusted >= reserve0 * reserve1 * (1000^2)
    require(
        balance0Adjusted.mul(balance1Adjusted) >= 
        uint(_reserve0).mul(_reserve1).mul(1000**2), 
        'UniswapV2: K'
    );
}
```

### 深度解析：这一行代码背后的数学魔法
1.  **为什么是乘以 1000 和 减去 3？**
    *   Uniswap V2 收取 **0.3%** 的交易手续费。
    *   这意味着，用户每充入 `1000` 个币，只有 `997` 个币不仅入池子参与 K 值计算，剩下的 `3` 个币是留给流动性提供者 (LP) 的奖励。
    *   `balance0` 是当前的真实余额（包含了刚才用户充进来的 `amount0In`）。
    *   `balance0.mul(1000).sub(amount0In.mul(3))` 的含义就是：**把当前余额放大1000倍，然后扣掉用户充值额的千分之三**。
    *   剩下的结果，就是用来维持 `x * y = k` 不变的“有效入账金额”。

2.  **K 值增长 = LP 赚钱**
    *   注意，虽然我们在此处检查的是 `K_new >= K_old`，但实际上，由于那 `0.3%` 的手续费留在了合约里（`balance0` 里包含了它，但 `adjusted` 减去了它），真实的 K 值（`balance0 * balance1`）是会随着每一笔交易**微微增大**的。
    *   这个增大的 K 值属于所有 LP，这就是做市商赚手续费的来源。

3.  **闪电贷 (Flash Swap) 的奥义**
    *   这段代码位于 `swap` 函数的**末尾**。
    *   而在检查 K 值之前，Uniswap 已经先把币转给了用户（代码上方的 `_safeTransfer`）。
    *   **流程**:
        1. 借钱：合约先把 `amountOut` 转给你。
        2. 用钱：你可以利用这一瞬间（回调函数中），拿这些钱去其他平台套利、清算等。
        3. 还钱：在回调结束回到 `swap` 函数时，你转回来的代币数量 `amountIn` 只要足够大（能满足上面的 K 值公式），交易就成功。
    *   这就是为什么叫“闪电贷”——借贷和还款发生在同一笔交易内，无需抵押，只要最后公式平了就行。
*   **手续费**: 这行代码 `sub(amount0In.mul(3))` 隐式地扣除了 0.3% 的手续费。
*   **闪电贷 (Flash Swap)**: 因为是在 `swap` 的最后才通过 `requre` 检查 k 值，所以你可以在 `swap` 过程中先借出 token，做任何操作（比如套利），只要在函数结束前把钱还回来（并由 K 值检查通过），交易就是有效的。

### 2.2 LP Token 的铸造 (Mint)
当你添加流动性时，合约会给你发 LP Token。
代码位置: `function mint(address to)`

```solidity
if (_totalSupply == 0) {
    // 首次添加流动性
    // 初始流动性 = sqrt(x * y) - MINIMUM_LIQUIDITY
    liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
    // 永久锁定 1000 web (MINIMUM_LIQUIDITY) 以防止“大数攻击”
    _mint(address(0), MINIMUM_LIQUIDITY); 
} else {
    // 后续添加，按比例增发
    // liquidity = min( (in0 * total) / reserve0, (in1 * total) / reserve1 )
    liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
}
```

### 2.3 价格预言机 (TWAP)
Pair 合约不仅做交易，还免费提供价格数据。
代码位置: `function _update(...)`

```solidity
price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
```
这意味着：它每秒钟都在累加当前的价格。外部使用者可以通过读取两个时间点的 `cumulativePrice`，相减并除以时间差，得到这段时间的**时间加权平均价格 (TWAP)**。这极大地增加了操纵价格的成本。

---

## Day 1 总结与思考
1.  **Factory** 只是个生孩子的机器，生完就不管了（除了存个地址）。
2.  **Pair** 是完全独立的，它不依赖 Router，也不依赖 Factory（除了查询 FeeTo）。
3.  **安全性**: `swap` 函数先转账（乐观转账），最后查 K 值。这种模式极其强大，直接赋予了合约 Flash Loan 的能力。

### ❓ 作业/思考题
1.  在 `mint` 函数中，为什么要永久锁定 `MINIMUM_LIQUIDITY` (1000 wei)？
    <details>
    <summary>点击查看提示</summary>
    这是为了防止早期攻击者通过捐赠巨额 Token 将 `totalSupply` 变得极小，从而让后续用户的流动性计算出现虽然有投入但获得 0 LP Token 的精度问题（舍入攻击）。
    </details>

2.  如果有人直接向 Pair 合约转账 ERC20 Token 而不调用 mint，会发生什么？这些钱归谁？
    <details>
    <summary>点击查看提示</summary>
    这些钱会使 `balance` > `reserve`。下一个调用 `skim()` 或者 `mint()` 的人可以将这部分差额据为己有（如果是 mint，这部分差额亦会计入 K 值贡献给所有 LP）。
    </details>
