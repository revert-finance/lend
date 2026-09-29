// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./B20TestBase.sol";

/// @notice Oracle behaviour for Coinbase B20 equity collateral (plan WP3 bucket 1, proposal §3).
///         Covers the 8-vs-6 decimal scaling branch, the three fail-closed checks, garbage prints on
///         the equity and USDC-reference feeds, and every row of the multiplier matrix (§3.2).
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
        assertEq(address(feed), address(nvdaAdapter));
        assertEq(uint8(nvdaMode), uint8(V3Oracle.Mode.CHAINLINK_TWAP_VERIFY));
        assertEq(maxDifference, EQUITY_MAX_DIFFERENCE);
        assertEq(oracle.liquidationMaxFeedAge(address(nvdac)), EQUITY_LIQUIDATION_MAX_FEED_AGE);
    }

    function testOperationalAgeCannotExceedLiquidationAge() external {
        vm.expectRevert(InvalidConfig.selector);
        oracle.setTokenConfig(
            address(nvdac),
            AggregatorV3Interface(address(nvdaAdapter)),
            EQUITY_LIQUIDATION_MAX_FEED_AGE + 1,
            EQUITY_LIQUIDATION_MAX_FEED_AGE,
            IUniswapV3Pool(address(nvdaPool)),
            TWAP_SECONDS,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            EQUITY_MAX_DIFFERENCE
        );
    }

    function testLegacySetterPreservesConfiguredLiquidationAge() external {
        oracle.setTokenConfig(
            address(nvdac),
            AggregatorV3Interface(address(nvdaAdapter)),
            EQUITY_MAX_FEED_AGE,
            IUniswapV3Pool(address(nvdaPool)),
            TWAP_SECONDS,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            EQUITY_MAX_DIFFERENCE
        );
        assertEq(oracle.liquidationMaxFeedAge(address(nvdac)), EQUITY_LIQUIDATION_MAX_FEED_AGE);
    }

    function testLegacySetterUsesOperationalAgeForFirstConfiguration() external {
        oracle.setTokenConfig(
            address(aero),
            AggregatorV3Interface(address(nvdaAdapter)),
            EQUITY_MAX_FEED_AGE,
            IUniswapV3Pool(address(0)),
            0,
            V3Oracle.Mode.CHAINLINK,
            0
        );
        assertEq(oracle.liquidationMaxFeedAge(address(aero)), EQUITY_MAX_FEED_AGE);

        oracle.setTokenConfig(
            address(aero),
            AggregatorV3Interface(address(nvdaAdapter)),
            EQUITY_MAX_FEED_AGE / 2,
            IUniswapV3Pool(address(0)),
            0,
            V3Oracle.Mode.CHAINLINK,
            0
        );
        assertEq(oracle.liquidationMaxFeedAge(address(aero)), EQUITY_MAX_FEED_AGE / 2);
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

    function testTwentyFourHourGapIsLiquidationOnly() external {
        vm.warp(block.timestamp + 24 hours);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        _expectValueRevert(nvdaPos, ChainlinkPriceError.selector);
        (uint256 value,,,) = oracle.getValueForLiquidation(nvdaPos, address(usdc), false);
        assertApproxEqRel(value, _expectedNvdaValue(), 1e12);
    }

    function testBeyondLiquidationMaxFeedAgeFailsBothPaths() external {
        vm.warp(block.timestamp + EQUITY_LIQUIDATION_MAX_FEED_AGE + 1);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        _expectValueRevert(nvdaPos, ChainlinkPriceError.selector);
        vm.expectRevert(ChainlinkPriceError.selector);
        oracle.getValueForLiquidation(nvdaPos, address(usdc), false);
    }

    function testAtExactlyLiquidationMaxFeedAgeStillValuesForLiquidation() external {
        vm.warp(block.timestamp + EQUITY_LIQUIDATION_MAX_FEED_AGE);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        (uint256 value,,,) = oracle.getValueForLiquidation(nvdaPos, address(usdc), false);
        assertApproxEqRel(value, _expectedNvdaValue(), 1e12);
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
        nvdaFeed.setAnswer(_fairShareAnswer(nvdaTick, 1e18) * 104 / 100);
        _expectValueRevert(nvdaPos, PriceDifferenceExceeded.selector);
    }

    function testFeedTwapDivergenceBelow3PercentValuesOnChainlink() external {
        nvdaFeed.setAnswer(_fairShareAnswer(nvdaTick, 1e18) * 102 / 100);
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
        int256 fair = _fairShareAnswer(nvdaTick, 1e18);
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

    // ---- multiplier matrix (proposal §3.2) ---------------------------------------------------------

    function testDividendMultiplierTracksWithoutOutage() external {
        nvdac.setMultiplier(GOOGL_DIVIDEND_MULTIPLIER);
        uint256 expected = FullMath.mulDiv(_expectedNvdaValue(), GOOGL_DIVIDEND_MULTIPLIER, 1e18);
        assertApproxEqRel(_value(nvdaPos), expected, 1e13);
    }

    function testForwardSplitMultiplierFlipsBeforeFeedIsBoundedOutage() external {
        // 2:1 split: token now = 2 shares. Pool (token terms) unchanged; feed still prints the pre-split share price.
        nvdac.setMultiplier(2e18);
        _expectValueRevert(nvdaPos, PriceDifferenceExceeded.selector);
        // first post-split print halves the share price: auto-recovery, no admin action
        nvdaFeed.setAnswer(_fairShareAnswer(nvdaTick, 2e18));
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue(), 1e12);
    }

    function testForwardSplitFeedAdjustsBeforeMultiplierIsBoundedOutage() external {
        nvdaFeed.setAnswer(_fairShareAnswer(nvdaTick, 2e18));
        _expectValueRevert(nvdaPos, PriceDifferenceExceeded.selector);
        nvdac.setMultiplier(2e18);
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue(), 1e12);
    }

    function testReverseSplitIsBoundedOutage() external {
        nvdac.setMultiplier(0.5e18);
        _expectValueRevert(nvdaPos, PriceDifferenceExceeded.selector);
        nvdaFeed.setAnswer(_fairShareAnswer(nvdaTick, 0.5e18));
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue(), 1e12);
    }

    // the fail-open path the adapter exists to close: issuer halves the multiplier while transfers are
    // gated, so the pool cannot reprice and the feed stays fresh
    function testEmergencyMultiplierCutWithFrozenPoolFailsClosed() external {
        nvdac.setMultiplier(0.5e18);
        _expectValueRevert(nvdaPos, PriceDifferenceExceeded.selector);
    }

    function testRawFeedConfigurationWouldFailOpenOnMultiplierCut() external {
        // control: configure NVDAc on the raw Chainlink feed (no adapter), as a naive deployment would
        oracle.setTokenConfig(
            address(nvdac),
            AggregatorV3Interface(address(nvdaFeed)),
            EQUITY_MAX_FEED_AGE,
            IUniswapV3Pool(address(nvdaPool)),
            TWAP_SECONDS,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            EQUITY_MAX_DIFFERENCE
        );
        nvdac.setMultiplier(0.5e18);
        // both checks pass while the collateral is worth half: impaired LP would be borrowable against
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue(), 1e12);
    }

    function testFatFingeredMultiplierInsideToleranceIsAccepted() external {
        nvdac.setMultiplier(1.02e18);
        assertApproxEqRel(_value(nvdaPos), _expectedNvdaValue() * 102 / 100, 1e14);
    }

    function testFatFingeredMultiplierOutsideToleranceFailsClosed() external {
        nvdac.setMultiplier(1.04e18);
        _expectValueRevert(nvdaPos, PriceDifferenceExceeded.selector);
    }

    function testMultiplierRevertFailsClosed() external {
        nvdac.setRevertMultiplier(true);
        vm.expectRevert("B20: not implemented");
        oracle.getValue(nvdaPos, address(usdc), false);
    }

    function testZeroMultiplierFailsClosed() external {
        nvdac.setMultiplier(0);
        _expectValueRevert(nvdaPos, ChainlinkPriceError.selector);
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
