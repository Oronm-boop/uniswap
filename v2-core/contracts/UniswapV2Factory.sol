pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) public getPair; // 通过两个代币地址查找到 Pair 地址的映射
    address[] public allPairs; // 存储所有已创建 Pair 地址的数组

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        // 校验：两个代币地址不能相同
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        // 排序：确保 token0 小于 token1，保证地址顺序的一致性
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // 校验：token0 不能是零地址
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        // 校验：确保该交易对尚未存在
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient

        // 获取 UniswapV2Pair 合约的字节码
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        // 计算 salt：使用两个代币地址打包后哈希，用于 create2 确定性地址计算
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        // 使用 create2 汇编指令部署合约
        // create2 允许我们在部署前就预测出合约地址
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        // 初始化 Pair 合约，设置 token0 和 token1
        IUniswapV2Pair(pair).initialize(token0, token1);

        // 更新映射，记录新创建的 Pair 地址（双向记录）
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        // 将新 Pair 地址加入数组
        allPairs.push(pair);

        // 触发交易对创建事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
