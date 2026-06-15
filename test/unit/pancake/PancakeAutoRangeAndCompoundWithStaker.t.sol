// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/automators/Automator.sol";
import "../../../src/automators/PancakeMasterChefV3Staker.sol";
import "../../../src/transformers/AutoRangeAndCompound.sol";
import "../../../src/utils/Constants.sol";
import "./PancakeMasterChefV3Mocks.sol";

contract PancakeAutoRangeAndCompoundWithStakerTest is Test {
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
    AutoRangeAndCompound internal autoRangeAndCompound;

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
        autoRangeAndCompound = new AutoRangeAndCompound(
            INonfungiblePositionManager(address(npm)), OPERATOR, WITHDRAWER, 60, 100, address(0), address(0)
        );

        autoRangeAndCompound.setPancakeStaker(address(staker));
        staker.setRewardBasePool(address(token0), address(cakePool));
        staker.setTransformer(address(autoRangeAndCompound), true);

        npm.mintPosition(ALICE, TOKEN_ID, address(token0), address(token1), FEE, 10, 20, 100, 0, 0);

        vm.startPrank(ALICE);
        npm.approve(address(staker), TOKEN_ID);
        staker.stakePosition(TOKEN_ID, ALICE);
        staker.approveTransform(TOKEN_ID, address(autoRangeAndCompound), true);
        autoRangeAndCompound.configToken(
            TOKEN_ID,
            address(staker),
            AutoRangeAndCompound.PositionConfig(
                0, 0, -10, 10, 0, 0, false, false, autoRangeAndCompound.MAX_REWARD_X64(), 0, 0, 0
            )
        );
        vm.stopPrank();
    }

    function testAutoRangeAndCompoundAdminSetters() external {
        uint16 maxTWAPTickDifference = autoRangeAndCompound.maxTWAPTickDifference();
        autoRangeAndCompound.setTWAPConfig(maxTWAPTickDifference, 120);
        assertEq(autoRangeAndCompound.TWAPSeconds(), 120);

        vm.expectRevert(Constants.InvalidConfig.selector);
        autoRangeAndCompound.setTWAPConfig(maxTWAPTickDifference, 30);

        uint32 twapSeconds = autoRangeAndCompound.TWAPSeconds();
        autoRangeAndCompound.setTWAPConfig(5, twapSeconds);
        assertEq(autoRangeAndCompound.maxTWAPTickDifference(), 5);

        vm.expectRevert(Constants.InvalidConfig.selector);
        autoRangeAndCompound.setTWAPConfig(201, twapSeconds);

        assertFalse(autoRangeAndCompound.operators(BOB));
        autoRangeAndCompound.setOperator(BOB, true);
        assertTrue(autoRangeAndCompound.operators(BOB));

        vm.expectRevert(Automator.ZeroAddress.selector);
        autoRangeAndCompound.setOperator(address(0), true);

        vm.expectRevert(Automator.ZeroAddress.selector);
        autoRangeAndCompound.setWithdrawer(address(0));

        uint64 currentReward = autoRangeAndCompound.totalRewardX64();
        autoRangeAndCompound.setAutoCompoundReward(currentReward / 2);
        assertEq(autoRangeAndCompound.totalRewardX64(), currentReward / 2);

        vm.expectRevert(Constants.InvalidConfig.selector);
        autoRangeAndCompound.setAutoCompoundReward(currentReward);
    }

    function testAutoRangeAndCompoundConfigAuthorizationResetAndInvalidConfig() external {
        uint64 maxReward = autoRangeAndCompound.MAX_REWARD_X64();
        AutoRangeAndCompound.PositionConfig memory config =
            AutoRangeAndCompound.PositionConfig(1, 2, -20, 20, 3, 4, false, true, maxReward, 5, 6, 7);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(BOB);
        autoRangeAndCompound.configToken(TOKEN_ID, address(staker), config);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(ALICE);
        autoRangeAndCompound.configToken(TOKEN_ID, address(0xDEAD), config);

        vm.expectRevert(Constants.InvalidConfig.selector);
        vm.prank(ALICE);
        autoRangeAndCompound.configToken(
            TOKEN_ID,
            address(staker),
            AutoRangeAndCompound.PositionConfig(0, 0, 20, -20, 0, 0, false, false, maxReward, 0, 0, 0)
        );

        vm.prank(ALICE);
        autoRangeAndCompound.configToken(TOKEN_ID, address(staker), config);

        (
            ,,
            int32 lowerTickDelta,
            int32 upperTickDelta,,,,
            bool autoCompoundEnabled,
            uint64 maxRewardX64,
            uint128 autoCompoundMin0,
            uint128 autoCompoundMin1,
            uint128 autoCompoundRewardMin
        ) = autoRangeAndCompound.positionConfigs(TOKEN_ID);

        assertEq(lowerTickDelta, config.lowerTickDelta);
        assertEq(upperTickDelta, config.upperTickDelta);
        assertTrue(autoCompoundEnabled);
        assertEq(maxRewardX64, config.maxRewardX64);
        assertEq(autoCompoundMin0, config.autoCompoundMin0);
        assertEq(autoCompoundMin1, config.autoCompoundMin1);
        assertEq(autoCompoundRewardMin, config.autoCompoundRewardMin);

        vm.prank(ALICE);
        autoRangeAndCompound.configToken(
            TOKEN_ID,
            address(staker),
            AutoRangeAndCompound.PositionConfig(0, 0, 0, 0, 0, 0, false, false, maxReward, 0, 0, 0)
        );
        (,, lowerTickDelta, upperTickDelta,,,,,,,,) = autoRangeAndCompound.positionConfigs(TOKEN_ID);
        assertEq(lowerTickDelta, 0);
        assertEq(upperTickDelta, 0);
    }

    function testAutoRangeAndCompoundCreatesAndStakesNewPosition() external {
        vm.prank(OPERATOR);
        autoRangeAndCompound.executeWithPancakeStaker(
            AutoRangeAndCompound.ExecuteParams(TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0), address(staker)
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

    function testAutoRangeAndCompoundWorksForOwnerHeldPosition() external {
        npm.mintPosition(ALICE, DIRECT_TOKEN_ID, address(token0), address(token1), FEE, 10, 20, 100, 0, 0);

        vm.startPrank(ALICE);
        npm.approve(address(autoRangeAndCompound), DIRECT_TOKEN_ID);
        autoRangeAndCompound.configToken(
            DIRECT_TOKEN_ID, AutoRangeAndCompound.PositionConfig(0, 0, -10, 10, 0, 0, false, false, 0, 0, 0, 0)
        );
        vm.stopPrank();

        vm.prank(OPERATOR);
        autoRangeAndCompound.execute(
            AutoRangeAndCompound.ExecuteParams(DIRECT_TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0)
        );

        assertEq(npm.ownerOf(DIRECT_TOKEN_ID), ALICE);
        assertEq(npm.ownerOf(NEW_TOKEN_ID), ALICE);
        assertEq(staker.ownerOf(DIRECT_TOKEN_ID), address(0));
        assertEq(staker.ownerOf(NEW_TOKEN_ID), address(0));
    }

    function testAutoRangeAndCompoundRejectsRangeWhenNotReady() external {
        pool.setTick(15);

        vm.expectRevert(Constants.NotReady.selector);
        vm.prank(OPERATOR);
        autoRangeAndCompound.executeWithPancakeStaker(
            AutoRangeAndCompound.ExecuteParams(TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0), address(staker)
        );
    }

    function testAutoRangeAndCompoundRejectsSameRange() external {
        uint64 maxReward = autoRangeAndCompound.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoRangeAndCompound.configToken(
            TOKEN_ID,
            address(staker),
            AutoRangeAndCompound.PositionConfig(0, 0, 10, 20, 0, 0, false, false, maxReward, 0, 0, 0)
        );

        vm.expectRevert(Constants.SameRange.selector);
        vm.prank(OPERATOR);
        autoRangeAndCompound.executeWithPancakeStaker(
            AutoRangeAndCompound.ExecuteParams(TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0), address(staker)
        );
    }

    function testAutoRangeAndCompoundRejectsNonOperatorAndMissingTransformApproval() external {
        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(ALICE);
        autoRangeAndCompound.executeWithPancakeStaker(
            AutoRangeAndCompound.ExecuteParams(TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0), address(staker)
        );

        vm.prank(ALICE);
        staker.approveTransform(TOKEN_ID, address(autoRangeAndCompound), false);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(OPERATOR);
        autoRangeAndCompound.executeWithPancakeStaker(
            AutoRangeAndCompound.ExecuteParams(TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0), address(staker)
        );
    }

    function testAutoRangeAndCompoundRejectsAutoCompoundWithoutConfig() external {
        vm.expectRevert(Constants.NotConfigured.selector);
        vm.prank(OPERATOR);
        autoRangeAndCompound.autoCompoundWithPancakeStaker(
            AutoRangeAndCompound.AutoCompoundParams(TOKEN_ID, false, 0, 1), address(staker)
        );
    }

    function testAutoRangeAndCompoundDirectAutoCompoundWorksForOwnerHeldPosition() external {
        npm.mintPosition(ALICE, DIRECT_TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 1_000, 1_000);

        vm.startPrank(ALICE);
        npm.approve(address(autoRangeAndCompound), DIRECT_TOKEN_ID);
        autoRangeAndCompound.configToken(
            DIRECT_TOKEN_ID,
            AutoRangeAndCompound.PositionConfig(
                0, 0, 0, 0, 0, 0, false, true, autoRangeAndCompound.MAX_REWARD_X64(), 0, 0, 0
            )
        );
        vm.stopPrank();

        vm.prank(OPERATOR);
        autoRangeAndCompound.autoCompound(AutoRangeAndCompound.AutoCompoundParams(DIRECT_TOKEN_ID, false, 0, 1));

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(DIRECT_TOKEN_ID);
        assertEq(liquidity, 2_060);
        assertEq(npm.ownerOf(DIRECT_TOKEN_ID), ALICE);
        assertEq(token0.balanceOf(ALICE), 1);
        assertEq(token1.balanceOf(ALICE), 1);
    }

    function testAutoRangeAndCompoundAutoCompoundSwapsFeesBeforeAddingLiquidity() external {
        npm.setFees(TOKEN_ID, 1_000, 1_000);
        uint64 maxReward = autoRangeAndCompound.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoRangeAndCompound.configToken(
            TOKEN_ID,
            address(staker),
            AutoRangeAndCompound.PositionConfig(0, 0, -10, 10, 0, 0, false, true, maxReward, 0, 0, 0)
        );

        vm.prank(OPERATOR);
        autoRangeAndCompound.autoCompoundWithPancakeStaker(
            AutoRangeAndCompound.AutoCompoundParams(TOKEN_ID, true, 100, 1), address(staker)
        );

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(TOKEN_ID);
        assertEq(liquidity, 2_060);
        assertEq(token0.balanceOf(address(autoRangeAndCompound)), 17);
        assertEq(token1.balanceOf(address(autoRangeAndCompound)), 21);
    }

    function testAutoRangeAndCompoundAutoCompoundRejectsSwapAmountTooLarge() external {
        npm.setFees(TOKEN_ID, 1_000, 1_000);
        uint64 maxReward = autoRangeAndCompound.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoRangeAndCompound.configToken(
            TOKEN_ID,
            address(staker),
            AutoRangeAndCompound.PositionConfig(0, 0, -10, 10, 0, 0, false, true, maxReward, 0, 0, 0)
        );

        vm.expectRevert(Constants.SwapAmountTooLarge.selector);
        vm.prank(OPERATOR);
        autoRangeAndCompound.autoCompoundWithPancakeStaker(
            AutoRangeAndCompound.AutoCompoundParams(TOKEN_ID, true, 1_001, 1), address(staker)
        );
    }

    function testAutoRangeAndCompoundAutoCompoundRejectsTwapFailureForSwap() external {
        npm.setFees(TOKEN_ID, 1_000, 1_000);
        pool.setTick(101);
        uint64 maxReward = autoRangeAndCompound.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoRangeAndCompound.configToken(
            TOKEN_ID,
            address(staker),
            AutoRangeAndCompound.PositionConfig(0, 0, -10, 10, 0, 0, false, true, maxReward, 0, 0, 0)
        );

        vm.expectRevert(Constants.TWAPCheckFailed.selector);
        vm.prank(OPERATOR);
        autoRangeAndCompound.autoCompoundWithPancakeStaker(
            AutoRangeAndCompound.AutoCompoundParams(TOKEN_ID, true, 100, 1), address(staker)
        );
    }

    function testAutoRangeAndCompoundRejectsRewardAboveCap() external {
        uint64 tooHighReward = autoRangeAndCompound.MAX_REWARD_X64() + 1;

        vm.expectRevert(Constants.InvalidConfig.selector);
        vm.prank(ALICE);
        autoRangeAndCompound.configToken(
            TOKEN_ID,
            address(staker),
            AutoRangeAndCompound.PositionConfig(0, 0, -10, 10, 0, 0, false, false, tooHighReward, 0, 0, 0)
        );
    }

    function testAutoRangeAndCompoundCompoundsCakeRewardBeforeChangingRange() external {
        masterChef.setReward(TOKEN_ID, 100);

        AutoRangeAndCompound.RewardCompoundParams memory rewardParams;
        rewardParams.minCakeReward = 100;
        rewardParams.cakeSplitBps = 10_000;
        rewardParams.deadline = 1;

        vm.prank(OPERATOR);
        autoRangeAndCompound.executeWithPancakeStakerAndRewardCompound(
            AutoRangeAndCompound.ExecuteParams(TOKEN_ID, false, 0, "", 0, 0, 0, 0, 1, 0), address(staker), rewardParams
        );

        (,,,,,,, uint128 newLiquidity,,,,) = npm.positions(NEW_TOKEN_ID);
        assertGt(newLiquidity, 200);
        assertEq(npm.ownerOf(NEW_TOKEN_ID), address(masterChef));
        assertEq(masterChef.positionUser(NEW_TOKEN_ID), address(staker));
        assertEq(staker.ownerOf(NEW_TOKEN_ID), ALICE);
    }

    function testAutoRangeAndCompoundAutoCompoundsCakeRewardAndFeesThroughStaker() external {
        npm.setFees(TOKEN_ID, 1_000, 1_000);
        masterChef.setReward(TOKEN_ID, 1_000);
        uint64 maxReward = autoRangeAndCompound.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoRangeAndCompound.configToken(
            TOKEN_ID,
            address(staker),
            AutoRangeAndCompound.PositionConfig(0, 0, -10, 10, 0, 0, false, true, maxReward, 0, 0, 1_000)
        );

        AutoRangeAndCompound.RewardCompoundParams memory rewardParams;
        rewardParams.minCakeReward = 100;
        rewardParams.cakeSplitBps = 10_000;
        rewardParams.deadline = 1;

        vm.prank(OPERATOR);
        autoRangeAndCompound.autoCompoundWithPancakeStakerAndRewardCompound(
            AutoRangeAndCompound.AutoCompoundParams(TOKEN_ID, false, 0, 1), address(staker), rewardParams
        );

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(TOKEN_ID);
        assertEq(liquidity, 3_040);
        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
        assertEq(token0.balanceOf(ALICE), 2);
        assertEq(token1.balanceOf(ALICE), 1);
        assertEq(token0.balanceOf(address(staker)), 19);
        assertEq(token0.balanceOf(address(autoRangeAndCompound)), 19);
        assertEq(token1.balanceOf(address(autoRangeAndCompound)), 19);
    }

    function testAutoRangeAndCompoundRewardAutoCompoundRejectsInvalidSplit() external {
        masterChef.setReward(TOKEN_ID, 100);
        vm.prank(ALICE);
        autoRangeAndCompound.configToken(
            TOKEN_ID, address(staker), AutoRangeAndCompound.PositionConfig(0, 0, -10, 10, 0, 0, false, true, 0, 0, 0, 0)
        );

        AutoRangeAndCompound.RewardCompoundParams memory rewardParams;
        rewardParams.cakeSplitBps = 10_001;

        vm.expectRevert(Constants.InvalidConfig.selector);
        vm.prank(OPERATOR);
        autoRangeAndCompound.autoCompoundWithPancakeStakerAndRewardCompound(
            AutoRangeAndCompound.AutoCompoundParams(TOKEN_ID, false, 0, 1), address(staker), rewardParams
        );
    }

    function testAutoRangeAndCompoundAutoCompoundRespectsConfiguredFeeMinimums() external {
        uint64 maxReward = autoRangeAndCompound.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoRangeAndCompound.configToken(
            TOKEN_ID,
            address(staker),
            AutoRangeAndCompound.PositionConfig(0, 0, -10, 10, 0, 0, false, true, maxReward, 1, 0, 0)
        );

        vm.expectRevert(Constants.NotEnoughReward.selector);
        vm.prank(OPERATOR);
        autoRangeAndCompound.autoCompoundWithPancakeStaker(
            AutoRangeAndCompound.AutoCompoundParams(TOKEN_ID, false, 0, 1), address(staker)
        );
    }
}
