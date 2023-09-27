// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "v3-core/libraries/FullMath.sol";
import "v3-core/libraries/SwapMath.sol";
import "v3-core/libraries/SqrtPriceMath.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/TickBitmap.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";

import "v3-periphery/libraries/PoolAddress.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Logic to calculate swaps for adding exact amounts to UniswapV3 pools
/// @notice Uses tick liquidity data to calculate exact amounts
library SwapAndAddLogic {

    uint256 internal constant Q96 = 2 ** 96; 
    uint256 internal constant MAX_FEE = 1e6;

    error Unauthorized();
    error TickError();
    error Overflow();

    struct SwapParams {
        address factory; 
        address token0;
        address token1; 
        uint24 fee;
        uint256 amount0;
        uint256 amount1;
        int24 tickLower;
        int24 tickUpper;
    }

    // execute swap on pool
    // amounts must be available on the contract for both tokens
    // caller must implement UniswapV3SwapCallback
    function _poolSwapForRange(SwapParams memory params) internal returns (uint256 amount0Final, uint256 amount1Final) {
        IUniswapV3Pool pool = _getPool(params.factory, params.token0, params.token1, params.fee);

        amount0Final = params.amount0;
        amount1Final = params.amount1;

        (bool swap0For1, uint256 amountIn,,) = _calculate(params.amount0, params.amount1, pool, params.tickLower, params.tickUpper);
            
        if (amountIn > 0) {
            (int256 amount0Delta, int256 amount1Delta) = pool.swap(
                address(this),
                swap0For1,
                int256(amountIn),
                (swap0For1 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1),
                abi.encode(swap0For1 ? params.token0 : params.token1, swap0For1 ? params.token1 : params.token0, params.fee));
            amount0Final = swap0For1 ? amount0Final - uint256(amount0Delta) : amount0Final + uint256(-amount0Delta);
            amount1Final = swap0For1 ? amount1Final + uint256(-amount1Delta) : amount1Final - uint256(amount1Delta);
        }
    }

    // calculate optimized swap - to add max amount of tokens after swap in the same pool
    function _calculate(SwapParams memory params) internal view returns (bool swap0For1, uint256 amountIn, uint256 amountOut, uint160 sqrtPriceX96Final) {
        IUniswapV3Pool pool = _getPool(params.factory, params.token0, params.token1, params.fee);
        return _calculate(params.amount0, params.amount1, pool, params.tickLower, params.tickUpper);
    }

    struct CalculateState {
        int24 tick;
        uint128 liquidity;
        uint24 fee;
        int24 tickSpacing;
        uint256 amount0;
        uint256 amount1;
        uint160 sqrtPriceX96Lower;
        uint160 sqrtPriceX96Upper;
        uint160 finalSqrtPriceX96;
        uint256 amount0AfterSwap;
        uint256 amount1AfterSwap;
        uint160 afterSwapSqrtPriceX96;
        uint256 amountInSwap;
        uint256 amountOutSwap;
        int128 liquidityNet;
        int24 nextTick;
        uint160 nextTickSqrtPriceX96;
    }

    // calculate optimized swap - to add max amount of tokens after swap in the same pool
    function _calculate(uint256 amountAdd0, uint256 amountAdd1, IUniswapV3Pool pool, int24 tickLower, int24 tickUpper) internal view returns (bool swap0For1, uint256 amountIn, uint256 amountOut, uint160 sqrtPriceX96) {

        CalculateState memory state;

        // get pool state data
        (sqrtPriceX96, state.tick, state.fee, state.tickSpacing, state.liquidity) = _getPoolData(pool);

        // needs some amounts to run
        if (amountAdd0 > 0 || amountAdd0 > 0) {
            // validate ticks
            if (tickLower >= tickUpper || tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) {
                revert TickError();
            }

            // define current amount variables
            state.amount0 = amountAdd0;
            state.amount1 = amountAdd1;

            // get prices at target ticks
            state.sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(tickLower);
            state.sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(tickUpper);

            // check general swap direction
            swap0For1 = _checkSwap0For1(state.amount0, state.amount1, sqrtPriceX96, state.sqrtPriceX96Lower, state.sqrtPriceX96Upper);

            // traverse initialized tick ranges to find ideal amounts
            while (true) {
                state.nextTick = _getNextTick(pool, state.tick, state.tickSpacing, swap0For1);
                state.nextTickSqrtPriceX96 = TickMath.getSqrtRatioAtTick(state.nextTick);

                // calculate swap amounts reaching next tick
                (state.afterSwapSqrtPriceX96, state.amountInSwap, state.amountOutSwap,) = SwapMath.computeSwapStep(sqrtPriceX96, state.nextTickSqrtPriceX96, state.liquidity, int256(swap0For1 ? state.amount0 : state.amount1), state.fee);

                // calculate amounts after swap
                state.amount0AfterSwap = swap0For1 ? state.amount0 - state.amountInSwap : state.amount0 + state.amountOutSwap;
                state.amount1AfterSwap = swap0For1 ? state.amount1 + state.amountOutSwap : state.amount1 - state.amountInSwap;

                // check the situation at this point
                bool nextSwap0For1 = _checkSwap0For1(state.amount0AfterSwap, state.amount1AfterSwap, state.afterSwapSqrtPriceX96, state.sqrtPriceX96Lower, state.sqrtPriceX96Upper);

                // if direction changed - the optimal solution lies between tick and nextTick
                if (swap0For1 != nextSwap0For1) {
                    // calculates final price
                    state.finalSqrtPriceX96 = _calculateFinalPrice(state.liquidity, swap0For1, state.amount0, state.amount1, sqrtPriceX96, state.sqrtPriceX96Lower, state.sqrtPriceX96Upper, state.fee);
                    if (swap0For1) {
                        amountIn = amountAdd0 - state.amount0 + SqrtPriceMath.getAmount0Delta(sqrtPriceX96, state.finalSqrtPriceX96, state.liquidity, true) * MAX_FEE / (MAX_FEE - state.fee);
                        amountOut = state.amount1 - amountAdd1 + SqrtPriceMath.getAmount1Delta(sqrtPriceX96, state.finalSqrtPriceX96, state.liquidity, false);
                    } else {
                        amountIn = amountAdd1 - state.amount1 + SqrtPriceMath.getAmount1Delta(sqrtPriceX96, state.finalSqrtPriceX96, state.liquidity, true) * MAX_FEE / (MAX_FEE - state.fee);
                        amountOut = state.amount0 - amountAdd0 + SqrtPriceMath.getAmount0Delta(sqrtPriceX96, state.finalSqrtPriceX96, state.liquidity, false);
                    }
                    sqrtPriceX96 = state.finalSqrtPriceX96;
                    return (swap0For1, amountIn, amountOut, sqrtPriceX96);
                } else {
                    // if all swapped
                    if (state.afterSwapSqrtPriceX96 != state.nextTickSqrtPriceX96) {
                        amountIn = swap0For1 ? amountAdd0 : amountAdd1;
                        amountOut = swap0For1 ? state.amount1AfterSwap - amountAdd1 : state.amount0AfterSwap - amountAdd0;
                        sqrtPriceX96 = state.afterSwapSqrtPriceX96;
                        return (swap0For1, amountIn, amountOut, sqrtPriceX96);
                    }
                }

                (,state.liquidityNet,,,,,,) = pool.ticks(state.nextTick);
                state.liquidity = state.liquidityNet > 0 ? state.liquidity + uint128(state.liquidityNet) : uint128(int128(state.liquidity) + state.liquidityNet);
                state.tick = state.nextTick;
                sqrtPriceX96 = state.nextTickSqrtPriceX96;
                state.amount0 = state.amount0AfterSwap;
                state.amount1 = state.amount1AfterSwap;
            }
        }
    }

    // swap callback function where amount for swap is payed
    function _uniswapV3SwapCallback(address factory, int256 amount0Delta, int256 amount1Delta, bytes calldata data) internal {

        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported

        // check if really called from pool
        (address tokenIn, address tokenOut, uint24 fee) = abi.decode(data, (address, address, uint24));
        if (address(_getPool(factory, tokenIn, tokenOut, fee)) != msg.sender) {
            revert Unauthorized();
        }

        // transfer needed amount of tokenIn
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        SafeERC20.safeTransfer(IERC20(tokenIn), msg.sender, amountToPay);
    }

    // helper method to get pool for token
    function _getPool(address factory, address tokenA, address tokenB, uint24 fee) internal view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(PoolAddress.computeAddress(factory, PoolAddress.getPoolKey(tokenA, tokenB, fee)));
    }

    // get all needed pool data
    function _getPoolData(IUniswapV3Pool pool) private view returns (uint160 sqrtPriceX96, int24 tick, uint24 fee, int24 tickSpacing, uint128 liquidity) {
        (sqrtPriceX96, tick,,,,,) = pool.slot0();
        fee = pool.fee();
        tickSpacing = pool.tickSpacing();
        liquidity = pool.liquidity();
    }

    // check in which direction the swap needs to be done - given current amounts and price 
    function _checkSwap0For1(
        uint256 amount0,
        uint256 amount1,
        uint256 sqrtPriceX96,
        uint256 sqrtPriceX96Lower,
        uint256 sqrtPriceX96Upper
    ) private pure returns (bool) {
        if (sqrtPriceX96 <= sqrtPriceX96Lower) return false;
        else if (sqrtPriceX96 >= sqrtPriceX96Upper) return true;
        else
            return
                FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, Q96), sqrtPriceX96 - sqrtPriceX96Lower, Q96) >
                FullMath.mulDiv(amount1, sqrtPriceX96Upper - sqrtPriceX96, sqrtPriceX96Upper);
    }

    // logic copied from TickBitmap.sol (nextInitializedTickWithinOneWord) - but adjusted to search in multiple words
    function _getNextTick(IUniswapV3Pool pool, int24 tick, int24 tickSpacing, bool swap0For1) private view returns (int24 nextTick) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity

        int16 wordPos = int16((swap0For1 ? compressed : compressed + 1) >> 8);
        uint8 bitPos = uint8(int8((swap0For1 ? compressed : compressed + 1) % 256));

        uint256 ticksWord;

        while (true) {
             ticksWord = pool.tickBitmap(wordPos);

             if (swap0For1) {
                // all the 1s at or to the right of the current bitPos
                uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
                uint256 masked = ticksWord & mask;

                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                if (masked != 0) {
                    return (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing;
                } else {
                    wordPos--;
                    bitPos = type(uint8).max;
                }
            } else {
                // all the 1s at or to the left of the bitPos
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = ticksWord & mask;

                // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
                if (masked != 0) {
                    return (compressed + 1 + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing;
                } else {
                    wordPos++;
                    bitPos = 0;
                }
            }
        }
    }

    struct CalculateFinalPriceState {
        uint256 nonFee;
        uint256 liquidityX96;
        uint256 x0;
        uint256 x1;
        uint256 y;
    }

    // calculates the final price which is reached after swapping optimal amount so all tokens can be added without left-over tokens
    function _calculateFinalPrice(uint256 liquidity, bool swap0For1, uint256 amount0, uint256 amount1, uint256 sqrtPriceStartX96, uint256 sqrtRatioLowerX96, uint256 sqrtRatioUpperX96, uint256 fee) private pure returns (uint160 sqrtPriceEndX96) {
        
        CalculateFinalPriceState memory state;

        // calculate needed values
        state.nonFee = MAX_FEE - fee;
        state.liquidityX96 = liquidity << 96;

        unchecked {
            if (swap0For1) {
                state.x0 = ((amount0 + (state.liquidityX96 * MAX_FEE) / (state.nonFee * sqrtPriceStartX96)) - (state.liquidityX96 / sqrtRatioUpperX96)) << 1;
                state.x1 = (amount1 + FullMath.mulDiv(liquidity, sqrtPriceStartX96, Q96) - FullMath.mulDiv(liquidity, (MAX_FEE * sqrtRatioLowerX96) / state.nonFee, Q96)) << 1;
                state.y = FullMath.mulDiv((amount0 + (state.liquidityX96 * MAX_FEE) / (state.nonFee * sqrtPriceStartX96)), sqrtRatioLowerX96, Q96) + ((fee * liquidity) / state.nonFee) - FullMath.mulDiv(amount1 + FullMath.mulDiv(liquidity, sqrtPriceStartX96, Q96), Q96, sqrtRatioUpperX96);
                if (state.x0 < amount0) {
                    revert Overflow();
                }
            } else {
                state.x0 = ((amount0 + state.liquidityX96 / sqrtPriceStartX96) - (state.liquidityX96 * MAX_FEE / (state.nonFee * sqrtRatioUpperX96))) << 1;
                state.x1 = ((amount1 + FullMath.mulDiv(liquidity, (MAX_FEE * sqrtPriceStartX96) / state.nonFee, Q96)) - FullMath.mulDiv(liquidity, sqrtRatioLowerX96, Q96)) << 1;
                state.y = FullMath.mulDiv(amount0 + state.liquidityX96 / sqrtPriceStartX96, sqrtRatioLowerX96, Q96) - (fee * liquidity / state.nonFee) - FullMath.mulDiv((amount1 + FullMath.mulDiv(liquidity, (MAX_FEE * sqrtPriceStartX96) / state.nonFee, Q96)), Q96, sqrtRatioUpperX96);
                if (state.x1 < amount1) {
                    revert Overflow();
                }
            }

            uint256 sqrtPriceEnd = Math.sqrt(state.x0 * state.x1 + state.y * state.y) + state.y;
            uint x0 = state.x0;
            assembly {
                sqrtPriceEndX96 := sdiv(shl(96, sqrtPriceEnd), x0)
            }
        }
        
        // fix wrong price in special cases
        if (swap0For1 && sqrtPriceEndX96 > sqrtPriceStartX96 || !swap0For1 && sqrtPriceEndX96 < sqrtPriceStartX96) {
            sqrtPriceEndX96 = uint160(sqrtPriceStartX96);
        }
    }
}