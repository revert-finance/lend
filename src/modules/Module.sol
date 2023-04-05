// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/console.sol";

import "./IModule.sol";
import "../IHolder.sol";

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { SafeCast as OZSafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/FullMath.sol";
import "v3-core/libraries/TickMath.sol";
import 'v3-core/libraries/SafeCast.sol';

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "v3-periphery/interfaces/external/IWETH9.sol";

// base functionality for modules
abstract contract Module is IModule, Ownable {

    uint256 constant Q64 = 2**64;
    uint256 constant Q96 = 2**96;

    // errors
    error HolderAlreadySet();
    error SwapFailed();
    error SlippageError();
    error TWAPCheckFailed();
    error Unauthorized();
    error NotWETH();
    error EtherSendFailed();
    error NotEnoughHistory();

    IHolder public holder;
    IWETH9 public immutable weth;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;
    IUniswapV3Factory public immutable factory;
    
    constructor(INonfungiblePositionManager npm) {
        nonfungiblePositionManager = npm;
        weth = IWETH9(npm.WETH9());
        factory = IUniswapV3Factory(npm.factory());
    }

    // sets holder contract as soon as deployed
    function setHolder(IHolder _holder) onlyOwner external {
        if (address(holder) != address(0)) {
            revert HolderAlreadySet();
        }
        holder = _holder;
    }

    // used to check if a valid caller
    modifier onlyHolder(uint tokenId) {
        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        // if position in holder contract - must be called from there
        if (msg.sender != owner) {
            revert Unauthorized();
        }
        _;
    }

    // helper to get owner of position
    function _getOwner(uint tokenId) internal returns (address owner) {
        IHolder _holder = holder;
        if (address(_holder) != address(0)) {
            owner = _holder.tokenOwners(tokenId);
        }
        if (owner == address(0)) {
            owner = nonfungiblePositionManager.ownerOf(tokenId);
        }
    }

    // decrease liquidity and collect
    // if this module has an assigned holder contract and position is in holder - holder must do decreaseLiquidityAndCollect
    function _decreaseLiquidityAndCollect(IHolder.DecreaseLiquidityAndCollectParams memory params) internal returns (uint256 amount0, uint256 amount1, bytes memory callbackReturnData) {
        
        IHolder _holder = holder;

        // if position is in holder - holder is responsible
        if (nonfungiblePositionManager.ownerOf(params.tokenId) == address(_holder)) {
            _holder.decreaseLiquidityAndCollect(params);
        } else {
            if (params.liquidity > 0) {
                (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams(
                        params.tokenId,
                        params.liquidity,
                        params.amount0Min,
                        params.amount1Min,
                        params.deadline
                    )
                );
            }

            (amount0, amount1) = nonfungiblePositionManager.collect(
                INonfungiblePositionManager.CollectParams(
                    params.tokenId,
                    params.unwrap ? address(this) : params.recipient,
                    amount0 + params.amountFees0Max >= type(uint128).max ? type(uint128).max : OZSafeCast.toUint128(amount0 + params.amountFees0Max),
                    amount1 + params.amountFees1Max >= type(uint128).max ? type(uint128).max : OZSafeCast.toUint128(amount1 + params.amountFees1Max)
                )
            );

            // if needs unwrapping - tokens are first recieved in this contract and then resent
            if (params.unwrap) {
                (,,address token0, address token1, , , , , , , , ) =  nonfungiblePositionManager.positions(params.tokenId);
                if (amount0 > 0) {
                    _transferToken(params.recipient, IERC20(token0), amount0, true);
                }
                if (amount1 > 0) {
                    _transferToken(params.recipient, IERC20(token1), amount1, true);
                }
            }

            callbackReturnData = decreaseLiquidityAndCollectCallback(params.tokenId, amount0, amount1, params.callbackData);
        }
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
    // NOTE: can be only called from (partially) trusted context (nft owner / contract owner / operator) because otherwise swapData can be manipulated to return always amountOutMin
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

    // transfers token (or unwraps WETH and sends ETH)
    function _transferToken(address to, IERC20 token, uint256 amount, bool unwrap) internal {
        if (address(weth) == address(token) && unwrap) {
            weth.withdraw(amount);
            if (to != address(this)) {
                (bool sent, ) = to.call{value: amount}("");
                if (!sent) {
                    revert EtherSendFailed();
                }
            }
        } else {
            if (to != address(this)) {
                SafeERC20.safeTransfer(token, to, amount);
            }
        }
    }

    // needed for WETH unwrapping
    receive() external payable {
        if (msg.sender != address(weth)) {
            revert NotWETH();
        }
    }

    // IModule default empty implementations
    function addToken(uint256 tokenId, address, bytes calldata data) override virtual external { }
    function withdrawToken(uint256 tokenId, address) override virtual external { }
    function checkOnCollect(uint256 tokenId, address, uint128 liquidity, uint256, uint256) override virtual external  { }
    function decreaseLiquidityAndCollectCallback(uint256 tokenId, uint256 amount0, uint256 amount1, bytes memory data) override virtual public returns (bytes memory returnData) { }
}