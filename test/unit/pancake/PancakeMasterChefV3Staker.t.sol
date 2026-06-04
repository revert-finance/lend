// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/automators/PancakeMasterChefV3Staker.sol";
import "../../../src/utils/Constants.sol";
import "./PancakeMasterChefV3Mocks.sol";

contract PancakeMasterChefV3StakerTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant RECIPIENT = address(0xCAFE);

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant NEW_TOKEN_ID = 2;
    uint24 internal constant FEE = 500;

    PancakeMockERC20 internal cake;
    PancakeMockERC20 internal token0;
    PancakeMockERC20 internal token1;
    PancakeMockFactory internal factory;
    PancakeMockPool internal pool;
    PancakeMockNPM internal npm;
    PancakeMockMasterChef internal masterChef;
    PancakeMasterChefV3Staker internal staker;

    function setUp() external {
        cake = new PancakeMockERC20("CAKE", "CAKE");
        token0 = new PancakeMockERC20("Token0", "TK0");
        token1 = new PancakeMockERC20("Token1", "TK1");
        factory = new PancakeMockFactory();
        pool = new PancakeMockPool(address(token0), address(token1), FEE);
        factory.setPool(address(token0), address(token1), FEE, address(pool));

        npm = new PancakeMockNPM(address(factory), address(token0));
        masterChef = new PancakeMockMasterChef(address(cake), address(npm));
        staker = new PancakeMasterChefV3Staker(
            INonfungiblePositionManager(address(npm)), IPancakeMasterChefV3(address(masterChef)), IERC20(address(cake))
        );

        npm.mintPosition(ALICE, TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 0, 0);
    }

    function testStakeRegistersStakerAsMasterChefUser() external {
        _stake();

        assertEq(staker.ownerOf(TOKEN_ID), ALICE);
        assertTrue(staker.isManaged(TOKEN_ID));
        assertTrue(staker.isStaked(TOKEN_ID));
        assertEq(staker.custodyOf(TOKEN_ID), address(masterChef));
        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
        assertEq(masterChef.positionUser(TOKEN_ID), address(staker));
    }

    function testMasterChefActionsAreGatedToStaker() external {
        _stake();
        masterChef.setReward(TOKEN_ID, 10 ether);

        vm.expectRevert("not MasterChef user");
        vm.prank(ALICE);
        masterChef.harvest(TOKEN_ID, ALICE);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(BOB);
        staker.claimRewards(TOKEN_ID, BOB);
    }

    function testClaimRewardsAndUnstakeSendCakeToRecipient() external {
        _stake();
        masterChef.setReward(TOKEN_ID, 10 ether);

        vm.prank(ALICE);
        uint256 claimed = staker.claimRewards(TOKEN_ID, RECIPIENT);
        assertEq(claimed, 10 ether);
        assertEq(cake.balanceOf(RECIPIENT), 10 ether);

        masterChef.setReward(TOKEN_ID, 3 ether);
        vm.prank(ALICE);
        uint256 withdrawnCake = staker.unstakePosition(TOKEN_ID, RECIPIENT);

        assertEq(withdrawnCake, 3 ether);
        assertEq(cake.balanceOf(RECIPIENT), 13 ether);
        assertEq(npm.ownerOf(TOKEN_ID), RECIPIENT);
        assertEq(staker.ownerOf(TOKEN_ID), address(0));
    }

    function testNormalTransformSendsCakeToOwnerAndRestakesOriginal() external {
        _stake();
        masterChef.setReward(TOKEN_ID, 5 ether);
        PancakeNoopTransformer transformer = new PancakeNoopTransformer();
        staker.setTransformer(address(transformer), true);

        vm.prank(ALICE);
        uint256 finalTokenId = staker.transform(
            TOKEN_ID, address(transformer), abi.encodeCall(PancakeNoopTransformer.execute, (TOKEN_ID))
        );

        assertEq(finalTokenId, TOKEN_ID);
        assertEq(cake.balanceOf(ALICE), 5 ether);
        assertEq(staker.ownerOf(TOKEN_ID), ALICE);
        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
        assertEq(masterChef.positionUser(TOKEN_ID), address(staker));
        assertEq(staker.transformedTokenId(), 0);
    }

    function testRewardTransformHandsCakeToTransformerAndRestakesOriginal() external {
        _stake();
        masterChef.setReward(TOKEN_ID, 7 ether);
        PancakeRewardTransformer transformer = new PancakeRewardTransformer(IERC20(address(cake)));
        staker.setTransformer(address(transformer), true);

        vm.prank(ALICE);
        uint256 finalTokenId = staker.transformWithRewardCompound(TOKEN_ID, address(transformer), "");

        assertEq(finalTokenId, TOKEN_ID);
        assertEq(transformer.lastCakeAmount(), 7 ether);
        assertEq(transformer.lastOwner(), ALICE);
        assertEq(cake.balanceOf(ALICE), 7 ether);
        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
        assertEq(staker.transformedTokenId(), 0);
    }

    function testCompoundRewardsAliasHandsCakeToTransformerAndRestakesOriginal() external {
        _stake();
        masterChef.setReward(TOKEN_ID, 7 ether);
        PancakeRewardTransformer transformer = new PancakeRewardTransformer(IERC20(address(cake)));
        staker.setTransformer(address(transformer), true);

        vm.prank(ALICE);
        uint256 finalTokenId = staker.compoundRewards(TOKEN_ID, address(transformer), "");

        assertEq(finalTokenId, TOKEN_ID);
        assertEq(transformer.lastCakeAmount(), 7 ether);
        assertEq(cake.balanceOf(ALICE), 7 ether);
        assertTrue(staker.isStaked(TOKEN_ID));
    }

    function testTransformNewTokenIsStakedAndOldEmptyResidualCanBeWithdrawn() external {
        _stake();
        PancakeReplaceTransformer transformer = new PancakeReplaceTransformer(INonfungiblePositionManager(address(npm)));
        staker.setTransformer(address(transformer), true);
        npm.mintPosition(address(transformer), NEW_TOKEN_ID, address(token0), address(token1), FEE, -20, 20, 200, 0, 0);

        vm.prank(ALICE);
        uint256 finalTokenId = staker.transform(
            TOKEN_ID,
            address(transformer),
            abi.encodeCall(PancakeReplaceTransformer.replace, (TOKEN_ID, NEW_TOKEN_ID, uint128(100), block.timestamp))
        );

        assertEq(finalTokenId, NEW_TOKEN_ID);
        assertEq(staker.ownerOf(TOKEN_ID), ALICE);
        assertEq(staker.ownerOf(NEW_TOKEN_ID), ALICE);
        assertEq(npm.ownerOf(TOKEN_ID), address(staker));
        assertEq(npm.ownerOf(NEW_TOKEN_ID), address(masterChef));

        vm.prank(ALICE);
        staker.unstakePosition(TOKEN_ID, RECIPIENT);
        assertEq(npm.ownerOf(TOKEN_ID), RECIPIENT);
        assertEq(staker.ownerOf(TOKEN_ID), address(0));
        assertEq(staker.ownerOf(NEW_TOKEN_ID), ALICE);
    }

    function _stake() internal {
        vm.startPrank(ALICE);
        npm.approve(address(staker), TOKEN_ID);
        staker.stakePosition(TOKEN_ID, ALICE);
        vm.stopPrank();
    }
}
