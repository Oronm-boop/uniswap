pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath for uint;
    using UQ112x112 for uint224;

    uint public constant MINIMUM_LIQUIDITY = 10 ** 3; // 最小流动性锁定数量，防止除以零和舍入攻击
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0; // 使用 uint112 以便与 blockTimestampLast 打包在一个 slot 中
    uint112 private reserve1; // 存储 token1 的储备量
    uint32 private blockTimestampLast; // 最后一次交互的区块时间戳

    uint public price0CumulativeLast; // 累积价格0（用于预言机）
    uint public price1CumulativeLast; // 累积价格1（用于预言机）
    uint public kLast; // 最近一次流动性事件后的 k 值 (reserve0 * reserve1)

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        // 使用低级 call 调用，而不是直接使用 IERC20(token).transfer(to, value)。
        // 注意：`call` 不是 Token 合约里的函数，而是 Solidity 中 `address` 类型自带的底层方法。
        // 任何 address 类型的变量都可以调用 .call() 来发送原始交易数据。
        // 原因是：某些非标准 ERC20 代币（如 USDT）在转账成功后不会返回 boolean 值。
        // 如果使用标准接口调用这些代币，交易会因为无法解码返回值而 revert。
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));

        // 校验逻辑：
        // 1. success 必须为 true（调用本身没有 revert）。
        // 2. data.length == 0：如果代币没返回任何数据（如 USDT），只要没 revert 就算成功。
        // 3. abi.decode(data, (bool))：如果代币返回了数据，那么解码出来的结果必须为 true。
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    // @param _token0 交易对中的第一个代币地址
    // @param _token1 交易对中的第二个代币地址
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // 更新储备量，并在每个区块首次调用时更新价格累积器（用于 TWAP）
    // @param balance0 当前合约中 token0 的真实余额
    // @param balance1 当前合约中 token1 的真实余额
    // @param _reserve0 更新前的 token0 储备量
    // @param _reserve1 更新前的 token1 储备量
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // 计算自上次更新以来的时间差（此处溢出是预期的行为）
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // 累加价格：价格 * 时间差。
            // 外部用户可以使用两个时间点的累积值相减并除以时间差，算出一个时间加权平均价格 (TWAP)。
            // * 永远不会溢出，+ 溢出是预期行为（因为我们只关心时间差）
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // 如果开启了协议费，铸造相当于 sqrt(k) 增长量的 1/6 的流动性作为手续费
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // 节省 gas
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // 铸造流动性代币 (Mint LP Tokens)
    // 这个低级函数通常由 Router 合约调用，Router 会先将代币转入本合约
    // @param to 接收新铸造 LP 代币的地址
    // @return liquidity 实际铸造出的 LP 代币数量
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // 节省 gas
        uint balance0 = IERC20(token0).balanceOf(address(this)); // 获取当前合约内的真实余额
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0); // 计算用户刚才转入了多少 token0
        uint amount1 = balance1.sub(_reserve1); // 计算用户刚才转入了多少 token1

        bool feeOn = _mintFee(_reserve0, _reserve1); // 计算并铸造协议费（如果有）
        uint _totalSupply = totalSupply; // 获取当前 LP 代币总量
        if (_totalSupply == 0) {
            // 如果是首次添加流动性
            // 几何平均数减去最小流动性
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            // 永久锁定最初的 MINIMUM_LIQUIDITY，防止攻击
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            // 后续添加流动性，按当前比例计算应该增发的 LP 数量
            // 取两者的最小值，确保添加比例正确
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity); // 给用户铸造 LP 代币

        _update(balance0, balance1, _reserve0, _reserve1); // 更新储备量记录
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // 更新 kLast
        emit Mint(msg.sender, amount0, amount1);
    }

    // 销毁流动性代币 (Burn LP Tokens)
    // 用户先将 LP token 转移到 Pair 合约，然后调用 burn
    // @param to 接收赎回的 token0 和 token1 的地址
    // @return amount0 赎回的 token0 数量
    // @return amount1 赎回的 token1 数量
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // 节省 gas
        address _token0 = token0; // 节省 gas
        address _token1 = token1; // 节省 gas
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)]; // 获取当前合约持有的 LP 代币数量（即用户转进来要销毁的数量）

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply;
        // 按比例计算用户应得的 token0 和 token1
        // amount = (liquidity / totalSupply) * balance
        amount0 = liquidity.mul(balance0) / _totalSupply;
        amount1 = liquidity.mul(balance1) / _totalSupply;
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity); // 销毁 LP 代币
        _safeTransfer(_token0, to, amount0); // 转账 token0 给用户
        _safeTransfer(_token1, to, amount1); // 转账 token1 给用户
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1); // 更新储备量
        if (feeOn) kLast = uint(reserve0).mul(reserve1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // 交易核心函数 (Swap)
    // 乐观转账：允许先转出代币，最后检查 K 值
    // @param amount0Out 用户想购买（转出）的 token0 数量
    // @param amount1Out 用户想购买（转出）的 token1 数量
    // @param to 接收购买到的代币的地址
    // @param data 用于回调的数据。如果不为空，则执行 Flash Swap（闪电贷）逻辑，调用 to 地址的 uniswapV2Call 函数
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // 节省 gas
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        {
            // 作用域块，防止 stack too deep 错误
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
            // 乐观转账：先把用户想要的币转给他！
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);
            // 如果 data 不为空，调用回调函数（用于 Flash Loan / 闪电贷）
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);

            // 在回调之后，再次查询当前的余额
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }

        // 计算用户实际转入了多少代币
        // amountIn = 当前余额 - (旧储备 - 转出金额)
        // 如果结果 < 0，说明没转入，置为 0
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');

        {
            // 作用域块，防止 stack too deep
            // 调整后的余额：扣除 0.3% 手续费
            // balanceAdjusted = balance * 1000 - amountIn * 3
            // 相当于 balanceAdjusted = (reserve - amountOut) * 1000 + amountIn * 997
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));

            // K 值恒定公式检查： (x * y) >= k
            // 使用 1000^2 修正来处理手续费乘数
            require(
                balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000 ** 2),
                'UniswapV2: K'
            );
        }

        _update(balance0, balance1, _reserve0, _reserve1); // 更新储备量
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // 强制余额与储备量匹配
    // 强制平衡：当真实余额 > 储备量时（例如有人向合约转账但未调用 mint），将多余的余额转给 to
    // @param to 接收多余代币的地址
    function skim(address to) external lock {
        address _token0 = token0; // 节省 gas
        address _token1 = token1; // 节省 gas
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // 强制储备量与余额匹配（当储备量与余额不一致时调用，通常用于纠正数据）
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
