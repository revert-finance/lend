// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AeroGaugeManager.t.sol";

import "../mocks/AeroRootDeliveryFixture.sol";

/// @dev Runs the existing leaf regression suite unchanged against root delivery, plus root-specific cases.
contract AeroGaugeManagerRootTest is AeroGaugeManagerTest {
    RootSettlementFixture rootHandler;
    RootTopologyFixture topology;
    uint256 constant DUST = 400_000;
    uint256 constant MINIMUM = 1_000_000;

    function setUp() public override {
        token = new MockERC20Token("AERO", "AERO");
        usdc = new MockERC20Token("USDC", "USDC");
        weth = new MockERC20Token("WETH", "WETH");
        factory = new MockSlipstreamFactory();
        pool = new MockPool(address(token), address(usdc), 100);
        factory.setPool(address(token), address(usdc), 100, address(pool));
        npm = new MockNPM(address(factory), address(weth));
        vault = new MockVault();
        rootHandler = new RootSettlementFixture(token);
        topology = new RootTopologyFixture(address(rootHandler), address(token));
        rootHandler.setVoter(address(topology));
        gauge = new AeroGaugeFixture(address(npm), address(pool), address(rootHandler));
        gauge.setVoter(address(topology));
        pool.setGauge(address(gauge));
        manager = new GaugeManager(
            INonfungiblePositionManager(address(npm)),
            IERC20(address(token)),
            IVault(address(vault)),
            address(0),
            address(0)
        );
        manager.setGauge(address(pool), address(gauge));
        manager.setRewardBasePool(address(usdc), address(pool));
        usdc.mint(address(pool), 1_000_000 ether);
        token.mint(address(pool), 1_000_000 ether);
        _stake(1, ALICE);
        _stake(2, BOB);
    }

    function testFuzzSharedBatchConservesOwnerRewards(uint96 a, uint96 b, bool bobFirst) public override {
        super.testFuzzSharedBatchConservesOwnerRewards(
            uint96(bound(a, MINIMUM, type(uint96).max)), uint96(bound(b, MINIMUM, type(uint96).max)), bobFirst
        );
    }

    function testFuzzRootDustPreservesBothOwners(uint96 a, uint96 b, bool bobFirst) public {
        a = uint96(bound(a, 1, 2 * MINIMUM));
        b = uint96(bound(b, 1, 2 * MINIMUM));
        gauge.setReward(1, a);
        _withdraw(1);
        gauge.setReward(2, b);
        _withdraw(2);
        if (rootHandler.pendingRedeems(address(manager)) != 0) rootHandler.mint(address(manager), MINIMUM);
        address first = bobFirst ? BOB : ALICE;
        address second = bobFirst ? ALICE : BOB;
        if (manager.rootDeferredRewards(first) != 0) {
            vm.prank(first);
            manager.claimRootDeferredRewards(first);
        }
        if (manager.rootDeferredRewards(second) != 0) {
            vm.prank(second);
            manager.claimRootDeferredRewards(second);
        }
        assertEq(token.balanceOf(ALICE), a);
        assertEq(token.balanceOf(BOB), b);
        assertEq(manager.reservedRewards(), 0);
    }

    function testRootWithdrawalDustSurvivesOwnerChangeAndCannotBeSwept() public {
        gauge.setReward(1, DUST);
        _withdraw(1);
        assertEq(manager.rootDeferredRewards(ALICE), DUST);
        assertEq(manager.reservedRewards(), DUST);
        assertEq(npm.ownerOf(1), address(vault));
        vault.setOwner(1, BOB);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        manager.withdrawBalances(tokens, BOB); // unfunded reserves must not make a sweep underflow
        vm.prank(ALICE);
        vm.expectRevert(GaugeManager.DeferredAccountingMismatch.selector);
        manager.claimRootDeferredRewards(ALICE);
        gauge.setReward(2, MINIMUM);
        vm.prank(BOB);
        assertEq(manager.claimRewards(2, BOB), MINIMUM);
        assertEq(token.balanceOf(BOB), MINIMUM);
        manager.withdrawBalances(tokens, BOB);
        assertEq(token.balanceOf(address(manager)), DUST);
        vm.prank(BOB);
        vm.expectRevert(GaugeManager.NoDeferredClaim.selector);
        manager.claimRootDeferredRewards(BOB);
        vm.prank(ALICE);
        assertEq(manager.claimRootDeferredRewards(BOB), DUST);
        assertEq(manager.reservedRewards(), 0);
        vm.prank(ALICE);
        vm.expectRevert(GaugeManager.NoDeferredClaim.selector);
        manager.claimRootDeferredRewards(ALICE);
    }

    function testRootDirectClaimDustBelongsToEconomicOwner() public {
        gauge.setReward(1, DUST);
        vm.prank(ALICE);
        assertEq(manager.claimRewards(1, BOB), 0);
        assertEq(manager.rootDeferredRewards(ALICE), DUST);
        assertEq(manager.rootDeferredRewards(BOB), 0);
        // A permissionless AERO top-up can cover the dust without waiting for another gauge reward.
        token.mint(address(manager), DUST);
        vm.prank(ALICE);
        manager.claimRootDeferredRewards(BOB);
        assertEq(token.balanceOf(BOB), DUST);
        assertEq(rootHandler.pendingRedeems(address(manager)), DUST);
    }

    function testRootPendingNotPaidAsPoolFeesOnNextWithdrawal() public {
        gauge.setReward(1, DUST);
        _withdraw(1);
        gauge.setReward(2, MINIMUM);
        gauge.setFees(address(token), 123);
        _withdraw(2);
        assertEq(token.balanceOf(BOB), MINIMUM + 123);
        assertEq(token.balanceOf(address(manager)), DUST);
        vm.prank(ALICE);
        manager.claimRootDeferredRewards(ALICE);
        assertEq(token.balanceOf(ALICE), DUST);
    }

    function testRootPendingNotCompoundedIntoBobsPosition() public {
        gauge.setReward(1, DUST);
        _withdraw(1);
        gauge.setReward(2, 10 ether);
        vm.prank(BOB);
        (uint256 reward,,) = manager.compoundRewards(2, 0, 5000, block.timestamp);
        assertEq(reward, 10 ether);
        assertEq(manager.reservedRewards(), DUST);
        assertEq(token.balanceOf(address(manager)) >= DUST, true);
        vm.prank(ALICE);
        assertEq(manager.claimRootDeferredRewards(ALICE), DUST);
    }

    function testRootGaugeMintFailureCanRecoverIntoPendingWithoutBlockingPrincipal() public {
        _deferAlice(DUST);
        gauge.setMintFails(false);
        assertEq(manager.recoverDeferredRewards(address(gauge)), DUST);
        assertEq(manager.currentDeferredBatch(address(gauge)), 1);
        assertTrue(manager.rootPendingBatches(address(gauge), 0));
        assertEq(manager.reservedRewards(), DUST);
        vm.prank(ALICE);
        vm.expectRevert(GaugeManager.DeferredAccountingMismatch.selector);
        manager.claimDeferredRewards(address(gauge), 0, ALICE);
        gauge.setReward(2, MINIMUM);
        vm.prank(BOB);
        assertEq(manager.claimRewards(2, BOB), MINIMUM);
        vm.prank(ALICE);
        assertEq(manager.claimDeferredRewards(address(gauge), 0, ALICE), DUST);
    }

    function testRootPreviouslyFundedGaugeBatchClaimableWhileNewRootDustPending() public {
        _deferAlice(2 * MINIMUM);
        gauge.setMintFails(false);
        manager.recoverDeferredRewards(address(gauge));
        gauge.setReward(2, DUST);
        _withdraw(2);
        vm.prank(ALICE);
        assertEq(manager.claimDeferredRewards(address(gauge), 0, ALICE), 2 * MINIMUM);
        assertEq(manager.reservedRewards(), DUST);
        assertEq(manager.rootDeferredRewards(BOB), DUST);
    }

    function testRootExternalRedemptionBeforeSweepStillProtectsOwner() public {
        gauge.setReward(1, DUST);
        _withdraw(1);
        rootHandler.mint(address(manager), MINIMUM); // unrelated caller's upstream reward addressed to manager
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        manager.withdrawBalances(tokens, BOB);
        assertEq(token.balanceOf(BOB), MINIMUM);
        assertEq(token.balanceOf(address(manager)), DUST);
        vm.prank(ALICE);
        manager.claimRootDeferredRewards(ALICE);
    }

    function testRootGaugeRecoveryDoesNotDuplicateAlreadyPendingOwnerRewards() public {
        gauge.setReward(1, DUST);
        _withdraw(1);
        gauge.setReward(2, MINIMUM);
        gauge.setMintFails(true);
        _withdraw(2);
        gauge.setMintFails(false);
        manager.recoverDeferredRewards(address(gauge));
        assertEq(manager.reservedRewards(), DUST + MINIMUM);
        vm.prank(BOB);
        manager.claimDeferredRewards(address(gauge), 0, BOB);
        vm.prank(ALICE);
        manager.claimRootDeferredRewards(ALICE);
        assertEq(token.balanceOf(BOB), MINIMUM);
        assertEq(token.balanceOf(ALICE), DUST);
    }

    function testRejectsWrongRootTokenAndRemoteSettlement() public {
        topology.setToken(address(usdc));
        vm.expectRevert(GaugeManager.UnsupportedRewardDelivery.selector);
        manager.setGauge(address(pool), address(gauge));
        topology.setToken(address(token));
        topology.setRootChain(block.chainid + 1);
        vm.expectRevert(GaugeManager.UnsupportedRewardDelivery.selector);
        manager.setGauge(address(pool), address(gauge));
    }

    function testRootDustSettlesAcrossGaugesWithNonRewardPoolWithdrawal() public {
        gauge.setReward(1, DUST);
        _withdraw(1);
        MockPool otherPool = new MockPool(address(weth), address(usdc), 100);
        factory.setPool(address(weth), address(usdc), 100, address(otherPool));
        AeroGaugeFixture otherGauge = new AeroGaugeFixture(address(npm), address(otherPool), address(rootHandler));
        otherGauge.setVoter(address(topology));
        otherPool.setGauge(address(otherGauge));
        manager.setGauge(address(otherPool), address(otherGauge));
        npm.setPosition(3, address(weth), address(usdc), 100, -60, 60, 10);
        npm.mint(address(vault), 3);
        vault.setOwner(3, BOB);
        vm.startPrank(address(vault));
        npm.approve(address(manager), 3);
        manager.stakePosition(3);
        vm.stopPrank();
        otherGauge.setReward(3, MINIMUM);
        vm.prank(address(vault));
        manager.unstakePosition(3);
        assertEq(token.balanceOf(BOB), MINIMUM);
        assertEq(manager.rootDeferredRewards(ALICE), DUST);
        vm.prank(ALICE);
        manager.claimRootDeferredRewards(ALICE);
        assertEq(token.balanceOf(ALICE), DUST);
    }

    function testRejectsDifferentRootHandlerWithoutLosingOldLiabilities() public {
        gauge.setReward(1, DUST);
        _withdraw(1);
        RootSettlementFixture other = new RootSettlementFixture(token);
        RootTopologyFixture otherTopology = new RootTopologyFixture(address(other), address(token));
        other.setVoter(address(otherTopology));
        gauge.setVoter(address(otherTopology));
        vm.expectRevert(GaugeManager.UnsupportedRewardDelivery.selector);
        manager.setGauge(address(pool), address(gauge));
        assertEq(manager.rootEmissionsHandler(), address(rootHandler));
        assertEq(manager.rootDeferredRewards(ALICE), DUST);
    }

    function testRootCompoundMinimumFailureRollsBackDustAttribution() public {
        gauge.setReward(1, DUST);
        vm.prank(ALICE);
        vm.expectRevert(bytes4(keccak256("NotEnoughReward()")));
        manager.compoundRewards(1, 1, 5000, block.timestamp);
        assertEq(rootHandler.pendingRedeems(address(manager)), 0);
        assertEq(manager.rootDeferredRewards(ALICE), 0);
        assertEq(manager.reservedRewards(), 0);
        assertEq(gauge.rewards(1), DUST);
        _withdraw(1);
        assertEq(manager.rootDeferredRewards(ALICE), DUST);
    }

    function testRootZeroRecipientRejected() public {
        vm.expectRevert(bytes4(keccak256("InvalidConfig()")));
        manager.claimRootDeferredRewards(address(0));
    }
}
