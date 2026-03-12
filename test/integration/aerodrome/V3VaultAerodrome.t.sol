// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "./AerodromeTestBase.sol";

contract MockLiquidityStripTransformer {
    MockAerodromePositionManager public immutable npm;

    constructor(MockAerodromePositionManager _npm) {
        npm = _npm;
    }

    function execute(uint256 tokenId) external {
        npm.setLiquidity(tokenId, 0);
    }
}

contract V3VaultAerodromeTest is AerodromeTestBase {
    event DebugUint(string label, uint256 value);

    function setUp() public override {
        super.setUp();

        // Set global debt and lend limits (higher to accommodate tests)
        // Increase the daily lend increase limit to allow large deposits
        vault.setLimits(0, 10000000e6, 10000000e6, 10000000e6, 10000000e6);
        //                                           ^^^^^^^^^^^ increased from 10000e6

        // Fund vault with some USDC for lending
        usdc.mint(address(this), 1000000e6);

        // Deposit USDC to vault to create shares (lent assets)
        usdc.approve(address(vault), 1000000e6);
        vault.deposit(1000000e6, address(this));
    }

    function testCreatePositionWithAerodrome() public {
        // Create Aerodrome position
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000000);

        // Deposit to vault
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vm.stopPrank();

        // Check position is owned by vault
        assertEq(npm.ownerOf(tokenId), address(vault));
        assertEq(vault.ownerOf(tokenId), alice);
    }

    function testSetGaugeManager() public {
        address newGaugeManager = address(0x123);

        // Only owner can set
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setGaugeManager(newGaugeManager);

        // Gauge manager is set-once (ops safety): cannot change once configured
        vm.expectRevert(Constants.GaugeManagerAlreadySet.selector);
        vault.setGaugeManager(newGaugeManager);
        assertEq(vault.gaugeManager(), address(gaugeManager));
    }

    function testStakePositionFlow() public {
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000000);

        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);

        // Stake position
        vault.stakePosition(tokenId);
        vm.stopPrank();

        // Position should still be owned by vault in records
        assertEq(vault.ownerOf(tokenId), alice);

        // NFT is now in the gauge (not gauge manager - gauge manager deposits it into the gauge)
        assertEq(npm.ownerOf(tokenId), address(usdcDaiGauge));

        // And tracked as staked
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
    }

    function testStakeRevertsWhenFeesAreRequiredForSolvency() public {
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        uint256 tokenId = createPositionProper(
            alice,
            address(usdc),
            address(dai),
            1,
            -100,
            100,
            0,
            100e6,
            100e18
        );

        (uint256 fullValueWithFees, uint256 feeValue,,) = oracle.getValue(tokenId, address(usdc), false);
        (uint256 fullValueIgnoringFees,,,) = oracle.getValue(tokenId, address(usdc), true);
        assertEq(fullValueIgnoringFees, 0, "position should only be worth uncollected fees");
        assertEq(fullValueWithFees, feeValue, "full value should come entirely from fees");
        assertGt(feeValue, 0, "fee value should be non-zero");

        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vault.borrow(tokenId, 1e6);

        vm.expectRevert(CollateralFail.selector);
        vault.stakePosition(tokenId);
        vm.stopPrank();

        assertEq(npm.ownerOf(tokenId), address(vault), "NFT should remain in vault after reverted stake");
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0), "reverted stake must not mark token as staked");
    }

    function testTransformRevertsWhenRestakeWouldInvalidateHealth() public {
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        MockLiquidityStripTransformer transformer = new MockLiquidityStripTransformer(npm);
        vault.setTransformer(address(transformer), true);

        uint256 tokenId = createPositionProper(
            alice,
            address(usdc),
            address(dai),
            1,
            -100,
            100,
            1e18,
            0,
            0
        );

        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vault.stakePosition(tokenId);
        vault.borrow(tokenId, 5_000);
        vault.approveTransform(tokenId, address(transformer), true);
        vm.stopPrank();

        npm.setTokensOwed(tokenId, 100e6, 100e18);

        (uint256 fullValueIgnoringFees,,,) = oracle.getValue(tokenId, address(usdc), true);
        (uint256 fullValueWithFees, uint256 feeValue,,) = oracle.getValue(tokenId, address(usdc), false);
        assertGt(fullValueIgnoringFees, 0, "position should have non-fee collateral before transform");
        assertEq(fullValueIgnoringFees + feeValue, fullValueWithFees, "fees should be additive before transform");
        assertGt(feeValue, 0, "position should have accrued fees before transform");

        vm.startPrank(alice);
        vm.expectRevert(CollateralFail.selector);
        vault.transform(tokenId, address(transformer), abi.encodeCall(MockLiquidityStripTransformer.execute, (tokenId)));
        vm.stopPrank();

        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge), "failed transform must leave stake intact");
        assertEq(npm.ownerOf(tokenId), address(usdcDaiGauge), "failed transform must revert NFT custody changes");
    }

    function testUnstakePosition() public {
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000000);

        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vault.stakePosition(tokenId);

        // Unstake
        vault.unstakePosition(tokenId);
        vm.stopPrank();

        // NFT back in vault
        assertEq(npm.ownerOf(tokenId), address(vault));
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
        assertEq(vault.ownerOf(tokenId), alice, "Wrong owner");
    }

    function testClaimRewardsFlow() public {
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000000);

        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vault.stakePosition(tokenId);
        vm.stopPrank();

        // Set some rewards
        usdcDaiGauge.setRewardForUser(address(gaugeManager), 100e18);

        uint256 balanceBefore = aero.balanceOf(alice);

        // Claim through gauge manager
        vm.prank(alice);
        uint256 claimed = gaugeManager.claimRewards(tokenId, alice);

        uint256 balanceAfter = aero.balanceOf(alice);
        assertGe(claimed, 100e18);
        assertEq(balanceAfter - balanceBefore, claimed);
    }

    function testRemoveWithStakedPosition() public {
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000000);

        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vault.stakePosition(tokenId);

        // Remove position (should auto-unstake)
        vault.remove(tokenId, alice, "");
        vm.stopPrank();

        // Position returned to alice
        assertEq(npm.ownerOf(tokenId), alice);

        // No longer staked
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
    }

    function testBorrowWithStakedPosition() public {
        // Create position with explicit token amounts for better collateral value
        uint256 tokenId = createPositionProper(
            alice,
            address(usdc),
            address(dai),
            1,
            -100,
            100,
            1e18,
            1000e6, // 1000 USDC
            1000e18 // 1000 DAI
        );

        // Set a very high maxPoolPriceDifference to bypass the price check
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vault.stakePosition(tokenId);

        (, uint256 fullValueAfterStake, uint256 collateralValueAfterStake,,) = vault.loanInfo(tokenId);
        assertGt(fullValueAfterStake, 0, "staked full value should be non-zero");
        assertGt(collateralValueAfterStake, 0, "staked collateral should be non-zero");

        uint256 borrowAmount = collateralValueAfterStake * vault.BORROW_SAFETY_BUFFER_X32() / Q32 / 2;
        if (borrowAmount > 1e6) {
            borrowAmount = 1e6;
        }
        assertGt(borrowAmount, 0, "borrow amount should be non-zero");

        // Should still be able to borrow against staked position, but using staked-aware valuation.
        vault.borrow(tokenId, borrowAmount);
        vm.stopPrank();

        // Check loan exists
        (uint256 debt,,,,) = vault.loanInfo(tokenId);
        assertGt(debt, 0);
    }

    function testStakeWithoutGaugeManager() public {
        // Use a fresh vault instance without configuring gauge manager
        V3Vault vaultNoGauge = new V3Vault("Revert Lend USDC", "rlUSDC", address(usdc), npm, irm, oracle);

        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000000);

        vm.startPrank(alice);
        npm.approve(address(vaultNoGauge), tokenId);
        vaultNoGauge.create(tokenId, alice);

        vm.expectRevert(GaugeManagerNotSet.selector);
        vaultNoGauge.stakePosition(tokenId);
        vm.stopPrank();
    }

    function testMultipleUsersStaking() public {
        // Alice stakes
        uint256 aliceTokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000000);
        vm.startPrank(alice);
        npm.approve(address(vault), aliceTokenId);
        vault.create(aliceTokenId, alice);
        vault.stakePosition(aliceTokenId);
        vm.stopPrank();

        // Bob stakes
        uint256 bobTokenId = createPosition(bob, address(weth), address(usdc), 10, -1000, 1000, 500000);
        vm.startPrank(bob);
        npm.approve(address(vault), bobTokenId);
        vault.create(bobTokenId, bob);
        vault.stakePosition(bobTokenId);
        vm.stopPrank();

        // Both positions staked in different gauges
        assertEq(gaugeManager.tokenIdToGauge(aliceTokenId), address(usdcDaiGauge));
        assertEq(gaugeManager.tokenIdToGauge(bobTokenId), address(wethUsdcGauge));
    }

    function testUnstakeOfStakedPositionWithDebt() public {
        uint256 tokenId = createPositionProper(
            alice,
            address(usdc),
            address(dai),
            1,
            -100,
            100,
            1e18,
            50e6, // 50 USDC
            50e18 // 50 DAI
        );

        // Set a very high maxPoolPriceDifference to bypass the price check
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        vm.startPrank(alice);

        // Deposit to vault
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);

        // Stake first so borrowing uses the staked-collateral valuation model.
        vault.stakePosition(tokenId);

        (, uint256 fullValueAfterStake, uint256 collateralValueAfterStake,,) = vault.loanInfo(tokenId);
        assertGt(fullValueAfterStake, 0, "staked full value should be non-zero");
        assertGt(collateralValueAfterStake, 0, "staked collateral should be non-zero");

        // Borrow against the already-staked position.
        uint256 borrowAmount = collateralValueAfterStake * vault.BORROW_SAFETY_BUFFER_X32() / Q32 / 4;
        assertGt(borrowAmount, 0, "borrow amount should be non-zero");
        vault.borrow(tokenId, borrowAmount);

        // Verify debt exists
        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);
        assertGt(debtBefore, 0, "Should have debt before staking");

        // Now unstake to trigger the bug
        vault.unstakePosition(tokenId);

        // Check debt after unstaking
        (uint256 debtAfter,,,,) = vault.loanInfo(tokenId);

        assertEq(debtAfter, debtBefore, "Debt should remain after unstaking");

        vm.stopPrank();
    }

    function testSetGaugeValidation() public {
        // Try to set wrong gauge for a pool
        address wrongGauge = address(0x1234);

        vm.expectRevert(Constants.InvalidPool.selector);
        gaugeManager.setGauge(usdcDaiPool, wrongGauge);

        // Try to set zero gauge
        vm.expectRevert(Constants.InvalidConfig.selector);
        gaugeManager.setGauge(usdcDaiPool, address(0));

        // Setting correct gauge should work (already done in setup)
        // Verify it was set correctly
        assertEq(gaugeManager.poolToGauge(usdcDaiPool), address(usdcDaiGauge));
    }

    function testCompoundRewardsInvalidSplit() public {
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000000);

        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vault.stakePosition(tokenId);
        usdcDaiGauge.setRewardForUser(address(gaugeManager), 10e18);

        // Test 1: Try to compound with invalid split (> 10000 bps)
        vm.expectRevert(Constants.InvalidConfig.selector);
        gaugeManager.compoundRewards(tokenId, 0, 10001, block.timestamp + 1000);

        // Test 2: Valid split compounds through the configured AERO -> USDC base route.
        gaugeManager.compoundRewards(tokenId, 0, 5000, block.timestamp + 1000);

        // Test 3: Compounding reverts when the required AERO base pool is missing.
        usdcDaiGauge.setRewardForUser(address(gaugeManager), 10e18);
        vm.stopPrank();
        gaugeManager.setRewardBasePool(address(usdc), address(0));
        vm.startPrank(alice);
        vm.expectRevert(Constants.NotConfigured.selector);
        gaugeManager.compoundRewards(tokenId, 0, 5000, block.timestamp + 1000);

        vm.stopPrank();
    }

    function testLiquidateStakedPosition() public {
        uint32 cf80Percent = uint32(Q32 * 80 / 100);
        vault.setTokenConfig(address(usdc), cf80Percent, type(uint32).max);
        vault.setTokenConfig(address(dai), cf80Percent, type(uint32).max);

        uint256 tokenId = createPositionProper(
            alice,
            address(usdc),
            address(dai),
            1,
            -100,
            100,
            1e18,
            100e6,
            100e18
        );

        oracle.setMaxPoolPriceDifference(type(uint16).max);

        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vault.stakePosition(tokenId);

        (, uint256 fullValueAfterStake, uint256 collateralValueAfterStake,,) = vault.loanInfo(tokenId);
        assertGt(fullValueAfterStake, 0, "staked full value should be non-zero");
        assertGt(collateralValueAfterStake, 0, "staked collateral should be non-zero");

        uint256 borrowAmount = collateralValueAfterStake * vault.BORROW_SAFETY_BUFFER_X32() / Q32 * 9 / 10;
        vault.borrow(tokenId, borrowAmount);
        vm.stopPrank();

        usdcDaiGauge.setRewardRate(0);
        usdcDaiGauge.setRewardForUser(address(gaugeManager), 1e18);

        // Verify position is staked
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
        assertEq(npm.ownerOf(tokenId), address(usdcDaiGauge));

        daiFeed = new MockChainlinkAggregator(1, 8); // $0.00000001 with 8 decimals
        oracle.setTokenConfig(
            address(dai),
            AggregatorV3Interface(address(daiFeed)),
            3600,
            IUniswapV3Pool(usdcDaiPool),
            60,
            V3Oracle.Mode.CHAINLINK_TWAP_VERIFY,
            type(uint16).max
        );

        vm.warp(block.timestamp + 1 days);

        (uint256 debtCheck,,,,) = vault.loanInfo(tokenId);

        // Give Bob enough USDC to cover the debt (debt includes interest accrued)
        usdc.mint(bob, debtCheck);

        uint256 aliceAeroBefore = aero.balanceOf(alice);

        // Perform liquidation
        vm.startPrank(bob);
        usdc.approve(address(vault), debtCheck);

        // Set liquidation parameters
        IVault.LiquidateParams memory params = IVault.LiquidateParams({
            tokenId: tokenId, amount0Min: 0, amount1Min: 0, recipient: bob, deadline: block.timestamp + 1000
        });

        // Liquidate the staked position
        (uint256 amount0, uint256 amount1) = vault.liquidate(params);
        vm.stopPrank();

        // Verify liquidation succeeded
        assertGt(amount0 + amount1, 0, "Liquidation should return collateral");

        // Verify position was unstaked during liquidation
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0), "Position should be unstaked");

        assertEq(npm.ownerOf(tokenId), address(vault), "NFT should be owned by vault after liquidation");

        // Vault should still track the original owner (alice) after liquidation
        assertEq(vault.ownerOf(tokenId), alice, "Vault should track alice as owner after liquidation");

        // Verify liquidation forwards claimed rewards on unstake
        uint256 aliceAeroAfter = aero.balanceOf(alice);
        assertEq(aliceAeroAfter - aliceAeroBefore, 1e18, "AERO reward should be forwarded to user on unstake");

        // Verify loan is cleared
        (uint256 debt,,,,) = vault.loanInfo(tokenId);
        assertEq(debt, 0, "Debt should be cleared after liquidation");
    }
}
