// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/console.sol";


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
    error OracleDeviation();

    // current oracle
    IOracle public oracle;

    struct PoolConfig {
        bool isActive; // pool may be deposited
        uint64 collateralFactorX64;
        uint64 maxOracleSqrtDeviationX64; // reasonable value maybe 10%
    }

    mapping (address => PoolConfig) poolConfigs;

    struct TokenConfig {
        uint8 decimals;
        bool isActive; // token may be deposited
    }

    mapping (address => TokenConfig) tokenConfigs;

    Comptroller public immutable comptroller;

    constructor(NFTHolder _holder, Comptroller _comptroller, IOracle _oracle) Module(_holder) {
        comptroller = _comptroller;
        oracle = _oracle;
    }

    /// @notice Management method to configure a pool
    function setPoolConfig(address pool, PoolConfig calldata config) external onlyOwner {
        poolConfigs[pool] = config;
    }

    /// @notice Management method to configure a token
    function setTokenConfig(address token, bool isActive) external onlyOwner {
        uint8 decimals = IERC20Metadata(token).decimals();
        tokenConfigs[token] = TokenConfig(decimals, isActive);
    }

    /// @notice Management method to set oracle
    function setOracle(IOracle _oracle) external onlyOwner {
        oracle = _oracle;
    }

    struct PositionState {
        address token0;
        address token1;
        uint8 decimals0;
        uint8 decimals1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        IUniswapV3Pool pool;
    }

    // calculates collateral value of v3 position returning value in compound format -> USD with 6 digits
    // this function may revert if there is any error with oracle prices - this will disable borrowing / liquidations in connected compound
    function getCollateralValue(uint256 tokenId) external returns (uint) {
 
        PositionState memory position = _getPositionState(tokenId);

        (uint256 price0, uint256 price1, uint160 oracleSqrtPriceX96) = _getOraclePrice(position.token0, position.token1, position.decimals0, position.decimals1);

        (uint160 sqrtPriceX96, int24 tick,,,,,) = position.pool.slot0();

        // calculate position amounts (incl uncollected fees)
        (uint amount0, uint amount1) = _getAmounts(position, oracleSqrtPriceX96, tick);

        PoolConfig storage poolConfig = poolConfigs[address(position.pool)];

        // check for mayor difference between pool price and oracle price - if to big - revert
        uint priceSqrtRatioX64 = Q64 - (sqrtPriceX96 < oracleSqrtPriceX96 ? sqrtPriceX96 * Q64 / oracleSqrtPriceX96 : oracleSqrtPriceX96 * Q64 / sqrtPriceX96);
        if (priceSqrtRatioX64 > poolConfig.maxOracleSqrtDeviationX64) {
            revert OracleDeviation();
        }

        return _getUSDValue(position.decimals0, position.decimals1, amount0, amount1, price0, price1, poolConfig.collateralFactorX64);
    }

    function _getPositionState(uint256 tokenId) internal view returns (PositionState memory state) {
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = nonfungiblePositionManager.positions(tokenId);

        TokenConfig storage tokenConfig0 = tokenConfigs[token0];
        TokenConfig storage tokenConfig1 = tokenConfigs[token1];

        state.token0 = token0;
        state.token1 = token1;
        state.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        state.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        state.tickLower = tickLower;
        state.tickUpper = tickUpper;
        state.liquidity = liquidity;
        state.tokensOwed0 = tokensOwed0;
        state.tokensOwed1 = tokensOwed1;
        state.pool = _getPool(token0, token1, fee);
        state.decimals0 = tokenConfig0.decimals;
        state.decimals1 = tokenConfig1.decimals;
    }

    function _getUSDValue(uint8 decimals0, uint8 decimals1, uint amount0, uint amount1, uint price0, uint price1, uint64 collateralFactorX64) internal returns (uint) {
        return (amount0 * price0 / (10 ** decimals0) + amount1 * price1 / (10 ** decimals1)) * collateralFactorX64 / Q64;
    }   

    function _getAmounts(PositionState memory position, uint160 oracleSqrtPriceX96, int24 tick) internal returns (uint amount0, uint amount1) {
  
        (uint fees0, uint fees1) = _getUncollectedFees(position, tick);

        uint160 sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(position.tickLower);
        uint160 sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(position.tickUpper);        

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(oracleSqrtPriceX96, sqrtPriceX96Lower, sqrtPriceX96Upper, position.liquidity);

        amount0 += fees0;
        amount1 += fees1;
    }

    function _getOraclePrice(address token0, address token1, uint8 decimals0, uint8 decimals1) internal returns (uint price0, uint price1, uint160 oracleSqrtPriceX96) {
        price0 = oracle.price(token0);
        price1 = oracle.price(token1);

        uint oraclePriceX192 = FullMath.mulDiv(price0 * (10 ** decimals1), Q96 * Q96, price1 * (10 ** decimals0));
        oracleSqrtPriceX96 = uint160(_sqrt(oraclePriceX192));
    }

    function _getUncollectedFees(PositionState memory position, int24 tick) internal view returns (uint256 fees0, uint256 fees1)
    {
        (uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = _getFeeGrowthInside(
            position.pool,
            position.tickLower,
            position.tickUpper,
            tick,
            position.pool.feeGrowthGlobal0X128(),
            position.pool.feeGrowthGlobal1X128()
        );

        fees0 = FullMath.mulDiv(feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128, position.liquidity, FixedPoint128.Q128);
        fees1 = FullMath.mulDiv(feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128, position.liquidity, FixedPoint128.Q128);
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


interface IOracle {
    /**
     * @notice Get the official price for a token (if it fails - call must revert)
     * @param token The token to fetch the price of
     * @return Price denominated in USD, with 6 decimals
     */
    function price(address token) external view returns (uint);
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

    uint8 constant OUTPUT_USD_DECIMALS = 6; // needed by compound

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
        if (decimals < OUTPUT_USD_DECIMALS) {
            revert WrongFeedDecimals();
        }
        feedConfigs[token] = FeedConfig(feed, maxFeedAge, decimals);
    }

    function price(address token) external view override returns (uint) {
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

        return uint256(answer) / (10 ** (feedConfig.decimals - OUTPUT_USD_DECIMALS));
    }
}
