// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./OperatorStaking.t.sol";

/// @notice An intervening owner must not copy a previous owner's staking consent into a replacement NFT.
contract StakingConsentRegression is OperatorStakingTest {
    function testReplacementDoesNotMigratePreviousOwnersConsent() public {
        uint256 oldTokenId = _createVaultPosition(address(usdc), address(dai), 1, false);
        _optIn(oldTokenId, true);

        // Alice removes the consented NFT and sells it to Bob. Bob has no staking consent.
        vm.prank(alice);
        vault.remove(oldTokenId, alice, "");
        vm.prank(alice);
        npm.transferFrom(alice, bob, oldTokenId);
        _enrollInVaultAs(bob, oldTokenId, false);
        vm.prank(bob);
        autoRange.configToken(
            oldTokenId, address(vault), _rangeChangeConfig(), AutoRangeAndCompound.CompoundMode.Advanced
        );

        assertEq(autoRange.stakingConsent(oldTokenId, address(vault)), alice);
        vm.prank(admin);
        vm.expectRevert(Unauthorized.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(oldTokenId), address(vault), _rewardParams(IVault.StakeTarget.Staked)
        );

        // Bob can still perform an ordinary, custody-preserving range replacement.
        MockPool(usdcDaiPool).setTick(200);
        npm.setLiquidity(oldTokenId, 0);
        npm.setTokensOwed(oldTokenId, 0, 0);
        vm.prank(admin);
        autoRange.executeWithVault(_executeParams(oldTokenId), address(vault));

        uint256 replacementTokenId = npm.lastMintedTokenId();
        assertEq(vault.ownerOf(replacementTokenId), bob);
        assertEq(autoRange.stakingConsent(replacementTokenId, address(vault)), address(0));
        assertEq(autoRange.stakingConsent(oldTokenId, address(vault)), address(0));

        // Bob returns the replacement to Alice. Removal does not clear AutoRange's consent mapping.
        vm.prank(bob);
        vault.remove(replacementTokenId, bob, "");
        vm.prank(bob);
        npm.transferFrom(bob, alice, replacementTokenId);

        // Alice redeposits and grants only ordinary transform permission, not staking consent.
        vm.startPrank(alice);
        npm.approve(address(vault), replacementTokenId);
        vault.create(replacementTokenId, alice);
        vault.approveTransform(replacementTokenId, address(autoRange), true);
        vm.stopPrank();

        assertEq(vault.ownerOf(replacementTokenId), alice);
        assertEq(autoRange.stakingConsent(replacementTokenId, address(vault)), address(0));

        // A previous owner's consent must not authorize a later custody change.
        vm.prank(admin);
        vm.expectRevert(Unauthorized.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(replacementTokenId), address(vault), _rewardParams(IVault.StakeTarget.Staked)
        );

        assertEq(gaugeManager.tokenIdToGauge(replacementTokenId), address(0));
        assertEq(npm.ownerOf(replacementTokenId), address(vault));
        assertEq(autoRange.lastStakeChangeBlock(replacementTokenId), 0);
    }
}
