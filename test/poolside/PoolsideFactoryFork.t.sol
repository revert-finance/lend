// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/poolside/PoolsideFactory.sol";
import "../../src/V3Oracle.sol";
import "../../src/interfaces/aerodrome/IAerodromeSlipstreamPool.sol";

// The repository's pinned forge-std predates the emitter field in Foundry's log cheatcode.
interface PoolsideLogReader {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
    function getRecordedLogs() external returns (Log[] memory);
}

contract PoolsideTestBeneficiary is IERC721Receiver {
    PoolsidePosition public holder;
    bool public rejectNFT;
    bool public reentrySucceeded;
    bool public reentryAttempted;

    function create(PoolsideFactory factory, V3Utils.SwapAndMintParams calldata p, AutoExit.PositionConfig calldata c)
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
        (reentrySucceeded,) = address(holder).call(abi.encodeCall(PoolsidePosition.withdraw, ()));
        return IERC721Receiver.onERC721Received.selector;
    }
}

// Deliberately has no ERC721 receiver hook and no upgrade path.
contract PoolsideNonReceiverBeneficiary {
    PoolsidePosition public holder;

    function create(PoolsideFactory factory, V3Utils.SwapAndMintParams calldata p, AutoExit.PositionConfig calldata c)
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

    function withdrawToAsset(V3Utils.Instructions calldata instructions, uint256 minAssets) external returns (uint256) {
        return holder.withdrawToAsset(instructions, minAssets);
    }

    function claimNFT(address recipient) external {
        holder.claimNFT(recipient);
    }
}

/// @dev Actual deployed Aero dependencies; only the proposed factory/holders are new.
/// BASE_RPC_URL must support historical state. No broadcast or signing occurs.
contract PoolsideFactoryForkTest is Test {
    using stdStorage for StdStorage;
    V3Utils constant UTILS = V3Utils(payable(0xF3B5c0689df879Db47Fd23590700910e7a99A068));
    V3Vault constant VAULT = V3Vault(0x39125A0476D44C9EEC1F4206E9e8B1e88b4Aa730);
    GaugeManager constant MANAGER = GaugeManager(payable(0x36F20A7859E25fC9102F761aCBfbD9AfE78924e6));
    AutoRangeAndCompound constant RANGE = AutoRangeAndCompound(payable(0x5c94a69fFDC3Fcb2c3d6e08Ce033297Fb92aE800));
    AutoExit constant EXIT = AutoExit(payable(0x9b23ba84C0B33c608db6a1c34Fc37BaA1F1A2C65));
    IAerodromeSlipstreamPool constant POOL = IAerodromeSlipstreamPool(0x4A7af46bC8aBc00048c6c7920a1488DAF568366c);
    address constant OPERATOR = 0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    INonfungiblePositionManager npm;
    PoolsideFactory factory;
    int24 tick;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 53255803);
        factory = new PoolsideFactory(UTILS, VAULT, RANGE, EXIT);
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

    function _create(address user, bool stake, bool triggered) internal returns (uint256 id, PoolsidePosition holder) {
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
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
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

    function test_SimpleFeeSelectedForStakedAndUnstakedCreation() public {
        for (uint256 i; i < 2; ++i) {
            (uint256 id, PoolsidePosition holder) = _create(ALICE, i == 1, false);
            assertEq(uint256(RANGE.compoundModes(id)), uint256(AutoRangeAndCompound.CompoundMode.Simple));
            assertEq(RANGE.compoundRewardX64(id), uint64((uint256(1) << 64) / 10));
            assertEq(MANAGER.compoundModeSource(), address(RANGE));
            (
                ,,
                int32 lowerDelta,
                int32 upperDelta,
                uint64 slippage0,
                uint64 slippage1,
                bool onlyFees,
                bool autoCompound,,,,
            ) = RANGE.positionConfigs(id);
            assertEq(int256(lowerDelta), 0);
            assertEq(int256(upperDelta), 0);
            assertEq(slippage0, uint64((uint256(1) << 64) / 100));
            assertEq(slippage1, slippage0);
            assertTrue(onlyFees);
            assertTrue(autoCompound);
            vm.startPrank(ALICE);
            holder.setStakingManagement(false);
            holder.setStakingManagement(true);
            vm.stopPrank();
            assertEq(RANGE.compoundRewardX64(id), RANGE.simpleRewardX64());
        }
    }

    function test_BeneficiaryAndOperatorCannotDowngradeHolderFee() public {
        (uint256 id,) = _create(ALICE, false, false);
        AutoRangeAndCompound.PositionConfig memory config;
        vm.prank(ALICE);
        vm.expectRevert(Constants.Unauthorized.selector);
        RANGE.configToken(id, address(VAULT), config, AutoRangeAndCompound.CompoundMode.Advanced);
        vm.prank(OPERATOR);
        vm.expectRevert(Constants.Unauthorized.selector);
        RANGE.configToken(id, address(VAULT), config, AutoRangeAndCompound.CompoundMode.Advanced);
        assertEq(RANGE.compoundRewardX64(id), RANGE.simpleRewardX64());
    }

    function _usdcExitInstructions(uint256 id) internal view returns (V3Utils.Instructions memory instructions) {
        (,, address t0, address t1,,,,,,,,) = npm.positions(id);
        address asset = VAULT.asset();
        instructions.deadline = block.timestamp;
        if (t0 != asset) instructions.swapData0 = _exitSwapData(t0, asset);
        if (t1 != asset) instructions.swapData1 = _exitSwapData(t1, asset);
    }

    function _exitSwapData(address input, address output) internal view returns (bytes memory) {
        bytes[] memory inputs = new bytes[](1);
        // Universal Router CONTRACT_BALANCE uses all input sent by V3Utils, including newly collected fees.
        inputs[0] = abi.encode(
            address(UTILS), uint256(1) << 255, uint256(1), abi.encodePacked(input, uint24(500), output), false
        );
        return
            abi.encode(
                UTILS.universalRouter(), abi.encode(Swapper.UniversalRouterData(hex"00", inputs, block.timestamp))
            );
    }

    function _assertClosedAndDisabled(uint256 id, PoolsidePosition holder) internal {
        assertEq(uint256(holder.state()), uint256(PoolsidePosition.State.Closed));
        assertEq(factory.activeHolder(id), address(0));
        assertEq(npm.ownerOf(id), address(holder));
        assertEq(npm.getApproved(id), address(0));
        (,,,,,,, uint128 liquidity,,,,) = npm.positions(id);
        assertEq(uint256(liquidity), 0);
        assertEq(RANGE.stakingConsent(id, address(VAULT)), address(0));
        (,,,,,,, bool autoCompound,,,,) = RANGE.positionConfigs(id);
        assertFalse(autoCompound);
        (bool exitActive,,,,,,,,) = EXIT.positionConfigs(id);
        assertFalse(exitActive);
    }

    function test_WithdrawToAssetSwapsAllLiquidityFromEitherCustody() public {
        for (uint256 i; i < 2; ++i) {
            (uint256 id, PoolsidePosition holder) = _create(ALICE, i == 1, false);
            V3Utils.Instructions memory instructions = _usdcExitInstructions(id);
            // These fields cannot turn the withdrawal into a partial withdrawal, reinvestment or redirected payout.
            instructions.whatToDo = V3Utils.WhatToDo.CHANGE_RANGE;
            instructions.targetToken = BOB;
            instructions.recipient = BOB;
            instructions.recipientNFT = BOB;
            instructions.unwrap = true;
            IERC20 asset = IERC20(VAULT.asset());
            uint256 before = asset.balanceOf(ALICE);
            uint256 bobBefore = asset.balanceOf(BOB);
            vm.prank(ALICE);
            uint256 received = holder.withdrawToAsset(instructions, 1e6);
            assertEq(asset.balanceOf(ALICE) - before, received);
            assertGt(received, 1e6);
            assertEq(asset.balanceOf(BOB), bobBefore);
            assertEq(IERC20(POOL.token0()).balanceOf(address(holder)), 0);
            _assertClosedAndDisabled(id, holder);
            vm.prank(ALICE);
            holder.claimNFT(ALICE);
            assertEq(npm.ownerOf(id), ALICE);
        }
    }

    function _partialExitSwap(bool refund, address swapRecipient) internal view returns (bytes memory) {
        bytes[] memory inputs = new bytes[](refund ? 2 : 1);
        inputs[0] = abi.encode(
            swapRecipient, uint256(1e12), uint256(1), abi.encodePacked(POOL.token0(), uint24(500), VAULT.asset()), false
        );
        if (refund) inputs[1] = abi.encode(POOL.token0(), address(UTILS), uint256(0));
        return abi.encode(
            UTILS.universalRouter(),
            abi.encode(Swapper.UniversalRouterData(refund ? bytes(hex"0004") : bytes(hex"00"), inputs, block.timestamp))
        );
    }

    function _assertRouterExitRejected(bool stake, bytes memory swapData) internal {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, stake, false);
        V3Utils.Instructions memory instructions = _usdcExitInstructions(id);
        instructions.swapData0 = swapData;
        address ownerBefore = npm.ownerOf(id);
        (,,,,,,, uint128 liquidityBefore,,,,) = npm.positions(id);
        IERC20 t0 = IERC20(POOL.token0());
        IERC20 t1 = IERC20(POOL.token1());
        uint256 router0 = t0.balanceOf(UTILS.universalRouter());
        uint256 router1 = t1.balanceOf(UTILS.universalRouter());
        uint256 aliceUsdc = t1.balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(PoolsidePosition.UnspentRouterInput.selector);
        holder.withdrawToAsset(instructions, 1e6);
        assertEq(uint256(holder.state()), uint256(PoolsidePosition.State.Active));
        assertEq(factory.activeHolder(id), address(holder));
        assertEq(npm.ownerOf(id), ownerBefore);
        (,,,,,,, uint128 liquidityAfter,,,,) = npm.positions(id);
        assertEq(uint256(liquidityAfter), uint256(liquidityBefore));
        assertEq(RANGE.stakingConsent(id, address(VAULT)), address(holder));
        assertTrue(VAULT.transformApprovals(address(holder), id, address(RANGE)));
        (,,,,,,, bool autoCompound,,,,) = RANGE.positionConfigs(id);
        assertTrue(autoCompound);
        (bool exitActive,,,,,,,,) = EXIT.positionConfigs(id);
        assertTrue(exitActive);
        assertEq(t0.balanceOf(UTILS.universalRouter()), router0);
        assertEq(t1.balanceOf(UTILS.universalRouter()), router1);
        assertEq(t1.balanceOf(ALICE), aliceUsdc);
    }

    function test_WithdrawToAssetRejectsEmptyRouterCommandsFromEitherCustody() public {
        bytes[] memory inputs = new bytes[](0);
        bytes memory data = abi.encode(
            UTILS.universalRouter(), abi.encode(Swapper.UniversalRouterData(hex"", inputs, block.timestamp))
        );
        _assertRouterExitRejected(false, data);
        _assertRouterExitRejected(true, data);
    }

    function test_WithdrawToAssetRejectsPartialSwapWithoutRefund() public {
        _assertRouterExitRejected(true, _partialExitSwap(false, address(UTILS)));
    }

    function test_WithdrawToAssetRejectsOtherPositionTokenLeftInRouter() public {
        // Refund WETH correctly, but leave the swapped USDC in the router instead of paying V3Utils.
        _assertRouterExitRejected(false, _partialExitSwap(true, UTILS.universalRouter()));
    }

    function test_WithdrawToAssetRefundsPartialSwapWithAndWithoutExistingRouterBalances() public {
        for (uint256 i; i < 2; ++i) {
            IERC20 t0 = IERC20(POOL.token0());
            IERC20 t1 = IERC20(POOL.token1());
            if (i == 1) {
                deal(address(t0), UTILS.universalRouter(), 7);
                deal(address(t1), UTILS.universalRouter(), 123e6);
            }
            uint256 routerUsdc = t1.balanceOf(UTILS.universalRouter());
            (uint256 id, PoolsidePosition holder) = _create(ALICE, i == 1, false);
            V3Utils.Instructions memory instructions = _usdcExitInstructions(id);
            instructions.swapData0 = _partialExitSwap(true, address(UTILS));
            uint256 beforeWeth = t0.balanceOf(ALICE);
            uint256 beforeUsdc = t1.balanceOf(ALICE);
            vm.prank(ALICE);
            uint256 received = holder.withdrawToAsset(instructions, 1e6);
            assertGt(received, 1e6);
            assertEq(t1.balanceOf(ALICE) - beforeUsdc, received);
            assertGt(t0.balanceOf(ALICE), beforeWeth);
            assertEq(t0.balanceOf(address(holder)), 0);
            assertEq(t1.balanceOf(address(holder)), 0);
            assertEq(t0.balanceOf(UTILS.universalRouter()), 0);
            assertEq(t1.balanceOf(UTILS.universalRouter()), routerUsdc);
            _assertClosedAndDisabled(id, holder);
        }
    }

    function test_WithdrawToAssetFailureRestoresStakedPosition() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, true, false);
        V3Utils.Instructions memory instructions = _usdcExitInstructions(id);
        address gauge = MANAGER.tokenIdToGauge(id);
        (,,,,,,, uint128 liquidityBefore,,,,) = npm.positions(id);
        IERC20 asset = IERC20(VAULT.asset());
        // A pre-existing asset balance cannot satisfy the minimum-output check.
        deal(address(asset), address(holder), 1_000_000e6);
        vm.prank(ALICE);
        vm.expectRevert(PoolsidePosition.InsufficientAssets.selector);
        holder.withdrawToAsset(instructions, 500_000e6);
        assertEq(factory.activeHolder(id), address(holder));
        assertEq(npm.ownerOf(id), gauge);
        assertEq(MANAGER.tokenIdToGauge(id), gauge);
        (,,,,,,, uint128 liquidityAfter,,,,) = npm.positions(id);
        assertEq(uint256(liquidityAfter), uint256(liquidityBefore));
        assertEq(asset.balanceOf(address(holder)), 1_000_000e6);
        assertEq(RANGE.stakingConsent(id, address(VAULT)), address(holder));
        assertTrue(VAULT.transformApprovals(address(holder), id, address(RANGE)));
        (,,,,,,, bool autoCompound,,,,) = RANGE.positionConfigs(id);
        assertTrue(autoCompound);
        (bool exitActive,,,,,,,,) = EXIT.positionConfigs(id);
        assertTrue(exitActive);
    }

    function test_WithdrawToAssetRejectsNonBeneficiaryAndRepeatExit() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, false);
        V3Utils.Instructions memory instructions = _usdcExitInstructions(id);
        vm.prank(BOB);
        vm.expectRevert(PoolsidePosition.Unauthorized.selector);
        holder.withdrawToAsset(instructions, 1);
        vm.prank(OPERATOR);
        vm.expectRevert(PoolsidePosition.Unauthorized.selector);
        holder.withdrawToAsset(instructions, 1);
        vm.startPrank(ALICE);
        holder.withdrawToAsset(instructions, 1);
        vm.expectRevert(PoolsidePosition.InvalidState.selector);
        holder.withdrawToAsset(instructions, 1);
        vm.stopPrank();
    }

    function test_WithdrawToAssetRejectsExpiredDeadlineAndBadSwap() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, false);
        V3Utils.Instructions memory instructions = _usdcExitInstructions(id);
        instructions.deadline = block.timestamp - 1;
        vm.startPrank(ALICE);
        vm.expectRevert();
        holder.withdrawToAsset(instructions, 1);
        instructions.deadline = block.timestamp;
        instructions.swapData0 = hex"deadbeef";
        vm.expectRevert();
        holder.withdrawToAsset(instructions, 1);
        vm.stopPrank();
        assertEq(factory.activeHolder(id), address(holder));
        assertEq(npm.ownerOf(id), address(VAULT));
    }

    function test_NonReceiverBeneficiaryCanExitToUsdcWithoutReceivingNft() public {
        PoolsideNonReceiverBeneficiary user = new PoolsideNonReceiverBeneficiary();
        V3Utils.SwapAndMintParams memory p = _params();
        deal(address(p.token0), address(user), p.amount0);
        deal(address(p.token1), address(user), p.amount1);
        uint256 id = user.create(factory, p, _config(false));
        IERC20 asset = IERC20(VAULT.asset());
        uint256 before = asset.balanceOf(address(user));
        uint256 received = user.withdrawToAsset(_usdcExitInstructions(id), 1e6);
        assertEq(asset.balanceOf(address(user)) - before, received);
        _assertClosedAndDisabled(id, user.holder());
        user.claimNFT(ALICE);
        assertEq(npm.ownerOf(id), ALICE);
    }

    function test_WithdrawalClearsCompoundingDespiteRecipientsGlobalApproval() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, false);
        vm.startPrank(ALICE);
        npm.setApprovalForAll(address(RANGE), true);
        holder.withdraw();
        vm.stopPrank();
        AutoRangeAndCompound.AutoCompoundParams memory params;
        params.tokenId = id;
        params.deadline = block.timestamp;
        vm.prank(OPERATOR);
        vm.expectRevert(Constants.NotConfigured.selector);
        RANGE.autoCompound(params);
    }

    function test_AssetExitReturnsAvailableBalancesAndPreservesDeferredRewards() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, false);
        _rootLiability(holder, 7e18, true);
        IERC20 asset = IERC20(VAULT.asset());
        IERC20 input = IERC20(POOL.token0());
        IERC20 reward = MANAGER.aeroToken();
        deal(address(asset), address(holder), 123e6);
        deal(address(reward), address(holder), 3e18);
        vm.deal(address(holder), 1 ether);
        uint256 beforeAsset = asset.balanceOf(ALICE);
        uint256 beforeToken = input.balanceOf(ALICE);
        uint256 beforeReward = reward.balanceOf(ALICE);
        V3Utils.Instructions memory instructions = _usdcExitInstructions(id);
        // Unspent quote input is returned in kind, alongside pre-existing balances and delivered rewards.
        instructions.swapData0 = "";
        vm.prank(ALICE);
        uint256 received = holder.withdrawToAsset(instructions, 1);
        assertEq(asset.balanceOf(ALICE) - beforeAsset, received);
        assertGt(received, 123e6);
        assertGt(input.balanceOf(ALICE) - beforeToken, 1 ether);
        assertEq(reward.balanceOf(ALICE) - beforeReward, 3e18);
        assertEq(asset.balanceOf(address(holder)), 0);
        assertEq(input.balanceOf(address(holder)), 0);
        assertEq(reward.balanceOf(address(holder)), 0);
        assertEq(address(holder).balance, 0);
        vm.prank(ALICE);
        assertEq(holder.claimRootDeferredRewards(), 7e18);
    }

    function test_AutoExitAlsoClearsRecurringCompounding() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
        _execute(id);
        _assertClosedAndDisabled(id, holder);
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
        (uint256 id, PoolsidePosition holder) = _create(ALICE, true, true);
        _clearPoolTokenOracleConfig();
        vm.prank(ALICE);
        holder.withdraw();
        assertEq(npm.ownerOf(id), ALICE);
        assertEq(factory.activeHolder(id), address(0));
    }

    function test_CreateCanStakeInSameTransaction() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, true, true);
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
        (uint256 id, PoolsidePosition holder) = factory.create(p, c, false);
        assertEq(holder.beneficiary(), ALICE);
        assertEq(VAULT.ownerOf(id), address(holder));
        assertEq(p.token0.balanceOf(BOB), bob0);
    }

    function test_ManualWithdrawalClearsRegistryConsentApprovalAndExitRule() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, true, false);
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
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
        uint256 before0 = IERC20(POOL.token0()).balanceOf(ALICE);
        uint256 before1 = IERC20(POOL.token1()).balanceOf(ALICE);
        _execute(id);
        assertEq(factory.activeHolder(id), address(0));
        assertEq(npm.ownerOf(id), address(holder));
        assertEq(uint256(holder.state()), uint256(PoolsidePosition.State.Closed));
        assertGt(IERC20(POOL.token0()).balanceOf(ALICE), before0);
        assertGt(IERC20(POOL.token1()).balanceOf(ALICE), before1);
        assertEq(address(holder).balance, 0);
    }

    function test_AutoExitFromGaugeAfterPenaltyWindow() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, true, true);
        vm.roll(MANAGER.penaltyWindowEnd(id));
        _execute(id);
        assertEq(npm.ownerOf(id), address(holder));
        assertEq(factory.activeHolder(id), address(0));
        assertEq(MANAGER.tokenIdToGauge(id), address(0));
    }

    function test_AutoExitRespectsPenaltyWindowButManualWithdrawalRemainsPossible() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, true, true);
        assertGt(MANAGER.penaltyWindowEnd(id), block.number);
        vm.expectRevert(PoolsidePosition.InsidePenaltyWindow.selector);
        _execute(id);
        assertEq(factory.activeHolder(id), address(holder));
        vm.prank(ALICE);
        holder.withdraw();
        assertEq(npm.ownerOf(id), ALICE);
    }

    function test_UnmetTriggerRollsBackUnstakingAndAllPermissions() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, true, false);
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
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
        vm.prank(OPERATOR);
        vm.expectRevert();
        factory.executeExit(AutoExit.ExecuteParams(id, "", type(uint256).max, type(uint256).max, block.timestamp, 0));
        assertEq(factory.activeHolder(id), address(holder));
        assertEq(npm.ownerOf(id), address(VAULT));
    }

    function test_UnknownUserCannotWithdrawOrChangeConsentOrClaim() public {
        (, PoolsidePosition holder) = _create(ALICE, false, true);
        vm.startPrank(BOB);
        vm.expectRevert(PoolsidePosition.Unauthorized.selector);
        holder.withdraw();
        vm.expectRevert(PoolsidePosition.Unauthorized.selector);
        holder.withdrawTo(BOB);
        vm.expectRevert(PoolsidePosition.Unauthorized.selector);
        holder.claimNFT(BOB);
        vm.expectRevert(PoolsidePosition.Unauthorized.selector);
        holder.setStakingManagement(false);
        vm.expectRevert(PoolsidePosition.Unauthorized.selector);
        holder.claimRootDeferredRewards();
        vm.expectRevert(PoolsidePosition.Unauthorized.selector);
        holder.claimNative();
        vm.stopPrank();
    }

    function test_OnlyFactoryCanPrepareOrFinishExit() public {
        (, PoolsidePosition holder) = _create(ALICE, false, true);
        vm.startPrank(OPERATOR);
        vm.expectRevert(PoolsidePosition.Unauthorized.selector);
        holder.prepareAutoExit();
        vm.expectRevert(PoolsidePosition.Unauthorized.selector);
        holder.finishAutoExit();
        vm.stopPrank();
    }

    function test_UnprivilegedCallerCannotTriggerExitOrForgeRegistryRemoval() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
        vm.prank(BOB);
        vm.expectRevert(PoolsideFactory.Unauthorized.selector);
        factory.executeExit(AutoExit.ExecuteParams(id, "", 0, 0, block.timestamp, 0));
        vm.prank(BOB);
        vm.expectRevert(PoolsideFactory.Unauthorized.selector);
        factory.positionClosed(id);
        assertEq(factory.activeHolder(id), address(holder));
    }

    function test_RevokedFactoryOperatorCannotExecuteAndDoesNotBlockManualWithdrawal() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
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
        vm.expectRevert(PoolsideFactory.InvalidBinding.selector);
        factory.create(p, c, false);
        assertEq(IERC20(POOL.token0()).balanceOf(ALICE), balance);
    }

    function test_CreateRejectsThirdTokenFunding() public {
        V3Utils.SwapAndMintParams memory p = _params();
        p.swapSourceToken = IERC20(address(0x1234));
        AutoExit.PositionConfig memory c = _config(true);
        vm.prank(ALICE);
        vm.expectRevert(PoolsideFactory.InvalidMint.selector);
        factory.create(p, c, false);
    }

    function test_CreateRejectsDisabledExitConfiguration() public {
        V3Utils.SwapAndMintParams memory p = _params();
        AutoExit.PositionConfig memory c;
        vm.prank(ALICE);
        vm.expectRevert(PoolsideFactory.InvalidMint.selector);
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
        vm.expectRevert(PoolsideFactory.UnsupportedToken.selector);
        factory.create(p, c, false);
    }

    function test_ArbitraryNFTReceiptAndRepeatInitializationRejected() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
        vm.expectRevert(PoolsidePosition.InvalidNFT.selector);
        holder.onERC721Received(address(UTILS), address(UTILS), id + 1, "");
        AutoExit.PositionConfig memory c = _config(true);
        vm.prank(address(factory));
        vm.expectRevert(PoolsidePosition.InvalidState.selector);
        holder.initialize(id, c, false);
    }

    function test_ClosedPositionCannotBeReactivatedOrRedeposited() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
        vm.prank(ALICE);
        holder.withdraw();
        vm.startPrank(ALICE);
        vm.expectRevert(PoolsidePosition.InvalidState.selector);
        holder.setStakingManagement(true);
        vm.expectRevert(PoolsidePosition.InvalidState.selector);
        holder.withdraw();
        vm.expectRevert(PoolsidePosition.InvalidNFT.selector);
        npm.safeTransferFrom(ALICE, address(holder), id);
        vm.stopPrank();
        assertEq(factory.activeHolder(id), address(0));
    }

    function test_OwnerCanDisableAndReenableStaking() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
        vm.startPrank(ALICE);
        holder.setStakingManagement(false);
        assertEq(RANGE.stakingConsent(id, address(VAULT)), address(0));
        holder.setStakingManagement(true);
        assertEq(RANGE.stakingConsent(id, address(VAULT)), address(holder));
        vm.stopPrank();
    }

    function test_ActualKeeperCanStakeWithGrantedConsent() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
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
        assertEq(RANGE.compoundRewardX64(id), RANGE.simpleRewardX64());
    }

    function test_RecurringCompoundKeepsRangeAndSimpleMode() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, false);
        (,,,,, int24 lowerBefore, int24 upperBefore,,,,,) = npm.positions(id);
        // Exercise the ordinary compound entrypoint without a custody change.
        AutoRangeAndCompound.AutoCompoundParams memory p;
        p.tokenId = id;
        p.deadline = block.timestamp;
        vm.prank(OPERATOR);
        RANGE.autoCompoundWithVault(p, address(VAULT));
        (,,,,, int24 lowerAfter, int24 upperAfter,,,,,) = npm.positions(id);
        assertEq(int256(lowerAfter), int256(lowerBefore));
        assertEq(int256(upperAfter), int256(upperBefore));
        assertEq(factory.activeHolder(id), address(holder));
        assertEq(RANGE.compoundRewardX64(id), RANGE.simpleRewardX64());
    }

    function test_DisabledConsentBlocksActualKeeperStaking() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
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

    function _rootLiability(PoolsidePosition holder, uint256 amount, bool funded) internal {
        stdstore.target(address(MANAGER))
            .sig("rootDeferredRewards(address)")
            .with_key(address(holder))
            .checked_write(amount);
        uint256 reserves = MANAGER.reservedRewards() + amount;
        stdstore.target(address(MANAGER)).sig("reservedRewards()").checked_write(reserves);
        deal(address(MANAGER.aeroToken()), address(MANAGER), funded ? reserves : 0);
    }

    function test_RootRewardsRemainClaimableAfterWithdrawalAndAreIsolated() public {
        (, PoolsidePosition aliceHolder) = _create(ALICE, false, true);
        (, PoolsidePosition bobHolder) = _create(BOB, false, true);
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
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
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
        (, PoolsidePosition holder) = _create(ALICE, false, true);
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
        (, PoolsidePosition aliceHolder) = _create(ALICE, false, true);
        (, PoolsidePosition bobHolder) = _create(BOB, false, true);
        IERC20 asset = IERC20(POOL.token1());
        deal(address(asset), address(aliceHolder), 123e6);
        deal(address(asset), address(bobHolder), 456e6);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = asset;
        vm.prank(BOB);
        vm.expectRevert(PoolsidePosition.Unauthorized.selector);
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
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
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
        (uint256 id, PoolsidePosition holder) = factory.create{value: p.amount0}(p, c, false);
        assertEq(factory.activeHolder(id), address(holder));
        assertEq(RANGE.stakingConsent(id, address(VAULT)), address(holder));
        assertTrue(holder.autoExitEnabled());
    }

    function test_ExcessNativeValueRejected() public {
        V3Utils.SwapAndMintParams memory p = _params();
        AutoExit.PositionConfig memory c = _config(true);
        vm.deal(ALICE, p.amount0 + 1);
        vm.prank(ALICE);
        vm.expectRevert(PoolsideFactory.InvalidMint.selector);
        factory.create{value: p.amount0 + 1}(p, c, false);
    }

    function test_UserCanPauseExitWithoutRemovingPosition() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
        vm.prank(BOB);
        vm.expectRevert(PoolsidePosition.Unauthorized.selector);
        holder.setAutoExitEnabled(false);
        vm.prank(ALICE);
        holder.setAutoExitEnabled(false);
        vm.expectRevert(PoolsidePosition.InvalidState.selector);
        _execute(id);
        assertEq(factory.activeHolder(id), address(holder));
        vm.prank(ALICE);
        holder.setAutoExitEnabled(true);
        _execute(id);
        assertEq(factory.activeHolder(id), address(0));
    }

    function test_OperatorCannotExceedSelectedFee() public {
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
        vm.prank(OPERATOR);
        vm.expectRevert(Constants.ExceedsMaxReward.selector);
        factory.executeExit(AutoExit.ExecuteParams(id, "", 0, 0, block.timestamp, 1));
        assertEq(factory.activeHolder(id), address(holder));
    }

    function test_WithdrawCallbackCannotReenterHolder() public {
        PoolsideTestBeneficiary receiver = new PoolsideTestBeneficiary();
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
        PoolsideTestBeneficiary receiver = new PoolsideTestBeneficiary();
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
        PoolsideNonReceiverBeneficiary user = new PoolsideNonReceiverBeneficiary();
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
        PoolsideNonReceiverBeneficiary user = new PoolsideNonReceiverBeneficiary();
        V3Utils.SwapAndMintParams memory p = _params();
        deal(address(p.token0), address(user), p.amount0);
        deal(address(p.token1), address(user), p.amount1);
        uint256 id = user.create(factory, p, _config(true));
        PoolsidePosition holder = user.holder();
        uint256 before0 = p.token0.balanceOf(address(user));
        uint256 before1 = p.token1.balanceOf(address(user));
        _execute(id);
        assertEq(npm.ownerOf(id), address(holder));
        assertEq(factory.activeHolder(id), address(0));
        assertEq(uint256(holder.state()), uint256(PoolsidePosition.State.Closed));
        (,,,,,,, uint128 liquidity,,,,) = npm.positions(id);
        assertEq(uint256(liquidity), 0);
        assertGt(p.token0.balanceOf(address(user)), before0);
        assertGt(p.token1.balanceOf(address(user)), before1);
        assertEq(npm.getApproved(id), address(0));
        (bool active,,,,,,,,) = EXIT.positionConfigs(id);
        assertFalse(active);
        vm.prank(OPERATOR);
        vm.expectRevert(PoolsidePosition.Unauthorized.selector);
        holder.claimNFT(OPERATOR);
        user.claimNFT(ALICE);
        assertEq(npm.ownerOf(id), ALICE);
        assertEq(holder.beneficiary(), address(user));
        vm.expectRevert();
        user.claimNFT(BOB);
        assertEq(npm.ownerOf(id), ALICE);
    }

    function test_ManualRecipientFailureRollsBackAndBeneficiaryCanChooseAnother() public {
        PoolsideTestBeneficiary receiver = new PoolsideTestBeneficiary();
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
        (uint256 id, PoolsidePosition holder) = _create(ALICE, false, true);
        vm.prank(ALICE);
        vm.expectRevert(PoolsidePosition.InvalidState.selector);
        holder.claimNFT(ALICE);
        assertEq(npm.ownerOf(id), address(VAULT));
        assertEq(factory.activeHolder(id), address(holder));
    }

    function test_ConstructorRejectsDifferentNpmBinding() public {
        vm.mockCall(
            address(VAULT), abi.encodeWithSignature("nonfungiblePositionManager()"), abi.encode(address(0x1234))
        );
        vm.expectRevert(PoolsideFactory.InvalidBinding.selector);
        new PoolsideFactory(UTILS, VAULT, RANGE, EXIT);
    }

    function test_NativeMintRefundWorksForBeneficiaryRejectingEther() public {
        _checkNativeMintRefund(1 ether, true);
    }

    function test_NativeMintAlsoReturnsUnusedNonNativeToken() public {
        _checkNativeMintRefund(0.001 ether, false);
    }

    function _checkNativeMintRefund(uint256 nativeAmount, bool expectWethExcess) internal {
        PoolsideTestBeneficiary receiver = new PoolsideTestBeneficiary();
        V3Utils.SwapAndMintParams memory p = _params();
        p.amount0 = nativeAmount;
        deal(address(p.token1), address(receiver), p.amount1);
        vm.deal(address(this), nativeAmount + 1);
        // It can accept ETH through create(), but has no payable receive/fallback for an empty-calldata refund.
        (bool receivesEther,) = address(receiver).call{value: 1}("");
        assertFalse(receivesEther);
        vm.recordLogs();
        uint256 id = receiver.create{value: nativeAmount}(factory, p, _config(true));
        PoolsideLogReader.Log[] memory logs = PoolsideLogReader(address(vm)).getRecordedLogs();
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
        PoolsidePosition holder = receiver.holder();
        assertEq(factory.activeHolder(id), address(holder));
        assertEq(address(receiver).balance, 0);
        assertEq(address(holder).balance, 0);
        assertEq(p.token0.balanceOf(address(holder)), 0);
        assertEq(p.token1.balanceOf(address(holder)), 0);
        assertEq(p.token0.balanceOf(address(factory)), 0);
        assertEq(p.token1.balanceOf(address(factory)), 0);
    }
}
