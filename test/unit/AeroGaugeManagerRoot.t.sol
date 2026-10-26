// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {GaugeManager} from "../../src/GaugeManager.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {RootVoterFixture, RootHandlerFixture, ReceiptTokenFixture} from "../mocks/AeroDeliveryFixture.sol";
import {AeroGaugeFixture} from "../mocks/AeroGaugeFixture.sol";
import {MockNPM, MockVault, MockPool, MockSlipstreamFactory, MockERC20Token} from "./GaugeManager.t.sol";

/// @dev Root redemption: the voter's RootEmissionsHandler redeems claims into the root token (`aero`, the manager's
/// reward token) but keeps a claim below MIN_REDEEM_AMOUNT in `pendingRedeems[manager]`, one bucket shared by every
/// owner this manager stakes for, until a later claim of any position lifts the total over the floor. The gauge double
/// routes its mints through the voter like the upstream gauge; `AeroGaugeManagerUpstream.t.sol` runs the same flow
/// against the pinned upstream CLGauge bytecode.
contract AeroGaugeManagerRootTest is Test {
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    uint256 constant FLOOR = 100 ether;

    ReceiptTokenFixture receipt;
    MockERC20Token aero;
    MockERC20Token usdc;
    MockERC20Token weth;
    MockSlipstreamFactory factory;
    MockPool pool;
    MockPool wethPool;
    MockNPM npm;
    MockVault vault;
    RootVoterFixture voter;
    RootHandlerFixture handler;
    AeroGaugeFixture gauge;
    AeroGaugeFixture wethGauge;
    GaugeManager manager;

    function setUp() public {
        receipt = new ReceiptTokenFixture();
        aero = new MockERC20Token("AERO", "AERO");
        usdc = new MockERC20Token("USDC", "USDC");
        weth = new MockERC20Token("WETH", "WETH");
        factory = new MockSlipstreamFactory();
        pool = new MockPool(address(aero), address(usdc), 100);
        wethPool = new MockPool(address(weth), address(usdc), 100);
        factory.setPool(address(aero), address(usdc), 100, address(pool));
        factory.setPool(address(weth), address(usdc), 100, address(wethPool));
        npm = new MockNPM(address(factory), address(weth));
        vault = new MockVault();

        voter = new RootVoterFixture(address(receipt), address(aero));
        voter.setMinRedeemAmount(FLOOR);
        handler = RootHandlerFixture(voter.EMISSIONS_HANDLER());

        // two gauges of the same voter: their legs share one pending bucket
        gauge = _gauge(address(pool));
        wethGauge = _gauge(address(wethPool));

        manager = new GaugeManager(
            INonfungiblePositionManager(address(npm)), IERC20(address(aero)), IVault(address(vault)), address(0), address(0)
        );
        manager.setGauge(address(pool), address(gauge));
        manager.setGauge(address(wethPool), address(wethGauge));
        manager.setRewardBasePool(address(usdc), address(pool));
        usdc.mint(address(pool), 1_000_000 ether);
        aero.mint(address(pool), 1_000_000 ether);

        _stake(1, ALICE, address(aero));
        _stake(2, BOB, address(aero));
        _stake(3, BOB, address(weth));
    }

    function _gauge(address pool_) internal returns (AeroGaugeFixture g) {
        g = new AeroGaugeFixture(address(npm), pool_, address(aero));
        g.setVoter(address(voter));
        g.setMintsViaVoter(true);
        MockPool(pool_).setGauge(address(g));
    }

    function _stake(uint256 id, address owner, address token0) internal {
        npm.setPosition(id, token0, address(usdc), 100, -60, 60, 10);
        npm.mint(address(vault), id);
        vault.setOwner(id, owner);
        vm.startPrank(address(vault));
        npm.approve(address(manager), id);
        manager.stakePosition(id);
        vm.stopPrank();
    }

    function _withdraw(uint256 id) internal {
        vm.prank(address(vault));
        manager.unstakePosition(id);
    }

    function _claim(uint256 id, address owner) internal returns (uint256) {
        vm.prank(owner);
        return manager.claimRewards(id, owner);
    }

    /// Alice's 40 stays below the floor and is parked for her.
    function _parkAlice(uint256 amount) internal {
        gauge.setReward(1, amount);
        vm.expectEmit(true, true, true, true, address(manager));
        emit GaugeManager.PendingRedeemRecorded(address(handler), 0, ALICE, 1, amount);
        _withdraw(1);
        assertEq(npm.ownerOf(1), address(vault));
        assertEq(handler.pendingRedeems(address(manager)), amount, "parked at the handler");
        assertEq(receipt.balanceOf(address(handler)), amount, "receipt stays with the handler");
        assertEq(manager.pendingClaims(address(handler), 0, ALICE), amount);
        assertEq(manager.pendingBatches(address(handler), 0), amount);
        assertEq(aero.balanceOf(ALICE), 0);
        assertEq(manager.reservedRewards(), 0);
    }

    function testSetGaugeDetectsRootRedemption() public {
        assertEq(manager.rootHandlers(address(gauge)), address(handler));
        assertEq(manager.rootHandlers(address(wethGauge)), address(handler));
        // a leaf gauge that delivers the reward token directly registers without a handler
        AeroGaugeFixture leaf = new AeroGaugeFixture(address(npm), address(pool), address(aero));
        pool.setGauge(address(leaf));
        manager.setGauge(address(pool), address(leaf));
        assertEq(manager.rootHandlers(address(leaf)), address(0));
    }

    function testSetGaugeRejectsRootRedemptionOfTheRewardTokenItself() public {
        // a manager configured with the receipt token can never receive it: root redemption burns it
        GaugeManager wrong = new GaugeManager(
            INonfungiblePositionManager(address(npm)),
            IERC20(address(receipt)),
            IVault(address(vault)),
            address(0),
            address(0)
        );
        vm.expectRevert(GaugeManager.UnsupportedRewardDelivery.selector);
        wrong.setGauge(address(pool), address(gauge));
    }

    function testSubFloorWithdrawalParksTheOwnersReward() public {
        _parkAlice(40 ether);
        assertEq(manager.currentPendingBatch(address(handler)), 0);
        assertEq(manager.tokenIdToGauge(1), address(0));
    }

    function testAboveFloorClaimPaysImmediately() public {
        gauge.setReward(2, 120 ether);
        assertEq(_claim(2, BOB), 120 ether);
        assertEq(aero.balanceOf(BOB), 120 ether);
        assertEq(handler.pendingRedeems(address(manager)), 0);
        assertEq(receipt.totalSupply(), 0, "redeemed receipts are burned");
        assertEq(manager.reservedRewards(), 0);
    }

    function testLaterClaimFlushesTheBatchAndPaysEachOwnerTheirOwn() public {
        _parkAlice(40 ether);
        gauge.setReward(2, 70 ether);
        vm.expectEmit(true, true, false, true, address(manager));
        emit GaugeManager.PendingRedeemsFlushed(address(handler), 0, 40 ether);
        assertEq(_claim(2, BOB), 70 ether, "Bob is paid his own claim only");
        assertEq(aero.balanceOf(BOB), 70 ether);
        assertEq(aero.balanceOf(address(manager)), 40 ether, "Alice's flushed share stays in the manager");
        assertEq(manager.reservedRewards(), 40 ether);
        assertEq(manager.currentPendingBatch(address(handler)), 1);
        assertEq(handler.pendingRedeems(address(manager)), 0);
        assertEq(receipt.totalSupply(), 0);

        vm.prank(ALICE);
        assertEq(manager.claimPendingRewards(address(handler), 0, ALICE), 40 ether);
        assertEq(aero.balanceOf(ALICE), 40 ether);
        assertEq(manager.reservedRewards(), 0);
        assertEq(manager.pendingClaims(address(handler), 0, ALICE), 0);
    }

    function testPendingClaimNeedsAFlushAndTheRightOwner() public {
        _parkAlice(40 ether);
        vm.prank(ALICE);
        vm.expectRevert(GaugeManager.PendingRedeemNotFunded.selector);
        manager.claimPendingRewards(address(handler), 0, ALICE);
        vm.prank(BOB);
        vm.expectRevert(GaugeManager.NoPendingClaim.selector);
        manager.claimPendingRewards(address(handler), 0, BOB);

        gauge.setReward(2, 70 ether);
        _claim(2, BOB);
        vm.prank(BOB);
        vm.expectRevert(GaugeManager.NoPendingClaim.selector);
        manager.claimPendingRewards(address(handler), 0, BOB);
        vm.prank(ALICE);
        vm.expectRevert(Constants.InvalidConfig.selector);
        manager.claimPendingRewards(address(handler), 0, address(0));
        vm.prank(ALICE);
        manager.claimPendingRewards(address(handler), 0, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(GaugeManager.NoPendingClaim.selector);
        manager.claimPendingRewards(address(handler), 0, ALICE);
    }

    /// The reward token is a pool token of position 2: the withdrawal forwards Bob's reward and fees, not the flush.
    function testFlushAtWithdrawalKeepsEarlierOwnersRewardWhenTheRewardTokenIsAPoolToken() public {
        _parkAlice(40 ether);
        gauge.setReward(2, 70 ether);
        gauge.setFees(address(aero), 7 ether);
        _withdraw(2);
        assertEq(aero.balanceOf(BOB), 77 ether, "own reward plus withdrawal fees");
        assertEq(aero.balanceOf(address(manager)), 40 ether);
        assertEq(manager.reservedRewards(), 40 ether);
        assertEq(manager.currentPendingBatch(address(handler)), 1);
        vm.prank(ALICE);
        assertEq(manager.claimPendingRewards(address(handler), 0, ALICE), 40 ether);
    }

    /// Gauges of the same voter share the bucket: a withdrawal on the WETH gauge flushes Alice's AERO-gauge claim.
    function testFlushAtWithdrawalOnAnotherGaugeOfTheSameVoter() public {
        _parkAlice(40 ether);
        wethGauge.setReward(3, 70 ether);
        _withdraw(3);
        assertEq(aero.balanceOf(BOB), 70 ether);
        assertEq(manager.reservedRewards(), 40 ether);
        assertEq(manager.currentPendingBatch(address(handler)), 1);
        assertEq(manager.pendingBatches(address(handler), 0), 40 ether);
        vm.prank(ALICE);
        assertEq(manager.claimPendingRewards(address(handler), 0, ALICE), 40 ether);
    }

    function testTwoParkedOwnersAreBothPaidByOneFlush() public {
        _parkAlice(40 ether);
        wethGauge.setReward(3, 30 ether);
        _withdraw(3);
        assertEq(manager.pendingClaims(address(handler), 0, BOB), 30 ether);
        assertEq(manager.pendingBatches(address(handler), 0), 70 ether);
        assertEq(handler.pendingRedeems(address(manager)), 70 ether);

        gauge.setReward(2, 50 ether);
        assertEq(_claim(2, BOB), 50 ether);
        assertEq(manager.reservedRewards(), 70 ether);
        vm.prank(ALICE);
        manager.claimPendingRewards(address(handler), 0, ALICE);
        vm.prank(BOB);
        manager.claimPendingRewards(address(handler), 0, BOB);
        assertEq(aero.balanceOf(ALICE), 40 ether);
        assertEq(aero.balanceOf(BOB), 80 ether);
        assertEq(manager.reservedRewards(), 0);
        assertEq(aero.balanceOf(address(manager)), 0);
    }

    function testCompoundWithASubFloorClaimCompoundsNothingAndRecordsTheOwner() public {
        gauge.setReward(1, 40 ether);
        vm.prank(ALICE);
        vm.expectRevert(Constants.NotEnoughReward.selector);
        manager.compoundRewards(1, 1, 5000, block.timestamp);
        assertEq(manager.pendingClaims(address(handler), 0, ALICE), 0, "strict compound rolled back");

        vm.prank(ALICE);
        (uint256 compounded, uint256 added0, uint256 added1) = manager.compoundRewards(1, 0, 5000, block.timestamp);
        assertEq(compounded, 0);
        assertEq(added0 + added1, 0);
        assertEq(manager.pendingClaims(address(handler), 0, ALICE), 40 ether);
        assertEq(npm.ownerOf(1), address(gauge), "position stays staked");
    }

    function testCompoundThatFlushesCompoundsOnlyItsOwnReward() public {
        _parkAlice(40 ether);
        gauge.setReward(2, 70 ether);
        vm.prank(BOB);
        (uint256 compounded,,) = manager.compoundRewards(2, 70 ether, 5000, block.timestamp);
        assertEq(compounded, 70 ether);
        assertEq(manager.reservedRewards(), 40 ether);
        assertGe(aero.balanceOf(address(manager)), 40 ether);
        assertEq(npm.ownerOf(2), address(gauge));
        vm.prank(ALICE);
        assertEq(manager.claimPendingRewards(address(handler), 0, ALICE), 40 ether);
    }

    /// A deferred batch (failed mint at withdrawal) recovered below the floor is parked as a unit.
    function testRecoveryParksTheDeferredBatchUntilAFlush() public {
        gauge.setReward(1, 40 ether);
        gauge.setMintFails(true);
        _withdraw(1);
        assertEq(manager.deferredClaims(address(gauge), 0, ALICE), 40 ether);
        gauge.setMintFails(false);

        vm.expectEmit(true, true, true, true, address(manager));
        emit GaugeManager.DeferredBatchParked(address(gauge), 0, address(handler), 0, 40 ether);
        manager.recoverDeferredRewards(address(gauge));
        assertEq(manager.currentDeferredBatch(address(gauge)), 1, "batch is recovered");
        assertEq(manager.deferredBatchPendingIn(address(gauge), 0), 1, "but parked in pending batch 0");
        assertEq(manager.pendingBatches(address(handler), 0), 40 ether);
        assertEq(handler.pendingRedeems(address(manager)), 40 ether);
        assertEq(manager.reservedRewards(), 0);

        vm.prank(ALICE);
        vm.expectRevert(GaugeManager.PendingRedeemNotFunded.selector);
        manager.claimDeferredRewards(address(gauge), 0, ALICE);

        gauge.setReward(2, 70 ether);
        assertEq(_claim(2, BOB), 70 ether);
        assertEq(manager.reservedRewards(), 40 ether);
        vm.prank(ALICE);
        assertEq(manager.claimDeferredRewards(address(gauge), 0, ALICE), 40 ether);
        assertEq(aero.balanceOf(ALICE), 40 ether);
        assertEq(manager.reservedRewards(), 0);
    }

    function testClaimDeferredRewardsRevertsWhenItsRecoveryParksAndLeavesTheBatchUnrecovered() public {
        gauge.setReward(1, 40 ether);
        gauge.setMintFails(true);
        _withdraw(1);
        gauge.setMintFails(false);
        vm.prank(ALICE);
        vm.expectRevert(GaugeManager.PendingRedeemNotFunded.selector);
        manager.claimDeferredRewards(address(gauge), 0, ALICE);
        assertEq(manager.currentDeferredBatch(address(gauge)), 0, "the reverted recovery left nothing behind");
        assertEq(handler.pendingRedeems(address(manager)), 0);
        manager.recoverDeferredRewards(address(gauge));
        assertEq(manager.deferredBatchPendingIn(address(gauge), 0), 1);
    }

    function testRecoveryThatFlushesPaysTheBatchAndReservesEarlierLegs() public {
        _parkAlice(40 ether);
        gauge.setReward(2, 70 ether);
        gauge.setMintFails(true);
        _withdraw(2);
        assertEq(manager.deferredClaims(address(gauge), 0, BOB), 70 ether);
        gauge.setMintFails(false);

        manager.recoverDeferredRewards(address(gauge));
        assertEq(manager.deferredBatchPendingIn(address(gauge), 0), 0, "paid at recovery");
        assertEq(manager.currentPendingBatch(address(handler)), 1, "the recovery flushed Alice's leg");
        assertEq(manager.reservedRewards(), 110 ether);
        assertEq(aero.balanceOf(address(manager)), 110 ether);

        vm.prank(BOB);
        assertEq(manager.claimDeferredRewards(address(gauge), 0, BOB), 70 ether);
        vm.prank(ALICE);
        assertEq(manager.claimPendingRewards(address(handler), 0, ALICE), 40 ether);
        assertEq(manager.reservedRewards(), 0);
        assertEq(aero.balanceOf(address(manager)), 0);
    }

    function testRedeemFailureDefersAtTheGaugeLikeAnyFailedMint() public {
        voter.setRedeemFails(true);
        gauge.setReward(2, 120 ether);
        _withdraw(2);
        assertEq(manager.deferredClaims(address(gauge), 0, BOB), 120 ether);
        assertEq(gauge.deferredEmissions(address(manager)), 120 ether);
        assertEq(aero.balanceOf(BOB), 0);
        voter.setRedeemFails(false);
        vm.prank(BOB);
        assertEq(manager.claimDeferredRewards(address(gauge), 0, BOB), 120 ether);
    }

    /// A bucket the manager never recorded is surfaced on every operation and never blocks an exit; its flush is
    /// unowned surplus, not a reserved claim.
    function testUnrecordedBucketIsSurfacedExitsWorkAndItsFlushIsSurplus() public {
        handler.setPendingRedeems(address(manager), 30 ether);
        gauge.setReward(2, 20 ether);
        vm.expectEmit(true, true, false, true, address(manager));
        emit GaugeManager.PendingBatchOutOfSync(address(handler), 0, 0, 30 ether);
        _withdraw(2);
        assertEq(npm.ownerOf(2), address(vault));
        assertEq(manager.pendingClaims(address(handler), 0, BOB), 20 ether);
        assertEq(manager.pendingBatches(address(handler), 0), 20 ether);
        assertEq(handler.pendingRedeems(address(manager)), 50 ether);

        receipt.mint(address(handler), 30 ether); // back the unrecorded bucket so the fixture can burn it
        gauge.setReward(1, 60 ether);
        assertEq(_claim(1, ALICE), 60 ether);
        assertEq(aero.balanceOf(address(manager)), 50 ether);
        assertEq(manager.reservedRewards(), 20 ether, "only the recorded claim is reserved");
        vm.prank(BOB);
        assertEq(manager.claimPendingRewards(address(handler), 0, BOB), 20 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(aero);
        manager.withdrawBalances(tokens, address(0xFEE));
        assertEq(aero.balanceOf(address(0xFEE)), 30 ether, "unowned surplus is sweepable");
    }

    function testSweepCannotConsumeFlushedPendingRewards() public {
        _parkAlice(40 ether);
        gauge.setReward(2, 70 ether);
        _claim(2, BOB);
        aero.mint(address(manager), 7 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(aero);
        manager.withdrawBalances(tokens, address(0xFEE));
        assertEq(aero.balanceOf(address(0xFEE)), 7 ether);
        assertEq(aero.balanceOf(address(manager)), 40 ether);
    }

    function testFuzzRootRedemptionConservesEachOwnersReward(uint96 a, uint96 b, bool bobFirst) public {
        a = uint96(bound(a, 1, 10 * FLOOR));
        b = uint96(bound(b, 1, 10 * FLOOR));
        gauge.setReward(1, a);
        gauge.setReward(2, b);
        if (bobFirst) {
            _claim(2, BOB);
            _withdraw(1);
        } else {
            _withdraw(1);
            _claim(2, BOB);
        }
        // one more claim at the floor flushes whatever is still parked
        gauge.setReward(2, FLOOR);
        _claim(2, BOB);
        assertEq(handler.pendingRedeems(address(manager)), 0);
        _claimAllPending(ALICE);
        _claimAllPending(BOB);
        assertEq(aero.balanceOf(ALICE), a, "Alice gets exactly her reward");
        assertEq(aero.balanceOf(BOB), uint256(b) + FLOOR, "Bob gets exactly his rewards");
        assertEq(manager.reservedRewards(), 0);
        assertEq(aero.balanceOf(address(manager)), 0);
        assertEq(receipt.totalSupply(), 0);
    }

    function _claimAllPending(address owner) internal {
        uint256 batches = manager.currentPendingBatch(address(handler));
        for (uint256 batch; batch < batches; ++batch) {
            if (manager.pendingClaims(address(handler), batch, owner) != 0) {
                vm.prank(owner);
                manager.claimPendingRewards(address(handler), batch, owner);
            }
        }
    }
}
