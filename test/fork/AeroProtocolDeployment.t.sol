// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../script/DeployAeroProtocol.s.sol";

interface IAeroForkClock {
    function getBlockTimestamp() external view returns (uint256);
    function getBlockNumber() external view returns (uint256);
}

interface IAeroRehearsalMint {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }
    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
}

/// @notice Exercises the actual deployment script and live Base dependencies. Requires BASE_RPC_URL.
/// @dev Synthetic actor balances only; production feeds, pools, NPM, gauges and root delivery run on the fork.
contract AeroProtocolDeploymentTest is Test {
    address constant DEPLOYER = 0x83681C14770b44361e21Faf91D8325423365eA5C;
    address constant SAFE = 0x45B220860A39f717Dc7daFF4fc08B69CB89d1cc9;
    address constant OPERATOR = 0xBb1A1a2773a799D83078ae4d59d9F4B2B6aC50fF;
    address constant WITHDRAWER = 0x5663ba1B0B1d9b8559CFE049b33fe3B194852e82;
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant ALICE = address(0xA11CE);
    address constant LENDER = address(0x1EAD);
    uint256 mintScale = 1;
    DeployAeroProtocol script;
    DeployAeroProtocol.Deployment d;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 53136369);
        vm.setEnv("AERO_DEPLOYER", vm.toString(DEPLOYER));
        script = new DeployAeroProtocol();
        d = script.run();
    }

    function _owned() internal view returns (address[] memory a) {
        a = new address[](7);
        a[0] = address(d.oracle);
        a[1] = address(d.vault);
        a[2] = address(d.gaugeManager);
        a[3] = address(d.v3Utils);
        a[4] = address(d.leverageTransformer);
        a[5] = address(d.autoRange);
        a[6] = address(d.autoExit);
    }

    function _activate() internal {
        address[] memory a = _owned();
        vm.startPrank(SAFE);
        for (uint256 i; i < a.length; ++i) {
            Ownable2Step(a[i]).acceptOwnership();
        }
        d.vault.setLimits(1e6, 1_000_000e6, 1_000_000e6, 100_000e6, 100_000e6);
        vm.stopPrank();
        deal(USDC, LENDER, 10_000e6);
        vm.startPrank(LENDER);
        IERC20(USDC).approve(address(d.vault), type(uint256).max);
        d.vault.deposit(10_000e6, LENDER);
        vm.stopPrank();
    }

    function _mint(address poolAddress) internal returns (uint256 id) {
        IAerodromeSlipstreamPool pool = IAerodromeSlipstreamPool(poolAddress);
        address t0 = pool.token0();
        address t1 = pool.token1();
        uint256 a0 = _amount(t0);
        uint256 a1 = _amount(t1);
        deal(t0, ALICE, a0);
        deal(t1, ALICE, a1);
        vm.startPrank(ALICE);
        IERC20(t0).approve(NPM, a0);
        IERC20(t1).approve(NPM, a1);
        (, int24 tick,,,,) = pool.slot0();
        int24 spacing = pool.tickSpacing();
        int24 center = tick / spacing * spacing;
        int24 width = (1000 / spacing + 1) * spacing;
        (id,,,) = IAeroRehearsalMint(NPM)
            .mint(
                IAeroRehearsalMint.MintParams(
                    t0, t1, spacing, center - width, center + width, a0, a1, 0, 0, ALICE, block.timestamp, 0
                )
            );
        INonfungiblePositionManager(NPM).approve(address(d.vault), id);
        d.vault.create(id, ALICE);
        vm.stopPrank();
    }

    function _amount(address t) internal view returns (uint256) {
        if (t == USDC) return 1000e6 * mintScale;
        if (t == WETH) return 0.2 ether * mintScale;
        require(t == CBBTC, "unexpected collateral");
        return 500_000 * mintScale;
    }

    function testDeploymentBindingsOwnershipAndActivation() public {
        address[] memory a = _owned();
        for (uint256 i; i < a.length; ++i) {
            assertEq(Ownable2Step(a[i]).owner(), DEPLOYER);
            assertEq(Ownable2Step(a[i]).pendingOwner(), SAFE);
            assertLe(a[i].code.length, 24_576);
        }
        assertEq(d.irm.owner(), SAFE);
        assertEq(d.vault.globalDebtLimit(), 0);
        assertEq(address(d.vault.oracle()), address(d.oracle));
        assertEq(address(d.vault.interestRateModel()), address(d.irm));
        assertEq(d.gaugeManager.withdrawer(), WITHDRAWER);
        assertTrue(d.autoRange.operators(OPERATOR));
        assertTrue(d.autoExit.operators(OPERATOR));
        assertEq(d.autoRange.totalRewardX64(), 368_934_881_474_191_032);
        assertEq(d.autoRange.simpleRewardX64(), uint64(uint256(2 ** 64) / 10));
        assertEq(d.gaugeManager.compoundModeSource(), address(d.autoRange));
        assertTrue(d.vault.transformerAllowList(address(d.v3Utils)));
        assertTrue(d.vault.transformerAllowList(address(d.leverageTransformer)));
        assertTrue(d.vault.transformerAllowList(address(d.autoRange)));
        assertFalse(d.vault.transformerAllowList(address(d.autoExit)));
        assertTrue(d.v3Utils.vaults(address(d.vault)));
        assertTrue(d.leverageTransformer.vaults(address(d.vault)));
        assertTrue(d.autoRange.vaults(address(d.vault)));
        assertEq(d.vault.emergencyAdmin(), address(0));
        assertEq(d.oracle.emergencyAdmin(), address(0));
        assertGt(d.oracle.getTokenValue(WETH, 1 ether, USDC), 0);
        assertGt(d.oracle.getTokenValue(CBBTC, 1e8, USDC), 0);
        _activate();
        for (uint256 i; i < a.length; ++i) {
            assertEq(Ownable2Step(a[i]).owner(), SAFE);
        }
        vm.prank(DEPLOYER);
        vm.expectRevert();
        d.vault.setLimits(1, 1, 1, 1, 1);
    }

    function testAllSixPoolsBorrowStakeClaimRepayRemove() public {
        _activate();
        address[] memory pools = script.collateralPools();
        for (uint256 i; i < pools.length; ++i) {
            uint256 id = _mint(pools[i]);
            vm.startPrank(ALICE);
            d.vault.borrow(id, 10e6);
            d.vault.stakePosition(id);
            vm.stopPrank();
            assertEq(INonfungiblePositionManager(NPM).ownerOf(id), IAerodromeSlipstreamPool(pools[i]).gauge());
            // 60 seconds per iteration stays within the actual feed-age allowance.
            vm.warp(IAeroForkClock(address(vm)).getBlockTimestamp() + 60);
            vm.roll(IAeroForkClock(address(vm)).getBlockNumber() + 30);
            uint256 beforeReward = IERC20(AERO).balanceOf(ALICE);
            vm.startPrank(ALICE);
            uint256 paid = d.gaugeManager.claimRewards(id, ALICE);
            assertGt(paid, 0);
            assertEq(IERC20(AERO).balanceOf(ALICE) - beforeReward, paid);
            IERC20(USDC).approve(address(d.vault), type(uint256).max);
            d.vault.repay(id, type(uint256).max, false);
            d.vault.remove(id, ALICE, "");
            vm.stopPrank();
            assertEq(INonfungiblePositionManager(NPM).ownerOf(id), ALICE);
            assertEq(d.vault.loans(id), 0);
        }
        vm.startPrank(LENDER);
        assertGe(d.vault.redeem(d.vault.balanceOf(LENDER), LENDER, LENDER), 10_000e6);
        vm.stopPrank();
    }

    function testRewardsCompoundThroughAllThreeLiveRoutes() public {
        _activate();
        mintScale = 1000; // enough rewards to produce both token units, including 8-decimal cbBTC
        address[] memory pools = script.collateralPools();
        for (uint256 i; i < pools.length; i += 2) {
            uint256 id = _mint(pools[i]);
            vm.prank(ALICE);
            d.vault.stakePosition(id);
            vm.warp(IAeroForkClock(address(vm)).getBlockTimestamp() + 120);
            vm.roll(IAeroForkClock(address(vm)).getBlockNumber() + 60);
            uint256 end = d.gaugeManager.penaltyWindowEnd(id);
            if (end > IAeroForkClock(address(vm)).getBlockNumber()) vm.roll(end); // isolate block-based penalty from feed freshness
            (,,,,,,, uint128 beforeLiquidity,,,,) = INonfungiblePositionManager(NPM).positions(id);
            vm.prank(ALICE);
            (uint256 reward, uint256 added0, uint256 added1) =
                d.gaugeManager.compoundRewards(id, 1, 5000, block.timestamp);
            assertGt(reward, 0);
            assertGt(added0 + added1, 0);
            (,,,,,,, uint128 afterLiquidity,,,,) = INonfungiblePositionManager(NPM).positions(id);
            assertGt(afterLiquidity, beforeLiquidity);
            assertEq(INonfungiblePositionManager(NPM).ownerOf(id), IAerodromeSlipstreamPool(pools[i]).gauge());
        }
    }

    function testBorrowDisabledUntilActivation() public {
        uint256 id = _mint(script.collateralPools()[0]);
        deal(USDC, LENDER, 100e6);
        vm.startPrank(LENDER);
        IERC20(USDC).approve(address(d.vault), 100e6);
        d.vault.deposit(100e6, LENDER);
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert();
        d.vault.borrow(id, 10e6);
    }

    function _advance() internal {
        vm.warp(IAeroForkClock(address(vm)).getBlockTimestamp() + 120);
        vm.roll(IAeroForkClock(address(vm)).getBlockNumber() + 60);
    }

    function _swapData(address receiver, address input, address output, uint256 amount)
        internal
        view
        returns (bytes memory)
    {
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(receiver, amount, uint256(1), abi.encodePacked(input, uint24(500), output), false);
        inputs[1] = abi.encode(input, receiver, uint256(0));
        return abi.encode(
            d.v3Utils.universalRouter(), abi.encode(Swapper.UniversalRouterData(hex"0004", inputs, block.timestamp))
        );
    }

    function testV3UtilsVaultWithdrawalWithUniversalRouterSwap() public {
        _activate();
        uint256 id = _mint(script.collateralPools()[0]);
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(NPM).positions(id);
        V3Utils.Instructions memory instructions;
        instructions.whatToDo = V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP;
        instructions.targetToken = USDC;
        instructions.liquidity = liquidity;
        instructions.amountIn0 = 0.001 ether;
        instructions.amountOut0Min = 1e6;
        instructions.swapData0 = _swapData(address(d.v3Utils), WETH, USDC, 0.001 ether);
        instructions.recipient = ALICE;
        instructions.deadline = block.timestamp;
        uint256 beforeBalance = IERC20(USDC).balanceOf(ALICE);
        vm.prank(ALICE);
        d.vault.transform(id, address(d.v3Utils), abi.encodeCall(V3Utils.execute, (id, instructions)));
        assertGt(IERC20(USDC).balanceOf(ALICE), beforeBalance);
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), address(d.vault));
        (,,,,,,, liquidity,,,,) = INonfungiblePositionManager(NPM).positions(id);
        assertEq(liquidity, 0);
    }

    function testLeverageUsingUniversalRouterAndNewNPM() public {
        _activate();
        uint256 id = _mint(script.collateralPools()[0]);
        (,,,,,,, uint128 beforeLiquidity,,,,) = INonfungiblePositionManager(NPM).positions(id);
        LeverageTransformer.LeverageUpParams memory params;
        params.tokenId = id;
        params.borrowAmount = 10e6;
        params.amountIn0 = 5e6;
        params.amountOut0Min = 1;
        params.swapData0 = _swapData(address(d.leverageTransformer), USDC, WETH, 5e6);
        params.recipient = ALICE;
        params.deadline = block.timestamp;
        vm.prank(ALICE);
        d.vault.transform(id, address(d.leverageTransformer), abi.encodeCall(LeverageTransformer.leverageUp, (params)));
        (uint256 debt,,,,) = d.vault.loanInfo(id);
        assertEq(debt, 10e6);
        (,,,,,,, uint128 afterLiquidity,,,,) = INonfungiblePositionManager(NPM).positions(id);
        assertGt(afterLiquidity, beforeLiquidity);
    }

    function testOperatorManagedStakeUnstakeAndSimpleRewardFees() public {
        _activate();
        uint256 id = _mint(script.collateralPools()[0]);
        AutoRangeAndCompound.PositionConfig memory config;
        config.autoCompound = true;
        config.lowerTickDelta = -1000;
        config.upperTickDelta = 1000;
        config.maxRewardX64 = d.autoRange.simpleRewardX64();
        vm.startPrank(ALICE);
        d.autoRange.configToken(id, address(d.vault), config, AutoRangeAndCompound.CompoundMode.Simple);
        d.vault.approveTransform(id, address(d.autoRange), true);
        d.autoRange.configStakingManagement(id, address(d.vault), true);
        vm.stopPrank();
        AutoRangeAndCompound.AutoCompoundParams memory params =
            AutoRangeAndCompound.AutoCompoundParams(id, false, 0, block.timestamp);
        IVault.RewardCompoundParams memory rewardParams =
            IVault.RewardCompoundParams(0, 5000, block.timestamp, IVault.StakeTarget.Staked);
        vm.prank(OPERATOR);
        d.autoRange.autoCompoundWithVaultAndRewardCompound(params, address(d.vault), rewardParams);
        assertEq(d.gaugeManager.tokenIdToGauge(id), IAerodromeSlipstreamPool(script.collateralPools()[0]).gauge());
        _advance();
        params.deadline = block.timestamp;
        rewardParams.deadline = block.timestamp;
        rewardParams.stakeTarget = IVault.StakeTarget.Unstaked;
        vm.prank(OPERATOR);
        d.autoRange.autoCompoundWithVaultAndRewardCompound(params, address(d.vault), rewardParams);
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), address(d.vault));
        assertEq(d.gaugeManager.tokenIdToGauge(id), address(0));
        assertGt(IERC20(WETH).balanceOf(address(d.gaugeManager)) + IERC20(USDC).balanceOf(address(d.gaugeManager)), 0);
        assertEq(d.autoRange.compoundRewardX64(id), d.autoRange.simpleRewardX64());
        vm.prank(ALICE);
        d.autoRange.configStakingManagement(id, address(d.vault), false);
        rewardParams.stakeTarget = IVault.StakeTarget.Staked;
        vm.prank(OPERATOR);
        vm.expectRevert();
        d.autoRange.autoCompoundWithVaultAndRewardCompound(params, address(d.vault), rewardParams);
    }

    function testStakedFlashloanLiquidationUsingRealPoolsAndRouter() public {
        _activate();
        uint256 id = _mint(script.collateralPools()[0]);
        vm.startPrank(ALICE);
        d.vault.borrow(id, 10e6);
        d.vault.stakePosition(id);
        vm.stopPrank();
        _advance();
        // Controlled governance shock solely to trigger liquidation; feeds and DEX prices stay real.
        vm.startPrank(SAFE);
        d.vault.setTokenConfig(WETH, 0, type(uint32).max);
        d.vault.setTokenConfig(USDC, 0, type(uint32).max);
        vm.stopPrank();
        uint256 snapshot = vm.snapshot();
        deal(USDC, address(this), 100e6);
        IERC20(USDC).approve(address(d.vault), type(uint256).max);
        (uint256 amount0,) = d.vault.liquidate(IVault.LiquidateParams(id, 0, 0, address(this), block.timestamp));
        assertTrue(vm.revertTo(snapshot));
        FlashloanLiquidator.LiquidateParams memory params;
        params.tokenId = id;
        params.vault = IVault(address(d.vault));
        params.flashLoanPool = IUniswapV3Pool(script.collateralPools()[1]);
        params.amount0In = amount0;
        params.swapData0 = _swapData(address(d.liquidator), WETH, USDC, amount0);
        params.deadline = block.timestamp;
        uint256 beforeBalance = IERC20(USDC).balanceOf(address(this));
        d.liquidator.liquidate(params);
        assertEq(d.vault.loans(id), 0);
        assertGt(IERC20(USDC).balanceOf(address(this)), beforeBalance);
        assertEq(d.gaugeManager.tokenIdToGauge(id), address(0));
    }

    function testTinyCbBtcCompoundRevertsAtomicallyAndPrincipalCanExit() public {
        _activate();
        uint256 id = _mint(script.collateralPools()[2]);
        vm.prank(ALICE);
        d.vault.stakePosition(id);
        _advance();
        uint256 rewards = d.gaugeManager.positionRewards(id);
        assertGt(rewards, 0);
        address gauge = d.gaugeManager.tokenIdToGauge(id);
        vm.prank(ALICE);
        vm.expectRevert();
        d.gaugeManager.compoundRewards(id, 1, 5000, block.timestamp);
        assertEq(d.gaugeManager.positionRewards(id), rewards);
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), gauge);
        uint256 beforeReward = IERC20(AERO).balanceOf(ALICE);
        vm.prank(ALICE);
        d.vault.remove(id, ALICE, "");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), ALICE);
        assertGt(IERC20(AERO).balanceOf(ALICE), beforeReward);
    }

    function testAutoRangeReplacesStakedCollateralAndPreservesLoan() public {
        _activate();
        uint256 id = _mint(script.collateralPools()[0]);
        AutoRangeAndCompound.PositionConfig memory config;
        config.lowerTickLimit = -2000;
        config.upperTickLimit = -2000;
        config.lowerTickDelta = -1200;
        config.upperTickDelta = 1200;
        vm.startPrank(ALICE);
        d.vault.borrow(id, 10e6);
        d.autoRange.configToken(id, address(d.vault), config, AutoRangeAndCompound.CompoundMode.Advanced);
        d.vault.approveTransform(id, address(d.autoRange), true);
        d.vault.stakePosition(id);
        vm.stopPrank();
        _advance();
        AutoRangeAndCompound.ExecuteParams memory params;
        params.tokenId = id;
        params.deadline = block.timestamp;
        vm.prank(OPERATOR);
        d.autoRange.executeWithVault(params, address(d.vault));
        uint256 replacement = d.vault.loanAtIndex(ALICE, d.vault.loanCount(ALICE) - 1);
        assertTrue(replacement != id);
        assertGt(d.vault.loans(replacement), 0);
        assertEq(d.vault.loans(id), 0);
        assertEq(d.vault.ownerOf(replacement), ALICE);
        assertEq(
            INonfungiblePositionManager(NPM).ownerOf(replacement),
            IAerodromeSlipstreamPool(script.collateralPools()[0]).gauge()
        );
    }

    function testAutoExitOnWalletPosition() public {
        _activate();
        uint256 id = _mint(script.collateralPools()[0]);
        (, int24 tick,,,,) = IAerodromeSlipstreamPool(script.collateralPools()[0]).slot0();
        AutoExit.PositionConfig memory config;
        config.isActive = true;
        config.token0TriggerTick = tick + 50;
        config.token1TriggerTick = tick + 100;
        vm.startPrank(ALICE);
        d.vault.remove(id, ALICE, "");
        INonfungiblePositionManager(NPM).approve(address(d.autoExit), id);
        d.autoExit.configToken(id, config);
        vm.stopPrank();
        uint256 beforeBalance = IERC20(USDC).balanceOf(ALICE);
        vm.prank(OPERATOR);
        d.autoExit.execute(AutoExit.ExecuteParams(id, "", 0, 0, block.timestamp, 0));
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(NPM).positions(id);
        assertEq(liquidity, 0);
        assertGt(IERC20(USDC).balanceOf(ALICE), beforeBalance);
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), ALICE);
    }
}
