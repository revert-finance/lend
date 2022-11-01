// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "compound-protocol/ComptrollerInterface.sol";

import "v3-core/libraries/TickMath.sol";
import 'v3-core/libraries/FixedPoint128.sol';

import "v3-periphery/libraries/LiquidityAmounts.sol";

import "../NFTHolder.sol";
import "./Module.sol";
import "./IModule.sol";

contract CollateralModule is Module, IModule {

    mapping (address => Token) tokenConfigs;

    struct TokenConfig {
        address pricePool; // uniswap v3 pool (token/USDC)
        address priceFeed; // chainlink USD oracle
        uint8 priceFeedDecimals;
        uint64 collateralFactorX64;
    }

    ComptrollerInterface public immutable comptroller;

    constructor(NFTHolder _holder, address _swapRouter, ComptrollerInterface _comptroller) Module(_holder, _swapRouter) {
        comptroller = _comptroller;
    }

    function getCollateralValue(uint256 tokenId) external returns (uint) {

        (, , address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1) = nonfungiblePositionManager.positions(params.tokenId);

        TokenConfig storage info0 = tokenConfigs[token0];
        TokenConfig storage info1 = tokenConfigs[token1];

        (,int price0,,uint timestamp0,) = info0.priceFeed.latestRoundData();
        (,int price1,,uint timestamp1,) = info1.priceFeed.latestRoundData();


        IUniswapV3Pool pool = _getPool(token0, token1, fee);
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = pool.slot0();

        (uint256 fees0, uint256 fees1) = _getFees(pool. tickLower, tickUpper, tick, feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwed0, tokensOwed1, liquidity);

        uint160 sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(tickUpper);
        
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceX96Lower, sqrtPriceX96Upper, liquidity);

        return (amount0 + fees0) * price0 * info0.collateralFactorX64 / (10 ** info0.priceFeedDecimals * Q64) + (amount1 + fees1) * price1 * info1.collateralFactorX64 / (10 ** info1.decpriceFeedDecimalsimals * Q64);
    }

    function _getFees(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, int24 tick, uint256 oldFeeGrowthInside0LastX128, uint256 oldFeeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1, uint128 liquidity) internal view returns (uint256 fees0, uint256 fees1)
    {
        (uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = _getFeeGrowthInside(
            pool,
            tickLower,
            tickUpper,
            tick,
            pool.feeGrowthGlobal0X128(),
            pool.feeGrowthGlobal1X128()
        );

        fees0 = tokensOwed0 + FullMath.mulDiv(feeGrowthInside0LastX128 - oldFeeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
        fees1 = tokensOwed1 + FullMath.mulDiv(feeGrowthInside1LastX128 - oldFeeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
    }

    function _getFeeGrowthInside(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        (, , uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128, , , , ) = pool.ticks(tickLower);
        (, , uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128, , , , ) = pool.ticks(tickUpper);

        // calculate fee growth below
        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (tickCurrent >= tickLower) {
            feeGrowthBelow0X128 = lowerFeeGrowthOutside0X128;
            feeGrowthBelow1X128 = lowerFeeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128;
        }

        // calculate fee growth above
        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (tickCurrent < tickUpper) {
            feeGrowthAbove0X128 = upperFeeGrowthOutside0X128;
            feeGrowthAbove1X128 = upperFeeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upperFeeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upperFeeGrowthOutside1X128;
        }

        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }

    function addToken(uint256 tokenId, address, bytes calldata data) override external  {
        (, , address token0, address token1, , , , , , , ,) = nonfungiblePositionManager.positions(params.tokenId);

        TokenConfig storage info0 = tokenConfigs[token0];
        TokenConfig storage info1 = tokenConfigs[token1];

        if (info0.priceFeed == address(0)) {
            revert NotSupportedToken(token0);
        }
        if (info1.priceFeed == address(0)) {
            revert NotSupportedToken(token1);
        }
    }

    function withdrawToken(uint256 tokenId, address) override external {
        (uint err,,uint shortfall) = comptroller.getHypotheticalAccountLiquidity(account); // create hypotetical function for removing token
        if (err != 0 || shortfall > 0) {
            revert NotWithdrawable(tokenId);
        }
    }

    function checkOnCollect(uint256, address account, uint, uint) override external pure returns (bool) {
        (uint err,,uint shortfall) = comptroller.getAccountLiquidity(account);
        return err == 0 && shortfall == 0;
    }
}

error NotSupportedToken(address);
error NotWithdrawable(uint256);

