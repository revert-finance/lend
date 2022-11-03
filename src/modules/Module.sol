// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../NFTHolder.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/FullMath.sol";

import 'v3-periphery/libraries/PoolAddress.sol';

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// base functionality for modules
contract Module is Ownable {

    uint256 constant Q16 = 2**16;
    uint256 constant Q64 = 2**64;
    uint256 constant Q96 = 2**96;

    // errors
    error SwapFailed();
    error SlippageError();
    error TWAPCheckFailed();

    // events
    event SwapRouterUpdated(address account, address swapRouter);

    NFTHolder public immutable holder;

    address public immutable weth;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;
    IUniswapV3Factory public immutable factory;
    address public swapRouter;
    
    constructor(NFTHolder _holder, address _swapRouter) {
        INonfungiblePositionManager npm = _holder.nonfungiblePositionManager();
        holder = _holder;
        nonfungiblePositionManager = npm;
        weth = npm.WETH9();
        factory = IUniswapV3Factory(npm.factory());
        swapRouter = _swapRouter;
    }

    /**
     * @notice Management method to change swap router for this module(onlyOwner)
     * @param _swapRouter new swap router
     */
    function setSwapRouter(address _swapRouter) external onlyOwner {
        require(_swapRouter != address(0), "!swapRouter");
        swapRouter = _swapRouter;
        emit SwapRouterUpdated(msg.sender, _swapRouter);
    }

    // helper method to get pool for token
    function _getPool(address token0, address token1, uint24 fee) internal view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(PoolAddress.computeAddress(address(factory), PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee})));
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

        // TODO call in multiple slices and remove outliers for average calculation (to avoid manipulation if needed)

        // pool observe may fail when there is not enough history available
        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            return (int24((tickCumulatives[0] - tickCumulatives[1]) / int56(uint56(twapPeriod))), true);
        } catch {
            return (0, false);
        } 
    }

    // validate if swap can be done with specified oracle parameters - if not possible reverts
    // if possible returns minAmountOut
    function _validateSwap(bool swap0For1, uint amountIn, IUniswapV3Pool pool, uint32 twapPeriod, uint32 maxTickDifference, uint16 maxPriceDifferenceX16) internal view returns (uint amountOutMin, uint priceX96) {
        
        // get current price and tick
        (uint160 sqrtPriceX96,int24 currentTick,,,,,) = pool.slot0();
        
        // check if current tick not too far from TWAP
        if (!_hasMaxTWAPTickDifference(pool, twapPeriod, currentTick, maxTickDifference)) {
            revert TWAPCheckFailed();
        }

        // calculate min output price price and percentage
        priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (swap0For1) {
            amountOutMin = FullMath.mulDiv(amountIn * (Q16 - maxPriceDifferenceX16), priceX96, Q96 * Q16);
        } else {
            amountOutMin = FullMath.mulDiv(amountIn * (Q16 - maxPriceDifferenceX16), Q96, priceX96 * Q16);
        }
    }

    // general swap function which uses external router with off-chain calculated swap instructions
    // does slippage check with amountOutMin param
    // returns new token amounts after swap
    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint amountIn, uint amountOutMin, bytes memory swapData) internal returns (uint amountInDelta, uint256 amountOutDelta) {
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
}