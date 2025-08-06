// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AerodromeTestBase.sol";

contract GaugeManagerTest is AerodromeTestBase {
    uint256 tokenId1;
    uint256 tokenId2;
    
    function setUp() public override {
        super.setUp();
        
        // Create test positions
        tokenId1 = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000000);
        tokenId2 = createPosition(bob, address(weth), address(usdc), 10, -1000, 1000, 500000);
    }
    
    function testSetGauge() public {
        address newPool = address(0x123);
        address newGauge = address(0x456);
        
        vm.prank(admin);
        vm.expectRevert("Ownable: caller is not the owner");
        gaugeManager.setGauge(newPool, newGauge);
        
        gaugeManager.setGauge(newPool, newGauge);
        assertEq(gaugeManager.poolToGauge(newPool), newGauge);
    }
    
    function testStakePosition() public {
        // Alice deposits position to vault
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId1);
        vault.create(tokenId1, alice);
        
        // Stake position
        vault.stakePosition(tokenId1);
        vm.stopPrank();
        
        // Check position is staked
        assertEq(gaugeManager.getPositionGauge(tokenId1), address(usdcDaiGauge));
        assertTrue(usdcDaiGauge.isStaked(tokenId1));
    }
    
    function testStakePositionUnauthorized() public {
        // Alice deposits position to vault
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId1);
        vault.create(tokenId1, alice);
        vm.stopPrank();
        
        // Bob tries to stake Alice's position
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        vault.stakePosition(tokenId1);
    }
    
    function testStakePositionNoGauge() public {
        // Create position for pool without gauge
        uint256 tokenId = createPosition(alice, address(0x111), address(0x222), 50, -100, 100, 1000);
        
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        
        // Set a pool without gauge in factory
        factory.setPool(address(0x111), address(0x222), 50, address(0x333));
        
        vm.expectRevert(GaugeNotSet.selector);
        vault.stakePosition(tokenId);
        vm.stopPrank();
    }
    
    function testUnstakePosition() public {
        // Setup: stake position
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId1);
        vault.create(tokenId1, alice);
        vault.stakePosition(tokenId1);
        
        // Unstake position
        vault.unstakePosition(tokenId1);
        vm.stopPrank();
        
        // Check position is no longer staked
        assertEq(gaugeManager.getPositionGauge(tokenId1), address(0));
        assertFalse(usdcDaiGauge.isStaked(tokenId1));
    }
    
    function testUnstakePositionNotStaked() public {
        // Alice deposits position to vault
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId1);
        vault.create(tokenId1, alice);
        
        // Try to unstake non-staked position
        vm.expectRevert(NotStaked.selector);
        vault.unstakePosition(tokenId1);
        vm.stopPrank();
    }
    
    function testClaimRewards() public {
        // Setup: stake position and set rewards
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId1);
        vault.create(tokenId1, alice);
        vault.stakePosition(tokenId1);
        vm.stopPrank();
        
        // Set rewards in gauge
        usdcDaiGauge.setRewardForUser(address(gaugeManager), 100e18);
        
        uint256 balanceBefore = aero.balanceOf(alice);
        
        // Claim rewards
        vm.prank(alice);
        vault.claimRewards(tokenId1);
        
        uint256 balanceAfter = aero.balanceOf(alice);
        assertGt(balanceAfter, balanceBefore);
    }
    
    function testClaimRewardsMultiple() public {
        // Setup: stake multiple positions
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId1);
        vault.create(tokenId1, alice);
        vault.stakePosition(tokenId1);
        vm.stopPrank();
        
        vm.startPrank(bob);
        npm.approve(address(vault), tokenId2);
        vault.create(tokenId2, bob);
        vault.stakePosition(tokenId2);
        vm.stopPrank();
        
        // Set rewards
        usdcDaiGauge.setRewardForUser(address(gaugeManager), 100e18);
        wethUsdcGauge.setRewardForUser(address(gaugeManager), 200e18);
        
        // Claim multiple
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;
        
        gaugeManager.claimRewardsMultiple(tokenIds);
        
        // Check accumulated rewards
        assertGt(gaugeManager.accumulatedRewards(tokenId1), 0);
        assertGt(gaugeManager.accumulatedRewards(tokenId2), 0);
    }
    
    function testDistributeRewards() public {
        // Setup: stake and claim rewards
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId1);
        vault.create(tokenId1, alice);
        vault.stakePosition(tokenId1);
        vm.stopPrank();
        
        usdcDaiGauge.setRewardForUser(address(gaugeManager), 100e18);
        gaugeManager.claimRewards(tokenId1);
        
        uint256 accumulated = gaugeManager.accumulatedRewards(tokenId1);
        assertGt(accumulated, 0);
        
        uint256 balanceBefore = aero.balanceOf(alice);
        
        // Distribute rewards (only vault can call)
        vm.prank(address(vault));
        gaugeManager.distributeRewards(tokenId1, alice);
        
        uint256 balanceAfter = aero.balanceOf(alice);
        assertEq(balanceAfter - balanceBefore, accumulated);
        assertEq(gaugeManager.accumulatedRewards(tokenId1), 0);
    }
    
    function testDistributeRewardsUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        gaugeManager.distributeRewards(tokenId1, alice);
    }
    
    function testPendingRewards() public {
        // Setup: stake position
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId1);
        vault.create(tokenId1, alice);
        vault.stakePosition(tokenId1);
        vm.stopPrank();
        
        // Check pending rewards
        uint256 pending = gaugeManager.pendingRewards(tokenId1);
        assertGt(pending, 0); // Should have some rewards from staking
        
        // Claim and check pending includes accumulated
        gaugeManager.claimRewards(tokenId1);
        uint256 pendingAfterClaim = gaugeManager.pendingRewards(tokenId1);
        assertGt(pendingAfterClaim, pending);
    }
    
    function testOnERC721Received() public {
        // Test the ERC721 receiver interface
        bytes4 selector = gaugeManager.onERC721Received(address(0), address(0), 0, "");
        assertEq(selector, IERC721Receiver.onERC721Received.selector);
    }
}