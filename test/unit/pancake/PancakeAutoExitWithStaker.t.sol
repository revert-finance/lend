// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/automators/AutoExit.sol";
import "../../../src/automators/Automator.sol";
import "../../../src/automators/PancakeMasterChefV3Staker.sol";
import "../../../src/utils/Constants.sol";
import "./PancakeMasterChefV3Mocks.sol";

contract PancakeAutoExitWithStakerTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant OPERATOR = address(0x0A);
    address internal constant WITHDRAWER = address(0x0B);
    address internal constant RECIPIENT = address(0xCAFE);

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant DIRECT_TOKEN_ID = 2;
    uint256 internal constant NO_LIQUIDITY_TOKEN_ID = 3;
    uint256 internal constant UNAPPROVED_DIRECT_TOKEN_ID = 4;
    uint24 internal constant FEE = 500;

    PancakeMockERC20 internal cake;
    PancakeMockERC20 internal token0;
    PancakeMockERC20 internal token1;
    PancakeMockFactory internal factory;
    PancakeMockPool internal pool;
    PancakeMockRouter internal router;
    PancakeMockNPM internal npm;
    PancakeMockMasterChef internal masterChef;
    PancakeMasterChefV3Staker internal staker;
    AutoExit internal autoExit;

    function setUp() external {
        cake = new PancakeMockERC20("CAKE", "CAKE");
        token0 = new PancakeMockERC20("Token0", "TK0");
        token1 = new PancakeMockERC20("Token1", "TK1");
        factory = new PancakeMockFactory();
        pool = new PancakeMockPool(address(token0), address(token1), FEE);
        router = new PancakeMockRouter();
        factory.setPool(address(token0), address(token1), FEE, address(pool));

        npm = new PancakeMockNPM(address(factory), address(cake));
        masterChef = new PancakeMockMasterChef(address(cake), address(npm));
        staker = new PancakeMasterChefV3Staker(
            INonfungiblePositionManager(address(npm)), IPancakeMasterChefV3(address(masterChef)), IERC20(address(cake))
        );
        autoExit = new AutoExit(
            INonfungiblePositionManager(address(npm)), OPERATOR, WITHDRAWER, 60, 100, address(0), address(router)
        );

        autoExit.setPancakeStaker(address(staker));
        staker.setTransformer(address(autoExit), true);

        npm.mintPosition(ALICE, TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 0, 0);

        vm.startPrank(ALICE);
        npm.approve(address(staker), TOKEN_ID);
        staker.stakePosition(TOKEN_ID, ALICE);
        staker.approveTransform(TOKEN_ID, address(autoExit), true);
        autoExit.configToken(
            TOKEN_ID, address(staker), AutoExit.PositionConfig(true, false, false, 1, 100, 0, 0, false, 0)
        );
        vm.stopPrank();
    }

    function testAutoExitAdminSetters() external {
        uint16 maxTWAPTickDifference = autoExit.maxTWAPTickDifference();
        autoExit.setTWAPConfig(maxTWAPTickDifference, 120);
        assertEq(autoExit.TWAPSeconds(), 120);

        vm.expectRevert(Constants.InvalidConfig.selector);
        autoExit.setTWAPConfig(maxTWAPTickDifference, 30);

        uint32 twapSeconds = autoExit.TWAPSeconds();
        autoExit.setTWAPConfig(5, twapSeconds);
        assertEq(autoExit.maxTWAPTickDifference(), 5);

        vm.expectRevert(Constants.InvalidConfig.selector);
        autoExit.setTWAPConfig(201, twapSeconds);

        assertFalse(autoExit.operators(BOB));
        autoExit.setOperator(BOB, true);
        assertTrue(autoExit.operators(BOB));

        vm.expectRevert(Automator.ZeroAddress.selector);
        autoExit.setOperator(address(0), true);

        vm.expectRevert(Automator.ZeroAddress.selector);
        autoExit.setWithdrawer(address(0));
    }

    function testAutoExitConfigAuthorizationResetAndInvalidConfig() external {
        uint64 maxReward = autoExit.MAX_REWARD_X64();
        AutoExit.PositionConfig memory config =
            AutoExit.PositionConfig(true, false, false, -10, 10, 1, 2, false, maxReward);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(BOB);
        autoExit.configToken(TOKEN_ID, address(staker), config);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(ALICE);
        autoExit.configToken(TOKEN_ID, address(0xDEAD), config);

        vm.expectRevert(Constants.InvalidConfig.selector);
        vm.prank(ALICE);
        autoExit.configToken(
            TOKEN_ID, address(staker), AutoExit.PositionConfig(true, false, false, 10, 10, 0, 0, false, maxReward)
        );

        vm.expectRevert(Constants.InvalidConfig.selector);
        vm.prank(ALICE);
        autoExit.configToken(
            TOKEN_ID, address(staker), AutoExit.PositionConfig(true, false, false, -10, 10, 0, 0, false, maxReward + 1)
        );

        vm.prank(ALICE);
        autoExit.configToken(TOKEN_ID, address(staker), config);
        (
            bool active,,,
            int24 token0TriggerTick,
            int24 token1TriggerTick,
            uint64 token0SlippageX64,
            uint64 token1SlippageX64,,
            uint64 maxRewardX64
        ) = autoExit.positionConfigs(TOKEN_ID);
        assertTrue(active);
        assertEq(token0TriggerTick, -10);
        assertEq(token1TriggerTick, 10);
        assertEq(token0SlippageX64, 1);
        assertEq(token1SlippageX64, 2);
        assertEq(maxRewardX64, maxReward);

        vm.prank(ALICE);
        autoExit.configToken(
            TOKEN_ID, address(staker), AutoExit.PositionConfig(false, false, false, 0, 0, 0, 0, false, 0)
        );
        (active,,,,,,,,) = autoExit.positionConfigs(TOKEN_ID);
        assertFalse(active);
    }

    function testAutoExitPaysLogicalOwnerAndLeavesEmptyResidualWithdrawable() external {
        vm.prank(OPERATOR);
        autoExit.executeWithPancakeStaker(AutoExit.ExecuteParams(TOKEN_ID, "", 0, 0, 1, 0), address(staker));

        assertEq(token0.balanceOf(ALICE), 100);
        assertEq(token1.balanceOf(ALICE), 100);
        assertEq(npm.ownerOf(TOKEN_ID), address(staker));
        assertEq(staker.ownerOf(TOKEN_ID), ALICE);

        vm.prank(ALICE);
        staker.unstakePosition(TOKEN_ID, RECIPIENT);
        assertEq(npm.ownerOf(TOKEN_ID), RECIPIENT);
        assertEq(staker.ownerOf(TOKEN_ID), address(0));
    }

    function testAutoExitWorksForOwnerHeldPosition() external {
        npm.mintPosition(ALICE, DIRECT_TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 0, 0);

        vm.startPrank(ALICE);
        npm.approve(address(autoExit), DIRECT_TOKEN_ID);
        autoExit.configToken(DIRECT_TOKEN_ID, AutoExit.PositionConfig(true, false, false, 1, 100, 0, 0, false, 0));
        vm.stopPrank();

        vm.prank(OPERATOR);
        autoExit.execute(AutoExit.ExecuteParams(DIRECT_TOKEN_ID, "", 0, 0, 1, 0));

        assertEq(token0.balanceOf(ALICE), 100);
        assertEq(token1.balanceOf(ALICE), 100);
        assertEq(npm.ownerOf(DIRECT_TOKEN_ID), ALICE);
        assertEq(staker.ownerOf(DIRECT_TOKEN_ID), address(0));
    }

    function testAutoExitDirectRejectsWithoutConfig() external {
        npm.mintPosition(ALICE, DIRECT_TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 0, 0);

        vm.prank(ALICE);
        npm.approve(address(autoExit), DIRECT_TOKEN_ID);

        vm.expectRevert(Constants.NotConfigured.selector);
        vm.prank(OPERATOR);
        autoExit.execute(AutoExit.ExecuteParams(DIRECT_TOKEN_ID, "", 0, 0, 1, 0));
    }

    function testAutoExitDirectRejectsWithoutApproval() external {
        npm.mintPosition(ALICE, UNAPPROVED_DIRECT_TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 0, 0);
        uint64 maxReward = autoExit.MAX_REWARD_X64();

        vm.prank(ALICE);
        autoExit.configToken(
            UNAPPROVED_DIRECT_TOKEN_ID, AutoExit.PositionConfig(true, false, false, 1, 100, 0, 0, false, maxReward)
        );

        vm.expectRevert("not approved");
        vm.prank(OPERATOR);
        autoExit.execute(AutoExit.ExecuteParams(UNAPPROVED_DIRECT_TOKEN_ID, "", 0, 0, 1, 0));
    }

    function testAutoExitRejectsNonOperatorAndMissingTransformApproval() external {
        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(ALICE);
        autoExit.executeWithPancakeStaker(AutoExit.ExecuteParams(TOKEN_ID, "", 0, 0, 1, 0), address(staker));

        vm.prank(ALICE);
        staker.approveTransform(TOKEN_ID, address(autoExit), false);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(OPERATOR);
        autoExit.executeWithPancakeStaker(AutoExit.ExecuteParams(TOKEN_ID, "", 0, 0, 1, 0), address(staker));
    }

    function testAutoExitRejectsMissingSwapDataWhenSwapConfigured() external {
        uint64 maxReward = autoExit.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoExit.configToken(
            TOKEN_ID, address(staker), AutoExit.PositionConfig(true, true, false, 1, 100, 0, 0, false, maxReward)
        );

        vm.expectRevert(Constants.MissingSwapData.selector);
        vm.prank(OPERATOR);
        autoExit.executeWithPancakeStaker(AutoExit.ExecuteParams(TOKEN_ID, "", 0, 0, 1, 0), address(staker));
    }

    function testAutoExitSwapsToTargetTokenWhenSwapDataProvided() external {
        uint64 maxReward = autoExit.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoExit.configToken(
            TOKEN_ID, address(staker), AutoExit.PositionConfig(true, true, false, 1, 100, 0, 0, false, maxReward)
        );

        bytes memory swapData =
            abi.encodeCall(PancakeMockRouter.swapExact, (token0, token1, uint256(100), uint256(100)));

        vm.prank(OPERATOR);
        autoExit.executeWithPancakeStaker(AutoExit.ExecuteParams(TOKEN_ID, swapData, 0, 0, 1, 0), address(staker));

        assertEq(token0.balanceOf(ALICE), 0);
        assertEq(token1.balanceOf(ALICE), 200);
    }

    function testAutoExitRejectsWhenNotConfigured() external {
        vm.prank(ALICE);
        autoExit.configToken(
            TOKEN_ID, address(staker), AutoExit.PositionConfig(false, false, false, 0, 0, 0, 0, false, 0)
        );

        vm.expectRevert(Constants.NotConfigured.selector);
        vm.prank(OPERATOR);
        autoExit.executeWithPancakeStaker(AutoExit.ExecuteParams(TOKEN_ID, "", 0, 0, 1, 0), address(staker));
    }

    function testAutoExitRejectsWhenTriggerNotReady() external {
        uint64 maxReward = autoExit.MAX_REWARD_X64();
        vm.prank(ALICE);
        autoExit.configToken(
            TOKEN_ID, address(staker), AutoExit.PositionConfig(true, false, false, -10, 10, 0, 0, false, maxReward)
        );

        vm.expectRevert(Constants.NotReady.selector);
        vm.prank(OPERATOR);
        autoExit.executeWithPancakeStaker(AutoExit.ExecuteParams(TOKEN_ID, "", 0, 0, 1, 0), address(staker));
    }

    function testAutoExitRejectsNoLiquidityPosition() external {
        npm.mintPosition(ALICE, NO_LIQUIDITY_TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 0, 0, 0);

        vm.startPrank(ALICE);
        npm.approve(address(staker), NO_LIQUIDITY_TOKEN_ID);
        staker.stakePosition(NO_LIQUIDITY_TOKEN_ID, ALICE);
        staker.approveTransform(NO_LIQUIDITY_TOKEN_ID, address(autoExit), true);
        autoExit.configToken(
            NO_LIQUIDITY_TOKEN_ID,
            address(staker),
            AutoExit.PositionConfig(true, false, false, 1, 100, 0, 0, false, autoExit.MAX_REWARD_X64())
        );
        vm.stopPrank();

        vm.expectRevert(Constants.NoLiquidity.selector);
        vm.prank(OPERATOR);
        autoExit.executeWithPancakeStaker(
            AutoExit.ExecuteParams(NO_LIQUIDITY_TOKEN_ID, "", 0, 0, 1, 0), address(staker)
        );
    }

    function testAutoExitRejectsRewardAboveCap() external {
        uint64 tooHighReward = autoExit.MAX_REWARD_X64() + 1;

        vm.expectRevert(Constants.InvalidConfig.selector);
        vm.prank(ALICE);
        autoExit.configToken(
            TOKEN_ID, address(staker), AutoExit.PositionConfig(true, false, false, 1, 100, 0, 0, false, tooHighReward)
        );
    }
}
