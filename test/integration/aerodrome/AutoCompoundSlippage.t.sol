// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./AerodromeTestBase.sol";
import "../../../src/transformers/AutoRangeAndCompound.sol";

/// Cantina LEND-9: the auto-compound swap must respect the position's configured per-token price tolerance, not
/// only the TWAP proximity check, which bounds the pre-swap price but not the execution itself.
contract AutoCompoundSlippageTest is AerodromeTestBase {
    AutoRangeAndCompound public autoRange;
    MockPool public pool;
    address public token0;
    address public token1;
    uint256 public tokenId;

    uint256 internal constant FEES0 = 100e18;
    uint256 internal constant FEES1 = 100e18;
    uint256 internal constant SWAP_IN = 40e18;

    function setUp() public override {
        super.setUp();

        autoRange = new AutoRangeAndCompound(
            INonfungiblePositionManager(address(npm)),
            admin, // operator
            admin, // withdrawer
            60, // TWAPSeconds
            200, // maxTWAPTickDifference
            address(0),
            address(0)
        );

        (token0, token1) =
            address(usdc) < address(dai) ? (address(usdc), address(dai)) : (address(dai), address(usdc));
        pool = MockPool(usdcDaiPool);

        tokenId = createPosition(alice, token0, token1, 1, -100, 100, 1000e18);
        npm.setTokensOwed(tokenId, uint128(FEES0), uint128(FEES1));

        // The mock position manager reports collected fees without transferring them: fund the transformer with
        // the same amounts. The mock pool pays swap output from its own balance.
        MockERC20(token0).mint(address(autoRange), FEES0);
        MockERC20(token1).mint(address(autoRange), FEES1);
        MockERC20(token0).mint(address(pool), 1_000e18);
        MockERC20(token1).mint(address(pool), 1_000e18);
    }

    function _configure(uint64 slippageX64) internal {
        vm.prank(alice);
        autoRange.configToken(
            tokenId,
            address(0),
            AutoRangeAndCompound.PositionConfig({
                lowerTickLimit: 0,
                upperTickLimit: 0,
                lowerTickDelta: 0,
                upperTickDelta: 0,
                token0SlippageX64: slippageX64,
                token1SlippageX64: slippageX64,
                onlyFees: false,
                autoCompound: true,
                maxRewardX64: 0,
                autoCompoundMin0: 0,
                autoCompoundMin1: 0,
                autoCompoundRewardMin: 0
            }), AutoRangeAndCompound.CompoundMode.Advanced
        );
    }

    function _compound() internal {
        vm.prank(admin);
        autoRange.autoCompound(
            AutoRangeAndCompound.AutoCompoundParams({
                tokenId: tokenId, swap0To1: true, amountIn: SWAP_IN, deadline: block.timestamp + 1 hours
            })
        );
    }

    /// 1% tolerance, the pool pays 2% below spot: the swap is rejected instead of compounding the impaired output.
    function testSwapBelowConfiguredSlippageReverts() public {
        _configure(uint64(Q64 / 100));
        pool.setOutputBps(9_800);

        vm.expectRevert(SlippageError.selector);
        _compound();
    }

    /// 1% tolerance, the pool pays 0.5% below spot: the swap executes and the fees compound.
    function testSwapWithinConfiguredSlippageExecutes() public {
        _configure(uint64(Q64 / 100));
        pool.setOutputBps(9_950);
        uint256 poolToken0Before = IERC20(token0).balanceOf(address(pool));

        _compound();

        assertEq(IERC20(token0).balanceOf(address(pool)) - poolToken0Before, SWAP_IN, "swap input paid to the pool");
    }

    /// A zero tolerance requires the full spot output, so even a 0.01% shortfall reverts: positions that should
    /// swap while compounding need a real tolerance configured, like they do for range adjustments.
    function testZeroToleranceRequiresSpotOutput() public {
        _configure(0);
        pool.setOutputBps(9_999);

        vm.expectRevert(SlippageError.selector);
        _compound();
    }

    /// Unchanged behaviour: when the spot price deviates from the TWAP beyond the allowed ticks the swap is skipped
    /// rather than reverted and the fees compound unswapped, so no output bound is evaluated.
    function testTwapDeviationStillSkipsTheSwap() public {
        _configure(uint64(Q64 / 100));
        pool.setOutputBps(9_000);
        pool.setTick(300); // observed TWAP tick stays 0: 300 > 200 allowed
        uint256 poolToken0Before = IERC20(token0).balanceOf(address(pool));

        _compound();

        assertEq(IERC20(token0).balanceOf(address(pool)), poolToken0Before, "no swap happened");
    }
}
