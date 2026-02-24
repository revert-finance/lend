// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "./AerodromeTestBase.sol";

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
        gaugeManager.claimRewards(tokenId, alice);

        uint256 balanceAfter = aero.balanceOf(alice);
        assertGt(balanceAfter, balanceBefore);
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

        // Should be able to borrow against staked position
        vault.borrow(tokenId, 1e6); // Borrow only 1 USDC (reduced from 10 USDC)
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
        // Create position with smaller collateral to fit within limits
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

        // Borrow against position (small amount to ensure it's safe initially)
        vault.borrow(tokenId, 10e6); // Borrow 10 USDC

        // Verify debt exists
        (uint256 debtBefore,,,,) = vault.loanInfo(tokenId);
        assertGt(debtBefore, 0, "Should have debt before staking");

        // Stake the position
        vault.stakePosition(tokenId);

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
        gaugeManager.compoundRewards(
            tokenId,
            new bytes(1), // swapData0 present
            new bytes(0), // swapData1 missing
            0, // minAmount0
            0, // minAmount1
            10001, // aeroSplitBps > 10000 (invalid)
            block.timestamp + 1000 // deadline
        );

        // Test 2: Partial split without payloads is allowed (unswapped AERO is returned to owner).
        gaugeManager.compoundRewards(
            tokenId,
            new bytes(0), // swapData0
            new bytes(0), // swapData1
            0, // minAmount0
            0, // minAmount1
            5000,
            block.timestamp + 1000 // deadline
        );

        // Test 3: malformed swap payload still reverts (selector is not stable here).
        usdcDaiGauge.setRewardForUser(address(gaugeManager), 10e18);
        vm.expectRevert();
        gaugeManager.compoundRewards(
            tokenId,
            new bytes(1), // invalid swapData0
            new bytes(0),
            0, // minAmount0
            0, // minAmount1
            5000,
            block.timestamp + 1000 // deadline
        );

        vm.stopPrank();
    }

    function testLiquidateStakedPosition() public {
        // Set proper collateral factors using X32 scaling
        // 80% CF = 0.80 * Q32 = 0.80 * 2^32 = 3,435,973,836
        uint32 cf80Percent = uint32(Q32 * 80 / 100);
        vault.setTokenConfig(address(usdc), cf80Percent, type(uint32).max); // 80% CF, max limit
        vault.setTokenConfig(address(dai), cf80Percent, type(uint32).max); // 80% CF, max limit

        // Create position with larger amounts to allow meaningful borrowing
        uint256 tokenId = createPositionProper(
            alice,
            address(usdc),
            address(dai),
            1,
            -100,
            100,
            0, // No liquidity - value comes only from tokensOwed
            100e6, // 100 USDC
            100e18 // 100 DAI
        );

        // Set a very high maxPoolPriceDifference to bypass the price check
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);

        // Borrow against the position
        // 100 USDC + 100 DAI = ~$200 total value
        // With 80% CF = $160 borrowing power, but vault may have additional safety buffer
        // Borrow 140 USDC
        vault.borrow(tokenId, 140e6);
        usdcDaiGauge.setRewardRate(0);
        usdcDaiGauge.setRewardForUser(address(gaugeManager), 1e18);

        // Stake the position
        vault.stakePosition(tokenId);
        vm.stopPrank();

        // Verify position is staked
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
        assertEq(npm.ownerOf(tokenId), address(usdcDaiGauge));

        // Make position underwater by dropping collateral value
        // Set USDC collateral value to lower (note: this affects collateral, not debt value)
        // Since the oracle values positions in the base asset (USDC), we need to
        // effectively reduce the total position value in USDC terms

        // Drop DAI price to almost zero to reduce total collateral value
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

        // Advance time to accrue interest
        vm.warp(block.timestamp + 1 days);

        // Bob will liquidate Alice's position
        // Debug: Check position values before liquidation to know how much Bob needs
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
