# C2: 精读 UniswapV2Pair.sol

> **目标**: 完全理解 AMM 的核心四个函数：`swap`, `mint`, `burn`, `_update`。
> **过关标准**: 能回答代码里每一行"为什么这样写"。

---

## 📍 文件概览

`UniswapV2Pair.sol` 是 Uniswap V2 的**灵魂**。每个交易对都由一个独立的 Pair 合约管理。

**核心状态变量**:
```solidity
uint112 private reserve0;             // Token0 的储备量
uint112 private reserve1;             // Token1 的储备量
uint32 private blockTimestampLast;    // 上次更新的区块时间
uint public price0CumulativeLast;     // 累积价格 (用于 TWAP 预言机)
uint public price1CumulativeLast;     
uint public kLast;                    // 上次事件后的 k 值 (用于协议费)
```

---

## 1. `swap()` - 交易核心 (最重要的函数)

```solidity
function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock
```

### 1.1 乐观转账 (Optimistic Transfer)
```solidity
// 先转账给用户！（还没检查你有没有付钱）
if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);
```
*   **为什么这样做？**
    *   传统逻辑: 先收钱，再发货。
    *   Uniswap 逻辑: 先发货，最后检查账是否对。
*   **好处**: 这赋予了合约 **Flash Swap** (闪电贷) 的能力。

### 1.2 Flash Swap 回调
```solidity
if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
```
*   如果 `data` 不为空，则认为这是一次 Flash Swap。
*   合约会调用 `to` 地址的 `uniswapV2Call` 函数，让你有机会用借来的钱做任何事（如套利），只要最后把钱还上。

### 1.3 计算实际输入量
```solidity
uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
```
*   **核心逻辑**: `amountIn = 当前余额 - (旧储备 - 转出金额)`
*   **含义**: 通过余额变化反推用户实际转入了多少钱。

### 1.4 手续费 & K 值检查 (最核心的一行)
```solidity
uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3)); // 扣除 0.3% 手续费
// ...
require(
    balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2),
    'UniswapV2: K'
);
```
*   **这就是 `x * y = k` 的强制执行点！**
*   `mul(3)` = 0.3% 手续费被隐式扣除。
*   如果调整后的乘积 < 原乘积 * 1000^2，交易 revert。
*   **结论**: 池子的 K 值只会增加（因为手续费），永远不会减少。

### 1.5 Swap 流程图
```
┌───────────────────────────────────────────────────────┐
│ 1. 读取旧 reserve0, reserve1                          │
├───────────────────────────────────────────────────────┤
│ 2. 乐观转账：先把用户想要的 Token 转给他              │
├───────────────────────────────────────────────────────┤
│ 3. (可选) Flash Swap 回调                            │
├───────────────────────────────────────────────────────┤
│ 4. 读取新的余额 balance0, balance1                    │
├───────────────────────────────────────────────────────┤
│ 5. 计算 amountIn (用户实际付了多少)                  │
├───────────────────────────────────────────────────────┤
│ 6. K 值检查 (核心！)                                │
│    newK = (balance0 - fee0) * (balance1 - fee1)       │
│    require(newK >= oldK)                              │
├───────────────────────────────────────────────────────┤
│ 7. 更新 reserve0, reserve1 (_update)                 │
└───────────────────────────────────────────────────────┘
```

---

## 2. `mint()` - 添加流动性

```solidity
function mint(address to) external lock returns (uint liquidity)
```

### 2.1 计算用户注入了多少
```solidity
uint amount0 = balance0.sub(_reserve0); // 当前余额 - 旧储备 = 用户转入量
uint amount1 = balance1.sub(_reserve1);
```

### 2.2 首次添加 vs 后续添加
```solidity
if (_totalSupply == 0) {
    // 首次添加：LP = sqrt(x * y) - MINIMUM_LIQUIDITY
    liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
    _mint(address(0), MINIMUM_LIQUIDITY); // 永久锁定 1000 wei
} else {
    // 后续添加：按比例
    liquidity = Math.min(amount0 * total / reserve0, amount1 * total / reserve1);
}
```

### 2.3 为什么锁定 MINIMUM_LIQUIDITY?
*   防止**舍入攻击 (Rounding Attack)**。
*   如果第一个 LP 可以 burn 全部 LP Token，可能会导致 `totalSupply` 变成 0，后续加入者可能因为除法舍入而获得 0 LP。

---

## 3. `burn()` - 移除流动性

```solidity
function burn(address to) external lock returns (uint amount0, uint amount1)
```

### 3.1 按比例计算应得资产
```solidity
uint liquidity = balanceOf[address(this)]; // 用户转进来的 LP 数量
amount0 = liquidity.mul(balance0) / _totalSupply;
amount1 = liquidity.mul(balance1) / _totalSupply;
```
*   **核心公式**: `你的 LP / 总 LP * 池子里的资产 = 你应得的`

### 3.2 销毁 & 转账
```solidity
_burn(address(this), liquidity); // 销毁 LP Token
_safeTransfer(_token0, to, amount0);
_safeTransfer(_token1, to, amount1);
```

---

## 4. `_update()` - 状态同步 & 预言机

```solidity
function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private
```

### 4.1 更新储备量
```solidity
reserve0 = uint112(balance0);
reserve1 = uint112(balance1);
```

### 4.2 更新累积价格 (TWAP)
```solidity
if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
    price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
    price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
}
```
*   **这是免费的预言机数据！**
*   外部合约可以在两个时间点读取累积值，相减除以时间差，得到 **TWAP**。

---

## C2 Checkpoint 小测验

完成 C2 后，你应该能回答：

| 问题 | 答案 |
|------|------|
| `x·y=k` 在哪一行被保证？ | `require(balance0Adjusted.mul(balance1Adjusted) >= ...)` (第 236-239 行) |
| 手续费在哪里扣？ | `.sub(amount0In.mul(3))` (第 231-232 行) |
| 为什么 swap 里没有 transferFrom？ | 因为 Router 已经在调用 swap 之前把 Token 转到 Pair 了，swap 只负责检查余额变化。 |
| 为什么 K 值会越来越大？ | 因为每次交易都扣手续费，手续费留在池子里，增加了 K 值。 |

---

## 下一步: C3 自己写一个 Mini AMM

理论到此结束。现在，用你学到的知识，**自己实现一个 50 行的 Mini AMM**。
