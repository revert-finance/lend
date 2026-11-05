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
            }),
            true
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

    /// A failed TWAP check reverts even with force: force only bypasses the leftover cap.
    function testTwapDeviationRevertsEvenWithForce() public {
        _configure(uint64(Q64 / 100));
        pool.setOutputBps(9_000);
        pool.setTick(300); // observed TWAP tick stays 0: 300 > 200 allowed
        uint256 poolToken0Before = IERC20(token0).balanceOf(address(pool));

        vm.expectRevert(TWAPCheckFailed.selector);
        _compound();

        assertEq(IERC20(token0).balanceOf(address(pool)), poolToken0Before, "no swap happened");
    }

    function _outcomeCompound(bool force, uint256 amountIn) internal {
        vm.prank(admin);
        autoRange.autoCompound(
            AutoRangeAndCompound.AutoCompoundParams(tokenId, true, amountIn, block.timestamp + 1 hours), force
        );
    }

    function testExcessiveLeftoverRevertsAtomically() public {
        _configure(uint64(Q64 / 100));
        npm.setNextIncreaseLiquidityResult(1e18, 1e18);
        uint256 ownerBefore = IERC20(token0).balanceOf(alice);
        (,,,,,,, uint128 liquidityBefore,,,,) = npm.positions(tokenId);
        vm.expectRevert(CompoundOutcome.ExcessiveCompoundLeftover.selector);
        _outcomeCompound(false, 0);
        (,,,,,,, uint128 liquidityAfter,,, uint128 owed0, uint128 owed1) = npm.positions(tokenId);
        assertEq(liquidityAfter, liquidityBefore);
        assertEq(owed0, FEES0);
        assertEq(owed1, FEES1);
        assertEq(IERC20(token0).balanceOf(alice), ownerBefore);
        assertEq(IERC20(token0).balanceOf(address(autoRange)), FEES0);
        assertEq(IERC20(token0).allowance(address(autoRange), address(npm)), 0);
    }

    function testForcePreservesOwnerPayoutAndFeeAccounting() public {
        _configure(uint64(Q64 / 100));
        npm.setNextIncreaseLiquidityResult(1e18, 1e18);
        uint256 ownerBefore = IERC20(token0).balanceOf(alice);
        uint256 fee = uint256(1e18) * autoRange.compoundRewardX64(tokenId) / Q64;
        _outcomeCompound(true, 0);
        assertEq(IERC20(token0).balanceOf(alice) - ownerBefore, FEES0 - 1e18 - fee);
        assertEq(IERC20(token0).balanceOf(address(autoRange)), fee);
    }

    function testHalfPercentBoundaryPasses() public {
        _configure(0);
        autoRange.setAutoCompoundRewards(0, 0);
        npm.setNextIncreaseLiquidityResult(99.5e18, 99.5e18);
        _outcomeCompound(false, 0);
    }

    function testAboveHalfPercentFailsForEitherToken() public {
        _configure(0);
        autoRange.setAutoCompoundRewards(0, 0);
        npm.setNextIncreaseLiquidityResult(99.5e18 - 1, 100e18);
        vm.expectRevert(CompoundOutcome.ExcessiveCompoundLeftover.selector);
        _outcomeCompound(false, 0);
        npm.setNextIncreaseLiquidityResult(100e18, 99.5e18 - 1);
        vm.expectRevert(CompoundOutcome.ExcessiveCompoundLeftover.selector);
        _outcomeCompound(false, 0);
    }

    function testOneSmallestUnitPassesForTinyCompound() public {
        _configure(0);
        autoRange.setAutoCompoundRewards(0, 0);
        npm.setTokensOwed(tokenId, 100, 100);
        npm.setNextIncreaseLiquidityResult(99, 99);
        _outcomeCompound(false, 0);
    }

    function testTwoSmallestUnitsFailForTinyCompound() public {
        _configure(0);
        autoRange.setAutoCompoundRewards(0, 0);
        npm.setTokensOwed(tokenId, 100, 100);
        npm.setNextIncreaseLiquidityResult(98, 99);
        vm.expectRevert(CompoundOutcome.ExcessiveCompoundLeftover.selector);
        _outcomeCompound(false, 0);
    }

    function testStrictModeAllowsFullUtilizationAfterProtocolFee() public {
        _configure(0);
        _outcomeCompound(false, 0);
        assertGt(IERC20(token0).balanceOf(address(autoRange)), 0, "protocol fee is not user leftover");
    }

    function testStrictModeRejectsRatioDriftDespiteSwapWithinSlippage() public {
        _configure(uint64(Q64 / 100));
        pool.setTick(20); // drift remains inside the TWAP tolerance
        pool.setOutputBps(9_950); // execution price still clears the swap bound
        // Model the changed ratio accepted by the NPM after the caller sized its swap.
        npm.setNextIncreaseLiquidityResult(1e18, 1e18);
        vm.expectRevert(CompoundOutcome.ExcessiveCompoundLeftover.selector);
        _outcomeCompound(false, SWAP_IN);
        _outcomeCompound(true, SWAP_IN);
    }

    function testStrictModeRejectsLeftoverAfterAllowedSwapImpact() public {
        _configure(uint64(Q64 / 100));
        pool.setOutputBps(9_950);
        pool.setTickAfterSwap(20);
        npm.setNextIncreaseLiquidityResult(1e18, 1e18);
        vm.expectRevert(CompoundOutcome.ExcessiveCompoundLeftover.selector);
        _outcomeCompound(false, SWAP_IN);
    }

    function testForceDoesNotAuthorizeStranger() public {
        _configure(0);
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        autoRange.autoCompound(
            AutoRangeAndCompound.AutoCompoundParams(tokenId, true, 0, block.timestamp + 1), true
        );
    }

    function testStrictModeAlsoRejectsFailedTWAP() public {
        _configure(uint64(Q64 / 100));
        pool.setTick(300);
        vm.expectRevert(TWAPCheckFailed.selector);
        _outcomeCompound(false, SWAP_IN);
    }

    function testProductionRuntimeSizes() public {
        assertLe(address(autoRange).code.length, 24576, "AutoRange exceeds EIP-170");
        assertLe(address(gaugeManager).code.length, 24576, "GaugeManager exceeds EIP-170");
        assertLe(address(vault).code.length, 24576, "Vault exceeds EIP-170");
    }
}
