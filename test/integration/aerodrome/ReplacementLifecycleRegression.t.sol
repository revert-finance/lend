// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./OperatorStaking.t.sol";

contract ReplacementLifecycleRegression is OperatorStakingTest {
    function testDepositorCannotClearAnotherPositionsCooldownThroughTransform() public {
        vault.setStakingPolicy(address(autoRange));
        autoRange.setStakeChangeCooldown(50);
        uint256 victimTokenId = _createVaultPosition(address(usdc), address(dai), 1, false);
        npm.setTokensOwed(victimTokenId, 0, 0);
        _optIn(victimTokenId, true);
        _flip(victimTokenId, IVault.StakeTarget.Staked);
        uint256 decisionBlock = autoRange.lastStakeChangeBlock(victimTokenId);
        assertGt(decisionBlock, 0);
        vm.roll(decisionBlock + 1);

        uint256 attackerTokenId = createPosition(bob, address(usdc), address(dai), 1, -100, 100, 1000e18);
        npm.setTokensOwed(attackerTokenId, 0, 0);
        _enrollInVaultAs(bob, attackerTokenId, false);
        assertEq(autoRange.lastStakeChangeBlock(attackerTokenId), 0);

        // The vault is an authorized caller and is transforming Bob's NFT, but has received no replacement.
        vm.prank(bob);
        vm.expectRevert(TransformFailed.selector);
        vault.transform(
            attackerTokenId,
            address(autoRange),
            abi.encodeCall(autoRange.migrateStakingPolicy, (attackerTokenId, victimTokenId))
        );

        assertEq(vault.ownerOf(attackerTokenId), bob);
        assertEq(autoRange.stakingConsent(victimTokenId, address(vault)), alice);
        assertEq(autoRange.lastStakeChangeBlock(victimTokenId), decisionBlock);
        vm.prank(admin);
        vm.expectRevert(NotReady.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(victimTokenId), address(vault), _rewardParams(IVault.StakeTarget.Unstaked)
        );
        assertEq(gaugeManager.tokenIdToGauge(victimTokenId), address(usdcDaiGauge));
    }

    function testRewardCompoundRangeChecksReadinessBeforeItsRewardSwap() public {
        (uint256 tokenId, uint256 windowEnd) = _stakedInsidePenaltyWindow();
        vm.roll(windowEnd);
        vm.prank(alice);
        autoRange.configToken(tokenId, address(vault), _rangeChangeConfig(), AutoRangeAndCompound.CompoundMode.Advanced);
        assertEq(autoRange.stakingConsent(tokenId, address(vault)), address(0));
        MockPool(usdcDaiPool).setTick(99);
        gaugeManager.setRewardBasePool(address(dai), address(0));
        MockPool(usdcDaiPool).setTickAfterSwap(101);

        IVault.RewardCompoundParams memory rewardParams = _rewardParams(IVault.StakeTarget.Keep);
        rewardParams.aeroSplitBps = 5000;

        // Keep custody is callable without staking-management consent, but must not bypass the range trigger.
        vm.prank(admin);
        vm.expectRevert(NotReady.selector);
        autoRange.executeWithVaultAndRewardCompound(
            _executeParams(tokenId), address(vault), rewardParams
        );
        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(usdcDaiGauge.rewards(tokenId), 7e18);
        assertEq(MockPool(usdcDaiPool).tick(), 99);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));

        // Once the position is already ready, the same operation compounds and replaces it successfully.
        MockPool(usdcDaiPool).setTick(101);
        vm.prank(admin);
        autoRange.executeWithVaultAndRewardCompound(
            _executeParams(tokenId), address(vault), rewardParams
        );
        uint256 newTokenId = npm.lastMintedTokenId();
        assertTrue(newTokenId != tokenId);
        assertEq(vault.ownerOf(newTokenId), alice);
        assertEq(usdcDaiGauge.rewards(tokenId), 0);
        assertEq(gaugeManager.tokenIdToGauge(newTokenId), address(usdcDaiGauge));
    }

    function testWalletReplacementClearsModeAndPreservesBothCooldowns() public {
        uint256 oldTokenId = _createVaultPosition(address(usdc), address(dai), 1, false);
        npm.setTokensOwed(oldTokenId, 0, 0);
        _optIn(oldTokenId, true);
        autoRange.setStakeChangeCooldown(1000);
        _flip(oldTokenId, IVault.StakeTarget.Staked);
        uint256 decisionBlock = autoRange.lastStakeChangeBlock(oldTokenId);
        vm.roll(gaugeManager.penaltyWindowEnd(oldTokenId));
        vm.prank(alice);
        vault.remove(oldTokenId, alice, "");
        vm.startPrank(alice);
        npm.approve(address(autoRange), oldTokenId);
        autoRange.configToken(oldTokenId, address(0), _rangeChangeConfig(), AutoRangeAndCompound.CompoundMode.Simple);
        vm.stopPrank();
        MockPool(usdcDaiPool).setTick(200);
        npm.setLiquidity(oldTokenId, 0);
        npm.setTokensOwed(oldTokenId, 0, 0);
        vm.prank(admin);
        autoRange.execute(_executeParams(oldTokenId));
        uint256 newTokenId = npm.lastMintedTokenId();
        assertEq(uint256(autoRange.compoundModes(newTokenId)), uint256(AutoRangeAndCompound.CompoundMode.Simple));
        assertEq(uint256(autoRange.compoundModes(oldTokenId)), uint256(AutoRangeAndCompound.CompoundMode.Advanced));
        assertEq(autoRange.lastStakeChangeBlock(oldTokenId), decisionBlock);
        assertEq(autoRange.lastStakeChangeBlock(newTokenId), decisionBlock);

        // Reusing the original NFT must not permit another custody decision during its original cooldown.
        npm.setLiquidity(oldTokenId, 1000e18);
        _enrollInVault(oldTokenId, false);
        vm.prank(admin);
        vm.expectRevert(NotReady.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(oldTokenId), address(vault), _rewardParams(IVault.StakeTarget.Staked)
        );
    }

    function testSameOwnerVaultReplacementCarriesConsentAndCooldown() public {
        vault.setStakingPolicy(address(autoRange));
        uint256 oldTokenId = _createVaultPosition(address(usdc), address(dai), 1, false);
        npm.setTokensOwed(oldTokenId, 0, 0);
        _optIn(oldTokenId, true);
        _flip(oldTokenId, IVault.StakeTarget.Staked);
        uint256 decisionBlock = autoRange.lastStakeChangeBlock(oldTokenId);
        vm.roll(gaugeManager.penaltyWindowEnd(oldTokenId));
        MockPool(usdcDaiPool).setTick(200);
        vm.prank(alice);
        autoRange.configToken(
            oldTokenId, address(vault), _rangeChangeConfig(), AutoRangeAndCompound.CompoundMode.Advanced
        );
        vm.prank(admin);
        autoRange.executeWithVault(_executeParams(oldTokenId), address(vault));
        uint256 newTokenId = npm.lastMintedTokenId();
        assertEq(autoRange.stakingConsent(oldTokenId, address(vault)), address(0));
        assertEq(autoRange.stakingConsent(newTokenId, address(vault)), alice);
        assertEq(autoRange.lastStakeChangeBlock(newTokenId), decisionBlock);
    }

    function testStakingMigrationRejectsUnregisteredCaller() public {
        vm.expectRevert(Unauthorized.selector);
        autoRange.migrateStakingPolicy(1, 2);
    }

    function testStakingMigrationRejectsIdleRegisteredVault() public {
        vm.prank(address(vault));
        vm.expectRevert(Unauthorized.selector);
        autoRange.migrateStakingPolicy(1, 2);
    }

    function testStakingMigrationRejectsEmptyContext() public {
        vm.prank(address(vault));
        vm.expectRevert(Unauthorized.selector);
        autoRange.migrateStakingPolicy(0, 0);
    }

    function testPlainRangeCannotBecomeReadyThroughItsRewardSwap() public {
        (uint256 tokenId, uint256 windowEnd) = _stakedInsidePenaltyWindow();
        vm.roll(windowEnd);
        vm.prank(alice);
        autoRange.configToken(tokenId, address(vault), _rangeChangeConfig(), AutoRangeAndCompound.CompoundMode.Advanced);
        MockPool(usdcDaiPool).setTick(99);
        // One reward route goes through the position pool and crosses the owner's upper trigger.
        gaugeManager.setRewardBasePool(address(dai), address(0));
        MockPool(usdcDaiPool).setTickAfterSwap(101);
        vm.prank(admin);
        vm.expectRevert(NotReady.selector);
        autoRange.executeWithVault(_executeParams(tokenId), address(vault));
        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(usdcDaiGauge.rewards(tokenId), 7e18);
        assertEq(MockPool(usdcDaiPool).tick(), 99);

        // Control: the old callback ordering does cross the trigger and replace the position.
        vm.prank(alice);
        vault.transform(tokenId, address(autoRange), abi.encodeCall(autoRange.execute, (_executeParams(tokenId))));
        assertEq(MockPool(usdcDaiPool).tick(), 101);
        assertEq(vault.ownerOf(npm.lastMintedTokenId()), alice);
        assertTrue(npm.lastMintedTokenId() != tokenId);
    }
}
