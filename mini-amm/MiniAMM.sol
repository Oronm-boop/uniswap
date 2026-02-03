// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title MiniAMM
 * @dev 一个极简的 AMM 实现，用于理解核心机制
 *
 * 特点：
 * - 两个 reserve (reserve0, reserve1)
 * - addLiquidity: 添加流动性
 * - swap: 交换代币
 * - 没有 LP Token（极简版本）
 * - 没有安全检查（学习用途）
 */
contract MiniAMM {
    // ============ 状态变量 ============
    uint256 public reserve0; // Token0 的储备量
    uint256 public reserve1; // Token1 的储备量

    // ============ 事件 ============
    event LiquidityAdded(uint256 amount0, uint256 amount1);
    event Swapped(bool zeroForOne, uint256 amountIn, uint256 amountOut);

    // ============ 核心函数 ============

    /**
     * @dev 添加流动性
     * 直接增加两个 reserve（极简版本，不发 LP Token）
     * @param amount0 添加的 Token0 数量
     * @param amount1 添加的 Token1 数量
     */
    function addLiquidity(uint256 amount0, uint256 amount1) external {
        // 直接增加储备量
        reserve0 += amount0;
        reserve1 += amount1;

        emit LiquidityAdded(amount0, amount1);
    }

    /**
     * @dev 交换代币 (核心！)
     * 使用恒定乘积公式: x * y = k
     * @param zeroForOne true = 用 Token0 换 Token1, false = 反过来
     * @param amountIn 输入的代币数量
     * @return amountOut 输出的代币数量
     */
    function swap(
        bool zeroForOne,
        uint256 amountIn
    ) external returns (uint256 amountOut) {
        // 1. 获取当前储备量
        uint256 reserveIn = zeroForOne ? reserve0 : reserve1;
        uint256 reserveOut = zeroForOne ? reserve1 : reserve0;

        // 2. 根据恒定乘积公式计算输出量
        // 公式推导:
        //   k = reserveIn * reserveOut
        //   k = (reserveIn + amountIn) * (reserveOut - amountOut)
        //   amountOut = reserveOut - k / (reserveIn + amountIn)
        //   amountOut = reserveOut * amountIn / (reserveIn + amountIn)
        amountOut = (reserveOut * amountIn) / (reserveIn + amountIn);

        // 3. 更新储备量
        if (zeroForOne) {
            reserve0 += amountIn; // Token0 增加
            reserve1 -= amountOut; // Token1 减少
        } else {
            reserve1 += amountIn; // Token1 增加
            reserve0 -= amountOut; // Token0 减少
        }

        emit Swapped(zeroForOne, amountIn, amountOut);
    }

    // ============ 辅助函数 ============

    /**
     * @dev 获取当前价格 (Token0 / Token1)
     * @return price 价格 (乘以 1e18 精度)
     */
    function getPrice() external view returns (uint256 price) {
        if (reserve1 == 0) return 0;
        price = (reserve0 * 1e18) / reserve1;
    }

    /**
     * @dev 获取当前的 K 值
     */
    function getK() external view returns (uint256) {
        return reserve0 * reserve1;
    }

    /**
     * @dev 预估输出量 (不改变状态)
     */
    function getAmountOut(
        bool zeroForOne,
        uint256 amountIn
    ) external view returns (uint256) {
        uint256 reserveIn = zeroForOne ? reserve0 : reserve1;
        uint256 reserveOut = zeroForOne ? reserve1 : reserve0;
        return (reserveOut * amountIn) / (reserveIn + amountIn);
    }
}
