// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../compound/ComptrollerInterface.sol";
import "../compound/Lens/CompoundLens.sol";

import "../compound/CErc20.sol";

import "../compound/PriceOracle.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";

import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FullMath.sol";
import 'v3-core/libraries/FixedPoint128.sol';

import "v3-periphery/libraries/LiquidityAmounts.sol";

import "./Module.sol";
import "./ICollateralModule.sol";

/// @title CollateralModule
/// @notice Module responsible for connection to Compound Fork, taking care collateral is checked after each liquidity/fee removal, supports lending of position when out of range, support seizing of collateral when liquidatable
/// can NOT be used together with LockModule (set blocking config)
contract CollateralModule is Module, ICollateralModule, ExponentialNoError {

    // errors 
    error PoolNotActive();
    error TokenNotActive();
    error NotAllowed();
    error OracleDeviation();
    error AlreadyAdded();
    error MintError();
    error OwnerNotBorrower();
    error SeizeNotAllowed(uint256 err);
    error PositionNotInValidTick();
    error CollateralShortfall();

    struct PoolConfig {
        bool isActive; // pool may be deposited
        uint64 maxOracleSqrtDeviationX64; // reasonable value maybe 10%
    }
    mapping (address => PoolConfig) poolConfigs;

    address public immutable comptroller;

    bool public immutable override needsCheckOnCollect = true;

    constructor(INonfungiblePositionManager _npm, address _comptroller) Module(_npm) {
        comptroller = _comptroller;
    }

    /// @notice Management method to configure a pool
    function setPoolConfig(address pool, bool isActive, uint64 maxOracleSqrtDeviationX64) external onlyOwner {

        CErc20 cToken0 = _getCToken(IUniswapV3Pool(pool).token0());
        CErc20 cToken1 = _getCToken(IUniswapV3Pool(pool).token1());

        // ctokens must be configured in comptroller
        if (address(cToken0) == address(0)) {
            revert TokenNotActive();
        }
        if (address(cToken1) == address(0)) {
            revert TokenNotActive();
        }

        poolConfigs[pool] = PoolConfig(isActive, maxOracleSqrtDeviationX64);
    }

    struct PositionState {
        address token0;
        address token1;
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

    function getOwnerOfPosition(uint256 tokenId) external override view returns(address) {
        return holder.tokenOwners(tokenId);
    }

    function getTokensOfPosition(uint256 tokenId) external override view returns (address token0, address token1) {
        (,,token0,token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);
    }

    function getPositionsOfOwner(address owner) external override view returns (uint256[] memory tokenIds, address[] memory tokens0, address[] memory tokens1) {
        tokenIds = holder.getModuleTokensForOwner(owner, address(this));
        tokens0 = new address[](tokenIds.length);
        tokens1 = new address[](tokenIds.length);
        uint256 i;
        uint256 count = tokenIds.length;
        for (;i < count;i++) {
            (,,address token0,address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenIds[i]);
            tokens0[i] = token0;
            tokens1[i] = token1;
        }
    }

    // returns token breakdown using given oracle prices for both tokens
    // returns corresponding ctoken balance if lent out
    // reverts if prices deviate to much from pool TODO check if better use error code (compound style)
    function getPositionBreakdown(uint256 tokenId, uint256 price0, uint256 price1) external override view returns (uint128 liquidity, uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1) {

        PositionState memory position = _getPositionState(tokenId);

        liquidity = position.liquidity;

        // calculate oracle sqrt price
        uint160 oracleSqrtPriceX96 = uint160(_sqrt(FullMath.mulDiv(price0, Q96 * Q96, price1)));

        (uint160 sqrtPriceX96, int24 tick,,,,,) = position.pool.slot0();

        // calculate position amounts (incl uncollected fees)
        (amount0, amount1, fees0, fees1) = _getAmounts(position, oracleSqrtPriceX96, tick);

        PoolConfig storage poolConfig = poolConfigs[address(position.pool)];

        // check for mayor difference between pool price and oracle price - if to big - revert
        uint256 priceSqrtRatioX64 = Q64 - (sqrtPriceX96 < oracleSqrtPriceX96 ? sqrtPriceX96 * Q64 / oracleSqrtPriceX96 : oracleSqrtPriceX96 * Q64 / sqrtPriceX96);
        if (priceSqrtRatioX64 > poolConfig.maxOracleSqrtDeviationX64) {
            revert OracleDeviation();
        }
    }

    struct BorrowAndAddLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 minAmount0;
        uint256 minAmount1;
        uint256 deadline;
    }

    struct BorrowAndAddLiquidityState {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        IUniswapV3Pool pool;
    }

    /// @notice borrows amount of liquidity and adds to position
    function borrowAndAddLiquidity(BorrowAndAddLiquidityParams calldata params) external {

        BorrowAndAddLiquidityState memory state;

        (,,state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, , , , , ) =  nonfungiblePositionManager.positions(params.tokenId);
        state.pool = _getPool(state.token0, state.token1, state.fee);
        (uint160 sqrtPriceX96, ,,,,,) = state.pool.slot0();

        uint160 sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(state.tickLower);
        uint160 sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(state.tickUpper);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceX96Lower, sqrtPriceX96Upper, params.liquidity);

        address owner = holder.tokenOwners(params.tokenId);

        CErc20 cToken0 = _getCToken(state.token0);
        CErc20 cToken1 = _getCToken(state.token1);

        if (amount0 > 0) {
            cToken0.borrowBehalf(owner, amount0);
            IERC20(state.token0).approve(address(nonfungiblePositionManager), amount0);
        }
        if (amount1 > 0) {
            cToken1.borrowBehalf(owner, amount1);
            IERC20(state.token1).approve(address(nonfungiblePositionManager), amount1);
        }

        (, uint256 addedAmount0, uint256 addedAmount1) = nonfungiblePositionManager.increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams(params.tokenId, amount0, amount1, params.minAmount0, params.minAmount1, params.deadline));

        // transfer left over tokens (should be minimal if any) - cheaper than repay borrow
        if (addedAmount0 < amount0) {
            _transferToken(owner, IERC20(state.token0), amount0 - addedAmount0, true);
        } 
        if (addedAmount1 < amount1) {
            _transferToken(owner, IERC20(state.token1), amount1 - addedAmount1, true);
        }
    }

    struct RepayFromRemovedLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 minAmount0;
        uint256 minAmount1;
        uint128 fees0;
        uint128 fees1;
        uint256 deadline;
    }

    struct RepayFromRemovedLiquidityState {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice removes liquidity (and or fees) to repay debt
    function repayFromRemovedLiquidity(RepayFromRemovedLiquidityParams calldata params) external {

        RepayFromRemovedLiquidityState memory state;

        (,,state.token0, state.token1, state.fee, state.tickLower, state.tickUpper, , , , , ) = nonfungiblePositionManager.positions(params.tokenId);

        address owner = holder.tokenOwners(params.tokenId);

        // this is done without collateral check here - it is done at the end of call
        (uint256 amount0, uint256 amount1, ) = holder.decreaseLiquidityAndCollect(IHolder.DecreaseLiquidityAndCollectParams(params.tokenId, params.liquidity, params.minAmount0, params.minAmount1, params.fees0, params.fees1, params.deadline, false, address(this), ""));

        CErc20 cToken0 = _getCToken(state.token0);
        CErc20 cToken1 = _getCToken(state.token1);

        uint256 borrowBalance0 = cToken0.borrowBalanceCurrent(owner);
        uint256 borrowBalance1 = cToken1.borrowBalanceCurrent(owner);

        if (amount0 > 0) {
            if (borrowBalance0 > 0) {
                IERC20(state.token0).approve(address(cToken0), amount0 > borrowBalance0 ? borrowBalance0 : amount0);
                cToken0.repayBorrowBehalf(owner, amount0 > borrowBalance0 ? borrowBalance0 : amount0);
            }
            if (amount0 > borrowBalance0) {
                _transferToken(owner, IERC20(state.token0), amount0 - borrowBalance0, true);
            }
        }
        if (amount1 > 0) {
            if (borrowBalance1 > 0) {
                IERC20(state.token1).approve(address(cToken1), amount1 > borrowBalance1 ? borrowBalance1 : amount1);
                cToken1.repayBorrowBehalf(owner, amount1 > borrowBalance1 ? borrowBalance1 : amount1);
            }
            if (amount1 > borrowBalance1) {
                _transferToken(owner, IERC20(state.token1), amount1 - borrowBalance1, true);
            }
        }

        // check collateral
        _checkCollateral(owner);
    }


    function seizePositionAssets(address liquidator, address borrower, uint256 tokenId, uint256 seizeLiquidity, uint256 seizeFeesToken0, uint256 seizeFeesToken1) external override {
        
        if (holder.tokenOwners(tokenId) != borrower) {
            revert OwnerNotBorrower();
        }

        // make call to comptroller to ensure seize is allowed
        uint256 err = ComptrollerInterface(comptroller).seizeAllowedUniV3(
            address(this),
            msg.sender,
            liquidator,
            borrower,
            tokenId,
            seizeLiquidity,
            seizeFeesToken0,
            seizeFeesToken1
        );

        if (err > 0) {
            revert SeizeNotAllowed(err);
        }

        // if position internal values are seized
        if (seizeLiquidity > 0 || seizeFeesToken0 > 0 || seizeFeesToken1 > 0) {
            holder.decreaseLiquidityAndCollect(IHolder.DecreaseLiquidityAndCollectParams(tokenId, _toUint128(seizeLiquidity), 0, 0, _toUint128(seizeFeesToken0), _toUint128(seizeFeesToken1), block.timestamp, false, liquidator, ""));
        }
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
    }

    function _getAmounts(PositionState memory position, uint160 oracleSqrtPriceX96, int24 tick) internal view returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1) {
        if (position.liquidity > 0) {
            uint160 sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(position.tickLower);
            uint160 sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(position.tickUpper);        
            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(oracleSqrtPriceX96, sqrtPriceX96Lower, sqrtPriceX96Upper, position.liquidity);
        }

        (fees0, fees1) = _getUncollectedFees(position, tick);
        
        fees0 += position.tokensOwed0;
        fees1 += position.tokensOwed1;
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

    function addToken(uint256 tokenId, address owner, bytes calldata data) override onlyHolder external {

        (, , address token0, address token1, uint24 fee , , , , , , ,) = nonfungiblePositionManager.positions(tokenId);

        IUniswapV3Pool pool = _getPool(token0, token1, fee);

        if (!poolConfigs[address(pool)].isActive) {
            revert PoolNotActive();
        }
    }

    function withdrawToken(uint256 tokenId, address owner) override onlyHolder external {
        _checkCollateralWithoutToken(owner, tokenId);
    }

    function checkOnCollect(uint256, address owner, uint128 , uint256 , uint256 ) override external {
        _checkCollateral(owner);
    }

    function getConfig(uint256 tokenId) override external view returns (bytes memory config) {
        return bytes("");
    }

    function _checkCollateral(address owner) internal {
        (uint256 err,,uint256 shortfall) = ComptrollerLensInterface(comptroller).getAccountLiquidity(owner);
        if (err > 0 || shortfall > 0) {
            revert CollateralShortfall();
        }
    }

    function _checkCollateralWithoutToken(address owner, uint256 tokenId) internal {
        (uint256 err,,uint256 shortfall) = ComptrollerLensInterface(comptroller).getHypotheticalAccountLiquidity(owner, address(0), 0, 0, tokenId);
        if (err > 0 || shortfall > 0) {
            revert CollateralShortfall();
        }
    }

    // gets ctoken for an underlying token from comptroller
    function _getCToken(address token) internal returns (CErc20) {
        return CErc20(address(ComptrollerLensInterface(comptroller).getCTokenByUnderlying(token)));
    }

    // utility function to do safe downcast
    function _toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x);
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
contract ChainlinkOracle is PriceOracle, Ownable {

    error NoFeedConfigured();

    struct FeedConfig {
        AggregatorV3Interface feed;
        uint32 maxFeedAge;
        uint8 feedDecimals;
        uint8 tokenDecimals;
    }

    // ctoken => config mapping
    mapping(address => FeedConfig) feedConfigs;
    
    constructor() {
    }

    function setTokenFeed(address cToken, AggregatorV3Interface feed, uint32 maxFeedAge) external onlyOwner {
        uint8 feedDecimals = feed.decimals();
        address underlying = CErc20Interface(address(cToken)).underlying();
        uint8 tokenDecimals = IERC20Metadata(underlying).decimals();
        feedConfigs[cToken] = FeedConfig(feed, maxFeedAge, feedDecimals, tokenDecimals);
    }

    function getUnderlyingPrice(CToken cToken) override external view returns (uint256) {
        FeedConfig storage feedConfig = feedConfigs[address(cToken)];
        if (address(feedConfig.feed) == address(0)) {
            revert NoFeedConfigured();
        }

        // if stale data - return 0 - handled as error in compound 
        (, int256 answer, , uint256 updatedAt, ) = feedConfig.feed.latestRoundData();
        if (updatedAt + feedConfig.maxFeedAge < block.timestamp) {
            return 0;
        }
        // if invalid data - return 0 - handled as error in compound 
        if (answer < 0) {
            return 0;
        }

        // convert to compound expected format
        return (10 ** (36 - feedConfig.feedDecimals - feedConfig.tokenDecimals)) * uint256(answer);
    }
}
