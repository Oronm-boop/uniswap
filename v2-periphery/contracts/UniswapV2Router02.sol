pragma solidity =0.6.6;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

import './interfaces/IUniswapV2Router02.sol';
import './libraries/UniswapV2Library.sol';
import './libraries/SafeMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';

contract UniswapV2Router02 is IUniswapV2Router02 {
    using SafeMath for uint;

    address public immutable override factory; // Uniswap V2 工厂合约地址
    address public immutable override WETH; // WETH 代币地址

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'UniswapV2Router: EXPIRED');
        _;
    }

    // 构造函数
    // @param _factory 工厂合约地址，用于创建配对和查询配对地址
    // @param _WETH WETH 合约地址，用于 ETH 和 WETH 之间的转换
    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    // **** ADD LIQUIDITY ****
    // **** 添加流动性 (ADD LIQUIDITY) ****
    // 内部函数：计算添加流动性的最优数量
    // @param tokenA 代币A地址
    // @param tokenB 代币B地址
    // @param amountADesired 用户期望添加的 A 数量
    // @param amountBDesired 用户期望添加的 B 数量
    // @param amountAMin 用户能接受的最小 A 数量
    // @param amountBMin 用户能接受的最小 B 数量
    // @return amountA 实际应该输入的 A 数量
    // @return amountB 实际应该输入的 B 数量
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal virtual returns (uint amountA, uint amountB) {
        // 如果交易对通过工厂查询不存在，则创建一个新的交易对
        // create the pair if it doesn't exist yet
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        // 获取当前的储备量 (Reserve)
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
        // 如果储备量为 0，说明是新池子，直接使用用户期望的数量作为初始比例
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            // 如果不是新池子，需要计算最优比例
            // 计算给定 amountADesired (A) 时，需要多少 amountB
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            // 如果计算出的 B 数量 <= 用户期望/拥有的 B 数量
            if (amountBOptimal <= amountBDesired) {
                // 检查计算出的 B 是否满足用户设置的最小 B 数量 (amountBMin)
                require(amountBOptimal >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
                // 确定最终添加数量：A 使用期望值，B 使用计算出的最优值
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                // 如果 B 不够，说明 A 给多了，反过来算：给定 amountBDesired (B) 需要多少 A
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                // 理论上 A 必然 <= amountADesired
                assert(amountAOptimal <= amountADesired);
                // 检查计算出的 A 是否满足用户设置的最小 A 数量 (amountAMin)
                require(amountAOptimal >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
                // 确定最终添加数量：A 使用计算出的最优值，B 使用期望值
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    // 添加流动性 (对外接口)
    // @param tokenA 代币A地址
    // @param tokenB 代币B地址
    // @param amountADesired 期望添加的A数量
    // @param amountBDesired 期望添加的B数量
    // @param amountAMin 最小接受的A数量(滑点保护)
    // @param amountBMin 最小接受的B数量(滑点保护)
    // @param to 接收 LP Token 的地址
    // @param deadline 交易截止时间
    // @return amountA 实际注入的A数量
    // @return amountB 实际注入的B数量
    // @return liquidity 获得的 LP Token 数量
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        // 1. 计算最优的添加数量 (amountA, amountB)
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        // 2. 获取 Pair 合约地址 (避免外部调用，节省 gas)
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 3. 将 Token A 转入 Pair 合约
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        // 4. 将 Token B 转入 Pair 合约
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        // 5. 调用 Pair 的 mint 函数，铸造 LP Token 给用户 (to)
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    // 添加 ETH 流动性
    // @param token ERC20代币地址
    // @param amountTokenDesired 期望添加的Token数量
    // @param amountTokenMin 最小接受的Token数量
    // @param amountETHMin 最小接受的ETH数量
    // @param to 接收 LP Token 的地址
    // @param deadline 交易截止时间
    // @return amountToken 实际注入的Token数量
    // @return amountETH 实际注入的ETH数量
    // @return liquidity 获得的 LP Token 数量
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable virtual override ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        // 1. 计算最优注入量 (ETH 当作 WETH 处理)
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        // 2. 获取 Pair 地址
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        // 3. 将 Token 转给 Pair
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        // 4. 将 ETH 换成 WETH
        IWETH(WETH).deposit{value: amountETH}();
        // 5. 将 WETH 转给 Pair
        assert(IWETH(WETH).transfer(pair, amountETH));
        // 6. 铸造 LP Token
        liquidity = IUniswapV2Pair(pair).mint(to);
        // 7. 如果用户发送的 ETH 多于实际需要的，退还剩余部分
        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** REMOVE LIQUIDITY ****
    // 移除流动性
    // @param tokenA 代币A地址
    // @param tokenB 代币B地址
    // @param liquidity 销毁的 LP Token 数量
    // @param amountAMin 最小接受的A数量
    // @param amountBMin 最小接受的B数量
    // @param to 接收资产的地址
    // @param deadline 截止时间
    // @return amountA 实际获得的A数量
    // @return amountB 实际获得的B数量
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 1. 将用户的 LP Token 发送到 Pair 合约
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        // 2. 销毁 LP Token，获取底层资产 (burn 函数会返回 asset0 和 asset1)
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        // 3. 排序 Token 以匹配返回值顺序 (tokenA/tokenB 可能不是 pair 的 token0/token1)
        (address token0, ) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        // 4. 检查是否满足用户设置的最小获得量
        require(amountA >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
    }

    // **** 移除流动性 (REMOVE LIQUIDITY) ****
    // @param token ERC20代币地址
    // @param liquidity 销毁的 LP Token 数量
    // @param amountTokenMin 最小接受的Token数量
    // @param amountETHMin 最小接受的ETH数量
    // @param to 接收资产的地址
    // @param deadline 截止时间
    // @return amountToken 实际获得的Token数量
    // @return amountETH 实际获得的ETH数量
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountToken, uint amountETH) {
        // 1. 先调用 removeLiquidity，此时获得的是 Token 和 WETH
        // 注意：接收者设置为 this (Router)，因为 Router 需要把 WETH 换成 ETH
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        // 2. 将 Token 转给用户
        TransferHelper.safeTransfer(token, to, amountToken);
        // 3. 将 WETH 换回 ETH
        IWETH(WETH).withdraw(amountETH); // 将 WETH 换回 ETH
        // 4. 发送 ETH 给用户
        TransferHelper.safeTransferETH(to, amountETH); // 发送 ETH 给用户
    }

    // 使用签名 (Permit) 移除流动性
    // @param tokenA 代币A地址
    // @param tokenB 代币B地址
    // @param liquidity 移除的流动性数量
    // @param amountAMin 最小A
    // @param amountBMin 最小B
    // @param to 接收地址
    // @param deadline 截止时间
    // @param approveMax 是否批准最大量
    // @param v, r, s 签名数据
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint amountA, uint amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 1. 计算批准的额度 (如果是 approveMax 则为 uint(-1))
        uint value = approveMax ? uint(-1) : liquidity;
        // 2. 调用 Pair 的 permit 函数，使用签名进行授权 (无需用户发送 approve 交易)
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        // 3. 执行标准的移除流动性逻辑
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    // 使用 EIP-2612 签名来移除流动性并直接换回 ETH (无 gas 批准)
    // @param token Token地址
    // @param liquidity 移除数量
    // @param amountTokenMin 最小Token
    // @param amountETHMin 最小ETH
    // @param to 接收地址
    // @param deadline 截止时间
    // @param approveMax 是否最大批准
    // @param v, r, s 签名
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint amountToken, uint amountETH) {
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    // **** 移除流动性（支持 Fee-On-Transfer 代币） ****
    // 对于那些转账会扣税的代币，不能假设 removeLiquidity 返回的数量就是最后到手的数量
    // @param token Token地址
    // @param liquidity 移除数量
    // @param amountTokenMin 最小Token
    // @param amountETHMin 最小ETH
    // @param to 接收地址
    // @param deadline 截止时间
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountETH) {
        // 1. 调用标准移除逻辑，接收者为 Router
        (, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this), // 先发给 Router 自己
            deadline
        );
        // 2. 这里的关键不同点：不依赖 removeLiquidity 的返回值
        // 而是直接查询 Router 当前持有的 Token 余额，全部转给用户
        TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        // 3. WETH 处理同上
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    // 使用签名 (Permit) 移除 ETH 流动性（支持 Fee-On-Transfer 代币）
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint amountETH) {
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token,
            liquidity,
            amountTokenMin,
            amountETHMin,
            to,
            deadline
        );
    }

    // **** SWAP (交易逻辑) ****
    // requires the initial amount to have already been sent to the first pair
    // 内部函数：执行多跳交易
    // 前提：初始的输入代币数量 (Input Amount) 已经被转入到了路径中的第一个 Pair 合约。
    // @param amounts 路径上每一步的代币数量数组 [Input, Output1, Output2, ... FinalOutput]
    // @param path 交易路径 [TokenA, TokenB, TokenC, ...]
    // @param _to 最终接收代币的地址
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
        // 遍历路径中的每一跳
        for (uint i; i < path.length - 1; i++) {
            // 获取当前交易对的输入 Token 和输出 Token 地址
            (address input, address output) = (path[i], path[i + 1]);
            // 排序 Token 以确定的 Pair 地址和 token0/1 顺序
            (address token0, ) = UniswapV2Library.sortTokens(input, output); // 确定交易方向
            // 获取当前这一跳应该输出的金额 (amounts 是预先计算好的)
            uint amountOut = amounts[i + 1];
            // 确定 amount0Out 和 amount1Out (其中一个为 0，另一个为 output amount)
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            // 确定接收地址 to：
            // 如果不是最后一跳 (i < path.length - 2)，则接收地址是下一个交易对 (output, path[i+2]) 的地址
            // 如果是最后一跳，则接收地址是最终用户 _to
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to; // 倒数第二跳的索引就是最后一棒了
            // 调用 Pair 合约的 swap 函数执行交易
            // 注意：data 参数为空，表示不是 Flash Swap
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap( // 修改状态
                amount0Out,
                amount1Out,
                to,
                new bytes(0)
            );
        }
    }

    // 精确输入 Token 换取尽可能多的 Token
    // @param amountIn: 输入的精确数量
    // @param amountOutMin: 最小接受的输出数量
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        // 1. 根据路径计算每一步的输出数量 (amounts)
        // 这个数组有什么用？ 滑点检查 (Slippage Check): 它会检查数组最后一个数（也就是你最终能拿到的钱）是否大于你设定的底线。
        // 指导交易执行: 在后续的循环交易中，Router 不会再重新计算“该换多少钱”，而是直接查这个表：
        // 告诉第一个池子：“我给你 amounts[0]，你要给我吐出 amounts[1] 这么多币。”
        // 告诉第二个池子：“你会收到 amounts[1]，你要给我吐出 amounts[2] 这么多币。”
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path); // amounts数组的所有元素预选算好
        // 2. 检查最终输出是否满足滑点要求 (>= amountOutMin)
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'); // 数组的最后一个元素即为uniswap输出的tokenB数量
        // 3. 将输入 Token 转给第一个 Pair
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]), // 计算 Pair 合约的地址
            amounts[0]
        );
        // 4. 执行多跳交易
        _swap(amounts, path, to);
    }

    // Token 换取精确的 Token
    // Token 换取精确的 Token (输入也尽可能少)
    // @param amountOut: 期望获得的精确输出数量
    // @param amountInMax: 愿意支付的最大输入数量
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        // 1. 根据最终输出反推每一步需要的输入 (amounts)
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        // 2. 检查第一步需要的输入是否超过了用户设置的最大值
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        // 3. 将刚好足够的输入 Token 转给第一个 Pair
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        // 4. 执行交易
        _swap(amounts, path, to);
    }

    // 精确的 ETH 换取 Token
    // 精确的 ETH 换取 Token
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable virtual override ensure(deadline) returns (uint[] memory amounts) {
        // 校验：路径起点必须是 WETH
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        // 1. 计算输出量，输入量即为 msg.value
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        // 2. 滑点检查
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        // 3. 将用户的 ETH 换成 WETH
        IWETH(WETH).deposit{value: amounts[0]}();
        // 4. 将 WETH 转给第一个 Pair
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        // 5. 执行交易
        _swap(amounts, path, to);
    }

    // Token 换取精确的 ETH
    function swapTokensForExactETH(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        // 校验：路径终点必须是 WETH
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        // 1. 反推输入
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        // 2. 检查最大输入
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        // 3. 转入 Token
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        // 4. 执行交易，接收者是 Router (this)，因为要换成 ETH
        _swap(amounts, path, address(this));
        // 5. 将 WETH 换回 ETH
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        // 6. 发送 ETH 给用户
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    // 精确的 Token 换取 ETH
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        // 1. 计算输出
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        // 2. 检查最小输出
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        // 3. 转入 Token
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        // 4. 执行交易，Router 收 WETH
        _swap(amounts, path, address(this));
        // 5. WETH -> ETH
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        // 6. 发送 ETH
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    // ETH 换取精确的 Token
    // ETH 换取精确的 Token
    function swapETHForExactTokens(
        uint amountOut,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable virtual override ensure(deadline) returns (uint[] memory amounts) {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        // 1. 反推需要的 ETH 数量 (amounts[0])
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        // 2. 检查用户发送的 ETH 是否足够
        require(amounts[0] <= msg.value, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        // 3. 将需要的 ETH 换成 WETH
        IWETH(WETH).deposit{value: amounts[0]}();
        // 4. 转移给 Pair
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        // 5. 执行交易
        _swap(amounts, path, to);
        // 6. 退还多余的 ETH
        // refund dust eth, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // **** 交易 (支持 Fee-On-Transfer 代币) ****
    // 内部函数：支持会扣费代币的 Swap 逻辑
    // 与标准 _swap 的区别在于不依赖预计算的 amounts，而是动态检查余额变化
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        // 遍历路径
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = UniswapV2Library.sortTokens(input, output);
            IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output));
            uint amountInput;
            uint amountOutput;
            {
                // 使用 scope 避免 stack too deep 错误
                (uint reserve0, uint reserve1, ) = pair.getReserves();
                (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);

                // 核心逻辑：
                // 1. 获取 Pair 当前的 input token 余额
                // 2. 减去 reserveInput (储备量)，得到实际转入的金额 (amountInput)
                // 这样就自动处理了转账过程中的税费扣除
                amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
                // 3. 基于实际收到的 amountInput 计算 amountOutput
                amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            // 确定 swap 参数
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
            // 确定接收地址
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            // 执行 Swap
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    // 精确 Token 换 Token (支持 FOT)
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) {
        // 1. 先转账
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amountIn
        );
        // 2. 记录接收者当前的余额
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        // 3. 执行支持 FOT 的交换
        _swapSupportingFeeOnTransferTokens(path, to);
        // 4. 检查实际增加的余额是否满足最低要求
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    // 精确 ETH 换 Token (支持 FOT)
    // 精确 ETH 换 Token (支持 FOT)
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable virtual override ensure(deadline) {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        uint amountIn = msg.value;
        // 1. ETH -> WETH
        IWETH(WETH).deposit{value: amountIn}();
        // 2. WETH -> Pair
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn));
        // 3. 记录余额
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        // 4. 执行 FOT 交换
        _swapSupportingFeeOnTransferTokens(path, to);
        // 5. 校验结果
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    // 精确 Token 换 ETH (支持 FOT)
    // 精确 Token 换 ETH (支持 FOT)
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amountIn
        );
        // 1. 交换，接收者是 Router
        _swapSupportingFeeOnTransferTokens(path, address(this));
        // 2. 查 Router 收到了多少 WETH
        uint amountOut = IERC20(WETH).balanceOf(address(this));
        // 3. 校验滑点
        require(amountOut >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        // 4. WETH -> ETH
        IWETH(WETH).withdraw(amountOut);
        // 5. 将 ETH 转给用户
        TransferHelper.safeTransferETH(to, amountOut);
    }

    // **** LIBRARY FUNCTIONS (库函数封装) ****
    // 计算给定输入数量能换多少输出（不含滑点，仅计算理论值）
    function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual override returns (uint amountB) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    // 给定 Reserve 输入，计算输出 Amount (由 Library 实现)
    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) public pure virtual override returns (uint amountOut) {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    // 给定 Reserve 输出，计算需要多少输入 (由 Library 实现)
    function getAmountIn(
        uint amountOut,
        uint reserveIn,
        uint reserveOut
    ) public pure virtual override returns (uint amountIn) {
        return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    // 计算路径中每一步的输出数量
    function getAmountsOut(
        uint amountIn,
        address[] memory path
    ) public view virtual override returns (uint[] memory amounts) {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    // 计算路径中每一步需要的输入数量
    function getAmountsIn(
        uint amountOut,
        address[] memory path
    ) public view virtual override returns (uint[] memory amounts) {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}
