// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import "forge-std/console.sol";

import "./IModule.sol";
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
import "v3-periphery/interfaces/external/IWETH9.sol";

// base functionality for modules
abstract contract Module is IModule, Ownable, IUniswapV3SwapCallback {

    using SafeCast for uint256;

    uint256 constant Q64 = 2**64;
    uint256 constant Q96 = 2**96;

    // errors
    error SwapFailed();
    error SlippageError();
    error TWAPCheckFailed();
    error Unauthorized();
    error NotWETH();
    error EtherSendFailed();
    error NotEnoughHistory();

    NFTHolder public immutable holder;
    IWETH9 public immutable weth;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;
    IUniswapV3Factory public immutable factory;
    
    constructor(NFTHolder _holder) {
        INonfungiblePositionManager npm = _holder.nonfungiblePositionManager();
        holder = _holder;
        nonfungiblePositionManager = npm;
        weth = IWETH9(npm.WETH9());
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

    // helper method to get pool for token
    function _getTokensPoolLiquidityAndTicks(uint256 tokenId) internal view returns (address token0, address token1, IUniswapV3Pool pool, uint128 liquidity, int24 tick, int24 tickLower, int24 tickUpper) {
        uint24 fee;
        (,,token0, token1, fee, tickLower, tickUpper, liquidity, , , , ) = nonfungiblePositionManager.positions(tokenId);
        pool = _getPool(token0, token1, fee);
        (,tick,,,,,) = pool.slot0();
    }

    // get current pool price
    function _getPoolPriceX96(address token0, address token1, uint24 fee) internal view returns (uint256) {
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

    // gets twap tick from pool history if enough history available
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

    // checks for how many block pool is in given condition (below or above tick)
    function _checkNumberOfBlocks(IUniswapV3Pool pool, uint16 secondsUntilMax, uint8 checkIntervals, int24 checkTick, bool isAbove) internal view returns (uint8) {

        uint16 blockTime = secondsUntilMax / checkIntervals; 

        uint32[] memory secondsAgos = new uint32[](checkIntervals + 1);
        uint8 i;
        for (; i <= checkIntervals; i++) {
            secondsAgos[i] = i * blockTime;
        }

        int56 checkTickMul = int16(blockTime) * checkTick;

        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            i = 0;
            for (; i < checkIntervals; i++) {
                if (isAbove) {
                    if ((tickCumulatives[i] - tickCumulatives[i + 1]) <= checkTickMul) {
                        return i;
                    }
                } else {
                    if ((tickCumulatives[i] - tickCumulatives[i + 1]) >= checkTickMul) {
                        return i;
                    }
                }
            }
        } catch {
            revert NotEnoughHistory();
        }

        return checkIntervals;
    }

    // validate if swap can be done with specified oracle parameters - if not possible reverts
    // if possible returns minAmountOut
    function _validateSwap(bool swap0For1, uint256 amountIn, IUniswapV3Pool pool, uint32 twapPeriod, uint32 maxTickDifference, uint64 maxPriceDifferenceX64) internal view returns (uint256 amountOutMin, uint160 sqrtPriceX96, uint256 priceX96) {
        
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
    function _swap(address swapRouter, IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 amountOutMin, bytes memory swapData) internal returns (uint256 amountInDelta, uint256 amountOutDelta) {
        if (amountIn > 0 && swapData.length > 0) {
            uint256 balanceInBefore = tokenIn.balanceOf(address(this));
            uint256 balanceOutBefore = tokenOut.balanceOf(address(this));

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

            uint256 balanceInAfter = tokenIn.balanceOf(address(this));
            uint256 balanceOutAfter = tokenOut.balanceOf(address(this));

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
    function _poolSwap(IUniswapV3Pool pool, address token0, address token1, uint24 fee, bool zeroForOne, uint256 amountIn, uint256 minAmountOut) internal returns (uint256 amountOut) {
        
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

    // swap callback function where amount for swap is payed - @inheritdoc IUniswapV3SwapCallback
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

    // transfers token (or unwraps WETH and sends ETH)
    function _transferToken(address to, IERC20 token, uint256 amount, bool unwrap) internal {
        if (address(weth) == address(token) && unwrap) {
            weth.withdraw(amount);
            (bool sent, ) = to.call{value: amount}("");
            if (!sent) {
                revert EtherSendFailed();
            }
        } else {
            SafeERC20.safeTransfer(token, to, amount);
        }
    }

    // needed for WETH unwrapping
    receive() external payable {
        if (msg.sender != address(weth)) {
            revert NotWETH();
        }
    }

    // IModule default empty implementations
    function addToken(uint256 tokenId, address, bytes calldata data) override virtual onlyHolder external { }
    function withdrawToken(uint256 tokenId, address) override virtual onlyHolder external { }
    function checkOnCollect(uint256 tokenId, address, uint128 liquidity, uint256, uint256) override virtual external  { }
    function decreaseLiquidityAndCollectCallback(uint256 tokenId, uint256 amount0, uint256 amount1, bytes calldata data) override virtual external returns (bytes memory returnData) { }
}