// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "v3-core/libraries/FullMath.sol";
import "v3-core/libraries/TickMath.sol";

import "./AerodromeTestBase.sol";
import "../../../src/utils/Swapper.sol";

contract SwapperHarness is Swapper {
    constructor(INonfungiblePositionManager npm) Swapper(npm, address(0), address(0)) {}

    function calc(bool swap0For1, uint256 amountIn, uint160 sqrtPriceX96, uint64 maxPriceDifferenceX64)
        external
        pure
        returns (uint256)
    {
        return _calculateAmountOutMin(swap0For1, amountIn, sqrtPriceX96, maxPriceDifferenceX64);
    }

    /// The formula used before: squares the sqrt price down to Q96 first, which truncates to zero below 2^48.
    function legacy(bool swap0For1, uint256 amountIn, uint160 sqrtPriceX96, uint64 maxPriceDifferenceX64)
        external
        pure
        returns (uint256)
    {
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (swap0For1) {
            return FullMath.mulDiv(amountIn * (Q64 - maxPriceDifferenceX64), priceX96, Q160);
        }
        return FullMath.mulDiv(amountIn * (Q64 - maxPriceDifferenceX64), Q32, priceX96);
    }
}

/// The minimum-output bound shared by range adjustments, reward compounding and (since LEND-9) fee auto-compounding
/// must hold over the whole tick range, not only where the squared price fits Q96.
contract SwapperAmountOutMinTest is AerodromeTestBase {
    SwapperHarness internal harness;
    uint64 internal onePercent;

    function setUp() public override {
        super.setUp();
        harness = new SwapperHarness(INonfungiblePositionManager(address(npm)));
        onePercent = uint64(Q64 / 100);
    }

    function _lessOnePercent(uint256 amount) internal view returns (uint256) {
        return FullMath.mulDiv(amount, Q64 - onePercent, Q64);
    }

    /// Price 2^-98 (sqrt price 2^47, a valid tick): the legacy formula returned 0 for token0 -> token1 and divided
    /// by zero for token1 -> token0; the bound is now the real spot quote less the tolerance in both directions.
    function testTinyPriceKeepsTheBound() public {
        uint160 sqrtPriceX96 = uint160(1) << 47;

        assertEq(harness.legacy(true, 1e36, sqrtPriceX96, onePercent), 0, "legacy bound collapsed to zero");

        uint256 expected0To1 = _lessOnePercent(FullMath.mulDiv(1e36, uint256(1) << 94, uint256(1) << 192));
        assertGt(expected0To1, 0);
        assertApproxEqAbs(harness.calc(true, 1e36, sqrtPriceX96, onePercent), expected0To1, 2, "0 -> 1 bound");

        uint256 expected1To0 = _lessOnePercent(FullMath.mulDiv(1e18, uint256(1) << 192, uint256(1) << 94));
        assertApproxEqAbs(harness.calc(false, 1e18, sqrtPriceX96, onePercent), expected1To0, 2, "1 -> 0 bound");
    }

    /// At ordinary prices the bound equals the legacy formula up to rounding.
    function testMatchesLegacyAtOrdinaryPrices() public {
        uint160[4] memory prices = [uint160(1) << 80, uint160(1) << 96, uint160(1) << 110, uint160(1) << 126];
        for (uint256 i = 0; i < prices.length; i++) {
            assertApproxEqAbs(
                harness.calc(true, 1e18, prices[i], onePercent),
                harness.legacy(true, 1e18, prices[i], onePercent),
                2,
                "0 -> 1"
            );
            assertApproxEqAbs(
                harness.calc(false, 1e18, prices[i], onePercent),
                harness.legacy(false, 1e18, prices[i], onePercent),
                2,
                "1 -> 0"
            );
        }
        assertApproxEqAbs(harness.calc(true, 1e18, uint160(1) << 96, onePercent), 0.99e18, 1, "1:1 price, 1%");
    }

    /// Above 2^128 the squared sqrt price no longer fits a uint256; the second branch keeps the bound exact.
    function testHighPriceBranch() public {
        uint160 sqrtPriceX96 = TickMath.MAX_SQRT_RATIO;
        uint256 bound = harness.calc(true, 1, sqrtPriceX96, onePercent);
        assertGt(bound, 0);
        assertApproxEqRel(bound, harness.legacy(true, 1, sqrtPriceX96, onePercent), 1e6, "0 -> 1 at max price"); // 1e-12 relative
        assertEq(harness.calc(false, 1e30, sqrtPriceX96, onePercent), 0, "1 -> 0 at max price rounds to zero");
    }

    /// Zero tolerance returns the full spot quote.
    function testZeroToleranceIsSpot() public {
        assertEq(harness.calc(true, 1e18, uint160(1) << 96, 0), 1e18);
        assertEq(harness.calc(false, 5e6, uint160(1) << 96, 0), 5e6);
    }
}
