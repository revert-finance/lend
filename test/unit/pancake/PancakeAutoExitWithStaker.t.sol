// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/automators/AutoExit.sol";
import "../../../src/automators/PancakeMasterChefV3Staker.sol";
import "../../../src/utils/Constants.sol";
import "./PancakeMasterChefV3Mocks.sol";

contract PancakeAutoExitWithStakerTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant OPERATOR = address(0x0A);
    address internal constant WITHDRAWER = address(0x0B);
    address internal constant RECIPIENT = address(0xCAFE);

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant DIRECT_TOKEN_ID = 2;
    uint24 internal constant FEE = 500;

    PancakeMockERC20 internal cake;
    PancakeMockERC20 internal token0;
    PancakeMockERC20 internal token1;
    PancakeMockFactory internal factory;
    PancakeMockPool internal pool;
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
        factory.setPool(address(token0), address(token1), FEE, address(pool));

        npm = new PancakeMockNPM(address(factory), address(cake));
        masterChef = new PancakeMockMasterChef(address(cake), address(npm));
        staker = new PancakeMasterChefV3Staker(
            INonfungiblePositionManager(address(npm)), IPancakeMasterChefV3(address(masterChef)), IERC20(address(cake))
        );
        autoExit = new AutoExit(
            INonfungiblePositionManager(address(npm)), OPERATOR, WITHDRAWER, 60, 100, address(0), address(0)
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

    function testAutoExitRejectsRewardAboveCap() external {
        uint64 tooHighReward = autoExit.MAX_REWARD_X64() + 1;

        vm.expectRevert(Constants.InvalidConfig.selector);
        vm.prank(ALICE);
        autoExit.configToken(
            TOKEN_ID, address(staker), AutoExit.PositionConfig(true, false, false, 1, 100, 0, 0, false, tooHighReward)
        );
    }
}
