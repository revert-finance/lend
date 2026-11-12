// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "../../lib/AggregatorV3Interface.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-periphery/libraries/OracleLibrary.sol";

/// @notice Chainlink-compatible check for 8-decimal stock tokens paired with 6-decimal USDC.
/// @dev Both underlying feeds must report USD with 8 decimals. Returns the original stock round,
/// never a pool price or a refreshed timestamp. No owner, custody, setters or fallback.
/// The deployment tooling must verify token decimals, pool provenance and feed identities.
contract StockTwapFeed is AggregatorV3Interface {
    error InvalidConfig();
    error InvalidRound();
    error PriceDifferenceExceeded();

    AggregatorV3Interface public immutable stockFeed;
    AggregatorV3Interface public immutable usdcFeed;
    IUniswapV3Pool public immutable pool;
    address public immutable stock;
    address public immutable usdc;
    uint32 public immutable maxStockAge;
    uint32 public immutable maxUsdcAge;
    uint32 public immutable twapSeconds;
    uint16 public immutable maxDifferenceBps;
    uint8 public constant override decimals = 8;

    constructor(
        AggregatorV3Interface _stockFeed,
        AggregatorV3Interface _usdcFeed,
        IUniswapV3Pool _pool,
        address _stock,
        address _usdc,
        uint32 _maxStockAge,
        uint32 _maxUsdcAge,
        uint32 _twapSeconds,
        uint16 _maxDifferenceBps
    ) {
        if (
            _stock == address(0) || _usdc == address(0) || _stock == _usdc || _maxStockAge == 0 || _maxUsdcAge == 0
                || _twapSeconds == 0 || _maxDifferenceBps == 0 || _maxDifferenceBps > 10_000
                || _stockFeed.decimals() != 8 || _usdcFeed.decimals() != 8
        ) revert InvalidConfig();
        address token0 = _pool.token0();
        address token1 = _pool.token1();
        if (!((token0 == _stock && token1 == _usdc) || (token0 == _usdc && token1 == _stock))) {
            revert InvalidConfig();
        }
        stockFeed = _stockFeed;
        usdcFeed = _usdcFeed;
        pool = _pool;
        stock = _stock;
        usdc = _usdc;
        maxStockAge = _maxStockAge;
        maxUsdcAge = _maxUsdcAge;
        twapSeconds = _twapSeconds;
        maxDifferenceBps = _maxDifferenceBps;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = stockFeed.latestRoundData();
        _validateRound(answer, updatedAt, maxStockAge);
        (, int256 usdcAnswer,, uint256 usdcUpdatedAt,) = usdcFeed.latestRoundData();
        _validateRound(usdcAnswer, usdcUpdatedAt, maxUsdcAge);

        // Both feeds have 8 decimals. Quote one whole stock in raw (6-decimal) USDC;
        // do not assume USDC/USD == 1. Pool quotes use the stock's 8-decimal unit.
        uint256 expected = FullMath.mulDiv(uint256(answer), 1e6, uint256(usdcAnswer));
        uint256 observed = OracleLibrary.getQuoteAtTick(_meanTick(), 1e8, stock, usdc);
        uint256 difference = expected > observed ? expected - observed : observed - expected;
        if (expected == 0 || observed == 0 || difference > FullMath.mulDiv(expected, maxDifferenceBps, 10_000)) {
            revert PriceDifferenceExceeded();
        }
    }

    function _validateRound(int256 answer, uint256 updatedAt, uint32 maxAge) private view {
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
            revert InvalidRound();
        }
    }

    function _meanTick() private view returns (int24 tick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSeconds;
        (int56[] memory cumulatives,) = pool.observe(secondsAgos);
        int56 delta;
        // Tick accumulators intentionally wrap at int56, as in the underlying pool.
        unchecked {
            delta = cumulatives[1] - cumulatives[0];
        }
        int56 period = int56(uint56(twapSeconds));
        int56 mean = delta / period;
        if (delta < 0 && delta % period != 0) --mean;
        if (mean < TickMath.MIN_TICK || mean > TickMath.MAX_TICK) revert InvalidRound();
        tick = int24(mean);
    }
}
