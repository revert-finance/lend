// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "compound-protocol/Comptroller.sol";

import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FullMath.sol";
import 'v3-core/libraries/FixedPoint128.sol';

import "v3-periphery/libraries/LiquidityAmounts.sol";

import "../NFTHolder.sol";
import "./Module.sol";
import "./IModule.sol";


contract CollateralModule is Module, IModule {

    // errors 
    error PoolNotActive();
    error TokenNotActive();
    error NotAllowed();

    // current oracle
    IOracle public oracle;

    struct PoolConfig {
        bool isActive; // pool may be deposited
        uint64 collateralFactorX64;
    }

    mapping (address => PoolConfig) poolConfigs;

    struct TokenConfig {
        string symbol;
        uint8 decimals;
        bool isActive; // token may be deposited
    }

    mapping (address => TokenConfig) tokenConfigs;

    Comptroller public immutable comptroller;

    constructor(NFTHolder _holder, Comptroller _comptroller, IOracle _oracle) Module(_holder) {
        comptroller = _comptroller;
        oracle = _oracle;
    }

    // calculates collateral value of v3 position returning value in compound format -> USD with 6 digits
    function getCollateralValue(uint256 tokenId) external returns (uint) {
 
        (, , address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1) = nonfungiblePositionManager.positions(tokenId);

        TokenConfig storage config0 = tokenConfigs[token0];
        TokenConfig storage config1 = tokenConfigs[token1];

        // if there is any problem with the oracle - call must revert
        uint price0 = oracle.price(token0, config0.symbol);
        uint price1 = oracle.price(token1, config1.symbol);

        // get corresponding price
        uint oraclePriceX192 = FullMath.mulDiv(price0, Q96 * Q96, price1);
        uint160 oracleSqrtPriceX96 = uint160(_sqrt(oraclePriceX192));

        // calculate uncollected fees
        IUniswapV3Pool pool = _getPool(token0, token1, fee);
        (,int24 tick,,,,,) = pool.slot0();
        (uint256 fees0, uint256 fees1) = _getUncollectedFees(pool, tickLower, tickUpper, tick, feeGrowthInside0LastX128, feeGrowthInside1LastX128, liquidity);
        fees0 += tokensOwed0;
        fees1 += tokensOwed1;

        uint160 sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(tickUpper);
        
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(oracleSqrtPriceX96, sqrtPriceX96Lower, sqrtPriceX96Upper, liquidity);

        return ((amount0 + fees0) * price0 / (10 ** config0.decimals) + (amount1 + fees1) * price1 / (10 ** config1.decimals)) * poolConfigs[address(pool)].collateralFactorX64 / Q64;
    }

    function _getUncollectedFees(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, int24 tick, uint256 oldFeeGrowthInside0LastX128, uint256 oldFeeGrowthInside1LastX128, uint128 liquidity) internal view returns (uint256 fees0, uint256 fees1)
    {
        (uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = _getFeeGrowthInside(
            pool,
            tickLower,
            tickUpper,
            tick,
            pool.feeGrowthGlobal0X128(),
            pool.feeGrowthGlobal1X128()
        );

        fees0 = FullMath.mulDiv(feeGrowthInside0LastX128 - oldFeeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
        fees1 = FullMath.mulDiv(feeGrowthInside1LastX128 - oldFeeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
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

    function addToken(uint256 tokenId, address, bytes calldata data) override onlyHolder external {
        (, , address token0, address token1, uint24 fee , , , , , , ,) = nonfungiblePositionManager.positions(tokenId);

        IUniswapV3Pool pool = _getPool(token0, token1, fee);

        if (!poolConfigs[address(pool)].isActive) {
            revert PoolNotActive();
        }

        TokenConfig storage info0 = tokenConfigs[token0];
        TokenConfig storage info1 = tokenConfigs[token1];

        if (!info0.isActive || !info1.isActive) {
            revert TokenNotActive();
        }
    }

    function withdrawToken(uint256 tokenId, address owner) override onlyHolder external {
        (uint err,,uint shortfall) = comptroller.getAccountLiquidity(owner); // TODO comptroller.getHypotheticalAccountLiquidity(account); // create hypotetical function for removing token
        if (err > 0 || shortfall > 0) {
            revert NotAllowed();
        }
    }

    function checkOnCollect(uint256, address owner, uint128 , uint , uint ) override external {
        (uint err,,uint shortfall) = comptroller.getAccountLiquidity(owner);
        if (err > 0 || shortfall > 0) {
            revert NotAllowed();
        }
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            let y := x // We start y at x, which will help us make our initial estimate.

            z := 181 // The "correct" value is 1, but this saves a multiplication later.

            // This segment is to get a reasonable initial estimate for the Babylonian method. With a bad
            // start, the correct # of bits increases ~linearly each iteration instead of ~quadratically.

            // We check y >= 2^(k + 8) but shift right by k bits
            // each branch to ensure that if x >= 256, then y >= 256.
            if iszero(lt(y, 0x10000000000000000000000000000000000)) {
                y := shr(128, y)
                z := shl(64, z)
            }
            if iszero(lt(y, 0x1000000000000000000)) {
                y := shr(64, y)
                z := shl(32, z)
            }
            if iszero(lt(y, 0x10000000000)) {
                y := shr(32, y)
                z := shl(16, z)
            }
            if iszero(lt(y, 0x1000000)) {
                y := shr(16, y)
                z := shl(8, z)
            }

            // Goal was to get z*z*y within a small factor of x. More iterations could
            // get y in a tighter range. Currently, we will have y in [256, 256*2^16).
            // We ensured y >= 256 so that the relative difference between y and y+1 is small.
            // That's not possible if x < 256 but we can just verify those cases exhaustively.

            // Now, z*z*y <= x < z*z*(y+1), and y <= 2^(16+8), and either y >= 256, or x < 256.
            // Correctness can be checked exhaustively for x < 256, so we assume y >= 256.
            // Then z*sqrt(y) is within sqrt(257)/sqrt(256) of sqrt(x), or about 20bps.

            // For s in the range [1/256, 256], the estimate f(s) = (181/1024) * (s+1) is in the range
            // (1/2.84 * sqrt(s), 2.84 * sqrt(s)), with largest error when s = 1 and when s = 256 or 1/256.

            // Since y is in [256, 256*2^16), let a = y/65536, so that a is in [1/256, 256). Then we can estimate
            // sqrt(y) using sqrt(65536) * 181/1024 * (a + 1) = 181/4 * (y + 65536)/65536 = 181 * (y + 65536)/2^18.

            // There is no overflow risk here since y < 2^136 after the first branch above.
            z := shr(18, mul(z, add(y, 65536))) // A mul() is saved from starting z at 181.

            // Given the worst case multiplicative error of 2.84 above, 7 iterations should be enough.
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))

            // If x+1 is a perfect square, the Babylonian method cycles between
            // floor(sqrt(x)) and ceil(sqrt(x)). This statement ensures we return floor.
            // See: https://en.wikipedia.org/wiki/Integer_square_root#Using_only_integer_division
            // Since the ceil is rare, we save gas on the assignment and repeat division in the rare case.
            // If you don't care whether the floor or ceil square root is returned, you can remove this statement.
            z := sub(z, lt(div(x, z), z))
        }
    }
}



// TODO oracle proposals

interface IOracle {
    /**
     * @notice Get the official price for a token (if it fails - call must revert)
     * @param token The token to fetch the price of
     * @return Price denominated in USD, with 6 decimals
     */
    function price(address token, string calldata symbol) external view returns (uint);
}
 
interface IUniswapAnchoredView {
    function price(string calldata symbol) external view returns (uint256);
}

contract UniswapAnchoredViewWrapperOracle is IOracle {

    IUniswapAnchoredView public immutable uniswapAnchoredView;

    constructor(IUniswapAnchoredView _uniswapAnchoredView) {
        uniswapAnchoredView = _uniswapAnchoredView;
    }

    function price(address token, string calldata symbol) external view override returns (uint) {
        return uniswapAnchoredView.price(symbol);
    }
}

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );

    function decimals() external view returns (uint8);
}

contract ChainlinkOracle is IOracle, Ownable {

    uint8 constant COMPOUND_USD_DECIMALS = 6;

    error WrongFeedDecimals();
    error NoFeedConfigured();
    error FeedOutdated();
    error InvalidAnswer();

    struct FeedConfig {
        AggregatorV3Interface feed;
        uint32 maxFeedAge;
        uint8 decimals;
    }

    mapping(address => FeedConfig) feedConfigs;
    
    constructor() {
    }

    function setTokenFeed(address token, AggregatorV3Interface feed, uint32 maxFeedAge) external onlyOwner {
        uint8 decimals = feed.decimals();
        if (decimals < COMPOUND_USD_DECIMALS) {
            revert WrongFeedDecimals();
        }
        feedConfigs[token] = FeedConfig(feed, maxFeedAge, decimals);
    }

    function price(address token, string calldata symbol) external view override returns (uint) {
        FeedConfig storage feedConfig = feedConfigs[token];
        if (address(feedConfig.feed) == address(0)) {
            revert NoFeedConfigured();
        }

        // if stale data - exception 
        (, int256 answer, , uint256 updatedAt, ) = feedConfig.feed.latestRoundData();
        if (updatedAt + feedConfig.maxFeedAge < block.timestamp) {
            revert FeedOutdated();
        }
        if (answer < 0) {
            revert InvalidAnswer();
        }

        return uint256(answer) / ((feedConfig.decimals - COMPOUND_USD_DECIMALS) ** 10);
    }
}
