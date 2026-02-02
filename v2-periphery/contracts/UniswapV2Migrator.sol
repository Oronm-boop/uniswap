pragma solidity =0.6.6;

import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

import './interfaces/IUniswapV2Migrator.sol';
import './interfaces/V1/IUniswapV1Factory.sol';
import './interfaces/V1/IUniswapV1Exchange.sol';
import './interfaces/IUniswapV2Router01.sol';
import './interfaces/IERC20.sol';

contract UniswapV2Migrator is IUniswapV2Migrator {
    IUniswapV2Migrator public immutable override factoryV1; // V1 工厂合约地址 (immutable 表示部署后不可更改)
    IUniswapV2Router01 public immutable override router; // V2 路由合约地址

    // 构造函数
    // @param _factoryV1 Uniswap V1 工厂地址
    // @param _router Uniswap V2 路由地址
    constructor(address _factoryV1, address _router) public {
        factoryV1 = IUniswapV2Migrator(_factoryV1);
        router = IUniswapV2Router01(_router);
    }

    // 接收 ETH 的回调函数
    // 需要接收来自 V1 交易所 (移除流动性返还 ETH) 和 Router (多余 ETH 退款) 的 ETH。
    // 理想情况下应该限制只能接收来自它们的 ETH，但检查 V1 工厂需要外部调用，太消耗 gas，所以开放接收。
    receive() external payable {}

    // 将 Uniswap V1 的流动性迁移到 V2
    // @param token 要迁移的 ERC20 代币地址（V1是基于 ETH-ERC20 的）
    // @param amountTokenMin 迁移后在 V2 获得的最小 Token 数量（滑点保护）
    // @param amountETHMin 迁移后在 V2 获得的最小 ETH 数量（滑点保护）
    // @param to 接收 V2 LP Token 的地址
    // @param deadline 交易截止时间
    function migrate(
        address token,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external override {
        // 1. 获取该 Token 在 V1 的交易所地址 (Uniswap V1 每个 Token 只有一个 Exchange)
        IUniswapV1Exchange exchangeV1 = IUniswapV1Exchange(factoryV1.getExchange(token));

        // 2. 获取用户在 V1 交易所的流动性余额 (LP Token 余额)
        uint liquidityV1 = exchangeV1.balanceOf(msg.sender);

        // 3. 将用户的 V1 LP Token 转移到当前合约（Migrator）
        // 必须先由用户 approve Migrator 合约
        require(exchangeV1.transferFrom(msg.sender, address(this), liquidityV1), 'TRANSFER_FROM_FAILED');

        // 4. 移除 V1 流动性，获得 ETH 和 Token
        // removeLiquidity 返回 (amountETH, amountToken)
        // 参数：amount, min_eth, min_tokens, deadline
        (uint amountETHV1, uint amountTokenV1) = exchangeV1.removeLiquidity(liquidityV1, 1, 1, uint(-1));

        // 5. 批准 Router 使用刚才取出来的 Token，为下一步添加 V2 流动性做准备
        TransferHelper.safeApprove(token, address(router), amountTokenV1);

        // 6. 将提取出来的 ETH 和 Token 添加到 V2 的流动性池中
        // 调用 Router 的 addLiquidityETH
        // value: amountETHV1 (发送所有取出来的 ETH)
        (uint amountTokenV2, uint amountETHV2, ) = router.addLiquidityETH{value: amountETHV1}(
            token,
            amountTokenV1, // Desired Token
            amountTokenMin, // Min Token (用户指定)
            amountETHMin, // Min ETH (用户指定)
            to, // LP Token 接收者
            deadline // 截止时间
        );

        // 7. 处理剩余的资产（如果有的话），返还给用户
        // 如果 V1 的比例和 V2 的当前比例不完全一致，会有少量的 Token 或 ETH 剩余
        if (amountTokenV1 > amountTokenV2) {
            TransferHelper.safeApprove(token, address(router), 0); // 重置授权为 0，做一个良好的区块链公民
            TransferHelper.safeTransfer(token, msg.sender, amountTokenV1 - amountTokenV2);
        } else if (amountETHV1 > amountETHV2) {
            // addLiquidityETH 保证了所有 ETH 或所有 Token 会被使用
            // 如果 ETH 有剩余，直接返还给用户
            TransferHelper.safeTransferETH(msg.sender, amountETHV1 - amountETHV2);
        }
    }
}
