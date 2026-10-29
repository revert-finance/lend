// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AerodromeTestBase.sol";
import "../../../src/transformers/AutoRangeAndCompound.sol";
import "../../../src/transformers/V3Utils.sol";
import "../../../src/interfaces/IVault.sol";
import "../../../test/mocks/AeroDeliveryFixture.sol";

/// @notice A V3Utils replacement must inherit the prior operator decision instead of resetting its cooldown.
contract V3UtilsCooldownRegression is AerodromeTestBase {
    AutoRangeAndCompound internal autoRange;
    V3Utils internal v3utils;

    function setUp() public override {
        super.setUp();

        autoRange = new AutoRangeAndCompound(
            INonfungiblePositionManager(address(npm)), admin, admin, 60, 200, address(0), address(0)
        );
        v3utils = new V3Utils(INonfungiblePositionManager(address(npm)), address(0x1), address(0x2));

        vault.setTransformer(address(autoRange), true);
        vault.setTransformer(address(v3utils), true);
        autoRange.setVault(address(vault));
        vault.setStakingPolicy(address(autoRange));
        gaugeManager.setCompoundModeSource(address(autoRange));
        v3utils.setVault(address(vault));
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        // The position and V3Utils replacement both use the 500 tick spacing.
        if (address(usdc) < address(dai)) {
            factory.setPool(address(usdc), address(dai), 500, usdcDaiPool);
        } else {
            factory.setPool(address(dai), address(usdc), 500, usdcDaiPool);
        }

        // Make the valid upstream-style penalty window shorter than the owner-set cooldown.
        AeroGaugeFactoryFixture(usdcDaiGauge.gaugeFactory()).setConfig(5, 200_000, address(0), 0);
        autoRange.setStakeChangeCooldown(50);
    }

    function _changeRangeInstructions() internal view returns (V3Utils.Instructions memory) {
        return V3Utils.Instructions({
            whatToDo: V3Utils.WhatToDo.CHANGE_RANGE,
            targetToken: address(0),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            feeAmount0: 0,
            feeAmount1: 0,
            fee: 500,
            tickLower: -500,
            tickUpper: 500,
            liquidity: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: type(uint256).max,
            recipient: alice,
            recipientNFT: address(vault),
            unwrap: false,
            returnData: "",
            swapAndMintReturnData: ""
        });
    }

    function testV3UtilsReplacementPreservesOperatorCooldown() public {
        _assertReplacementPreservesCooldown(false);
    }

    function testV3UtilsReplacementPreservesCooldownWithoutFeeSource() public {
        gaugeManager.setCompoundModeSource(address(0));
        _assertReplacementPreservesCooldown(false);
    }

    function testV3UtilsReplacementPreservesCooldownAfterDisablingFeeSource() public {
        _assertReplacementPreservesCooldown(true);
    }

    function testStakingPolicyCannotBeClearedOrReplaced() public {
        vm.expectRevert(InvalidConfig.selector);
        vault.setStakingPolicy(address(0));
        vm.expectRevert(InvalidConfig.selector);
        vault.setStakingPolicy(address(v3utils));
        assertEq(vault.stakingPolicy(), address(autoRange));
    }

    function _assertReplacementPreservesCooldown(bool disableFeeSourceAfterDecision) internal {
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 500, -100, 100, 1000e18);
        npm.setTokensOwed(tokenId, 0, 0);

        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vault.approveTransform(tokenId, admin, true);
        vault.approveTransform(tokenId, address(autoRange), true);
        autoRange.configStakingManagement(tokenId, address(vault), true);
        vm.stopPrank();

        AutoRangeAndCompound.AutoCompoundParams memory autoParams = AutoRangeAndCompound.AutoCompoundParams({
            tokenId: tokenId, swap0To1: true, amountIn: 0, deadline: block.timestamp + 1 hours
        });
        IVault.RewardCompoundParams memory stakeParams = IVault.RewardCompoundParams({
            minAeroReward: 0,
            aeroSplitBps: 0,
            deadline: block.timestamp + 1 hours,
            stakeTarget: IVault.StakeTarget.Staked
        });

        // B: the first real operator custody decision records the cooldown timestamp for the old NFT.
        vm.prank(admin);
        autoRange.autoCompoundWithVaultAndRewardCompound(autoParams, address(vault), stakeParams);
        uint256 firstDecisionBlock = autoRange.lastStakeChangeBlock(tokenId);
        assertEq(autoRange.lastStakeChangeBlock(tokenId), firstDecisionBlock);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));

        if (disableFeeSourceAfterDecision) gaugeManager.setCompoundModeSource(address(0));

        // The owner performs a supported V3Utils replacement after the old penalty window ends.
        vm.roll(gaugeManager.penaltyWindowEnd(tokenId));
        vm.prank(alice);
        uint256 newTokenId = vault.transform(
            tokenId, address(v3utils), abi.encodeCall(V3Utils.execute, (tokenId, _changeRangeInstructions()))
        );

        assertTrue(newTokenId != tokenId);
        assertEq(vault.ownerOf(newTokenId), alice);
        assertEq(npm.ownerOf(newTokenId), address(usdcDaiGauge));
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
        // V3Vault migrates the approval of the caller (Alice), not an unrelated AutoRange approval. This is a
        // negative control for the report's stated "already migrated" prerequisite.
        assertFalse(vault.transformApprovals(alice, newTokenId, address(autoRange)));
        assertEq(autoRange.lastStakeChangeBlock(newTokenId), firstDecisionBlock, "replacement inherits cooldown");

        // Re-consent is valid for the same current owner, but it must not waive the existing cooldown.
        vm.prank(alice);
        autoRange.configStakingManagement(newTokenId, address(vault), true);
        uint256 replacementPenaltyEnd = gaugeManager.penaltyWindowEnd(newTokenId);
        assertLt(replacementPenaltyEnd, firstDecisionBlock + autoRange.stakeChangeCooldownBlocks());
        vm.roll(replacementPenaltyEnd);

        // The wrapper must enforce the inherited cooldown even before the owner restores transform approval.
        stakeParams.stakeTarget = IVault.StakeTarget.Unstaked;
        vm.prank(admin);
        vm.expectRevert(NotReady.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(autoParamsFor(newTokenId), address(vault), stakeParams);
        assertEq(autoRange.lastStakeChangeBlock(newTokenId), firstDecisionBlock);
        assertEq(gaugeManager.tokenIdToGauge(newTokenId), address(usdcDaiGauge));

        // Re-approving the configured operator is a valid owner action, but it must not waive the existing cooldown.
        vm.prank(alice);
        vault.approveTransform(newTokenId, address(autoRange), true);

        vm.prank(admin);
        vm.expectRevert(NotReady.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(autoParamsFor(newTokenId), address(vault), stakeParams);
        assertEq(gaugeManager.tokenIdToGauge(newTokenId), address(usdcDaiGauge));
        vm.roll(firstDecisionBlock + autoRange.stakeChangeCooldownBlocks());
        vm.prank(admin);
        autoRange.autoCompoundWithVaultAndRewardCompound(autoParamsFor(newTokenId), address(vault), stakeParams);

        assertEq(gaugeManager.tokenIdToGauge(newTokenId), address(0));
        assertEq(npm.ownerOf(newTokenId), address(vault));
        assertEq(autoRange.lastStakeChangeBlock(newTokenId), firstDecisionBlock + autoRange.stakeChangeCooldownBlocks());
        assertLt(replacementPenaltyEnd, firstDecisionBlock + autoRange.stakeChangeCooldownBlocks());
    }

    function autoParamsFor(uint256 tokenId) internal view returns (AutoRangeAndCompound.AutoCompoundParams memory) {
        return AutoRangeAndCompound.AutoCompoundParams({
            tokenId: tokenId, swap0To1: true, amountIn: 0, deadline: block.timestamp + 1 hours
        });
    }
}

contract StakingPolicyBindingTest is AerodromeTestBase {
    function testOnlyOwnerCanBindStakingPolicy() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setStakingPolicy(address(npm));
        assertEq(vault.stakingPolicy(), address(0));
    }

    function testStakingPolicyRejectsZeroAndNonContract() public {
        vm.expectRevert(InvalidConfig.selector);
        vault.setStakingPolicy(address(0));
        vm.expectRevert(InvalidConfig.selector);
        vault.setStakingPolicy(alice);
        assertEq(vault.stakingPolicy(), address(0));
    }
}
