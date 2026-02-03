# C3: Mini AMM 学习笔记

> **目标**: 用最少的代码实现一个能跑的 AMM，彻底理解 `x * y = k`。

---

## 📍 文件位置

`mini-amm/MiniAMM.sol`

---

## 核心代码解析

### 1. 状态变量 (The Pool State)

```solidity
uint256 public reserve0;  // Token0 的储备量
uint256 public reserve1;  // Token1 的储备量
```

这两个变量就是整个池子的全部状态。**K = reserve0 * reserve1**

---

### 2. addLiquidity (添加流动性)

```solidity
function addLiquidity(uint256 amount0, uint256 amount1) external {
    reserve0 += amount0;
    reserve1 += amount1;
}
```

*   **极简版本**: 我们没有实现 LP Token（生产环境需要）。
*   **核心思想**: 往池子里扔两种资产，储备量增加，K 值变大。

---

### 3. swap (交换) - 最核心的函数！

```solidity
function swap(bool zeroForOne, uint256 amountIn) external returns (uint256 amountOut) {
    uint256 reserveIn = zeroForOne ? reserve0 : reserve1;
    uint256 reserveOut = zeroForOne ? reserve1 : reserve0;

    // 恒定乘积公式:
    // amountOut = reserveOut * amountIn / (reserveIn + amountIn)
    amountOut = (reserveOut * amountIn) / (reserveIn + amountIn);

    // 更新储备量
    if (zeroForOne) {
        reserve0 += amountIn;
        reserve1 -= amountOut;
    } else {
        reserve1 += amountIn;
        reserve0 -= amountOut;
    }
}
```

### 公式推导 (用人话讲)

**场景**: 池子里有 100 苹果 (reserve0) 和 100 元 (reserve1)。你要用 10 元买苹果。

1.  **K 值**: `100 * 100 = 10000` (恒定)
2.  **交易后钱变多**: 钱变成 `100 + 10 = 110` 元
3.  **苹果必须变少**: 为了保持 K = 10000，苹果变成 `10000 / 110 ≈ 90.9` 个
4.  **你拿走**: `100 - 90.9 = 9.1` 个苹果

**公式对应**:
```
amountOut = reserveOut * amountIn / (reserveIn + amountIn)
          = 100 * 10 / (100 + 10)
          = 1000 / 110
          ≈ 9.09
```

---

## 验证：K 值不变

交易前:
```
reserve0 = 100, reserve1 = 100
K = 100 * 100 = 10000
```

交易后 (用 10 元买苹果):
```
amountOut = 100 * 10 / 110 = 9.09
reserve0 = 100 - 9.09 = 90.91 (苹果被买走)
reserve1 = 100 + 10 = 110 (钱增加)
K = 90.91 * 110 = 10000 ✓ (K 保持不变！)
```

---

## 与 Uniswap V2 的区别

| 特性 | MiniAMM | UniswapV2 |
|------|---------|-----------|
| LP Token | ❌ 无 | ✅ 按比例铸造 |
| 手续费 | ❌ 无 | ✅ 0.3% |
| 安全检查 | ❌ 无 | ✅ 溢出、锁、K 值验证 |
| 预言机 | ❌ 无 | ✅ TWAP 累积 |
| Flash Swap | ❌ 无 | ✅ 乐观转账 |

---

## 动手实验

你可以在 Remix 或本地部署这个合约，然后：

1.  调用 `addLiquidity(100, 100)` 初始化池子
2.  调用 `getK()` 验证 K = 10000
3.  调用 `swap(true, 10)` 用 10 个 Token0 换 Token1
4.  调用 `getK()` 验证 K 仍然是 10000 (实际会略有不同因为整数舍入)
5.  观察 `reserve0` 和 `reserve1` 的变化

---

## 下一步: C4 V3 对比

理解了 V2 的 `x * y = k` 后，我们来看 V3 如何通过**集中流动性**改进这个公式。
