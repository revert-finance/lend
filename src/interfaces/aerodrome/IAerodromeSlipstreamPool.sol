// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IAerodromeSlipstreamPool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );

    function fee() external view returns (uint24);

    function positions(bytes32 key)
        external
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function observations(uint256 index)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityPostWriteX128, bool initialized);

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityPostWriteX128s);

    function tickSpacing() external view returns (int24);

    function token0() external view returns (address);
    function token1() external view returns (address);
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);

    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            int128 stakedLiquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            uint256 rewardGrowthOutsideX128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    function gauge() external view returns (address);
}
