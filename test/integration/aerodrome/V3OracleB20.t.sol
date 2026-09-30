// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./B20TestBase.sol";

/// @notice Oracle behaviour for Coinbase B20 equity collateral.
///         Covers the 8-vs-6 decimal scaling branch, the three fail-closed checks, garbage prints on
///         the equity and USDC-reference feeds, token-basis corporate actions and the delayed stale-feed cutoff.
contract V3OracleB20Test is B20TestBase {
    uint128 constant NVDA_AMOUNT = 100e8; // 100 NVDAc ~ $21.8K
    uint128 constant MSFT_AMOUNT = 10e8; // 10 MSFTc ~ $5K
    uint256 constant GOOGL_DIVIDEND_MULTIPLIER = 1.000377118676784179e18; // observed on-chain

    uint256 nvdaPos;
    uint256 msftPos;
    uint256 crossPos;

    function setUp() public override {
        super.setUp();
        nvdaPos = _mintNvdaPosition(borrower, NVDA_AMOUNT, 0);
        msftPos = _mintMsftPosition(borrower, MSFT_AMOUNT, 0);
        crossPos = _mintCrossPosition(borrower, NVDA_AMOUNT, MSFT_AMOUNT);
    }

    function _expectedNvdaValue() internal view returns (uint256) {
        return FullMath.mulDiv(NVDA_AMOUNT, _refPriceX96(nvdaTick), Q96);
    }

    function _expectedMsftValue() internal view returns (uint256) {
        return FullMath.mulDiv(MSFT_AMOUNT, _refPriceX96(msftTick), Q96);
    }

    function _nvdaPoolTick() internal view returns (int24) {
        return nvdaPool.token0() == address(nvdac) ? nvdaTick : -nvdaTick;
    }

    // ---- configuration ----------------------------------------------------------------------

    function testUsdcReferenceIsForcedIntoChainlinkMode() external {
        (,,,,,,, V3Oracle.Mode mode,) = oracle.feedConfigs(address(usdc));
        assertEq(uint8(mode), uint8(V3Oracle.Mode.CHAINLINK));
        (AggregatorV3Interface feed,,,,,,, V3Oracle.Mode nvdaMode, uint16 maxDifference) =
            oracle.feedConfigs(address(nvdac));
        assertEq(address(feed), address(nvdaFeed));
        assertEq(uint8(nvdaMode), uint8(V3Oracle.Mode.CHAINLINK_TWAP_VERIFY));
        assertEq(maxDifference, EQUITY_MAX_DIFFERENCE);
        (, uint32 maxFeedAge,,,,,,,) = oracle.feedConfigs(address(nvdac));
        assertEq(maxFeedAge, EQUITY_MAX_FEED_AGE);
    }

    function testSetterUpdatesSharedAge() external {
        oracle.setTokenConfig(
            address(nvdac),
            AggregatorV3Interface(address(nvdaFeed)),
            1 hours,
            IUniswapV3Pool(address(nvdaPool)),
            TWAP_SECONDS,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            EQUITY_MAX_DIFFERENCE
        );
        (, uint32 maxFeedAge,,,,,,,) = oracle.feedConfigs(address(nvdac));
        assertEq(maxFeedAge, 1 hours);
        vm.warp(nvdaFeed.updatedAt() + 1 hours + 1);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        _expectValueRevert(nvdaPos, ChainlinkPriceError.selector);
    }

    // ---- decimal scaling (V3Oracle referenceTokenDecimals < tokenDecimals branch) ------------

    function testValues8DecimalTokenAgainst6DecimalReference() external {
        uint256 value = _value(nvdaPos);
        assertApproxEqRel(value, _expectedNvdaValue(), 1e12);
        // ~$218/share * 100 shares, in 6-decimal USDC
        assertGt(value, 21_000e6);
        assertLt(value, 22_500e6);
    }

    function testCrossPairValuesBothLegs() external {
        assertApproxEqRel(_value(crossPos), _expectedNvdaValue() + _expectedMsftValue(), 1e12);
    }

    // ---- check 1: staleness ---------------------------------------------------------------------

    function testEquityFeedStaleBeyondMaxFeedAgeFailsClosed() external {
        vm.warp(block.timestamp + EQUITY_MAX_FEED_AGE + 1);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        _expectValueRevert(nvdaPos, ChainlinkPriceError.selector);
    }

    function testEquityFeedAtExactlyMaxFeedAgeStillValues() external {
        vm.warp(block.timestamp + EQUITY_MAX_FEED_AGE);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue(), 1e12);
    }

    function testQuietWeekdayStillValues() external {
        vm.warp(nvdaFeed.updatedAt() + 24 hours);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue(), 1e12);
    }

    function testWeekendStillValues() external {
        vm.warp(nvdaFeed.updatedAt() + 48 hours);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue(), 1e12);
    }

    function testLongHolidayPlusPreCloseGapStillValues() external {
        vm.warp(nvdaFeed.updatedAt() + 116 hours + 35 minutes);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue(), 1e12);
    }

    function testZeroOrFutureUpdatedAtFailsClosed() external {
        nvdaFeed.setUpdatedAt(0);
        _expectValueRevert(nvdaPos, ChainlinkPriceError.selector);
        nvdaFeed.setUpdatedAt(block.timestamp + 1);
        _expectValueRevert(nvdaPos, ChainlinkPriceError.selector);
    }

    function testUsdcReferenceStaleFreezesEveryEquity() external {
        vm.warp(block.timestamp + USDC_MAX_FEED_AGE + 1);
        nvdaFeed.setUpdatedAt(block.timestamp);
        msftFeed.setUpdatedAt(block.timestamp);
        _expectValueRevert(nvdaPos, ChainlinkPriceError.selector);
        _expectValueRevert(msftPos, ChainlinkPriceError.selector);
        _expectValueRevert(crossPos, ChainlinkPriceError.selector);
    }

    function testStaleEquityOnlyBlacksOutPositionsHoldingIt() external {
        vm.warp(block.timestamp + EQUITY_MAX_FEED_AGE + 1);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        nvdaFeed.setUpdatedAt(block.timestamp);
        // msft stale
        _expectValueRevert(msftPos, ChainlinkPriceError.selector);
        _expectValueRevert(crossPos, ChainlinkPriceError.selector);
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue(), 1e12);
    }

    // ---- check 2: chainlink vs TWAP divergence ----------------------------------------------------

    function testFeedTwapDivergenceAbove3PercentFailsClosed() external {
        nvdaFeed.setAnswer(_fairTokenAnswer(nvdaTick) * 104 / 100);
        _expectValueRevert(nvdaPos, PriceDifferenceExceeded.selector);
    }

    function testFeedTwapDivergenceBelow3PercentValuesOnChainlink() external {
        nvdaFeed.setAnswer(_fairTokenAnswer(nvdaTick) * 102 / 100);
        // CHAINLINK_TWAP_VERIFY: chainlink is the price, TWAP only verifies
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue() * 102 / 100, 1e14);
    }

    // ---- check 3: spot vs derived (maxPoolPriceDifference) -----------------------------------------

    function testSpotVsDerivedAbove3PercentFailsClosed() external {
        // spot wicks 4% while TWAP and feed agree: reopen-wick scenario
        nvdaPool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(_nvdaPoolTick() + 400));
        _expectValueRevert(nvdaPos, PriceDifferenceExceeded.selector);
    }

    function testSpotVsDerivedBelow3PercentValues() external {
        nvdaPool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(_nvdaPoolTick() + 250));
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue(), 1e12);
    }

    function testCrossPairSpotCheckUsesCrossPool() external {
        int24 crossTick = crossPool.tick();
        crossPool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(crossTick + 400));
        _expectValueRevert(crossPos, PriceDifferenceExceeded.selector);
    }

    // ---- garbage prints: what replaces C4 #446 answer bounds here ------------------------------

    function testGarbageEquityPrintFailsClosed() external {
        int256 fair = _fairTokenAnswer(nvdaTick);
        nvdaFeed.setAnswer(fair * 10);
        _expectValueRevert(nvdaPos, PriceDifferenceExceeded.selector);
        nvdaFeed.setAnswer(fair / 10);
        _expectValueRevert(nvdaPos, PriceDifferenceExceeded.selector);
        nvdaFeed.setAnswer(fair);
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue(), 1e12);
    }

    function testGarbageUsdcReferencePrintFailsClosedForEveryEquity() external {
        usdcRefFeed.setAnswer(10e8); // USDC "= $10"
        _expectValueRevert(nvdaPos, PriceDifferenceExceeded.selector);
        _expectValueRevert(msftPos, PriceDifferenceExceeded.selector);
        _expectValueRevert(crossPos, PriceDifferenceExceeded.selector);
        usdcRefFeed.setAnswer(0.1e8); // USDC "= $0.10"
        _expectValueRevert(nvdaPos, PriceDifferenceExceeded.selector);
    }

    function testUsdcDepegInsideToleranceRepricesEquities() external {
        usdcRefFeed.setAnswer(0.98e8);
        // a share is worth more of a cheaper USDC; 2.04% off the pool TWAP, inside 3%
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue() * 100 / 98, 1e14);
    }

    function testNonPositiveUsdcReferenceFailsClosed() external {
        usdcRefFeed.setAnswer(0);
        _expectValueRevert(nvdaPos, ChainlinkPriceError.selector);
    }

    // ---- token-basis corporate actions ------------------------------------------------------------

    function testDividendIsIncludedExactlyOnceInFeed() external {
        nvdac.setMultiplier(GOOGL_DIVIDEND_MULTIPLIER);
        int256 tokenAnswer =
            int256(FullMath.mulDiv(uint256(_fairTokenAnswer(nvdaTick)), GOOGL_DIVIDEND_MULTIPLIER, 1e18));
        nvdaFeed.setAnswer(tokenAnswer);
        uint256 expected = FullMath.mulDiv(NVDA_AMOUNT, uint256(tokenAnswer), 1e10);
        assertApproxEqAbs(_value(nvdaPos), expected, 1);
    }

    function testForwardSplitKeepsTokenPriceContinuous() external {
        uint256 beforeValue = _value(nvdaPos);
        // Underlying share price divides by ten and multiplier grows tenfold.
        // Chainlink publishes their product; the pool and token price remain unchanged.
        nvdac.setMultiplier(10e18);
        nvdaFeed.setAnswer(_fairTokenAnswer(nvdaTick));
        assertEq(_value(nvdaPos), beforeValue);
    }

    function testReverseSplitKeepsTokenPriceContinuous() external {
        uint256 beforeValue = _value(nvdaPos);
        nvdac.setMultiplier(0.1e18);
        nvdaFeed.setAnswer(_fairTokenAnswer(nvdaTick));
        assertEq(_value(nvdaPos), beforeValue);
    }

    function testTokenFeedDoesNotReadMultiplier() external {
        uint256 beforeValue = _value(nvdaPos);
        nvdac.setRevertMultiplier(true);
        assertEq(_value(nvdaPos), beforeValue);
    }

    function testPublishedMultiplierCutDivergesFromFrozenPool() external {
        nvdac.setMultiplier(0.5e18);
        nvdaFeed.setAnswer(_fairTokenAnswer(nvdaTick) / 2);
        _expectValueRevert(nvdaPos, PriceDifferenceExceeded.selector);
    }

    function testPausedFeedDoesNotImmediatelyRejectMultiplierCut() external {
        uint256 beforeValue = _value(nvdaPos);
        uint256 lastPrint = nvdaFeed.updatedAt();
        nvdac.setMultiplier(0.5e18);
        // Known residual risk: no updated print or pool repricing, and no registry pause check.
        // Holding the last price does not invalidate it until its applicable age limit expires.
        assertEq(_value(nvdaPos), beforeValue);

        vm.warp(lastPrint + EQUITY_MAX_FEED_AGE + 1);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        _expectValueRevert(nvdaPos, ChainlinkPriceError.selector);
    }

    function testSplitPauseRecoversOnFreshTokenPrintWithoutReconfiguration() external {
        uint256 beforeValue = _value(nvdaPos);
        uint256 lastPrint = nvdaFeed.updatedAt();
        nvdac.setMultiplier(10e18);
        vm.warp(lastPrint + EQUITY_MAX_FEED_AGE + 1);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        _expectValueRevert(nvdaPos, ChainlinkPriceError.selector);
        // Issuer unpauses after share price and multiplier align; total-return price is continuous.
        nvdaFeed.setAnswer(_fairTokenAnswer(nvdaTick));
        assertEq(_value(nvdaPos), beforeValue);
    }

    // ---- market moves ------------------------------------------------------------------------------

    function testCoordinatedRepriceKeepsValuing() external {
        _moveNvda(nvdaTick - 3_567); // -30%
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue(), 1e12);
        assertApproxEqRel(_value(nvdaPos), 21_828e6 * 70 / 100, 2e16); // ~2% tolerance on the round number
        // cross pool was re-synced too
        assertApproxEqRel(_value(crossPos), _expectedNvdaValue() + _expectedMsftValue(), 1e12);
    }
}
