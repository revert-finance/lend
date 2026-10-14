// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {GaugeManager} from "../../src/GaugeManager.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LeafDeliveryFixture, LeafVoterFixture} from "../mocks/AeroDeliveryFixture.sol";
import {AeroGaugeFixture} from "../mocks/AeroGaugeFixture.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {MockNPM, MockVault, MockPool, MockSlipstreamFactory, MockERC20Token} from "./GaugeManager.t.sol";

// The root handler has LEAF_VOTER/pendingRedeems but no receipt-token delivery getter.
contract RootDeliveryFixture {
    address public LEAF_VOTER;
    mapping(address => uint256) public pendingRedeems;
}

contract DeliveryConfigFixture {
    address public RECEIPT_TOKEN;
    address public EMISSIONS_HANDLER;

    constructor(address token, address handler) {
        RECEIPT_TOKEN = token;
        EMISSIONS_HANDLER = handler;
    }
}

contract AeroGaugeManagerTest is Test {
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    MockERC20Token token;
    MockERC20Token usdc;
    MockERC20Token weth;
    MockSlipstreamFactory factory;
    MockPool pool;
    MockNPM npm;
    MockVault vault;
    AeroGaugeFixture gauge;
    GaugeManager manager;

    function setUp() public {
        token = new MockERC20Token("Aero receipt", "rAERO");
        usdc = new MockERC20Token("USDC", "USDC");
        weth = new MockERC20Token("WETH", "WETH");
        factory = new MockSlipstreamFactory();
        pool = new MockPool(address(token), address(usdc), 100);
        factory.setPool(address(token), address(usdc), 100, address(pool));
        npm = new MockNPM(address(factory), address(weth));
        vault = new MockVault();
        gauge = new AeroGaugeFixture(address(npm), address(pool), address(token));
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

    function _stake(uint256 id, address owner) internal {
        npm.setPosition(id, address(token), address(usdc), 100, -60, 60, 10);
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

    function _deferAlice(uint256 amount) internal {
        gauge.setReward(1, amount);
        gauge.setMintFails(true);
        _withdraw(1);
        assertEq(npm.ownerOf(1), address(vault));
        assertEq(manager.tokenIdToGauge(1), address(0));
        assertEq(manager.deferredClaims(address(gauge), 0, ALICE), amount);
    }

    function test_WhenFailedMintReleasesPrincipalAndRecordsOwner() public {
        _deferAlice(100 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(manager.reservedRewards(), 0);
        assertEq(gauge.deferredEmissions(address(manager)), 100 ether);
    }

    function testBobClaimCannotReceiveAliceDeferral() public {
        _deferAlice(100 ether);
        gauge.setReward(2, 20 ether);
        assertEq(manager.positionRewards(2), 20 ether);
        gauge.setMintFails(false);
        vm.prank(BOB);
        assertEq(manager.claimRewards(2, BOB), 20 ether);
        assertEq(token.balanceOf(BOB), 20 ether);
        assertEq(token.balanceOf(address(manager)), 100 ether);
        assertEq(manager.reservedRewards(), 100 ether);
        assertEq(manager.currentDeferredBatch(address(gauge)), 1);
        vm.prank(ALICE);
        manager.claimDeferredRewards(address(gauge), 0, ALICE);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(manager.reservedRewards(), 0);
    }

    function testDeferredClaimSurvivesNFTLeavingAndChangingOwner() public {
        _deferAlice(100 ether);
        vm.prank(address(vault));
        npm.transferFrom(address(vault), BOB, 1);
        vault.setOwner(1, BOB);
        gauge.setMintFails(false);
        vm.prank(BOB);
        vm.expectRevert(GaugeManager.NoDeferredClaim.selector);
        manager.claimDeferredRewards(address(gauge), 0, BOB);
        vm.prank(ALICE);
        manager.claimDeferredRewards(address(gauge), 0, ALICE);
        assertEq(token.balanceOf(ALICE), 100 ether);
        vm.prank(ALICE);
        vm.expectRevert(GaugeManager.NoDeferredClaim.selector);
        manager.claimDeferredRewards(address(gauge), 0, ALICE);
    }

    function testRecoveredOldBatchPayableDuringNewOutage() public {
        _deferAlice(100 ether);
        gauge.setMintFails(false);
        manager.recoverDeferredRewards(address(gauge));
        gauge.setReward(2, 20 ether);
        gauge.setMintFails(true);
        _withdraw(2);
        vm.prank(ALICE);
        manager.claimDeferredRewards(address(gauge), 0, ALICE);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(manager.deferredClaims(address(gauge), 1, BOB), 20 ether);
        assertEq(gauge.deferredEmissions(address(manager)), 20 ether);
        vm.prank(BOB);
        vm.expectRevert(bytes("mint unavailable"));
        manager.claimDeferredRewards(address(gauge), 1, BOB);
        assertEq(manager.deferredClaims(address(gauge), 1, BOB), 20 ether);
    }

    function testSweepCannotConsumeUserEscrowIncludingDuplicateTokenEntries() public {
        _deferAlice(100 ether);
        gauge.setMintFails(false);
        manager.recoverDeferredRewards(address(gauge));
        token.mint(address(manager), 7 ether);
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token);
        manager.withdrawBalances(tokens, BOB);
        assertEq(token.balanceOf(BOB), 7 ether);
        assertEq(token.balanceOf(address(manager)), 100 ether);
        assertEq(manager.reservedRewards(), 100 ether);
    }

    function test_WhenFailedClaimRecoveryRollsBackAndWithdrawalStillDefers() public {
        _deferAlice(100 ether);
        gauge.setReward(2, 20 ether);
        vm.prank(BOB);
        vm.expectRevert(bytes("mint unavailable"));
        manager.claimRewards(2, BOB);
        assertEq(manager.reservedRewards(), 0);
        _withdraw(2);
        assertEq(manager.deferredClaims(address(gauge), 0, ALICE), 100 ether);
        assertEq(manager.deferredClaims(address(gauge), 0, BOB), 20 ether);
        assertEq(gauge.deferredEmissions(address(manager)), 120 ether);
    }

    function testWithdrawalPayoutBelongsToOwnerEvenWhenStandaloneClaimsAreUnavailable() public {
        gauge.setReward(1, 10 ether);
        gauge.setClaimFails(true);
        _withdraw(1);
        assertEq(token.balanceOf(ALICE), 10 ether);
        assertEq(manager.reservedRewards(), 0);
    }

    function testWithdrawalFeesIncludingAeroArePaidExactlyOnce() public {
        gauge.setFees(address(token), 7 ether);
        gauge.setWithdrawalReward(3 ether);
        _withdraw(1);
        assertEq(token.balanceOf(ALICE), 10 ether);
        gauge.setFees(address(usdc), 5 ether);
        _withdraw(2);
        assertEq(token.balanceOf(BOB), 3 ether);
        assertEq(usdc.balanceOf(BOB), 5 ether);
    }

    function testDeferredRecoverySurvivesGaugeReplacement() public {
        _deferAlice(100 ether);
        AeroGaugeFixture next = new AeroGaugeFixture(address(npm), address(pool), address(token));
        pool.setGauge(address(next));
        manager.setGauge(address(pool), address(next));
        gauge.setMintFails(false);
        vm.prank(ALICE);
        manager.claimDeferredRewards(address(gauge), 0, ALICE);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    function testDifferentGaugesDoNotShareBatches() public {
        _deferAlice(100 ether);
        AeroGaugeFixture next = new AeroGaugeFixture(address(npm), address(pool), address(token));
        pool.setGauge(address(next));
        manager.setGauge(address(pool), address(next));
        _stake(3, BOB);
        next.setReward(3, 40 ether);
        next.setMintFails(true);
        _withdraw(3);
        next.setMintFails(false);
        vm.prank(BOB);
        manager.claimDeferredRewards(address(next), 0, BOB);
        assertEq(token.balanceOf(BOB), 40 ether);
        assertEq(gauge.deferredEmissions(address(manager)), 100 ether);
        assertEq(manager.deferredClaims(address(gauge), 0, ALICE), 100 ether);
    }

    function testBobCompoundingCannotSpendAliceEscrow() public {
        _deferAlice(100 ether);
        gauge.setReward(2, 20 ether);
        gauge.setMintFails(false);
        vm.prank(BOB);
        (uint256 compounded,,) = manager.compoundRewards(2, 20 ether, 5000, block.timestamp);
        assertEq(compounded, 20 ether);
        assertGe(token.balanceOf(address(manager)), 100 ether);
        assertEq(manager.reservedRewards(), 100 ether);
        assertEq(npm.ownerOf(2), address(gauge));
        vm.prank(ALICE);
        manager.claimDeferredRewards(address(gauge), 0, ALICE);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    function test_WhenFailedRestakeRollsBackRecoveryAndClaim() public {
        _deferAlice(100 ether);
        gauge.setReward(2, 20 ether);
        gauge.setMintFails(false);
        gauge.setDepositsDisabled(true);
        vm.prank(BOB);
        vm.expectRevert(bytes("retired"));
        manager.compoundRewards(2, 20 ether, 5000, block.timestamp);
        assertEq(gauge.deferredEmissions(address(manager)), 100 ether);
        assertEq(manager.reservedRewards(), 0);
        assertEq(gauge.rewards(2), 20 ether);
        assertEq(npm.ownerOf(2), address(gauge));
        _withdraw(2);
        assertEq(npm.ownerOf(2), address(vault));
    }

    function testExitSucceedsWhileRecoveryRevertsWhenGaugeBucketIsOutOfSync() public {
        _deferAlice(100 ether);
        gauge.setDeferredEmissions(address(manager), 130 ether); // 30 the manager never recorded
        gauge.setReward(2, 20 ether);
        vm.expectEmit(true, true, false, true, address(manager));
        emit GaugeManager.DeferredBatchOutOfSync(address(gauge), 0, 100 ether, 130 ether);
        vm.prank(address(vault));
        assertTrue(manager.unstakeIfStaked(2));
        assertEq(npm.ownerOf(2), address(vault));
        assertEq(manager.tokenIdToGauge(2), address(0));
        assertEq(manager.deferredClaims(address(gauge), 0, BOB), 20 ether);
        (uint256 recorded,) = manager.deferredBatches(address(gauge), 0);
        assertEq(recorded, 120 ether);
        assertEq(gauge.deferredEmissions(address(manager)), 150 ether);

        gauge.setMintFails(false);
        vm.expectRevert(GaugeManager.DeferredAccountingMismatch.selector);
        manager.recoverDeferredRewards(address(gauge));
        vm.prank(ALICE);
        vm.expectRevert(GaugeManager.DeferredAccountingMismatch.selector);
        manager.claimDeferredRewards(address(gauge), 0, ALICE);
        assertEq(manager.reservedRewards(), 0);
    }

    function testExitRecordsNothingWhenWithdrawalShrinksGaugeBucket() public {
        _deferAlice(100 ether);
        gauge.setWithdrawClearsBucket(true);
        gauge.setReward(2, 20 ether);
        vm.prank(address(vault));
        assertTrue(manager.unstakeIfStaked(2));
        assertEq(npm.ownerOf(2), address(vault));
        assertEq(manager.deferredClaims(address(gauge), 0, BOB), 0);
        assertEq(gauge.deferredEmissions(address(manager)), 20 ether);
    }

    function testUnauthorizedPaths() public {
        vm.expectRevert(GaugeManager.UnknownGauge.selector);
        manager.recoverDeferredRewards(address(0xBAD));
        vm.prank(BOB);
        vm.expectRevert();
        manager.claimRewards(1, BOB);
        vm.prank(BOB);
        vm.expectRevert();
        manager.unstakePosition(1);
    }

    function testNonOwnerCannotSetGauge() public {
        vm.prank(BOB);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        manager.setGauge(address(pool), address(gauge));
        assertEq(manager.poolToGauge(address(pool)), address(gauge));
        assertTrue(manager.knownGauges(address(gauge)));
    }

    function testRejectsRootRedemptionHandler() public {
        gauge.setVoter(address(new DeliveryConfigFixture(address(token), address(new RootDeliveryFixture()))));
        vm.expectRevert();
        manager.setGauge(address(pool), address(gauge));
    }

    function testRejectsWrongReceiptToken() public {
        gauge.setVoter(address(new LeafVoterFixture(address(usdc))));
        vm.expectRevert(GaugeManager.UnsupportedRewardDelivery.selector);
        manager.setGauge(address(pool), address(gauge));
    }

    function testRejectsHandlerBoundToAnotherVoter() public {
        address handler = address(new LeafDeliveryFixture(address(token), address(0xBAD)));
        gauge.setVoter(address(new DeliveryConfigFixture(address(token), handler)));
        vm.expectRevert(GaugeManager.UnsupportedRewardDelivery.selector);
        manager.setGauge(address(pool), address(gauge));
    }

    function testFuzzSharedBatchConservesOwnerRewards(uint96 a, uint96 b, bool bobFirst) public {
        a = uint96(bound(a, 1, type(uint96).max));
        b = uint96(bound(b, 1, type(uint96).max));
        _deferAlice(a);
        gauge.setReward(2, b);
        _withdraw(2);
        gauge.setMintFails(false);
        manager.recoverDeferredRewards(address(gauge));
        assertEq(manager.reservedRewards(), uint256(a) + b);
        address first = bobFirst ? BOB : ALICE;
        address second = bobFirst ? ALICE : BOB;
        vm.prank(first);
        manager.claimDeferredRewards(address(gauge), 0, first);
        vm.prank(second);
        manager.claimDeferredRewards(address(gauge), 0, second);
        assertEq(token.balanceOf(ALICE), a);
        assertEq(token.balanceOf(BOB), b);
        assertEq(manager.reservedRewards(), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(gauge.deferredEmissions(address(manager)), 0);
    }
}
