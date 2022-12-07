// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import "forge-std/console.sol";

import "../NFTHolder.sol";

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/FullMath.sol";
import "v3-core/libraries/TickMath.sol";
import 'v3-core/libraries/SafeCast.sol';
import 'v3-core/interfaces/callback/IUniswapV3SwapCallback.sol';

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

// base functionality for modules
contract Module is Ownable, IUniswapV3SwapCallback {

    using SafeCast for uint256;

    uint256 constant Q64 = 2**64;
    uint256 constant Q96 = 2**96;

    // errors
    error SwapFailed();
    error SlippageError();
    error TWAPCheckFailed();
    error Unauthorized();

    NFTHolder public immutable holder;

    address public immutable weth;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;
    IUniswapV3Factory public immutable factory;
    
    constructor(NFTHolder _holder) {
        INonfungiblePositionManager npm = _holder.nonfungiblePositionManager();
        holder = _holder;
        nonfungiblePositionManager = npm;
        weth = npm.WETH9();
        factory = IUniswapV3Factory(npm.factory());
    }

    modifier onlyHolder() {
        if (msg.sender != address(holder)) {
            revert Unauthorized();
        }
        _;
    }

    // helper method to get pool for token
    function _getPool(address tokenA, address tokenB, uint24 fee) internal view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(PoolAddress.computeAddress(address(factory), PoolAddress.getPoolKey(tokenA, tokenB, fee)));
    }

    function _getPoolPrice(address token0, address token1, uint24 fee) internal view returns (uint) {
        IUniswapV3Pool pool = _getPool(token0, token1, fee);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
    }

    // Checks if there was not more tick difference
    // returns false if not enough data available or tick difference >= maxDifference
    function _hasMaxTWAPTickDifference(IUniswapV3Pool pool, uint32 twapPeriod, int24 currentTick, uint32 maxDifference) internal view returns (bool) {
        (int24 twapTick, bool twapOk) = _getTWAPTick(pool, twapPeriod);
        if (twapOk) {
            return twapTick > currentTick && (uint48(int48(twapTick - currentTick)) < maxDifference) || twapTick <= currentTick && (uint48(int48(twapTick - currentTick)) < maxDifference);
        } else {
            return false;
        }
    }

    function _getTWAPTick(IUniswapV3Pool pool, uint32 twapPeriod) internal view returns (int24, bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0; // from (before)
        secondsAgos[1] = twapPeriod; // from (before)

        // pool observe may fail when there is not enough history available
        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            return (int24((tickCumulatives[0] - tickCumulatives[1]) / int56(uint56(twapPeriod))), true);
        } catch {
            return (0, false);
        } 
    }

    // validate if swap can be done with specified oracle parameters - if not possible reverts
    // if possible returns minAmountOut
    function _validateSwap(bool swap0For1, uint amountIn, IUniswapV3Pool pool, uint32 twapPeriod, uint32 maxTickDifference, uint64 maxPriceDifferenceX64) internal view returns (uint amountOutMin, uint160 sqrtPriceX96, uint priceX96) {
        
        // get current price and tick
        int24 currentTick;
        
        (sqrtPriceX96,currentTick,,,,,) = pool.slot0();

        // check if current tick not too far from TWAP
        if (!_hasMaxTWAPTickDifference(pool, twapPeriod, currentTick, maxTickDifference)) {
            revert TWAPCheckFailed();
        }

        // calculate min output price price and percentage
        priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (swap0For1) {
            amountOutMin = FullMath.mulDiv(amountIn * (Q64 - maxPriceDifferenceX64), priceX96, Q96 * Q64);
        } else {
            amountOutMin = FullMath.mulDiv(amountIn * (Q64 - maxPriceDifferenceX64), Q96, priceX96 * Q64);
        }
    }

    // general swap function which uses external router with off-chain calculated swap instructions
    // does price difference check with amountOutMin param (calculated based on oracle verified price)
    // NOTE: can be only called from trusted context (nft owner / contract owner) because otherwise swapData can be manipulated to return always amountOutMin
    // returns new token amounts after swap
    function _swap(address swapRouter, IERC20 tokenIn, IERC20 tokenOut, uint amountIn, uint amountOutMin, bytes memory swapData) internal returns (uint amountInDelta, uint256 amountOutDelta) {
        if (amountIn > 0 && swapData.length > 0) {
            uint balanceInBefore = tokenIn.balanceOf(address(this));
            uint balanceOutBefore = tokenOut.balanceOf(address(this));

            // get router specific swap data
            (address allowanceTarget, bytes memory data) = abi.decode(swapData, (address, bytes));

            // approve needed amount
            tokenIn.approve(allowanceTarget, amountIn);

            // execute swap
            (bool success,) = swapRouter.call(data);
            if (!success) {
                revert SwapFailed();
            }

            // remove any remaining allowance
            tokenIn.approve(allowanceTarget, 0);

            uint balanceInAfter = tokenIn.balanceOf(address(this));
            uint balanceOutAfter = tokenOut.balanceOf(address(this));

            amountInDelta = balanceInBefore - balanceInAfter;
            amountOutDelta = balanceOutAfter - balanceOutBefore;

            // amountMin slippage check
            if (amountOutDelta < amountOutMin) {
                revert SlippageError();
            }
        }
    }

    // general swap function which uses given pool to swap amount available in the contract
    // returns new token amounts after swap
    function _poolSwap(IUniswapV3Pool pool, address token0, address token1, uint24 fee, bool zeroForOne, uint amountIn, uint minAmountOut) internal returns (uint amountOut) {
        
        (int256 amount0, int256 amount1) = pool.swap(
                address(this),
                zeroForOne,
                amountIn.toInt256(),
                (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1),
                abi.encode(zeroForOne ? token0 : token1, zeroForOne ? token1 : token0, fee)
            );

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));

        if (amountOut < minAmountOut) {
            revert SlippageError();
        }
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {

        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported

        // check if really called from pool
        (address tokenIn, address tokenOut, uint24 fee) = abi.decode(data, (address, address, uint24));
        if (address(_getPool(tokenIn, tokenOut, fee)) != msg.sender) {
            revert Unauthorized();
        }

        // transfer needed amount of tokenIn
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        SafeERC20.safeTransfer(IERC20(tokenIn), msg.sender, amountToPay);
    }
}