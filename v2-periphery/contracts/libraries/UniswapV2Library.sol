pragma solidity >=0.5.0;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';

import './SafeMath.sol';

library UniswapV2Library {
    using SafeMath for uint;

    // 返回排序后的代币地址
    // @param tokenA 代币A地址
    // @param tokenB 代币B地址
    // @return token0 排序较前的地址
    // @return token1 排序较后的地址
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }

    // 计算 Pair 合约的地址 (无需外部调用)
    // 使用 CREATE2 预测地址，节省 gas 并支持链下计算
    // @param factory 工厂合约地址
    // @param tokenA 代币A
    // @param tokenB 代币B
    // @return pair 计算出的 Pair 合约地址
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint(
                keccak256(
                    abi.encodePacked(
                        hex'ff',
                        factory,
                        keccak256(abi.encodePacked(token0, token1)),
                        hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f' // init code hash
                    )
                )
            )
        );
    }

    // 获取交易对的储备量 (Reserves) 并按 tokenA, tokenB 的顺序返回
    // @param factory 工厂合约地址
    // @param tokenA 代币A
    // @param tokenB 代币B
    // @return reserveA 代币A的储备量
    // @return reserveB 代币B的储备量
    function getReserves(
        address factory,
        address tokenA,
        address tokenB
    ) internal view returns (uint reserveA, uint reserveB) {
        (address token0, ) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1, ) = IUniswapV2Pair(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // 给定某种代币的数量和储备量，计算等值的另一种代币数量
    // 主要用于添加流动性时计算两个代币的比例
    // 公式: amountB = amountA * reserveB / reserveA
    // @param amountA 输入的代币A数量
    // @param reserveA 代币A的储备量
    // @param reserveB 代币B的储备量
    // @return amountB 等值的代币B数量
    function quote(uint amountA, uint reserveA, uint reserveB) internal pure returns (uint amountB) {
        require(amountA > 0, 'UniswapV2Library: INSUFFICIENT_AMOUNT');
        require(reserveA > 0 && reserveB > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        amountB = amountA.mul(reserveB) / reserveA;
    }

    // 给定输入金额，计算扣除 0.3% 手续费后的最大输出金额
    // 公式: amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
    // @param amountIn 输入的代币数量
    // @param reserveIn 输入代币的储备量
    // @param reserveOut 输出代币的储备量
    // @return amountOut 能获得的输出代币数量
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // 给定期望的输出金额，计算需要多少输入金额（包含 0.3% 手续费）
    // 公式: amountIn = (amountOut * 1000 * reserveIn) / ((reserveOut - amountOut) * 997) + 1
    // @param amountOut 期望获得的输出代币数量
    // @param reserveIn 输入代币的储备量
    // @param reserveOut 输出代币的储备量
    // @return amountIn 需要支付的输入代币数量
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) internal pure returns (uint amountIn) {
        require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint numerator = reserveIn.mul(amountOut).mul(1000);
        uint denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    // 执行多跳交易的输出计算
    // @param factory 工厂合约地址
    // @param amountIn 初始输入数量
    // @param path 交易路径
    // @return amounts 路径上每一步的输出数量数组
    function getAmountsOut(
        address factory,
        uint amountIn,
        address[] memory path
    ) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i; i < path.length - 1; i++) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    // 执行多跳交易的输入计算（反向推导）
    // @param factory 工厂合约地址
    // @param amountOut 最终期望输出数量
    // @param path 交易路径
    // @return amounts 路径上每一步需要的输入数量数组
    function getAmountsIn(
        address factory,
        uint amountOut,
        address[] memory path
    ) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint i = path.length - 1; i > 0; i--) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}
