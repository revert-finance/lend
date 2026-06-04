// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/automators/PancakeMasterChefV3Staker.sol";
import "../../../src/transformers/AutoRange.sol";
import "../../../src/utils/Constants.sol";
import "./PancakeMasterChefV3Mocks.sol";

contract PancakeAutoRangeWithStakerTest is Test {
    address internal constant ALICE = address(0xA11CE);
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

        npm = new PancakeMockNPM(address(factory), address(token0));
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
