// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "./AeroProtocolDeployment.t.sol";

/// @notice Reuses the complete deployment/lending/automation/fee/liquidation rehearsal with USDC as reference.
contract AeroUsdcReferenceTest is AeroProtocolDeploymentTest {
    function _usdcReference() internal pure override returns (bool) {
        return true;
    }

    function testUsdcReferencePolicyAndFeeSettings() public {
        assertEq(d.oracle.referenceToken(), USDC);
        assertEq(d.oracle.referenceTokenDecimals(), 6);
        assertEq(d.oracle.chainlinkReferenceToken(), address(0)); // USD feeds, not a hardcoded USDC peg.
        (,,,, uint32 window, IUniswapV3Pool pool, bool is0, V3Oracle.Mode mode, uint16 tolerance) =
            d.oracle.feedConfigs(WETH);
        assertEq(window, 60);
        assertEq(address(pool), script.collateralPools()[0]);
        assertTrue(is0);
        assertEq(uint256(mode), uint256(V3Oracle.Mode.CHAINLINK_TWAP_VERIFY));
        assertEq(tolerance, 200);
        (,,,, window, pool, is0, mode, tolerance) = d.oracle.feedConfigs(CBBTC);
        assertEq(window, 60);
        assertEq(address(pool), script.collateralPools()[5]);
        assertFalse(is0);
        assertEq(uint256(mode), uint256(V3Oracle.Mode.CHAINLINK_TWAP_VERIFY));
        (,,,, window, pool,, mode,) = d.oracle.feedConfigs(USDC);
        assertEq(window, 0);
        assertEq(address(pool), address(0));
        assertEq(uint256(mode), uint256(V3Oracle.Mode.CHAINLINK));
        assertEq(d.gaugeManager.totalRewardX64(), uint256(2 ** 64) / 20);
        assertEq(d.autoRange.totalRewardX64(), uint256(2 ** 64) / 20);
        assertEq(d.autoRange.simpleRewardX64(), uint256(2 ** 64) / 10);
        assertEq(d.vault.reserveFactorX32(), uint256(2 ** 32) / 10);
    }

    function _legacyOracle() internal returns (V3Oracle o) {
        o = new V3Oracle(INonfungiblePositionManager(NPM), WETH, address(0));
        address[3] memory tokens = [WETH, USDC, CBBTC];
        for (uint256 i; i < 3; ++i) {
            (AggregatorV3Interface feed, uint32 age,,,,,,,) = d.oracle.feedConfigs(tokens[i]);
            o.setTokenConfig(tokens[i], feed, age, IUniswapV3Pool(address(0)), 0, V3Oracle.Mode.CHAINLINK, 0);
        }
        o.setMaxPoolPriceDifference(200);
    }

    function testReferenceChangePreservesPrincipalAndAccruedFeeValuation() public {
        V3Oracle legacy = _legacyOracle();
        address[] memory pools = script.collateralPools();
        for (uint256 i; i < pools.length; ++i) {
            uint256 id = _mint(pools[i]);
            address t0 = IUniswapV3Pool(pools[i]).token0();
            address t1 = IUniswapV3Pool(pools[i]).token1();
            // Actual freshly minted NFT; introduce known owed fees without changing pool observations.
            // Exercise both fee-growth valuation and the ignoreFees path used for staked collateral.
            (bool ok, bytes memory position) = NPM.staticcall(abi.encodeWithSignature("positions(uint256)", id));
            require(ok);
            uint256 fee0 = _amount(t0) / 100;
            uint256 fee1 = _amount(t1) / 100;
            assembly ("memory-safe") {
                mstore(add(position, 352), fee0)
                mstore(add(position, 384), fee1)
            }
            vm.mockCall(NPM, abi.encodeWithSignature("positions(uint256)", id), position);
            for (uint256 j; j < 2; ++j) {
                bool ignore = j == 1;
                (uint256 actual, uint256 fees,,) = d.oracle.getValue(id, USDC, ignore);
                (uint256 expected, uint256 oldFees,,) = legacy.getValue(id, USDC, ignore);
                assertApproxEqAbs(actual, expected, 2); // At most two raw USDC units of rounding.
                assertApproxEqAbs(fees, oldFees, 2);
                if (ignore) {
                    assertEq(fees, 0);
                } else {
                    assertGt(fees, 0);
                    uint256 expectedFees =
                        d.oracle.getTokenValue(t0, fee0, USDC) + d.oracle.getTokenValue(t1, fee1, USDC);
                    assertApproxEqAbs(fees, expectedFees, 2);
                }
            }
            vm.clearMockedCalls();
        }
    }

    function testUsdcDepegStillAffectsConversionAndTripsTwapGuard() public {
        (AggregatorV3Interface feed,,,,,,,,) = d.oracle.feedConfigs(USDC);
        (uint80 id, int256 answer, uint256 start, uint256 updated, uint80 answered) = feed.latestRoundData();
        vm.mockCall(
            address(feed),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(id, answer * 90 / 100, start, updated, answered)
        );
        vm.expectRevert(bytes4(keccak256("PriceDifferenceExceeded()")));
        d.oracle.getTokenValue(WETH, 1 ether, USDC);
        vm.expectRevert(bytes4(keccak256("PriceDifferenceExceeded()")));
        d.oracle.getTokenValue(CBBTC, 1e8, USDC);
    }
}
