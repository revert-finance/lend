// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./GaugeManager.t.sol";
import "../../src/transformers/AutoRangeAndCompound.sol";

/// Uses the real manager, automator and linked ledger with the existing ordinary ERC20/pool fixtures.
contract GaugeCarryForwardTest is GaugeManagerUnitTest {
    AutoRangeAndCompound internal automation;

    function _enableCarry() internal {
        automation = new AutoRangeAndCompound(
            INonfungiblePositionManager(address(npm)), address(this), address(this), 60, 200, address(0), address(0)
        );
        automation.setVault(address(vault));
        vm.mockCall(address(vault), abi.encodeWithSignature("gaugeManager()"), abi.encode(address(gaugeManager)));
        gaugeManager.setCompoundBalanceSource(address(automation));
    }

    function _seedCarry() internal returns (uint256 saved0, uint256 saved1) {
        _enableCarry();
        _stake();
        aero.mint(address(gauge), 100 ether);
        gauge.setReward(TOKEN_ID, 100 ether);
        npm.setNextIncreaseLiquidityResult(1 ether, 1 ether);
        vm.prank(ALICE);
        gaugeManager.compoundRewards(TOKEN_ID, 0, 4000, block.timestamp + 1);
        saved0 = automation.positionBalances(TOKEN_ID, address(usdc));
        saved1 = automation.positionBalances(TOKEN_ID, address(dai));
        assertGt(saved0, 0);
        assertGt(saved1, 0);
    }

    function testCarry_ReusesRewardsWithoutFreshClaimOrDoubleFee() external {
        (uint256 saved0, uint256 saved1) = _seedCarry();
        uint256 before0 = usdc.balanceOf(address(npm));
        uint256 before1 = dai.balanceOf(address(npm));
        uint256 fee0 = usdc.balanceOf(address(gaugeManager));
        uint256 fee1 = dai.balanceOf(address(gaugeManager));
        vm.prank(ALICE);
        gaugeManager.compoundRewards(TOKEN_ID, 0, 4000, block.timestamp + 1);
        uint256 added0 = usdc.balanceOf(address(npm)) - before0;
        uint256 added1 = dai.balanceOf(address(npm)) - before1;
        uint256 rate = gaugeManager.totalRewardX64();
        assertEq(usdc.balanceOf(address(gaugeManager)), fee0 + added0 * rate / 2 ** 64);
        assertEq(dai.balanceOf(address(gaugeManager)), fee1 + added1 * rate / 2 ** 64);
        assertEq(automation.positionBalances(TOKEN_ID, address(usdc)), saved0 - added0 - added0 * rate / 2 ** 64);
        assertEq(automation.positionBalances(TOKEN_ID, address(dai)), saved1 - added1 - added1 * rate / 2 ** 64);
        assertEq(usdc.balanceOf(ALICE), 0);
        assertEq(dai.balanceOf(ALICE), 0);
        assertEq(usdc.allowance(address(gaugeManager), address(automation)), 0);
        assertEq(dai.allowance(address(gaugeManager), address(automation)), 0);
    }

    function testCarry_ReceiptPartialFillIsSavedAndReused() external {
        _enableCarry();
        _stake();
        aeroUsdcPool.setMaxAmountIn(49.5 ether);
        aero.mint(address(gauge), 100 ether);
        gauge.setReward(TOKEN_ID, 100 ether);
        vm.prank(ALICE);
        gaugeManager.compoundRewards(TOKEN_ID, 0, 5000, block.timestamp + 1);
        assertEq(automation.positionBalances(TOKEN_ID, address(aero)), 1 ether);
        assertEq(aero.balanceOf(ALICE), 0);
        aeroUsdcPool.setMaxAmountIn(0);
        vm.prank(ALICE);
        (uint256 reward,,) = gaugeManager.compoundRewards(TOKEN_ID, 0, 5000, block.timestamp + 1);
        assertEq(reward, 0); // Recycled receipts are not reported as newly claimed emissions.
        assertEq(automation.positionBalances(TOKEN_ID, address(aero)), 0);
        assertEq(aero.allowance(address(gaugeManager), address(automation)), 0);
    }

    function testCarry_FreshRewardMinimumCannotBeSatisfiedBySavedBalances() external {
        (uint256 saved0,) = _seedCarry();
        vm.prank(ALICE);
        vm.expectRevert(Constants.NotEnoughReward.selector);
        gaugeManager.compoundRewards(TOKEN_ID, 1, 4000, block.timestamp + 1);
        assertEq(automation.positionBalances(TOKEN_ID, address(usdc)), saved0);
    }

    function testCarry_StakedOwnerCanWithdrawAndOtherOwnerCannot() external {
        (uint256 saved0, uint256 saved1) = _seedCarry();
        vm.prank(RECIPIENT);
        vm.expectRevert(Constants.Unauthorized.selector);
        automation.withdrawLeftoverBalances(TOKEN_ID, RECIPIENT);
        vm.prank(ALICE);
        automation.withdrawLeftoverBalances(TOKEN_ID, RECIPIENT);
        assertEq(usdc.balanceOf(RECIPIENT), saved0);
        assertEq(dai.balanceOf(RECIPIENT), saved1);
        assertEq(automation.positionBalances(TOKEN_ID, address(usdc)), 0);
        assertEq(npm.ownerOf(TOKEN_ID), address(gauge));
    }

    function testCarry_WithdrawersCannotSweepUserLedger() external {
        (uint256 saved0, uint256 saved1) = _seedCarry();
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(dai);
        tokens[2] = address(aero);
        gaugeManager.withdrawBalances(tokens, RECIPIENT);
        automation.withdrawBalances(tokens, RECIPIENT);
        assertEq(usdc.balanceOf(address(automation)), saved0);
        assertEq(dai.balanceOf(address(automation)), saved1);
    }

    function testCarry_UnauthorizedLedgerTakeAndCreditRevert() external {
        (uint256 saved0,) = _seedCarry();
        uint256[3] memory amounts;
        vm.expectRevert();
        automation.compoundBalances(TOKEN_ID, false, amounts);
        vm.expectRevert();
        automation.compoundBalances(TOKEN_ID, true, amounts);
        assertEq(automation.positionBalances(TOKEN_ID, address(usdc)), saved0);
    }

    function testCarry_CreditRequiresActualFundsAndRollsBack() external {
        (uint256 saved0,) = _seedCarry();
        uint256[3] memory amounts = [uint256(1 ether), uint256(0), uint256(0)];
        vm.prank(address(gaugeManager));
        vm.expectRevert();
        automation.compoundBalances(TOKEN_ID, true, amounts);
        assertEq(automation.positionBalances(TOKEN_ID, address(usdc)), saved0);
    }

    function testCarry_UnstakedAndTransferredBalancesFollowNftOwner() external {
        (uint256 saved0, uint256 saved1) = _seedCarry();
        vm.prank(address(vault));
        gaugeManager.unstakePosition(TOKEN_ID);
        vm.prank(address(vault));
        npm.transferFrom(address(vault), RECIPIENT, TOKEN_ID);
        vm.prank(ALICE);
        vm.expectRevert(Constants.Unauthorized.selector);
        automation.withdrawLeftoverBalances(TOKEN_ID, ALICE);
        vm.prank(RECIPIENT);
        automation.withdrawLeftoverBalances(TOKEN_ID, RECIPIENT);
        assertEq(usdc.balanceOf(RECIPIENT), saved0);
        assertEq(dai.balanceOf(RECIPIENT), saved1);
    }

    function testCarry_FailedCompoundRestoresSharedLedger() external {
        (uint256 saved0, uint256 saved1) = _seedCarry();
        aero.mint(address(gauge), 10 ether);
        gauge.setReward(TOKEN_ID, 10 ether);
        aeroUsdcPool.setOutputBps(1000);
        vm.prank(ALICE);
        vm.expectRevert();
        gaugeManager.compoundRewards(TOKEN_ID, 0, 4000, block.timestamp + 1);
        assertEq(automation.positionBalances(TOKEN_ID, address(usdc)), saved0);
        assertEq(automation.positionBalances(TOKEN_ID, address(dai)), saved1);
        assertEq(npm.ownerOf(TOKEN_ID), address(gauge));
        assertEq(gauge.rewardPerTokenId(TOKEN_ID), 10 ether);
    }

    function testCarry_ReplacementMovesBalancesAndClearsOldNft() external {
        (uint256 saved0, uint256 saved1) = _seedCarry();
        npm.setPosition(2, address(usdc), address(dai), 100, -120, 120, 10);
        npm.mint(address(vault), 2);
        vm.mockCall(address(vault), abi.encodeWithSignature("transformedTokenId()"), abi.encode(TOKEN_ID));
        vm.prank(address(vault));
        automation.migrateStakingPolicy(TOKEN_ID, 2);
        assertEq(automation.positionBalances(2, address(usdc)), saved0);
        assertEq(automation.positionBalances(2, address(dai)), saved1);
        assertEq(automation.positionBalances(TOKEN_ID, address(usdc)), 0);
        assertEq(automation.positionBalances(TOKEN_ID, address(dai)), 0);
    }

    function testCarry_DifferentAssetReplacementPaysOldOwner() external {
        (uint256 saved0, uint256 saved1) = _seedCarry();
        npm.setPosition(2, address(aero), address(usdc), 200, -120, 120, 10);
        npm.mint(address(vault), 2);
        vm.mockCall(address(vault), abi.encodeWithSignature("transformedTokenId()"), abi.encode(TOKEN_ID));
        vm.prank(address(vault));
        automation.migrateStakingPolicy(TOKEN_ID, 2);
        assertEq(usdc.balanceOf(ALICE), saved0);
        assertEq(dai.balanceOf(ALICE), saved1);
        assertEq(automation.positionBalances(TOKEN_ID, address(usdc)), 0);
    }

    function testCarry_ReceiptAsPoolTokenIsNotDoubleCounted() external {
        _enableCarry();
        MockGauge receiptGauge = new MockGauge(IERC721(address(npm)), IERC20(address(aero)), address(aeroUsdcPool));
        aeroUsdcPool.setGauge(address(receiptGauge));
        gaugeManager.setGauge(address(aeroUsdcPool), address(receiptGauge));
        npm.setPosition(2, address(aero), address(usdc), 200, -60, 60, 10);
        npm.mint(address(vault), 2);
        vault.setOwner(2, ALICE);
        vm.startPrank(address(vault));
        npm.approve(address(gaugeManager), 2);
        gaugeManager.stakePosition(2);
        vm.stopPrank();
        aero.mint(address(receiptGauge), 100 ether);
        receiptGauge.setReward(2, 100 ether);
        npm.setNextIncreaseLiquidityResult(1 ether, 1 ether);
        vm.prank(ALICE);
        gaugeManager.compoundRewards(2, 0, 5000, block.timestamp + 1);
        uint256 saved = automation.positionBalances(2, address(aero));
        assertGt(saved, 1 ether);
        uint256 before = aero.balanceOf(address(npm));
        vm.prank(ALICE);
        gaugeManager.compoundRewards(2, 0, 5000, block.timestamp + 1);
        uint256 added = aero.balanceOf(address(npm)) - before;
        assertLe(added, saved);
        assertLe(automation.positionBalances(2, address(aero)), 2);
        assertEq(aero.balanceOf(ALICE), 0);
    }

    function testCarry_BindingIsOwnerOnlyAndOneTime() external {
        vm.prank(ALICE);
        vm.expectRevert("Ownable: caller is not the owner");
        gaugeManager.setCompoundBalanceSource(address(vault));
        vm.expectRevert(Constants.InvalidConfig.selector);
        gaugeManager.setCompoundBalanceSource(address(0));
        _enableCarry();
        vm.expectRevert(Constants.InvalidConfig.selector);
        gaugeManager.setCompoundBalanceSource(address(automation));
        assertEq(gaugeManager.compoundBalanceSource(), address(automation));
    }

    function testCarry_RuntimeLimits() external {
        _enableCarry();
        assertLe(address(automation).code.length, 24576);
        assertLe(address(gaugeManager).code.length, 24576);
        assertLe(address(CompoundBalanceLib).code.length, 24576);
    }

    function testCarry_OtherPositionBalancesAreIsolated() external {
        (uint256 saved0, uint256 saved1) = _seedCarry();
        npm.setPosition(2, address(usdc), address(dai), 100, -60, 60, 10);
        npm.mint(address(vault), 2);
        vault.setOwner(2, RECIPIENT);
        vm.startPrank(address(vault));
        npm.approve(address(gaugeManager), 2);
        gaugeManager.stakePosition(2);
        vm.stopPrank();
        aero.mint(address(gauge), 50 ether);
        gauge.setReward(2, 50 ether);
        npm.setNextIncreaseLiquidityResult(1 ether, 1 ether);
        vm.prank(RECIPIENT);
        gaugeManager.compoundRewards(2, 0, 5000, block.timestamp + 1);
        uint256 other0 = automation.positionBalances(2, address(usdc));
        uint256 other1 = automation.positionBalances(2, address(dai));
        vm.prank(ALICE);
        automation.withdrawLeftoverBalances(TOKEN_ID, ALICE);
        assertEq(usdc.balanceOf(ALICE), saved0);
        assertEq(dai.balanceOf(ALICE), saved1);
        assertEq(automation.positionBalances(2, address(usdc)), other0);
        assertEq(automation.positionBalances(2, address(dai)), other1);
        assertEq(usdc.balanceOf(address(automation)), other0);
        assertEq(dai.balanceOf(address(automation)), other1);
    }

    function testCarry_RegisteredManagerCannotTakeUnstakedPositionBalances() external {
        (uint256 saved0,) = _seedCarry();
        vm.prank(address(vault));
        gaugeManager.unstakePosition(TOKEN_ID);
        uint256[3] memory amounts;
        vm.prank(address(gaugeManager));
        vm.expectRevert(Constants.Unauthorized.selector);
        automation.compoundBalances(TOKEN_ID, false, amounts);
        assertEq(automation.positionBalances(TOKEN_ID, address(usdc)), saved0);
    }

    function testCarry_WrongVaultManagerCannotTakeBalances() external {
        (uint256 saved0,) = _seedCarry();
        vm.mockCall(address(vault), abi.encodeWithSignature("gaugeManager()"), abi.encode(RECIPIENT));
        uint256[3] memory amounts;
        vm.prank(address(gaugeManager));
        vm.expectRevert(Constants.Unauthorized.selector);
        automation.compoundBalances(TOKEN_ID, false, amounts);
        assertEq(automation.positionBalances(TOKEN_ID, address(usdc)), saved0);
    }
}
