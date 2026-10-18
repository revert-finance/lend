// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AerodromeTestBase.sol";
import "../../../src/transformers/AutoRangeAndCompound.sol";
import {AeroGaugeFactoryFixture} from "../../mocks/AeroDeliveryFixture.sol";

/// @notice Operator-managed staking through the vault: stake-target transforms, the owner opt-in, the cooldown,
/// the gauge penalty-window refusal and the compound-only policy (fees before a stake, rewards before an unstake).
contract OperatorStakingTest is AerodromeTestBase {
    AutoRangeAndCompound public autoRange;

    function setUp() public override {
        super.setUp();
        autoRange = new AutoRangeAndCompound(
            INonfungiblePositionManager(address(npm)), admin, admin, 60, 200, address(0), address(0)
        );
        vault.setTransformer(address(autoRange), true);
        autoRange.setVault(address(vault));
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        // lend-side limits and liquidity so positions can borrow in the health tests
        vault.setLimits(0, 10000000e6, 10000000e6, 10000000e6, 10000000e6);
        usdc.mint(address(this), 1000000e6);
        usdc.approve(address(vault), 1000000e6);
        vault.deposit(1000000e6, address(this));
    }

    // ---- helpers

    function _createVaultPosition(address tokenA, address tokenB, int24 tickSpacing, bool stake)
        internal
        returns (uint256 tokenId)
    {
        tokenId = createPosition(alice, tokenA, tokenB, tickSpacing, -100, 100, 1000e18);
        _enrollInVault(tokenId, stake);
    }

    function _enrollInVault(uint256 tokenId, bool stake) internal {
        _enrollInVaultAs(alice, tokenId, stake);
    }

    function _enrollInVaultAs(address owner, uint256 tokenId, bool stake) internal {
        vm.startPrank(owner);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, owner);
        if (stake) {
            vault.stakePosition(tokenId);
        }
        vault.approveTransform(tokenId, admin, true);
        vault.approveTransform(tokenId, address(autoRange), true);
        autoRange.configToken(tokenId, address(vault), _autoCompoundConfig());
        vm.stopPrank();
    }

    function _autoCompoundConfig() internal pure returns (AutoRangeAndCompound.PositionConfig memory) {
        return AutoRangeAndCompound.PositionConfig({
            lowerTickLimit: 0,
            upperTickLimit: 0,
            lowerTickDelta: 0,
            upperTickDelta: 0,
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            autoCompound: true,
            maxRewardX64: 0,
            autoCompoundMin0: 0,
            autoCompoundMin1: 0,
            autoCompoundRewardMin: 0
        });
    }

    function _payload(uint256 tokenId) internal view returns (bytes memory) {
        return abi.encodeCall(AutoRangeAndCompound.autoCompound, (_params(tokenId)));
    }

    function _optIn(uint256 tokenId, bool managed) internal {
        vm.prank(alice);
        autoRange.configStakingManagement(tokenId, address(vault), managed);
    }

    function _params(uint256 tokenId) internal view returns (AutoRangeAndCompound.AutoCompoundParams memory) {
        return AutoRangeAndCompound.AutoCompoundParams({
            tokenId: tokenId, swap0To1: true, amountIn: 0, deadline: block.timestamp + 1 hours
        });
    }

    function _rewardParams(IVault.StakeTarget target) internal view returns (IVault.RewardCompoundParams memory) {
        return IVault.RewardCompoundParams({
            minAeroReward: 0, aeroSplitBps: 0, deadline: block.timestamp + 1 hours, stakeTarget: target
        });
    }

    function _flip(uint256 tokenId, IVault.StakeTarget target) internal {
        vm.prank(admin);
        autoRange.autoCompoundWithVaultAndRewardCompound(_params(tokenId), address(vault), _rewardParams(target));
    }

    /// The mock position manager reports collected fees without transferring them: fund the transformer with the
    /// same amounts so the fee compound can pull them into the position like the real NPM would.
    function _fundCollectedFees(uint256 tokenId) internal returns (uint256 fee0, uint256 fee1) {
        (,, address token0, address token1,,,,,,, uint128 owed0, uint128 owed1) = npm.positions(tokenId);
        fee0 = owed0;
        fee1 = owed1;
        MockERC20(token0).mint(address(autoRange), fee0);
        MockERC20(token1).mint(address(autoRange), fee1);
    }

    function _liquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = npm.positions(tokenId);
    }

    // ---- opt-in and authorization

    function testFlipRequiresOwnerOptIn() public {
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, false);
        npm.setTokensOwed(tokenId, 0, 0);
        vm.prank(admin);
        vm.expectRevert(Unauthorized.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(tokenId), address(vault), _rewardParams(IVault.StakeTarget.Staked)
        );
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
    }

    function testOptInIsOwnerOnlyAndCanBeRevoked() public {
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, false);
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        autoRange.configStakingManagement(tokenId, address(vault), true);
        _optIn(tokenId, true);
        assertEq(autoRange.stakingConsent(tokenId, address(vault)), alice);
        _optIn(tokenId, false);
        assertEq(autoRange.stakingConsent(tokenId, address(vault)), address(0));
    }

    function testVaultRejectsCustodyChangeFromPlainTransformDelegate() public {
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, true);
        npm.setTokensOwed(tokenId, 0, 0);
        _optIn(tokenId, true);
        // admin holds a generic approveTransform permission: it may transform, but not change custody directly
        vm.prank(admin);
        vm.expectRevert(Unauthorized.selector);
        vault.transformWithRewardCompound(
            tokenId, address(autoRange), _payload(tokenId), _rewardParams(IVault.StakeTarget.Unstaked)
        );
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
        // keeping the current custody is still allowed for the delegate
        vm.prank(admin);
        vault.transformWithRewardCompound(
            tokenId, address(autoRange), _payload(tokenId), _rewardParams(IVault.StakeTarget.Keep)
        );
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
    }

    function testOwnerMayChangeCustodyDirectlyThroughTheVault() public {
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, true);
        npm.setTokensOwed(tokenId, 0, 0);
        vm.prank(alice);
        vault.transformWithRewardCompound(
            tokenId, address(autoRange), _payload(tokenId), _rewardParams(IVault.StakeTarget.Unstaked)
        );
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
        assertEq(npm.ownerOf(tokenId), address(vault));
    }

    function testStaleOptInDoesNotCarryToANewOwner() public {
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, false);
        npm.setTokensOwed(tokenId, 0, 0);
        _optIn(tokenId, true);

        // alice leaves the vault and sells the position; bob deposits it and allows ordinary transforms only
        vm.prank(alice);
        vault.remove(tokenId, alice, "");
        vm.prank(alice);
        npm.transferFrom(alice, bob, tokenId);
        _enrollInVaultAs(bob, tokenId, false);

        vm.prank(admin);
        vm.expectRevert(Unauthorized.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(tokenId), address(vault), _rewardParams(IVault.StakeTarget.Staked)
        );
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));

        // bob's own consent works
        vm.prank(bob);
        autoRange.configStakingManagement(tokenId, address(vault), true);
        _flip(tokenId, IVault.StakeTarget.Staked);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
    }

    function testConsentDoesNotCarryToAnotherVault() public {
        // second vault with its own gauge manager, both allowlisted on the transformer
        V3Vault vaultB = new V3Vault("B", "B", address(usdc), npm, irm, oracle);
        GaugeManager managerB = new GaugeManager(
            IAerodromeNonfungiblePositionManager(address(npm)), IERC20(address(aero)), IVault(address(vaultB)), address(0), address(0)
        );
        managerB.setGauge(usdcDaiPool, address(usdcDaiGauge));
        vaultB.setGaugeManager(address(managerB));
        vaultB.setTokenConfig(address(usdc), uint32(Q32 * 90 / 100), type(uint32).max);
        vaultB.setTokenConfig(address(dai), uint32(Q32 * 90 / 100), type(uint32).max);
        vaultB.setTransformer(address(autoRange), true);
        autoRange.setVault(address(vaultB));

        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, false);
        npm.setTokensOwed(tokenId, 0, 0);
        _optIn(tokenId, true); // consent for vault A

        // alice moves the same position to vault B and allows ordinary transforms there
        vm.startPrank(alice);
        vault.remove(tokenId, alice, "");
        npm.approve(address(vaultB), tokenId);
        vaultB.create(tokenId, alice);
        vaultB.approveTransform(tokenId, admin, true);
        vaultB.approveTransform(tokenId, address(autoRange), true);
        autoRange.configToken(tokenId, address(vaultB), _autoCompoundConfig());
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(Unauthorized.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(tokenId), address(vaultB), _rewardParams(IVault.StakeTarget.Staked)
        );
        assertEq(managerB.tokenIdToGauge(tokenId), address(0));

        // consent given for vault B works there
        vm.prank(alice);
        autoRange.configStakingManagement(tokenId, address(vaultB), true);
        vm.prank(admin);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(tokenId), address(vaultB), _rewardParams(IVault.StakeTarget.Staked)
        );
        assertEq(managerB.tokenIdToGauge(tokenId), address(usdcDaiGauge));
    }

    function testConsentRequiresAVault() public {
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000e18);
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        autoRange.configStakingManagement(tokenId, address(0), true);
    }

    function testStakeChangeCompoundIsOnlyAVaultTransformPayload() public {
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, false);
        _optIn(tokenId, true);
        vm.prank(admin);
        vm.expectRevert(Unauthorized.selector);
        autoRange.autoCompoundForStakeChange(_params(tokenId));
    }

    function testStakeTargetEntrypointsAreOperatorOnly() public {
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, false);
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(tokenId), address(vault), _rewardParams(IVault.StakeTarget.Keep)
        );
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        vault.transformWithRewardCompound(
            tokenId,
            address(autoRange),
            abi.encodeCall(AutoRangeAndCompound.autoCompound, (_params(tokenId))),
            _rewardParams(IVault.StakeTarget.Staked)
        );
    }

    function testKeepAndNoopTargetsNeedNoOptIn() public {
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, true);
        npm.setTokensOwed(tokenId, 0, 0);
        _flip(tokenId, IVault.StakeTarget.Keep);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
        // already staked: the target is a no-op, not a custody change
        _flip(tokenId, IVault.StakeTarget.Staked);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
        assertEq(autoRange.lastStakeChangeBlock(tokenId), 0);
    }

    // ---- compound-only policy on custody changes

    function testFlipToStakedCompoundsFeesFirst() public {
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, false);
        (uint256 fee0, uint256 fee1) = _fundCollectedFees(tokenId);
        uint128 liquidityBefore = _liquidity(tokenId);
        uint256 npm0Before = usdc.balanceOf(address(npm));
        uint256 alice0Before = usdc.balanceOf(alice);
        _optIn(tokenId, true);

        _flip(tokenId, IVault.StakeTarget.Staked);

        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge), "ends staked");
        assertEq(npm.ownerOf(tokenId), address(usdcDaiGauge));
        assertGt(_liquidity(tokenId), liquidityBefore, "fees were added as liquidity");
        (,,,,,,,,,, uint128 owed0, uint128 owed1) = npm.positions(tokenId);
        assertEq(owed0 + owed1, 0, "fees collected before staking");
        // most of the fee went into the position, only the protocol cut and dust stayed outside it
        uint256 token0Compounded = usdc.balanceOf(address(npm)) - npm0Before;
        assertGt(token0Compounded, fee0 * 97 / 100);
        assertLt(usdc.balanceOf(alice) - alice0Before, fee0 / 50, "no fee payout to the owner");
        assertEq(autoRange.lastStakeChangeBlock(tokenId), block.number);
        fee1; // token1 side follows the same path
    }

    function testFlipToStakedWorksWithoutAutoCompoundConfigAndWithMinimums() public {
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, false);
        vm.prank(alice);
        autoRange.configToken(
            tokenId,
            address(vault),
            AutoRangeAndCompound.PositionConfig({
                lowerTickLimit: 0,
                upperTickLimit: 0,
                lowerTickDelta: 0,
                upperTickDelta: 0,
                token0SlippageX64: 0,
                token1SlippageX64: 0,
                onlyFees: false,
                autoCompound: false,
                maxRewardX64: 0,
                autoCompoundMin0: type(uint128).max,
                autoCompoundMin1: type(uint128).max,
                autoCompoundRewardMin: type(uint128).max
            })
        );
        _fundCollectedFees(tokenId);
        _optIn(tokenId, true);
        _flip(tokenId, IVault.StakeTarget.Staked);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
    }

    function testFlipToUnstakedCompoundsRewardsFirst() public {
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, true);
        npm.setTokensOwed(tokenId, 0, 0);
        usdcDaiGauge.setReward(tokenId, 7e18);
        uint128 liquidityBefore = _liquidity(tokenId);
        uint256 aliceAeroBefore = aero.balanceOf(alice);
        _optIn(tokenId, true);

        _flip(tokenId, IVault.StakeTarget.Unstaked);

        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0), "ends unstaked");
        assertEq(npm.ownerOf(tokenId), address(vault));
        assertEq(aero.balanceOf(alice), aliceAeroBefore, "rewards compounded, not paid out");
        assertEq(usdcDaiGauge.rewards(tokenId), 0, "rewards claimed");
        assertGt(_liquidity(tokenId), liquidityBefore, "rewards were added as liquidity");
        assertEq(autoRange.lastStakeChangeBlock(tokenId), block.number);
    }

    function testFlipToUnstakedRefusedInsidePenaltyWindow() public {
        AeroGaugeFactoryFixture(usdcDaiGauge.gaugeFactory()).setConfig(100, 200_000, address(0), 0);
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, true);
        npm.setTokensOwed(tokenId, 0, 0);
        usdcDaiGauge.setReward(tokenId, 7e18);
        _optIn(tokenId, true);
        assertEq(gaugeManager.penaltyWindowEnd(tokenId), block.number + 100);

        vm.prank(admin);
        vm.expectRevert(NotReady.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(tokenId), address(vault), _rewardParams(IVault.StakeTarget.Unstaked)
        );
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge), "still staked");

        vm.roll(block.number + 100);
        _flip(tokenId, IVault.StakeTarget.Unstaked);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
    }

    function testFlipRespectsCooldown() public {
        autoRange.setStakeChangeCooldown(50);
        assertEq(autoRange.stakeChangeCooldownBlocks(), 50);
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, false);
        npm.setTokensOwed(tokenId, 0, 0);
        _optIn(tokenId, true);

        _flip(tokenId, IVault.StakeTarget.Staked);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));

        vm.prank(admin);
        vm.expectRevert(NotReady.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(tokenId), address(vault), _rewardParams(IVault.StakeTarget.Unstaked)
        );

        vm.roll(block.number + 50);
        _flip(tokenId, IVault.StakeTarget.Unstaked);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
    }

    function testCooldownSetterIsOwnerOnly() public {
        vm.prank(bob);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        autoRange.setStakeChangeCooldown(1);
    }

    // ---- health

    function testFlipToStakedUsesBufferedHealthCheck() public {
        // small position with large uncollected fees, so the fee value is a real share of the collateral
        uint256 tokenId = createPositionProper(alice, address(usdc), address(dai), 1, -100, 100, 1e18, 1000e6, 1000e18);
        _enrollInVault(tokenId, false);
        // uncollected fees count as collateral while unstaked: borrow up to the buffer against them
        (,, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        uint256 maxBorrow = collateralValue * vault.BORROW_SAFETY_BUFFER_X32() / Q32;
        vm.prank(alice);
        vault.borrow(tokenId, maxBorrow);
        _fundCollectedFees(tokenId);
        _optIn(tokenId, true);

        // staking switches to the fee-less valuation, so the buffered check that stakePosition applies must fail
        vm.prank(admin);
        vm.expectRevert(CollateralFail.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(tokenId), address(vault), _rewardParams(IVault.StakeTarget.Staked)
        );
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
    }

    /// Vault without a gauge manager, allowlisted on the transformer, holding a configured position of alice's.
    function _bareVaultPosition() internal returns (V3Vault bareVault, uint256 tokenId) {
        bareVault = new V3Vault("bare", "bare", address(usdc), npm, irm, oracle);
        bareVault.setTokenConfig(address(usdc), uint32(Q32 * 90 / 100), type(uint32).max);
        bareVault.setTokenConfig(address(dai), uint32(Q32 * 90 / 100), type(uint32).max);
        bareVault.setTransformer(address(autoRange), true);
        autoRange.setVault(address(bareVault));

        tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000e18);
        npm.setTokensOwed(tokenId, 0, 0);
        vm.startPrank(alice);
        npm.approve(address(bareVault), tokenId);
        bareVault.create(tokenId, alice);
        bareVault.approveTransform(tokenId, admin, true);
        bareVault.approveTransform(tokenId, address(autoRange), true);
        autoRange.configToken(tokenId, address(bareVault), _autoCompoundConfig());
        vm.stopPrank();
    }

    function testStakeTargetWithoutGaugeManagerReverts() public {
        (V3Vault bareVault, uint256 tokenId) = _bareVaultPosition();
        vm.prank(alice);
        autoRange.configStakingManagement(tokenId, address(bareVault), true);

        vm.prank(admin);
        vm.expectRevert(GaugeManagerNotSet.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(tokenId), address(bareVault), _rewardParams(IVault.StakeTarget.Staked)
        );
    }

    // ---- compound-only policy on plain transforms

    function testPlainTransformCompoundsStakedRewardsBestEffort() public {
        uint256 tokenId = _createVaultPosition(address(weth), address(usdc), 10, true);
        npm.setTokensOwed(tokenId, 0, 0);
        wethUsdcGauge.setReward(tokenId, 5e18);
        uint128 liquidityBefore = _liquidity(tokenId);
        uint256 aliceAeroBefore = aero.balanceOf(alice);

        vm.prank(admin);
        autoRange.autoCompoundWithVault(_params(tokenId), address(vault));

        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(wethUsdcGauge), "restaked");
        assertEq(aero.balanceOf(alice), aliceAeroBefore, "rewards compounded, not paid out");
        assertEq(wethUsdcGauge.rewards(tokenId), 0);
        assertGt(_liquidity(tokenId), liquidityBefore);
    }

    function testPlainTransformFallsBackToPayoutWhenCompoundFails() public {
        uint256 tokenId = _createVaultPosition(address(usdc), address(dai), 1, true);
        npm.setTokensOwed(tokenId, 0, 0);
        usdcDaiGauge.setReward(tokenId, 7e18);
        usdcDaiGauge.setMintFails(true);

        vm.prank(admin);
        autoRange.autoCompoundWithVault(_params(tokenId), address(vault));

        // the unstake deferred the failed mint to the owner and the transform still completed and restaked
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
        assertEq(gaugeManager.deferredClaims(address(usdcDaiGauge), 0, alice), 7e18);
    }

    // ---- penalty window on plain transforms (Cantina LEND-4)

    /// Staked usdc/dai position with pending rewards, inside a 100-block penalty window that starts now. The window
    /// end is read back from the manager: a local copy of block.number does not survive vm.roll under via-IR.
    function _stakedInsidePenaltyWindow() internal returns (uint256 tokenId, uint256 windowEnd) {
        AeroGaugeFactoryFixture(usdcDaiGauge.gaugeFactory()).setConfig(100, 200_000, address(0), 0);
        tokenId = _createVaultPosition(address(usdc), address(dai), 1, true);
        npm.setTokensOwed(tokenId, 0, 0);
        usdcDaiGauge.setReward(tokenId, 7e18);
        windowEnd = gaugeManager.penaltyWindowEnd(tokenId);
        assertEq(windowEnd, block.number + 100);
    }

    function _assertUntouchedInGauge(uint256 tokenId, uint256 windowEnd) internal {
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge), "still staked");
        assertEq(npm.ownerOf(tokenId), address(usdcDaiGauge));
        assertEq(usdcDaiGauge.rewards(tokenId), 7e18, "rewards untouched");
        assertEq(gaugeManager.penaltyWindowEnd(tokenId), windowEnd, "window not restarted");
    }

    /// Out-of-range re-range config: at tick 200 the -100..100 position is replaced by one around the current tick.
    function _rangeChangeConfig() internal pure returns (AutoRangeAndCompound.PositionConfig memory) {
        return AutoRangeAndCompound.PositionConfig({
            lowerTickLimit: -1,
            upperTickLimit: 0,
            lowerTickDelta: -1,
            upperTickDelta: 1,
            token0SlippageX64: 0,
            token1SlippageX64: 0,
            onlyFees: false,
            autoCompound: false,
            maxRewardX64: 0,
            autoCompoundMin0: 0,
            autoCompoundMin1: 0,
            autoCompoundRewardMin: 0
        });
    }

    function _executeParams(uint256 tokenId) internal view returns (AutoRangeAndCompound.ExecuteParams memory) {
        return AutoRangeAndCompound.ExecuteParams({
            tokenId: tokenId,
            swap0To1: true,
            amountIn: 0,
            swapData: "",
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp + 1 hours,
            rewardX64: 0
        });
    }

    function testPlainAutoCompoundRefusedInsidePenaltyWindow() public {
        (uint256 tokenId, uint256 windowEnd) = _stakedInsidePenaltyWindow();
        uint256 aliceAeroBefore = aero.balanceOf(alice);
        uint128 liquidityBefore = _liquidity(tokenId);

        vm.prank(admin);
        vm.expectRevert(NotReady.selector);
        autoRange.autoCompoundWithVault(_params(tokenId), address(vault));
        _assertUntouchedInGauge(tokenId, windowEnd);

        // still refused on the last block of the window
        vm.roll(windowEnd - 1);
        vm.prank(admin);
        vm.expectRevert(NotReady.selector);
        autoRange.autoCompoundWithVault(_params(tokenId), address(vault));
        _assertUntouchedInGauge(tokenId, windowEnd);

        // from penaltyWindowEnd on the transform runs: rewards are compounded, nothing is paid out, position restaked
        vm.roll(windowEnd);
        vm.prank(admin);
        autoRange.autoCompoundWithVault(_params(tokenId), address(vault));
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge), "restaked");
        assertEq(usdcDaiGauge.rewards(tokenId), 0, "rewards compounded");
        assertEq(aero.balanceOf(alice), aliceAeroBefore, "nothing paid out");
        assertGt(_liquidity(tokenId), liquidityBefore);
        assertEq(gaugeManager.penaltyWindowEnd(tokenId), windowEnd + 100, "restake restarted the window");
    }

    function testPlainRangeChangeRefusedInsidePenaltyWindow() public {
        (uint256 tokenId, uint256 windowEnd) = _stakedInsidePenaltyWindow();
        uint256 aliceAeroBefore = aero.balanceOf(alice);
        MockPool(usdcDaiPool).setTick(200);
        vm.prank(alice);
        autoRange.configToken(tokenId, address(vault), _rangeChangeConfig());

        vm.prank(admin);
        vm.expectRevert(NotReady.selector);
        autoRange.executeWithVault(_executeParams(tokenId), address(vault));
        _assertUntouchedInGauge(tokenId, windowEnd);

        vm.roll(windowEnd);
        vm.prank(admin);
        autoRange.executeWithVault(_executeParams(tokenId), address(vault));
        uint256 newTokenId = npm.lastMintedTokenId();
        assertEq(usdcDaiGauge.rewards(tokenId), 0, "rewards compounded before the range change");
        assertEq(aero.balanceOf(alice), aliceAeroBefore, "nothing paid out");
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
        assertEq(gaugeManager.tokenIdToGauge(newTokenId), address(usdcDaiGauge), "replacement restaked");
        assertEq(vault.ownerOf(newTokenId), alice);
    }

    function testRewardCompoundTransformsRefusedInsidePenaltyWindow() public {
        (uint256 tokenId, uint256 windowEnd) = _stakedInsidePenaltyWindow();

        // the strict compound these entrypoints request refuses the window on its own, whatever the stake target
        vm.prank(admin);
        vm.expectRevert(GaugeManager.InsidePenaltyWindow.selector);
        autoRange.autoCompoundWithVaultAndRewardCompound(
            _params(tokenId), address(vault), _rewardParams(IVault.StakeTarget.Keep)
        );
        vm.prank(admin);
        vm.expectRevert(GaugeManager.InsidePenaltyWindow.selector);
        autoRange.executeWithVaultAndRewardCompound(
            _executeParams(tokenId), address(vault), _rewardParams(IVault.StakeTarget.Staked)
        );
        _assertUntouchedInGauge(tokenId, windowEnd);

        vm.roll(windowEnd);
        _flip(tokenId, IVault.StakeTarget.Keep);
        assertEq(usdcDaiGauge.rewards(tokenId), 0, "rewards compounded");
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
    }

    function testPlainTransformIgnoresPenaltyWindowWhenUnstaked() public {
        (uint256 tokenId,) = _stakedInsidePenaltyWindow();
        // leaving the gauge inside the window stays the owner's choice; afterwards the operator is not blocked
        vm.prank(alice);
        vault.unstakePosition(tokenId);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));

        vm.prank(admin);
        autoRange.autoCompoundWithVault(_params(tokenId), address(vault));
        assertEq(npm.ownerOf(tokenId), address(vault), "stays unstaked");
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
    }

    function testPlainTransformIgnoresPenaltyWindowWithoutGaugeManager() public {
        AeroGaugeFactoryFixture(usdcDaiGauge.gaugeFactory()).setConfig(100, 200_000, address(0), 0);
        (V3Vault bareVault, uint256 tokenId) = _bareVaultPosition();

        vm.prank(admin);
        autoRange.autoCompoundWithVault(_params(tokenId), address(bareVault));
        assertEq(npm.ownerOf(tokenId), address(bareVault));
    }
}
