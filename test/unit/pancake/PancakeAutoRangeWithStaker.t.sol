// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/automators/Automator.sol";
import "../../../src/automators/PancakeMasterChefV3Staker.sol";
import "../../../src/transformers/AutoRange.sol";
import "../../../src/utils/Constants.sol";
import "./PancakeMasterChefV3Mocks.sol";

contract PancakeAutoRangeWithStakerTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant OPERATOR = address(0x0A);
    address internal constant WITHDRAWER = address(0x0B);
    address internal constant RECIPIENT = address(0xCAFE);

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant DIRECT_TOKEN_ID = 2;
    uint256 internal constant NEW_TOKEN_ID = 100;
    uint24 internal constant FEE = 500;

    PancakeMockERC20 internal cake;
    PancakeMockERC20 internal token0;
    PancakeMockERC20 internal token1;
    PancakeMockFactory internal factory;
    PancakeMockPool internal pool;
    PancakeMockPool internal cakePool;
    PancakeMockNPM internal npm;
    PancakeMockMasterChef internal masterChef;
    PancakeMasterChefV3Staker internal staker;
    AutoRange internal autoRange;

    function setUp() external {
        cake = new PancakeMockERC20("CAKE", "CAKE");
        token0 = new PancakeMockERC20("Token0", "TK0");
        token1 = new PancakeMockERC20("Token1", "TK1");
        factory = new PancakeMockFactory();
        pool = new PancakeMockPool(address(token0), address(token1), FEE);
        cakePool = new PancakeMockPool(address(cake), address(token0), FEE);
        factory.setPool(address(token0), address(token1), FEE, address(pool));
        factory.setPool(address(cake), address(token0), FEE, address(cakePool));
        token0.mint(address(cakePool), 1_000_000);

        npm = new PancakeMockNPM(address(factory), address(cake));
        masterChef = new PancakeMockMasterChef(address(cake), address(npm));
        staker = new PancakeMasterChefV3Staker(
            INonfungiblePositionManager(address(npm)), IPancakeMasterChefV3(address(masterChef)), IERC20(address(cake))
        );
        autoRange = new AutoRange(
            INonfungiblePositionManager(address(npm)), OPERATOR, WITHDRAWER, 60, 100, address(0), address(0)
        );

        autoRange.setPancakeStaker(address(staker));
        autoRange.setCakeToken(IERC20(address(cake)));
        autoRange.setRewardAnchor(address(token0), 1);
        staker.setTransformer(address(autoRange), true);

        npm.mintPosition(ALICE, TOKEN_ID, address(token0), address(token1), FEE, 10, 20, 100, 0, 0);

        vm.startPrank(ALICE);
        npm.approve(address(staker), TOKEN_ID);
        staker.stakePosition(TOKEN_ID, ALICE);
        staker.approveTransform(TOKEN_ID, address(autoRange), true);
        autoRange.configToken(
            TOKEN_ID,
            address(staker),
            AutoRange.PositionConfig(0, 0, -10, 10, 0, 0, false, false, autoRange.MAX_REWARD_X64(), 0, 0, 0)
        );
        vm.stopPrank();
    }

    function testAutoRangeAdminSetters() external {
        uint16 maxTWAPTickDifference = autoRange.maxTWAPTickDifference();
        autoRange.setTWAPConfig(maxTWAPTickDifference, 120);
        assertEq(autoRange.TWAPSeconds(), 120);

        vm.expectRevert(Constants.InvalidConfig.selector);
        autoRange.setTWAPConfig(maxTWAPTickDifference, 30);

        uint32 twapSeconds = autoRange.TWAPSeconds();
        autoRange.setTWAPConfig(5, twapSeconds);
        assertEq(autoRange.maxTWAPTickDifference(), 5);

        vm.expectRevert(Constants.InvalidConfig.selector);
        autoRange.setTWAPConfig(201, twapSeconds);

        assertFalse(autoRange.operators(BOB));
        autoRange.setOperator(BOB, true);
        assertTrue(autoRange.operators(BOB));

        vm.expectRevert(Automator.ZeroAddress.selector);
        autoRange.setOperator(address(0), true);

        vm.expectRevert(Automator.ZeroAddress.selector);
        autoRange.setWithdrawer(address(0));

        uint64 currentReward = autoRange.totalRewardX64();
        autoRange.setAutoCompoundReward(currentReward / 2);
        assertEq(autoRange.totalRewardX64(), currentReward / 2);

        vm.expectRevert(Constants.InvalidConfig.selector);
        autoRange.setAutoCompoundReward(currentReward);
    }

    function testAutoRangeConfigAuthorizationResetAndInvalidConfig() external {
        uint64 maxReward = autoRange.MAX_REWARD_X64();
        AutoRange.PositionConfig memory config =
            AutoRange.PositionConfig(1, 2, -20, 20, 3, 4, false, true, maxReward, 5, 6, 7);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(BOB);
        autoRange.configToken(TOKEN_ID, address(staker), config);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(ALICE);
        autoRange.configToken(TOKEN_ID, address(0xDEAD), config);

        vm.expectRevert(Constants.InvalidConfig.selector);
        vm.prank(ALICE);
        autoRange.configToken(
            TOKEN_ID, address(staker), AutoRange.PositionConfig(0, 0, 20, -20, 0, 0, false, false, maxReward, 0, 0, 0)
        );

        vm.prank(ALICE);
        autoRange.configToken(TOKEN_ID, address(staker), config);

        (
            ,,
            int32 lowerTickDelta,
            int32 upperTickDelta,,,,
            bool autoCompoundEnabled,
            uint64 maxRewardX64,
            uint128 autoCompoundMin0,
            uint128 autoCompoundMin1,
            uint128 autoCompoundRewardMin
        ) = autoRange.positionConfigs(TOKEN_ID);

        assertEq(lowerTickDelta, config.lowerTickDelta);
        assertEq(upperTickDelta, config.upperTickDelta);
        assertTrue(autoCompoundEnabled);
        assertEq(maxRewardX64, config.maxRewardX64);
        assertEq(autoCompoundMin0, config.autoCompoundMin0);
        assertEq(autoCompoundMin1, config.autoCompoundMin1);
        assertEq(autoCompoundRewardMin, config.autoCompoundRewardMin);

        vm.prank(ALICE);
        autoRange.configToken(
            TOKEN_ID, address(staker), AutoRange.PositionConfig(0, 0, 0, 0, 0, 0, false, false, maxReward, 0, 0, 0)
        );
        (,, lowerTickDelta, upperTickDelta,,,,,,,,) = autoRange.positionConfigs(TOKEN_ID);
        assertEq(lowerTickDelta, 0);
        assertEq(upperTickDelta, 0);
    }

    function testAutoRangeCreatesAndStakesNewPosition() external {
        vm.prank(OPERATOR);
        autoRange.executeWithPancakeStaker(
            AutoRange.ExecuteParams(TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0), address(staker)
        );

        assertEq(staker.ownerOf(TOKEN_ID), ALICE);
        assertEq(staker.ownerOf(NEW_TOKEN_ID), ALICE);
        assertEq(npm.ownerOf(TOKEN_ID), address(staker));
        assertEq(npm.ownerOf(NEW_TOKEN_ID), address(masterChef));
        assertEq(masterChef.positionUser(NEW_TOKEN_ID), address(staker));

        vm.prank(ALICE);
        staker.unstakePosition(TOKEN_ID, RECIPIENT);
        assertEq(npm.ownerOf(TOKEN_ID), RECIPIENT);
        assertEq(staker.ownerOf(TOKEN_ID), address(0));
    }

    function testAutoRangeWorksForOwnerHeldPosition() external {
        npm.mintPosition(ALICE, DIRECT_TOKEN_ID, address(token0), address(token1), FEE, 10, 20, 100, 0, 0);

        vm.startPrank(ALICE);
        npm.approve(address(autoRange), DIRECT_TOKEN_ID);
        autoRange.configToken(DIRECT_TOKEN_ID, AutoRange.PositionConfig(0, 0, -10, 10, 0, 0, false, false, 0, 0, 0, 0));
        vm.stopPrank();

        vm.prank(OPERATOR);
        autoRange.execute(AutoRange.ExecuteParams(DIRECT_TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0));

        assertEq(npm.ownerOf(DIRECT_TOKEN_ID), ALICE);
        assertEq(npm.ownerOf(NEW_TOKEN_ID), ALICE);
        assertEq(staker.ownerOf(DIRECT_TOKEN_ID), address(0));
        assertEq(staker.ownerOf(NEW_TOKEN_ID), address(0));
    }

    function testAutoRangeRejectsRangeWhenNotReady() external {
        pool.setTick(15);

        vm.expectRevert(Constants.NotReady.selector);
        vm.prank(OPERATOR);
        autoRange.executeWithPancakeStaker(
            AutoRange.ExecuteParams(TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0), address(staker)
        );
    }

    function testAutoRangeRejectsSameRange() external {
        uint64 maxReward = autoRange.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoRange.configToken(
            TOKEN_ID, address(staker), AutoRange.PositionConfig(0, 0, 10, 20, 0, 0, false, false, maxReward, 0, 0, 0)
        );

        vm.expectRevert(Constants.SameRange.selector);
        vm.prank(OPERATOR);
        autoRange.executeWithPancakeStaker(
            AutoRange.ExecuteParams(TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0), address(staker)
        );
    }

    function testAutoRangeRejectsNonOperatorAndMissingTransformApproval() external {
        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(ALICE);
        autoRange.executeWithPancakeStaker(
            AutoRange.ExecuteParams(TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0), address(staker)
        );

        vm.prank(ALICE);
        staker.approveTransform(TOKEN_ID, address(autoRange), false);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(OPERATOR);
        autoRange.executeWithPancakeStaker(
            AutoRange.ExecuteParams(TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0), address(staker)
        );
    }

    function testAutoRangeRejectsAutoCompoundWithoutConfig() external {
        vm.expectRevert(Constants.NotConfigured.selector);
        vm.prank(OPERATOR);
        autoRange.autoCompoundWithPancakeStaker(AutoRange.AutoCompoundParams(TOKEN_ID, false, 0, 1), address(staker));
    }

    function testAutoRangeDirectAutoCompoundWorksForOwnerHeldPosition() external {
        npm.mintPosition(ALICE, DIRECT_TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 1_000, 1_000);

        vm.startPrank(ALICE);
        npm.approve(address(autoRange), DIRECT_TOKEN_ID);
        autoRange.configToken(
            DIRECT_TOKEN_ID,
            AutoRange.PositionConfig(0, 0, 0, 0, 0, 0, false, true, autoRange.MAX_REWARD_X64(), 0, 0, 0)
        );
        vm.stopPrank();

        vm.prank(OPERATOR);
        autoRange.autoCompound(AutoRange.AutoCompoundParams(DIRECT_TOKEN_ID, false, 0, 1));

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(DIRECT_TOKEN_ID);
        assertEq(liquidity, 2_060);
        assertEq(npm.ownerOf(DIRECT_TOKEN_ID), ALICE);
        assertEq(token0.balanceOf(ALICE), 1);
        assertEq(token1.balanceOf(ALICE), 1);
    }

    function testAutoRangeAutoCompoundSwapsFeesBeforeAddingLiquidity() external {
        npm.setFees(TOKEN_ID, 1_000, 1_000);
        uint64 maxReward = autoRange.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoRange.configToken(
            TOKEN_ID, address(staker), AutoRange.PositionConfig(0, 0, -10, 10, 0, 0, false, true, maxReward, 0, 0, 0)
        );

        vm.prank(OPERATOR);
        autoRange.autoCompoundWithPancakeStaker(AutoRange.AutoCompoundParams(TOKEN_ID, true, 100, 1), address(staker));

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(TOKEN_ID);
        assertEq(liquidity, 2_060);
        assertEq(token0.balanceOf(address(autoRange)), 17);
        assertEq(token1.balanceOf(address(autoRange)), 21);
    }

    function testAutoRangeAutoCompoundRejectsSwapAmountTooLarge() external {
        npm.setFees(TOKEN_ID, 1_000, 1_000);
        uint64 maxReward = autoRange.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoRange.configToken(
            TOKEN_ID, address(staker), AutoRange.PositionConfig(0, 0, -10, 10, 0, 0, false, true, maxReward, 0, 0, 0)
        );

        vm.expectRevert(Constants.SwapAmountTooLarge.selector);
        vm.prank(OPERATOR);
        autoRange.autoCompoundWithPancakeStaker(AutoRange.AutoCompoundParams(TOKEN_ID, true, 1_001, 1), address(staker));
    }

    function testAutoRangeAutoCompoundRejectsTwapFailureForSwap() external {
        npm.setFees(TOKEN_ID, 1_000, 1_000);
        pool.setTick(101);
        uint64 maxReward = autoRange.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoRange.configToken(
            TOKEN_ID, address(staker), AutoRange.PositionConfig(0, 0, -10, 10, 0, 0, false, true, maxReward, 0, 0, 0)
        );

        vm.expectRevert(Constants.TWAPCheckFailed.selector);
        vm.prank(OPERATOR);
        autoRange.autoCompoundWithPancakeStaker(AutoRange.AutoCompoundParams(TOKEN_ID, true, 100, 1), address(staker));
    }

    function testAutoRangeRejectsRewardAboveCap() external {
        uint64 tooHighReward = autoRange.MAX_REWARD_X64() + 1;

        vm.expectRevert(Constants.InvalidConfig.selector);
        vm.prank(ALICE);
        autoRange.configToken(
            TOKEN_ID,
            address(staker),
            AutoRange.PositionConfig(0, 0, -10, 10, 0, 0, false, false, tooHighReward, 0, 0, 0)
        );
    }

    function testAutoRangeCompoundsCakeRewardBeforeChangingRange() external {
        masterChef.setReward(TOKEN_ID, 100);

        AutoRange.RewardCompoundParams memory rewardParams;
        rewardParams.minCakeReward = 100;
        rewardParams.cakeSplitBps = 10_000;
        rewardParams.token0CakePool = IUniswapV3Pool(address(cakePool));

        vm.prank(OPERATOR);
        autoRange.executeWithPancakeStakerAndRewardCompound(
            AutoRange.ExecuteParams(TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0), address(staker), rewardParams
        );

        (,,,,,,, uint128 newLiquidity,,,,) = npm.positions(NEW_TOKEN_ID);
        assertGt(newLiquidity, 200);
        assertEq(npm.ownerOf(NEW_TOKEN_ID), address(masterChef));
        assertEq(masterChef.positionUser(NEW_TOKEN_ID), address(staker));
        assertEq(staker.ownerOf(NEW_TOKEN_ID), ALICE);
    }

    function testAutoRangeAutoCompoundsCakeRewardAndFeesThroughStaker() external {
        npm.setFees(TOKEN_ID, 1_000, 1_000);
        masterChef.setReward(TOKEN_ID, 1_000);
        uint64 maxReward = autoRange.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoRange.configToken(
            TOKEN_ID,
            address(staker),
            AutoRange.PositionConfig(0, 0, -10, 10, 0, 0, false, true, maxReward, 0, 0, 1_000)
        );

        AutoRange.RewardCompoundParams memory rewardParams;
        rewardParams.minCakeReward = 100;
        rewardParams.cakeSplitBps = 10_000;
        rewardParams.token0CakePool = IUniswapV3Pool(address(cakePool));

        vm.prank(OPERATOR);
        autoRange.autoCompoundWithPancakeStakerAndRewardCompound(
            AutoRange.AutoCompoundParams(TOKEN_ID, false, 0, 1), address(staker), rewardParams
        );

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(TOKEN_ID);
        assertEq(liquidity, 3_040);
        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
        assertEq(token0.balanceOf(ALICE), 2);
        assertEq(token1.balanceOf(ALICE), 1);
        assertEq(token0.balanceOf(address(autoRange)), 38);
        assertEq(token1.balanceOf(address(autoRange)), 19);
    }

    function testAutoRangeRewardAutoCompoundRejectsInvalidSplit() external {
        masterChef.setReward(TOKEN_ID, 100);
        vm.prank(ALICE);
        autoRange.configToken(
            TOKEN_ID, address(staker), AutoRange.PositionConfig(0, 0, -10, 10, 0, 0, false, true, 0, 0, 0, 0)
        );

        AutoRange.RewardCompoundParams memory rewardParams;
        rewardParams.cakeSplitBps = 10_001;

        vm.expectRevert(Constants.InvalidConfig.selector);
        vm.prank(OPERATOR);
        autoRange.autoCompoundWithPancakeStakerAndRewardCompound(
            AutoRange.AutoCompoundParams(TOKEN_ID, false, 0, 1), address(staker), rewardParams
        );
    }

    function testAutoRangeAutoCompoundRespectsConfiguredFeeMinimums() external {
        uint64 maxReward = autoRange.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoRange.configToken(
            TOKEN_ID, address(staker), AutoRange.PositionConfig(0, 0, -10, 10, 0, 0, false, true, maxReward, 1, 0, 0)
        );

        vm.expectRevert(Constants.NotEnoughReward.selector);
        vm.prank(OPERATOR);
        autoRange.autoCompoundWithPancakeStaker(AutoRange.AutoCompoundParams(TOKEN_ID, false, 0, 1), address(staker));
    }
}
