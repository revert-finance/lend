// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/poolpeach/PoolPeachFactory.sol";
import "../../src/V3Oracle.sol";
import "../../src/interfaces/aerodrome/IAerodromeSlipstreamPool.sol";

// The repository's pinned forge-std predates the emitter field in Foundry's log cheatcode.
interface PoolPeachLogReader {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
    function getRecordedLogs() external returns (Log[] memory);
}

contract PoolPeachTestBeneficiary is IERC721Receiver {
    PoolPeachPosition public holder;
    bool public rejectNFT;
    bool public reentrySucceeded;
    bool public reentryAttempted;

    function create(PoolPeachFactory factory, V3Utils.SwapAndMintParams calldata p, AutoExit.PositionConfig calldata c)
        external
        payable
        returns (uint256 id)
    {
        p.token0.approve(address(factory), p.amount0);
        p.token1.approve(address(factory), p.amount1);
        (id, holder) = factory.create{value: msg.value}(p, c, false);
    }

    function setRejectNFT(bool reject) external {
        rejectNFT = reject;
    }

    function withdraw() external {
        holder.withdraw();
    }

    function withdrawTo(address recipient) external {
        holder.withdrawTo(recipient);
    }

    function claimNFT(address recipient) external {
        holder.claimNFT(recipient);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!rejectNFT, "reject NFT");
        reentryAttempted = true;
        (reentrySucceeded,) = address(holder).call(abi.encodeCall(PoolPeachPosition.withdraw, ()));
        return IERC721Receiver.onERC721Received.selector;
    }
}

// Deliberately has no ERC721 receiver hook and no upgrade path.
contract PoolPeachNonReceiverBeneficiary {
    PoolPeachPosition public holder;

    function create(PoolPeachFactory factory, V3Utils.SwapAndMintParams calldata p, AutoExit.PositionConfig calldata c)
        external
        returns (uint256 id)
    {
        p.token0.approve(address(factory), p.amount0);
        p.token1.approve(address(factory), p.amount1);
        (id, holder) = factory.create(p, c, false);
    }

    function withdrawTo(address recipient) external {
        holder.withdrawTo(recipient);
    }

    function claimNFT(address recipient) external {
        holder.claimNFT(recipient);
    }
}

/// @dev Actual deployed Aero dependencies; only the proposed factory/holders are new.
/// BASE_RPC_URL must support historical state. No broadcast or signing occurs.
contract PoolPeachFactoryForkTest is Test {
    using stdStorage for StdStorage;
    V3Utils constant UTILS = V3Utils(payable(0x1D388deC5C440f572D3103B09f22aCd674b707f5));
    V3Vault constant VAULT = V3Vault(0x1c69eb478425199D34D93484c76c1B39554979a1);
    GaugeManager constant MANAGER = GaugeManager(0x1AC3a1C018a09146dcE000eFcC67e2129aDc6DBD);
    AutoRangeAndCompound constant RANGE = AutoRangeAndCompound(payable(0x1d0B1401AFdd36aFCAc521DaC95a7F1906BAD642));
    AutoExit constant EXIT = AutoExit(payable(0x5793aed47c74b53a67c864ca080136Ba4E8452b8));
    IAerodromeSlipstreamPool constant POOL = IAerodromeSlipstreamPool(0x4A7af46bC8aBc00048c6c7920a1488DAF568366c);
    address constant OPERATOR = 0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    INonfungiblePositionManager npm;
    PoolPeachFactory factory;
    int24 tick;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 53168029);
        factory = new PoolPeachFactory(UTILS, VAULT, RANGE, EXIT);
        npm = UTILS.nonfungiblePositionManager();
        (, tick,,,,) = POOL.slot0();
        _operator(address(factory), true);
        for (uint256 i; i < 2; ++i) {
            address user = i == 0 ? ALICE : BOB;
            deal(POOL.token0(), user, 1 ether);
            deal(POOL.token1(), user, 10000e6);
            vm.startPrank(user);
            IERC20(POOL.token0()).approve(address(factory), type(uint256).max);
            IERC20(POOL.token1()).approve(address(factory), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _operator(address who, bool enabled) internal {
        address admin = EXIT.owner();
        vm.prank(admin);
        EXIT.setOperator(who, enabled);
    }

    function _params() internal view returns (V3Utils.SwapAndMintParams memory p) {
        p.token0 = IERC20(POOL.token0());
        p.token1 = IERC20(POOL.token1());
        int24 spacing = POOL.tickSpacing();
        p.fee = uint24(spacing);
        p.tickLower = (tick / spacing) * spacing - spacing * 100;
        p.tickUpper = (tick / spacing) * spacing + spacing * 100;
        p.amount0 = 0.01 ether;
        p.amount1 = 100e6;
        p.deadline = block.timestamp + 3600;
    }

    function _config(bool triggered) internal view returns (AutoExit.PositionConfig memory c) {
        c.isActive = true;
        c.onlyFees = true;
        c.token0TriggerTick = triggered ? tick + 1 : tick - 100;
        c.token1TriggerTick = tick + 100;
    }

    function _create(address user, bool stake, bool triggered) internal returns (uint256 id, PoolPeachPosition holder) {
        V3Utils.SwapAndMintParams memory p = _params();
        AutoExit.PositionConfig memory c = _config(triggered);
        vm.prank(user);
        return factory.create(p, c, stake);
    }

    function _execute(uint256 id) internal {
        vm.prank(OPERATOR);
        factory.executeExit(AutoExit.ExecuteParams(id, "", 0, 0, block.timestamp, 0));
    }

    function test_CreateRegistersOnlyActualMintAndSetsBothAutomations() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        assertEq(factory.activeHolder(id), address(holder));
        assertEq(holder.beneficiary(), ALICE);
        assertEq(npm.ownerOf(id), address(VAULT));
        assertEq(VAULT.ownerOf(id), address(holder));
        assertEq(VAULT.loans(id), 0);
        assertTrue(VAULT.transformApprovals(address(holder), id, address(RANGE)));
        assertEq(RANGE.stakingConsent(id, address(VAULT)), address(holder));
        (bool active,,,,,,,,) = EXIT.positionConfigs(id);
        assertTrue(active);
        assertEq(factory.creatingHolder(), address(0));
        assertEq(IERC20(POOL.token0()).allowance(address(factory), address(UTILS)), 0);
        assertEq(IERC20(POOL.token1()).allowance(address(factory), address(UTILS)), 0);
        assertEq(IERC20(POOL.token0()).balanceOf(address(factory)), 0);
        assertEq(IERC20(POOL.token1()).balanceOf(address(factory)), 0);
    }

    function _clearPoolTokenOracleConfig() internal {
        V3Oracle oracle = V3Oracle(address(VAULT.oracle()));
        address token = POOL.token1();
        assertTrue(oracle.isTokenConfigured(token));
        // Model a registered gauge whose token has not been configured, without assuming storage slots.
        vm.record();
        oracle.feedConfigs(token);
        (bytes32[] memory slots,) = vm.accesses(address(oracle));
        assertGt(slots.length, 0);
        for (uint256 i; i < slots.length; ++i) {
            vm.store(address(oracle), slots[i], bytes32(0));
        }
        assertFalse(oracle.isTokenConfigured(token));
        assertTrue(MANAGER.poolToGauge(address(POOL)) != address(0));
    }

    function _assertMissingOracleRejectsCreation(bool initiallyStake) internal {
        _clearPoolTokenOracleConfig();
        V3Utils.SwapAndMintParams memory p = _params();
        AutoExit.PositionConfig memory c = _config(true);
        uint256 before0 = p.token0.balanceOf(ALICE);
        uint256 before1 = p.token1.balanceOf(ALICE);
        uint256 supplyBefore = npm.totalSupply();
        vm.prank(ALICE);
        vm.expectRevert(Constants.NotConfigured.selector);
        factory.create(p, c, initiallyStake);
        assertEq(p.token0.balanceOf(ALICE), before0);
        assertEq(p.token1.balanceOf(ALICE), before1);
        assertEq(npm.totalSupply(), supplyBefore);
        assertEq(factory.creatingHolder(), address(0));
        assertEq(p.token0.allowance(address(factory), address(UTILS)), 0);
        assertEq(p.token1.allowance(address(factory), address(UTILS)), 0);
    }

    function test_CreateRejectsMissingOracleForUnstakedPosition() public {
        _assertMissingOracleRejectsCreation(false);
    }

    function test_CreateRejectsMissingOracleForStakedPosition() public {
        _assertMissingOracleRejectsCreation(true);
    }

    function test_OracleUnavailableAfterCreationDoesNotBlockManualWithdrawal() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, true, true);
        _clearPoolTokenOracleConfig();
        vm.prank(ALICE);
        holder.withdraw();
        assertEq(npm.ownerOf(id), ALICE);
        assertEq(factory.activeHolder(id), address(0));
    }

    function test_CreateCanStakeInSameTransaction() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, true, true);
        assertEq(npm.ownerOf(id), MANAGER.tokenIdToGauge(id));
        assertEq(factory.activeHolder(id), address(holder));
    }

    function test_CallerIsBeneficiaryRegardlessOfRecipientFields() public {
        V3Utils.SwapAndMintParams memory p = _params();
        p.recipient = BOB;
        p.recipientNFT = BOB;
        p.returnData = abi.encode(BOB);
        AutoExit.PositionConfig memory c = _config(true);
        uint256 bob0 = p.token0.balanceOf(BOB);
        vm.prank(ALICE);
        (uint256 id, PoolPeachPosition holder) = factory.create(p, c, false);
        assertEq(holder.beneficiary(), ALICE);
        assertEq(VAULT.ownerOf(id), address(holder));
        assertEq(p.token0.balanceOf(BOB), bob0);
    }

    function test_ManualWithdrawalClearsRegistryConsentApprovalAndExitRule() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, true, false);
        vm.prank(ALICE);
        holder.withdraw();
        assertEq(factory.activeHolder(id), address(0));
        assertEq(address(factory.positions(id)), address(holder), "retain recovery address");
        assertEq(npm.ownerOf(id), ALICE);
        assertEq(VAULT.ownerOf(id), address(0));
        assertEq(RANGE.stakingConsent(id, address(VAULT)), address(0));
        assertFalse(VAULT.transformApprovals(address(holder), id, address(RANGE)));
        assertEq(npm.getApproved(id), address(0));
        (bool active,,,,,,,,) = EXIT.positionConfigs(id);
        assertFalse(active);
    }

    function test_AutoExitPaysOnlyBeneficiaryAndClosesRegistry() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        uint256 before0 = IERC20(POOL.token0()).balanceOf(ALICE);
        uint256 before1 = IERC20(POOL.token1()).balanceOf(ALICE);
        _execute(id);
        assertEq(factory.activeHolder(id), address(0));
        assertEq(npm.ownerOf(id), address(holder));
        assertEq(uint256(holder.state()), uint256(PoolPeachPosition.State.Closed));
        assertGt(IERC20(POOL.token0()).balanceOf(ALICE), before0);
        assertGt(IERC20(POOL.token1()).balanceOf(ALICE), before1);
        assertEq(address(holder).balance, 0);
    }

    function test_AutoExitFromGaugeAfterPenaltyWindow() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, true, true);
        vm.roll(MANAGER.penaltyWindowEnd(id));
        _execute(id);
        assertEq(npm.ownerOf(id), address(holder));
        assertEq(factory.activeHolder(id), address(0));
        assertEq(MANAGER.tokenIdToGauge(id), address(0));
    }

    function test_AutoExitRespectsPenaltyWindowButManualWithdrawalRemainsPossible() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, true, true);
        assertGt(MANAGER.penaltyWindowEnd(id), block.number);
        vm.expectRevert(PoolPeachPosition.InsidePenaltyWindow.selector);
        _execute(id);
        assertEq(factory.activeHolder(id), address(holder));
        vm.prank(ALICE);
        holder.withdraw();
        assertEq(npm.ownerOf(id), ALICE);
    }

    function test_UnmetTriggerRollsBackUnstakingAndAllPermissions() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, true, false);
        vm.roll(MANAGER.penaltyWindowEnd(id));
        address gauge = npm.ownerOf(id);
        vm.expectRevert(Constants.NotReady.selector);
        _execute(id);
        assertEq(npm.ownerOf(id), gauge);
        assertEq(VAULT.ownerOf(id), address(holder));
        assertEq(factory.activeHolder(id), address(holder));
        assertEq(RANGE.stakingConsent(id, address(VAULT)), address(holder));
        assertTrue(VAULT.transformApprovals(address(holder), id, address(RANGE)));
    }

    function test_SlippageFailureRollsBackExit() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        vm.prank(OPERATOR);
        vm.expectRevert();
        factory.executeExit(AutoExit.ExecuteParams(id, "", type(uint256).max, type(uint256).max, block.timestamp, 0));
        assertEq(factory.activeHolder(id), address(holder));
        assertEq(npm.ownerOf(id), address(VAULT));
    }

    function test_UnknownUserCannotWithdrawOrChangeConsentOrClaim() public {
        (, PoolPeachPosition holder) = _create(ALICE, false, true);
        vm.startPrank(BOB);
        vm.expectRevert(PoolPeachPosition.Unauthorized.selector);
        holder.withdraw();
        vm.expectRevert(PoolPeachPosition.Unauthorized.selector);
        holder.withdrawTo(BOB);
        vm.expectRevert(PoolPeachPosition.Unauthorized.selector);
        holder.claimNFT(BOB);
        vm.expectRevert(PoolPeachPosition.Unauthorized.selector);
        holder.setStakingManagement(false);
        vm.expectRevert(PoolPeachPosition.Unauthorized.selector);
        holder.claimRootDeferredRewards();
        vm.expectRevert(PoolPeachPosition.Unauthorized.selector);
        holder.claimNative();
        vm.stopPrank();
    }

    function test_OnlyFactoryCanPrepareOrFinishExit() public {
        (, PoolPeachPosition holder) = _create(ALICE, false, true);
        vm.startPrank(OPERATOR);
        vm.expectRevert(PoolPeachPosition.Unauthorized.selector);
        holder.prepareAutoExit();
        vm.expectRevert(PoolPeachPosition.Unauthorized.selector);
        holder.finishAutoExit();
        vm.stopPrank();
    }

    function test_UnprivilegedCallerCannotTriggerExitOrForgeRegistryRemoval() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        vm.prank(BOB);
        vm.expectRevert(PoolPeachFactory.Unauthorized.selector);
        factory.executeExit(AutoExit.ExecuteParams(id, "", 0, 0, block.timestamp, 0));
        vm.prank(BOB);
        vm.expectRevert(PoolPeachFactory.Unauthorized.selector);
        factory.positionClosed(id);
        assertEq(factory.activeHolder(id), address(holder));
    }

    function test_RevokedFactoryOperatorCannotExecuteAndDoesNotBlockManualWithdrawal() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        _operator(address(factory), false);
        vm.expectRevert(Constants.Unauthorized.selector);
        _execute(id);
        assertEq(factory.activeHolder(id), address(holder));
        vm.prank(ALICE);
        holder.withdraw();
        assertEq(npm.ownerOf(id), ALICE);
    }

    function test_CreateFailsWithoutFactoryOperatorRegistrationBeforeTakingFunds() public {
        _operator(address(factory), false);
        uint256 balance = IERC20(POOL.token0()).balanceOf(ALICE);
        V3Utils.SwapAndMintParams memory p = _params();
        AutoExit.PositionConfig memory c = _config(true);
        vm.prank(ALICE);
        vm.expectRevert(PoolPeachFactory.InvalidBinding.selector);
        factory.create(p, c, false);
        assertEq(IERC20(POOL.token0()).balanceOf(ALICE), balance);
    }

    function test_CreateRejectsThirdTokenFunding() public {
        V3Utils.SwapAndMintParams memory p = _params();
        p.swapSourceToken = IERC20(address(0x1234));
        AutoExit.PositionConfig memory c = _config(true);
        vm.prank(ALICE);
        vm.expectRevert(PoolPeachFactory.InvalidMint.selector);
        factory.create(p, c, false);
    }

    function test_CreateRejectsDisabledExitConfiguration() public {
        V3Utils.SwapAndMintParams memory p = _params();
        AutoExit.PositionConfig memory c;
        vm.prank(ALICE);
        vm.expectRevert(PoolPeachFactory.InvalidMint.selector);
        factory.create(p, c, false);
    }

    function test_CreateInvalidExitConfigRollsBackMintAndFunding() public {
        uint256 balance = IERC20(POOL.token0()).balanceOf(ALICE);
        uint256 count = VAULT.loanCount(address(this));
        V3Utils.SwapAndMintParams memory p = _params();
        AutoExit.PositionConfig memory c = _config(true);
        c.token0TriggerTick = c.token1TriggerTick;
        vm.prank(ALICE);
        vm.expectRevert(Constants.InvalidConfig.selector);
        factory.create(p, c, false);
        assertEq(IERC20(POOL.token0()).balanceOf(ALICE), balance);
        assertEq(factory.creatingHolder(), address(0));
        assertEq(VAULT.loanCount(address(this)), count);
    }

    function test_FundingRejectsTokensReportingSuccessWithoutExactTransfer() public {
        V3Utils.SwapAndMintParams memory p = _params();
        AutoExit.PositionConfig memory c = _config(true);
        vm.mockCall(address(p.token0), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.prank(ALICE);
        vm.expectRevert(PoolPeachFactory.UnsupportedToken.selector);
        factory.create(p, c, false);
    }

    function test_ArbitraryNFTReceiptAndRepeatInitializationRejected() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        vm.expectRevert(PoolPeachPosition.InvalidNFT.selector);
        holder.onERC721Received(address(UTILS), address(UTILS), id + 1, "");
        AutoExit.PositionConfig memory c = _config(true);
        vm.prank(address(factory));
        vm.expectRevert(PoolPeachPosition.InvalidState.selector);
        holder.initialize(id, c, false);
    }

    function test_ClosedPositionCannotBeReactivatedOrRedeposited() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        vm.prank(ALICE);
        holder.withdraw();
        vm.startPrank(ALICE);
        vm.expectRevert(PoolPeachPosition.InvalidState.selector);
        holder.setStakingManagement(true);
        vm.expectRevert(PoolPeachPosition.InvalidState.selector);
        holder.withdraw();
        vm.expectRevert(PoolPeachPosition.InvalidNFT.selector);
        npm.safeTransferFrom(ALICE, address(holder), id);
        vm.stopPrank();
        assertEq(factory.activeHolder(id), address(0));
    }

    function test_OwnerCanDisableAndReenableStaking() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        vm.startPrank(ALICE);
        holder.setStakingManagement(false);
        assertEq(RANGE.stakingConsent(id, address(VAULT)), address(0));
        holder.setStakingManagement(true);
        assertEq(RANGE.stakingConsent(id, address(VAULT)), address(holder));
        vm.stopPrank();
    }

    function test_ActualKeeperCanStakeWithGrantedConsent() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        AutoRangeAndCompound.AutoCompoundParams memory p;
        p.tokenId = id;
        p.deadline = block.timestamp;
        IVault.RewardCompoundParams memory r =
            IVault.RewardCompoundParams(0, 5000, block.timestamp, IVault.StakeTarget.Staked);
        vm.prank(OPERATOR);
        RANGE.autoCompoundWithVaultAndRewardCompound(p, address(VAULT), r);
        assertEq(npm.ownerOf(id), MANAGER.tokenIdToGauge(id));
        assertEq(factory.activeHolder(id), address(holder));
        assertEq(VAULT.loans(id), 0);
    }

    function test_DisabledConsentBlocksActualKeeperStaking() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        vm.prank(ALICE);
        holder.setStakingManagement(false);
        AutoRangeAndCompound.AutoCompoundParams memory p;
        p.tokenId = id;
        p.deadline = block.timestamp;
        IVault.RewardCompoundParams memory r =
            IVault.RewardCompoundParams(0, 5000, block.timestamp, IVault.StakeTarget.Staked);
        vm.prank(OPERATOR);
        vm.expectRevert(Constants.Unauthorized.selector);
        RANGE.autoCompoundWithVaultAndRewardCompound(p, address(VAULT), r);
        assertEq(npm.ownerOf(id), address(VAULT));
    }

    function _rootLiability(PoolPeachPosition holder, uint256 amount, bool funded) internal {
        stdstore.target(address(MANAGER))
            .sig("rootDeferredRewards(address)")
            .with_key(address(holder))
            .checked_write(amount);
        uint256 reserves = MANAGER.reservedRewards() + amount;
        stdstore.target(address(MANAGER)).sig("reservedRewards()").checked_write(reserves);
        deal(address(MANAGER.aeroToken()), address(MANAGER), funded ? reserves : 0);
    }

    function test_RootRewardsRemainClaimableAfterWithdrawalAndAreIsolated() public {
        (, PoolPeachPosition aliceHolder) = _create(ALICE, false, true);
        (, PoolPeachPosition bobHolder) = _create(BOB, false, true);
        _rootLiability(aliceHolder, 7e18, true);
        _rootLiability(bobHolder, 11e18, true);
        vm.prank(ALICE);
        aliceHolder.withdraw();
        uint256 aliceBefore = MANAGER.aeroToken().balanceOf(ALICE);
        vm.prank(ALICE);
        assertEq(aliceHolder.claimRootDeferredRewards(), 7e18);
        assertEq(MANAGER.aeroToken().balanceOf(ALICE), aliceBefore + 7e18);
        assertEq(MANAGER.rootDeferredRewards(address(bobHolder)), 11e18);
        vm.prank(BOB);
        assertEq(bobHolder.claimRootDeferredRewards(), 11e18);
    }

    function test_UnfundedRewardDoesNotBlockPrincipalWithdrawal() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        _rootLiability(holder, 9e18, false);
        vm.prank(ALICE);
        vm.expectRevert(GaugeManager.DeferredAccountingMismatch.selector);
        holder.claimRootDeferredRewards();
        vm.prank(ALICE);
        holder.withdraw();
        assertEq(npm.ownerOf(id), ALICE);
        assertEq(MANAGER.rootDeferredRewards(address(holder)), 9e18);
    }

    function test_BatchDeferredRewardsRemainClaimableAfterWithdrawal() public {
        (, PoolPeachPosition holder) = _create(ALICE, false, true);
        address gauge = POOL.gauge();
        uint256 batch = MANAGER.currentDeferredBatch(gauge);
        stdstore.target(address(MANAGER)).sig("currentDeferredBatch(address)").with_key(gauge).checked_write(batch + 1);
        stdstore.target(address(MANAGER))
            .sig("deferredClaims(address,uint256,address)")
            .with_key(gauge)
            .with_key(batch)
            .with_key(address(holder))
            .checked_write(5e18);
        uint256 reserves = MANAGER.reservedRewards() + 5e18;
        stdstore.target(address(MANAGER)).sig("reservedRewards()").checked_write(reserves);
        deal(address(MANAGER.aeroToken()), address(MANAGER), reserves);
        vm.prank(ALICE);
        holder.withdraw();
        uint256 beforeBalance = MANAGER.aeroToken().balanceOf(ALICE);
        vm.prank(ALICE);
        assertEq(holder.claimDeferredRewards(gauge, batch), 5e18);
        assertEq(MANAGER.aeroToken().balanceOf(ALICE), beforeBalance + 5e18);
    }

    function test_ResidualTokensCannotCrossBetweenHoldersAndSurviveClosure() public {
        (, PoolPeachPosition aliceHolder) = _create(ALICE, false, true);
        (, PoolPeachPosition bobHolder) = _create(BOB, false, true);
        IERC20 asset = IERC20(POOL.token1());
        deal(address(asset), address(aliceHolder), 123e6);
        deal(address(asset), address(bobHolder), 456e6);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = asset;
        vm.prank(BOB);
        vm.expectRevert(PoolPeachPosition.Unauthorized.selector);
        aliceHolder.claimTokens(tokens);
        vm.prank(ALICE);
        aliceHolder.withdraw();
        uint256 beforeBalance = asset.balanceOf(ALICE);
        vm.prank(ALICE);
        aliceHolder.claimTokens(tokens);
        assertEq(asset.balanceOf(ALICE), beforeBalance + 123e6);
        assertEq(asset.balanceOf(address(bobHolder)), 456e6);
    }

    function test_NoBorrowOrGenericCallEntrypoint() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        vm.prank(ALICE);
        (bool ok,) = address(holder).call(abi.encodeWithSignature("borrow(uint256,uint256)", id, 1e6));
        assertFalse(ok);
        assertEq(VAULT.loans(id), 0);
        vm.prank(ALICE);
        (ok,) = address(holder)
            .call(
                abi.encodeWithSignature(
                    "execute(address,bytes)", address(VAULT), abi.encodeCall(V3Vault.borrow, (id, 1e6))
                )
            );
        assertFalse(ok);
    }

    function test_NativeFundingNeedsNoWethApproval() public {
        V3Utils.SwapAndMintParams memory p = _params();
        AutoExit.PositionConfig memory c = _config(true);
        vm.prank(ALICE);
        p.token0.approve(address(factory), 0);
        uint256 wethBefore = p.token0.balanceOf(ALICE);
        vm.deal(ALICE, p.amount0);
        vm.prank(ALICE);
        (uint256 id,) = factory.create{value: p.amount0}(p, c, false);
        assertTrue(factory.activeHolder(id) != address(0));
        assertGe(p.token0.balanceOf(ALICE), wethBefore, "WETH refund must not consume the user's existing WETH");
        assertEq(address(factory).balance, 0);
    }

    function test_EthOnlyOneSidedCreationNeedsNoTokenApprovals() public {
        V3Utils.SwapAndMintParams memory p = _params();
        AutoExit.PositionConfig memory c = _config(true);
        int24 spacing = POOL.tickSpacing();
        p.tickLower = (tick / spacing) * spacing + 10 * spacing;
        p.tickUpper = p.tickLower + 10 * spacing;
        p.amount1 = 0;
        vm.startPrank(ALICE);
        p.token0.approve(address(factory), 0);
        p.token1.approve(address(factory), 0);
        vm.stopPrank();
        vm.deal(ALICE, p.amount0);
        vm.prank(ALICE);
        (uint256 id, PoolPeachPosition holder) = factory.create{value: p.amount0}(p, c, false);
        assertEq(factory.activeHolder(id), address(holder));
        assertEq(RANGE.stakingConsent(id, address(VAULT)), address(holder));
        assertTrue(holder.autoExitEnabled());
    }

    function test_ExcessNativeValueRejected() public {
        V3Utils.SwapAndMintParams memory p = _params();
        AutoExit.PositionConfig memory c = _config(true);
        vm.deal(ALICE, p.amount0 + 1);
        vm.prank(ALICE);
        vm.expectRevert(PoolPeachFactory.InvalidMint.selector);
        factory.create{value: p.amount0 + 1}(p, c, false);
    }

    function test_UserCanPauseExitWithoutRemovingPosition() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        vm.prank(BOB);
        vm.expectRevert(PoolPeachPosition.Unauthorized.selector);
        holder.setAutoExitEnabled(false);
        vm.prank(ALICE);
        holder.setAutoExitEnabled(false);
        vm.expectRevert(PoolPeachPosition.InvalidState.selector);
        _execute(id);
        assertEq(factory.activeHolder(id), address(holder));
        vm.prank(ALICE);
        holder.setAutoExitEnabled(true);
        _execute(id);
        assertEq(factory.activeHolder(id), address(0));
    }

    function test_OperatorCannotExceedSelectedFee() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        vm.prank(OPERATOR);
        vm.expectRevert(Constants.ExceedsMaxReward.selector);
        factory.executeExit(AutoExit.ExecuteParams(id, "", 0, 0, block.timestamp, 1));
        assertEq(factory.activeHolder(id), address(holder));
    }

    function test_WithdrawCallbackCannotReenterHolder() public {
        PoolPeachTestBeneficiary receiver = new PoolPeachTestBeneficiary();
        V3Utils.SwapAndMintParams memory p = _params();
        deal(address(p.token0), address(receiver), p.amount0);
        deal(address(p.token1), address(receiver), p.amount1);
        uint256 id = receiver.create(factory, p, _config(true));
        receiver.withdraw();
        assertTrue(receiver.reentryAttempted());
        assertFalse(receiver.reentrySucceeded());
        assertEq(npm.ownerOf(id), address(receiver));
        assertEq(factory.activeHolder(id), address(0));
    }

    function test_RejectingNFTDoesNotBlockAutoExitProceeds() public {
        PoolPeachTestBeneficiary receiver = new PoolPeachTestBeneficiary();
        V3Utils.SwapAndMintParams memory p = _params();
        deal(address(p.token0), address(receiver), p.amount0);
        deal(address(p.token1), address(receiver), p.amount1);
        uint256 id = receiver.create(factory, p, _config(true));
        receiver.setRejectNFT(true);
        uint256 before0 = p.token0.balanceOf(address(receiver));
        uint256 before1 = p.token1.balanceOf(address(receiver));
        _execute(id);
        assertEq(factory.activeHolder(id), address(0));
        assertEq(npm.ownerOf(id), address(receiver.holder()));
        assertGt(p.token0.balanceOf(address(receiver)), before0);
        assertGt(p.token1.balanceOf(address(receiver)), before1);
        vm.expectRevert(bytes("reject NFT"));
        receiver.claimNFT(address(receiver));
        assertEq(factory.activeHolder(id), address(0));
        assertEq(npm.ownerOf(id), address(receiver.holder()));
        receiver.setRejectNFT(false);
        receiver.claimNFT(address(receiver));
        assertEq(npm.ownerOf(id), address(receiver));
        assertTrue(receiver.reentryAttempted());
        assertFalse(receiver.reentrySucceeded());
    }

    function test_NonReceiverCanWithdrawPrincipalToAnotherRecipient() public {
        PoolPeachNonReceiverBeneficiary user = new PoolPeachNonReceiverBeneficiary();
        V3Utils.SwapAndMintParams memory p = _params();
        deal(address(p.token0), address(user), p.amount0);
        deal(address(p.token1), address(user), p.amount1);
        uint256 id = user.create(factory, p, _config(true));
        (,,,,,,, uint128 liquidityBefore,,,,) = npm.positions(id);
        assertGt(liquidityBefore, 0);
        user.withdrawTo(ALICE);
        assertEq(npm.ownerOf(id), ALICE);
        assertEq(factory.activeHolder(id), address(0));
        assertEq(user.holder().beneficiary(), address(user));
        (,,,,,,, uint128 liquidityAfter,,,,) = npm.positions(id);
        assertEq(uint256(liquidityAfter), uint256(liquidityBefore));
    }

    function test_NonReceiverGetsAutoExitProceedsAndCanRetrieveEmptyNFT() public {
        PoolPeachNonReceiverBeneficiary user = new PoolPeachNonReceiverBeneficiary();
        V3Utils.SwapAndMintParams memory p = _params();
        deal(address(p.token0), address(user), p.amount0);
        deal(address(p.token1), address(user), p.amount1);
        uint256 id = user.create(factory, p, _config(true));
        PoolPeachPosition holder = user.holder();
        uint256 before0 = p.token0.balanceOf(address(user));
        uint256 before1 = p.token1.balanceOf(address(user));
        _execute(id);
        assertEq(npm.ownerOf(id), address(holder));
        assertEq(factory.activeHolder(id), address(0));
        assertEq(uint256(holder.state()), uint256(PoolPeachPosition.State.Closed));
        (,,,,,,, uint128 liquidity,,,,) = npm.positions(id);
        assertEq(uint256(liquidity), 0);
        assertGt(p.token0.balanceOf(address(user)), before0);
        assertGt(p.token1.balanceOf(address(user)), before1);
        assertEq(npm.getApproved(id), address(0));
        (bool active,,,,,,,,) = EXIT.positionConfigs(id);
        assertFalse(active);
        vm.prank(OPERATOR);
        vm.expectRevert(PoolPeachPosition.Unauthorized.selector);
        holder.claimNFT(OPERATOR);
        user.claimNFT(ALICE);
        assertEq(npm.ownerOf(id), ALICE);
        assertEq(holder.beneficiary(), address(user));
        vm.expectRevert();
        user.claimNFT(BOB);
        assertEq(npm.ownerOf(id), ALICE);
    }

    function test_ManualRecipientFailureRollsBackAndBeneficiaryCanChooseAnother() public {
        PoolPeachTestBeneficiary receiver = new PoolPeachTestBeneficiary();
        V3Utils.SwapAndMintParams memory p = _params();
        deal(address(p.token0), address(receiver), p.amount0);
        deal(address(p.token1), address(receiver), p.amount1);
        uint256 id = receiver.create(factory, p, _config(true));
        receiver.setRejectNFT(true);
        vm.expectRevert(bytes("reject NFT"));
        receiver.withdraw();
        assertEq(factory.activeHolder(id), address(receiver.holder()));
        assertEq(npm.ownerOf(id), address(VAULT));
        receiver.withdrawTo(ALICE);
        assertEq(npm.ownerOf(id), ALICE);
        assertEq(factory.activeHolder(id), address(0));
    }

    function test_CannotClaimNFTWhileActive() public {
        (uint256 id, PoolPeachPosition holder) = _create(ALICE, false, true);
        vm.prank(ALICE);
        vm.expectRevert(PoolPeachPosition.InvalidState.selector);
        holder.claimNFT(ALICE);
        assertEq(npm.ownerOf(id), address(VAULT));
        assertEq(factory.activeHolder(id), address(holder));
    }

    function test_ConstructorRejectsDifferentNpmBinding() public {
        vm.mockCall(
            address(VAULT), abi.encodeWithSignature("nonfungiblePositionManager()"), abi.encode(address(0x1234))
        );
        vm.expectRevert(PoolPeachFactory.InvalidBinding.selector);
        new PoolPeachFactory(UTILS, VAULT, RANGE, EXIT);
    }

    function test_NativeMintRefundWorksForBeneficiaryRejectingEther() public {
        _checkNativeMintRefund(1 ether, true);
    }

    function test_NativeMintAlsoReturnsUnusedNonNativeToken() public {
        _checkNativeMintRefund(0.001 ether, false);
    }

    function _checkNativeMintRefund(uint256 nativeAmount, bool expectWethExcess) internal {
        PoolPeachTestBeneficiary receiver = new PoolPeachTestBeneficiary();
        V3Utils.SwapAndMintParams memory p = _params();
        p.amount0 = nativeAmount;
        deal(address(p.token1), address(receiver), p.amount1);
        vm.deal(address(this), nativeAmount + 1);
        // It can accept ETH through create(), but has no payable receive/fallback for an empty-calldata refund.
        (bool receivesEther,) = address(receiver).call{value: 1}("");
        assertFalse(receivesEther);
        vm.recordLogs();
        uint256 id = receiver.create{value: nativeAmount}(factory, p, _config(true));
        PoolPeachLogReader.Log[] memory logs = PoolPeachLogReader(address(vm)).getRecordedLogs();
        bool found;
        uint256 used0;
        uint256 used1;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(UTILS)
                    && logs[i].topics[0] == keccak256("SwapAndMint(uint256,uint128,uint256,uint256)")
                    && uint256(logs[i].topics[1]) == id
            ) {
                (, used0, used1) = abi.decode(logs[i].data, (uint128, uint256, uint256));
                found = true;
            }
        }
        assertTrue(found);
        if (expectWethExcess) assertGt(p.amount0 - used0, 0, "exercise an actual native refund");
        else assertGt(p.amount1 - used1, 0, "exercise an actual ERC20 refund");
        assertEq(p.token0.balanceOf(address(receiver)), p.amount0 - used0);
        assertEq(p.token1.balanceOf(address(receiver)), p.amount1 - used1);
        PoolPeachPosition holder = receiver.holder();
        assertEq(factory.activeHolder(id), address(holder));
        assertEq(address(receiver).balance, 0);
        assertEq(address(holder).balance, 0);
        assertEq(p.token0.balanceOf(address(holder)), 0);
        assertEq(p.token1.balanceOf(address(holder)), 0);
        assertEq(p.token0.balanceOf(address(factory)), 0);
        assertEq(p.token1.balanceOf(address(factory)), 0);
    }
}
