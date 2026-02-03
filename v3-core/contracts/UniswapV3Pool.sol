// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3Pool.sol';

import './NoDelegateCall.sol';

import './libraries/LowGasSafeMath.sol';
import './libraries/SafeCast.sol';
import './libraries/Tick.sol';
import './libraries/TickBitmap.sol';
import './libraries/Position.sol';
import './libraries/Oracle.sol';

import './libraries/FullMath.sol';
import './libraries/FixedPoint128.sol';
import './libraries/TransferHelper.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/SqrtPriceMath.sol';
import './libraries/SwapMath.sol';

import './interfaces/IUniswapV3PoolDeployer.sol';
import './interfaces/IUniswapV3Factory.sol';
import './interfaces/IERC20Minimal.sol';
import './interfaces/callback/IUniswapV3MintCallback.sol';
import './interfaces/callback/IUniswapV3SwapCallback.sol';
import './interfaces/callback/IUniswapV3FlashCallback.sol';

contract UniswapV3Pool is IUniswapV3Pool, NoDelegateCall {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override factory;
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override token0;
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override token1;
    /// @inheritdoc IUniswapV3PoolImmutables
    uint24 public immutable override fee;

    /// @inheritdoc IUniswapV3PoolImmutables
    int24 public immutable override tickSpacing;

    /// @inheritdoc IUniswapV3PoolImmutables
    uint128 public immutable override maxLiquidityPerTick;

    struct Slot0 {
        // 当前价格 (current price)
        // 以 Q64.96 格式表示的 sqrt(token1/token0)
        uint160 sqrtPriceX96;
        // 当前 tick (current tick)
        // 对应于当前价格的 tick 指数
        int24 tick;
        // 观察数组中最近一次更新的索引 (observation index)
        uint16 observationIndex;
        // 当前存储的观察数据的最大数量 (observation cardinality)
        // 初始只有 1 个，随时间推移或用户操作可增加
        uint16 observationCardinality;
        // 下一次观察数据扩容时的目标大小 (next observation cardinality)
        // 当写入新的观察数据时触发扩容
        uint16 observationCardinalityNext;
        // 协议费用的比例 (protocol fee)
        // 以分母形式表示 (1/x)%，即如果值为 4，则收取 1/4 = 25% 的交易手续费作为协议费
        uint8 feeProtocol;
        // 池子是否未锁定 (unlocked)
        // 用于防重入保护，true 表示未锁定，false 表示已锁定
        bool unlocked;
    }
    /// @inheritdoc IUniswapV3PoolState
    Slot0 public override slot0;

    /// @inheritdoc IUniswapV3PoolState
    // 全局每单位流动性的累计手续费 (token0)
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc IUniswapV3PoolState
    // 全局每单位流动性的累计手续费 (token1)
    uint256 public override feeGrowthGlobal1X128;

    // 累计的协议费用，以 token0/token1 数量为单位
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    /// @inheritdoc IUniswapV3PoolState
    ProtocolFees public override protocolFees;

    /// @inheritdoc IUniswapV3PoolState
    // 当前激活的流动性 (L)
    // 只有在当前 tick 范围内的流动性才会计入此处
    uint128 public override liquidity;

    /// @inheritdoc IUniswapV3PoolState
    mapping(int24 => Tick.Info) public override ticks;
    /// @inheritdoc IUniswapV3PoolState
    mapping(int16 => uint256) public override tickBitmap;
    /// @inheritdoc IUniswapV3PoolState
    mapping(bytes32 => Position.Info) public override positions;
    /// @inheritdoc IUniswapV3PoolState
    Oracle.Observation[65535] public override observations;

    /// @dev 互斥锁，用于保护池子免受重入攻击。
    /// 该修饰符也防止了在池子初始化之前调用某些函数。
    /// 由于我们在 mint、swap 和 flash 等操作中通过检查余额变动来判断支付状态，
    /// 因此必须在整个合约中强制执行防重入保护。
    modifier lock() {
        require(slot0.unlocked, 'LOK');
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    /// @dev 仅允许由 Factory 所有者调用的修饰符
    modifier onlyFactoryOwner() {
        require(msg.sender == IUniswapV3Factory(factory).owner());
        _;
    }

    constructor() {
        int24 _tickSpacing;
        (factory, token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters();
        tickSpacing = _tickSpacing;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    /// @dev 检查 tick 输入是否有效
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, 'TLU');
        require(tickLower >= TickMath.MIN_TICK, 'TLM');
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');
    }

    /// @dev 返回截断为 32 位的区块时间戳。
    /// 这里的截断是预期的行为，用于节省存储空间，32位时间戳可以使用到 2106 年。
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @dev 获取池子的 token0 余额
    /// @dev 此函数经过 Gas 优化，直接通过 staticcall 调用 balanceOf，
    /// 避免了 Solidity 默认通过 returndatasize 检查产生的额外开销。
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) = token0.staticcall(
            abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this))
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @dev 获取池子的 token1 余额
    /// @dev 同 balance0，Gas 优化版本
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) = token1.staticcall(
            abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this))
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    /// @notice 获取指定 tick 范围内的累计数据快照
    /// @dev 计算逻辑：范围内的值 = 总值 - 范围下限外的值 - 范围上限外的值
    /// 或者如果当前 tick 在范围内，则需要不同的计算方式，具体取决于初始化状态。
    function snapshotCumulativesInside(
        int24 tickLower,
        int24 tickUpper
    )
        external
        view
        override
        noDelegateCall
        returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside)
    {
        checkTicks(tickLower, tickUpper);

        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        {
            Tick.Info storage lower = ticks[tickLower];
            Tick.Info storage upper = ticks[tickUpper];
            bool initializedLower;
            (tickCumulativeLower, secondsPerLiquidityOutsideLowerX128, secondsOutsideLower, initializedLower) = (
                lower.tickCumulativeOutside,
                lower.secondsPerLiquidityOutsideX128,
                lower.secondsOutside,
                lower.initialized
            );
            require(initializedLower);

            bool initializedUpper;
            (tickCumulativeUpper, secondsPerLiquidityOutsideUpperX128, secondsOutsideUpper, initializedUpper) = (
                upper.tickCumulativeOutside,
                upper.secondsPerLiquidityOutsideX128,
                upper.secondsOutside,
                upper.initialized
            );
            require(initializedUpper);
        }

        Slot0 memory _slot0 = slot0;

        // 根据当前 tick 的位置，计算范围内的累计值
        // 核心思想：Position 中的累计值是"当前时刻"减去"上次更新时刻"的差值吗？
        // 不，这里的 Outside 变量存储的是"tick被穿越时"的历史累计值。
        // Inside = Global - OutsideLower - OutsideUpper 这种公式用于计算区间内的累积量。
        // 但需要根据当前 tick 相对于 tickLower 和 tickUpper 的位置做调整。

        if (_slot0.tick < tickLower) {
            // 情况 1: 当前 tick 在范围左侧 (tick < Lower < Upper)
            // 此时范围内的累计值 = LowerOutside - UpperOutside
            return (
                tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128,
                secondsOutsideLower - secondsOutsideUpper
            );
        } else if (_slot0.tick < tickUpper) {
            // 情况 2: 当前 tick 在范围内 (Lower <= tick < Upper)
            // 此时范围内的累计值 = Global - LowerOutside - UpperOutside
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                time,
                0,
                _slot0.tick,
                _slot0.observationIndex,
                liquidity,
                _slot0.observationCardinality
            );
            return (
                tickCumulative - tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityCumulativeX128 -
                    secondsPerLiquidityOutsideLowerX128 -
                    secondsPerLiquidityOutsideUpperX128,
                time - secondsOutsideLower - secondsOutsideUpper
            );
        } else {
            // 情况 3: 当前 tick 在范围右侧 (Lower < Upper <= tick)
            // 此时范围内的累计值 = UpperOutside - LowerOutside
            return (
                tickCumulativeUpper - tickCumulativeLower,
                secondsPerLiquidityOutsideUpperX128 - secondsPerLiquidityOutsideLowerX128,
                secondsOutsideUpper - secondsOutsideLower
            );
        }
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    /// @notice 查询历史数据
    function observe(
        uint32[] calldata secondsAgos
    )
        external
        view
        override
        noDelegateCall
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 扩容观察列表的容量
    function increaseObservationCardinalityNext(
        uint16 observationCardinalityNext
    ) external override lock noDelegateCall {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew = observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev 初始化函数，不加锁，因为它初始化 unlocked 状态
    /// @param sqrtPriceX96 初始价格
    function initialize(uint160 sqrtPriceX96) external override {
        require(slot0.sqrtPriceX96 == 0, 'AI');

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });

        emit Initialize(sqrtPriceX96, tick);
    }

    struct ModifyPositionParams {
        // 头寸拥有者的地址
        address owner;
        // 头寸的价格区间下限 tick
        int24 tickLower;
        // 头寸的价格区间上限 tick
        int24 tickUpper;
        // 流动性的变化量 (添加为正，移除为负)
        int128 liquidityDelta;
    }

    /// @dev 执行对头寸的修改
    /// @param params 头寸的详细信息以及要执行的流动性变化量
    /// @return position 一个存储指针，指向具有给定 owner 和 tick 范围的头寸信息
    /// @return amount0 池子应收取的 token0 数量（如果是负数，则表示池子应支付给接收者）
    /// @return amount1 池子应收取的 token1 数量（如果是负数，则表示池子应支付给接收者）
    function _modifyPosition(
        ModifyPositionParams memory params
    ) private noDelegateCall returns (Position.Info storage position, int256 amount0, int256 amount1) {
        checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0; // SLOAD 优化，将 slot0 读取到内存

        // 更新 tick 信息和 position 信息，返回更新后的 position 存储指针
        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            _slot0.tick
        );

        if (params.liquidityDelta != 0) {
            if (_slot0.tick < params.tickLower) {
                // 情况 1: 当前 tick 小于区间下限 (current tick < Lower < Upper)
                // 此时价格太低，整个区间都在当前价格的"右侧"（更高价格）。
                // 为了让价格上涨进入区间，需要买入 Token1 卖出 Token0？
                // 实际上，当价格低于区间时，区间内的流动性完全由 Token0 组成。
                // 为什么？因为在这个区间内卖出 Token0 可以换回 Token1，直到价格跌出区间变为全 Token0 可以在这里理解为：
                // 如果目前价格很低（tick 很小），说明 Token1 很便宜（或者 Token0 很贵）。
                // 要提供流动性支持更高价格范围，你需要提供 Token0。
                // 因此这里只计算 amount0Delta。
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // 情况 2: 当前 tick 在区间内部 (Lower <= current tick < Upper)
                // 此时流动性处于激活状态。
                uint128 liquidityBefore = liquidity; // SLOAD 优化

                // 写入观察记录，因为流动性发生变化会影响加权平均值
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                // 计算当前价格到区间上限所需的 Token0 数量
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                // 计算区间下限到当前价格所需的 Token1 数量
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96,
                    params.liquidityDelta
                );

                // 更新全局流动性 L
                liquidity = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta);
            } else {
                // 情况 3: 当前 tick 大于区间上限 (Lower < Upper <= current tick)
                // 此时价格太高，整个区间都在当前价格的"左侧"。
                // 意味着在这个价格区间内，所有的 Token0 都已经卖在更高价格换成了 Token1。
                // 区间内的流动性完全由 Token1 组成。
                // 因此这只需要计算 amount1Delta。
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /// @dev 获取并更新具有给定流动性变化的头寸
    /// @param owner 头寸持有者
    /// @param tickLower 区间下限
    /// @param tickUpper 区间上限
    /// @param liquidityDelta 流动性变化量
    /// @param tick 当前 tick，作为参数传入以避免重复读取
    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        position = positions.get(owner, tickLower, tickUpper);

        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128; // SLOAD 优化
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128; // SLOAD 优化

        // 如果我们需要更新 tick 累加器，则进行更新
        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                time,
                0,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );

            // 更新下限 tick 的信息
            // 这里的 maxLiquidityPerTick 检查确保了单个 tick 上的流动性不会溢出
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false,
                maxLiquidityPerTick
            );
            // 更新上限 tick 的信息
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true,
                maxLiquidityPerTick
            );

            // 如果 tick 的激活状态发生了变化（从有流动性变无，或反之），更新 bitmap
            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        // 计算区间内的手续费增长情况
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks.getFeeGrowthInside(
            tickLower,
            tickUpper,
            tick,
            _feeGrowthGlobal0X128,
            _feeGrowthGlobal1X128
        );

        // 更新 position 的流动性以及手续费追踪
        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        // 清除不再需要的 tick 数据以释放 Gas (Solidity 的 gas 仅在 SSTORE 0 时返还)
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall 通过 _modifyPosition 间接应用
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        require(amount > 0);
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(amount).toInt128()
            })
        );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        // 回调用户合约，要求支付代币
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        // 检查余额是否正确增加
        if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), 'M0');
        if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), 'M1');

        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        // 这里不需要 checkTicks，因为无效的 position 不会有非零的 tokensOwed
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        // 计算实际可借出的金额（不能超过 position.tokensOwed）
        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall 通过 _modifyPosition 间接应用
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: msg.sender,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(amount).toInt128()
            })
        );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            // 将移除流动性获得的代币增加到 tokensOwed 中，用户稍后需通过 collect 提取
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    struct SwapCache {
        // 输入代币的协议费用，以分母表示 (1/x)
        uint8 feeProtocol;
        // 交换开始时的流动性
        uint128 liquidityStart;
        // 当前区块时间戳
        uint32 blockTimestamp;
        // tick 累积值，仅在穿越已初始化的 tick 时计算
        int56 tickCumulative;
        // 每单位流动性的秒数累积值，仅在穿越已初始化的 tick 时计算
        uint160 secondsPerLiquidityCumulativeX128;
        // 是否已经计算并缓存了上述两个累积值
        bool computedLatestObservation;
    }

    // 交换的顶层状态，其结果将在结束时记录到存储中
    struct SwapState {
        // 剩余待交换的金额 (负数表示完全交换完成？不，amountSpecifiedRemaining 是剩余量)
        // exactInput: >0, exactOutput: <0
        int256 amountSpecifiedRemaining;
        // 已经计算出的输出/输入金额 (取反方向)
        int256 amountCalculated;
        // 当前的平方根价格
        uint160 sqrtPriceX96;
        // 当前价格对应的 tick
        int24 tick;
        // 输入代币的全局手续费增长总量
        uint256 feeGrowthGlobalX128;
        // 作为协议费用支付的输入代币数量
        uint128 protocolFee;
        // 当前激活的流动性
        uint128 liquidity;
    }

    struct StepComputations {
        // 本步骤开始时的价格
        uint160 sqrtPriceStartX96;
        // 交换方向上的下一个已初始化 tick
        int24 tickNext;
        // tickNext 是否已初始化
        bool initialized;
        // 下一个 tick 的平方根价格
        uint160 sqrtPriceNextX96;
        // 本步骤中消耗的输入金额
        uint256 amountIn;
        // 本步骤中产生的输出金额
        uint256 amountOut;
        // 本步骤中支付的手续费金额
        uint256 feeAmount;
    }

    /// @inheritdoc IUniswapV3PoolActions
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override noDelegateCall returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, 'AS');

        Slot0 memory slot0Start = slot0;

        require(slot0Start.unlocked, 'LOK');
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            'SPL'
        );

        slot0.unlocked = false;

        SwapCache memory cache = SwapCache({
            liquidityStart: liquidity,
            blockTimestamp: _blockTimestamp(),
            feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4),
            secondsPerLiquidityCumulativeX128: 0,
            tickCumulative: 0,
            computedLatestObservation: false
        });

        bool exactInput = amountSpecified > 0;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0Start.sqrtPriceX96,
            tick: slot0Start.tick,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            protocolFee: 0,
            liquidity: cache.liquidityStart
        });

        // 只要还有剩余待交换金额，且未达到价格限制，就继续交换
        // 这是一个循环，每次循环处理一个 tick 区间内的交换
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            // 在 tick bitmap 中寻找下一个已初始化的 tick
            // 这是 V3 相比 V2 的核心优化之一：跳过无流动性的 tick 区域，节省 gas
            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                tickSpacing,
                zeroForOne
            );

            // 确保不会超出最小/最大 tick 限制
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // 获取下一个 tick 的价格
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // 计算这一步的交换结果
            // 计算我们将交换到目标 tick，还是价格限制，还是耗尽输入金额
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            if (exactInput) {
                // 如果是固定输入，减少剩余输入量，增加计算出的输出量（负值递减）
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                // 如果是固定输出，增加剩余输出量（从负数向0趋近），增加计算出的输入量
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            // 如果开启了协议费用，计算应付金额
            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;
                state.protocolFee += uint128(delta);
            }

            // 更新全局与本次交换相关的代币手续费增长
            if (state.liquidity > 0)
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);

            // 如果我们到达了下一个 tick 的价格（说明要穿过这个 tick）
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // 只有当 tick 是初始化过的（有流动性添加/移除操作），才需要处理穿越逻辑
                if (step.initialized) {
                    // 如果这是第一次穿越 tick，需要初始化 oracle 数据
                    if (!cache.computedLatestObservation) {
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    // 穿越 tick，获取该 tick 上的净流动性变化
                    int128 liquidityNet = ticks.cross(
                        step.tickNext,
                        (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                        (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128),
                        cache.secondsPerLiquidityCumulativeX128,
                        cache.tickCumulative,
                        cache.blockTimestamp
                    );
                    // 如果是向左移动 (price decrease, zeroForOne)，我们需要反转流动性变化的符号
                    // 因为 liquidityNet 通常定义为 (upper - lower)，进入区间通常是增加，离开是减少
                    // 具体取决于方向
                    if (zeroForOne) liquidityNet = -liquidityNet;

                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }

                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // 如果价格变动了，但没有到达下一个 tick，我们需要重新计算当前 tick
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // 如果 tick 发生了变化，更新 oracle 和 slot0
        if (state.tick != slot0Start.tick) {
            (uint16 observationIndex, uint16 observationCardinality) = observations.write(
                slot0Start.observationIndex,
                cache.blockTimestamp,
                slot0Start.tick,
                cache.liquidityStart,
                slot0Start.observationCardinality,
                slot0Start.observationCardinalityNext
            );
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // 否则只更新价格
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // 如果流动性发生了变化，更新存储
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // 更新全局手续费和协议费用
        // 允许溢出，协议必须在手续费达到 type(uint128).max 之前提取
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }

        // 确定最终的 amount0 和 amount1
        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        // 执行转账和回调
        if (zeroForOne) {
            if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
        } else {
            if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
        }

        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        slot0.unlocked = true;
    }

    /// @inheritdoc IUniswapV3PoolActions
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override lock noDelegateCall {
        uint128 _liquidity = liquidity;
        require(_liquidity > 0, 'L');

        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();

        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        uint256 balance0After = balance0();
        uint256 balance1After = balance1();

        require(balance0Before.add(fee0) <= balance0After, 'F0');
        require(balance1Before.add(fee1) <= balance1After, 'F1');

        // 计算用户实际支付的费用（不仅仅是预期的 fee0/fee1，可能更多）
        uint256 paid0 = balance0After - balance0Before;
        uint256 paid1 = balance1After - balance1Before;

        if (paid0 > 0) {
            uint8 feeProtocol0 = slot0.feeProtocol % 16;
            uint256 fees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0;
            if (uint128(fees0) > 0) protocolFees.token0 += uint128(fees0);
            feeGrowthGlobal0X128 += FullMath.mulDiv(paid0 - fees0, FixedPoint128.Q128, _liquidity);
        }
        if (paid1 > 0) {
            uint8 feeProtocol1 = slot0.feeProtocol >> 4;
            uint256 fees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;
            if (uint128(fees1) > 0) protocolFees.token1 += uint128(fees1);
            feeGrowthGlobal1X128 += FullMath.mulDiv(paid1 - fees1, FixedPoint128.Q128, _liquidity);
        }

        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external override lock onlyFactoryOwner {
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10)) &&
                (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10))
        );
        uint8 feeProtocolOld = slot0.feeProtocol;
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function collectProtocol(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock onlyFactoryOwner returns (uint128 amount0, uint128 amount1) {
        amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested;
        amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;

        if (amount0 > 0) {
            if (amount0 == protocolFees.token0) amount0--; // 确保 slot 不被清除，节省 gas
            protocolFees.token0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            if (amount1 == protocolFees.token1) amount1--; // 确保 slot 不被清除，节省 gas
            protocolFees.token1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}
