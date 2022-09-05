// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './external/uniswap/v3-core/libraries/TickMath.sol';

contract Contract {

    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160 sqrtPriceX96) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    function getTickAtSqrtRatio(uint160 sqrtPriceX96) external pure returns (int24 tick) {
        return TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

}
