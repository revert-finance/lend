// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/automators/PancakeMasterChefV3Staker.sol";
import "../../../src/transformers/V3Utils.sol";
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

    function testStakePositionRejectsZeroRecipient() external {
        vm.startPrank(ALICE);
        npm.approve(address(staker), TOKEN_ID);
        vm.expectRevert(PancakeMasterChefV3Staker.ZeroAddress.selector);
        staker.stakePosition(TOKEN_ID, address(0));
        vm.stopPrank();
    }

    function testSafeTransferDepositStakesToEncodedRecipient() external {
        vm.prank(ALICE);
        npm.safeTransferFrom(ALICE, address(staker), TOKEN_ID, abi.encode(BOB));

        assertEq(staker.ownerOf(TOKEN_ID), BOB);
        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
        assertEq(masterChef.positionUser(TOKEN_ID), address(staker));
    }

    function testSetTransformerRejectsInvalidAddressesAndDeactivationBlocksTransform() external {
        PancakeNoopTransformer transformer = new PancakeNoopTransformer();

        vm.expectRevert(Constants.InvalidConfig.selector);
        staker.setTransformer(address(0), true);
        vm.expectRevert(Constants.InvalidConfig.selector);
        staker.setTransformer(address(staker), true);
        vm.expectRevert(Constants.InvalidConfig.selector);
        staker.setTransformer(address(masterChef), true);
        vm.expectRevert(Constants.InvalidConfig.selector);
        staker.setTransformer(address(npm), true);
        vm.expectRevert(Constants.InvalidConfig.selector);
        staker.setTransformer(address(cake), true);

        staker.setTransformer(address(transformer), true);
        staker.setTransformer(address(transformer), false);
        _stake();

        vm.expectRevert(Constants.TransformNotAllowed.selector);
        vm.prank(ALICE);
        staker.transform(TOKEN_ID, address(transformer), abi.encodeCall(PancakeNoopTransformer.execute, (TOKEN_ID)));
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

    function testTransformRejectsUnknownTransformer() external {
        _stake();
        PancakeNoopTransformer transformer = new PancakeNoopTransformer();

        vm.expectRevert(Constants.TransformNotAllowed.selector);
        vm.prank(ALICE);
        staker.transform(TOKEN_ID, address(transformer), abi.encodeCall(PancakeNoopTransformer.execute, (TOKEN_ID)));
    }

    function testApprovedTransformerCanTransformButUnapprovedCannot() external {
        _stake();
        PancakeNoopTransformer transformer = new PancakeNoopTransformer();
        staker.setTransformer(address(transformer), true);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(address(transformer));
        staker.transform(TOKEN_ID, address(transformer), abi.encodeCall(PancakeNoopTransformer.execute, (TOKEN_ID)));

        vm.prank(ALICE);
        staker.approveTransform(TOKEN_ID, address(transformer), true);

        vm.prank(address(transformer));
        uint256 finalTokenId = staker.transform(
            TOKEN_ID, address(transformer), abi.encodeCall(PancakeNoopTransformer.execute, (TOKEN_ID))
        );

        assertEq(finalTokenId, TOKEN_ID);
        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
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

    function testTransformRejectsUnexpectedMasterChefWithdrawalToStaker() external {
        uint256 otherTokenId = 3;
        _stake();

        PancakeMasterChefWithdrawTransformer transformer =
            new PancakeMasterChefWithdrawTransformer(INonfungiblePositionManager(address(npm)), masterChef);
        staker.setTransformer(address(transformer), true);

        npm.mintPosition(address(transformer), otherTokenId, address(token0), address(token1), FEE, -30, 30, 100, 0, 0);
        transformer.stakeOwned(otherTokenId);
        assertEq(masterChef.positionUser(otherTokenId), address(transformer));

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(ALICE);
        staker.transform(
            TOKEN_ID,
            address(transformer),
            abi.encodeCall(PancakeMasterChefWithdrawTransformer.withdrawOther, (otherTokenId))
        );

        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
        assertEq(npm.ownerOf(otherTokenId), address(masterChef));
    }

    function testTransformStakesEveryNewReceivedPositionForCurrentOwner() external {
        uint256 thirdTokenId = 3;
        _stake();

        PancakeMultiSendTransformer transformer =
            new PancakeMultiSendTransformer(INonfungiblePositionManager(address(npm)));
        staker.setTransformer(address(transformer), true);

        npm.mintPosition(address(transformer), NEW_TOKEN_ID, address(token0), address(token1), FEE, -20, 20, 200, 0, 0);
        npm.mintPosition(address(transformer), thirdTokenId, address(token0), address(token1), FEE, -30, 30, 300, 0, 0);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = NEW_TOKEN_ID;
        tokenIds[1] = thirdTokenId;

        vm.prank(ALICE);
        uint256 finalTokenId = staker.transform(
            TOKEN_ID, address(transformer), abi.encodeCall(PancakeMultiSendTransformer.sendMany, (tokenIds))
        );

        assertEq(finalTokenId, thirdTokenId);
        assertEq(staker.ownerOf(TOKEN_ID), ALICE);
        assertEq(staker.ownerOf(NEW_TOKEN_ID), ALICE);
        assertEq(staker.ownerOf(thirdTokenId), ALICE);
        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
        assertEq(npm.ownerOf(NEW_TOKEN_ID), address(masterChef));
        assertEq(npm.ownerOf(thirdTokenId), address(masterChef));
        assertEq(masterChef.positionUser(TOKEN_ID), address(staker));
        assertEq(masterChef.positionUser(NEW_TOKEN_ID), address(staker));
        assertEq(masterChef.positionUser(thirdTokenId), address(staker));
    }

    function testV3UtilsCompoundFeesThroughStakerKeepsPositionStaked() external {
        _stake();
        V3Utils v3Utils = _deployV3Utils();
        npm.setFees(TOKEN_ID, 25, 35);

        V3Utils.Instructions memory instructions = _baseV3Instructions(V3Utils.WhatToDo.COMPOUND_FEES);

        vm.prank(ALICE);
        uint256 finalTokenId =
            staker.transform(TOKEN_ID, address(v3Utils), abi.encodeCall(V3Utils.execute, (TOKEN_ID, instructions)));

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(TOKEN_ID);
        assertEq(finalTokenId, TOKEN_ID);
        assertEq(liquidity, 160);
        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
        assertEq(token0.balanceOf(ALICE), 0);
        assertEq(token1.balanceOf(ALICE), 0);
    }

    function testV3UtilsChangeRangeThroughStakerStakesNewPositionAndLeavesEmptyResidual() external {
        _stake();
        V3Utils v3Utils = _deployV3Utils();
        uint256 expectedNewTokenId = npm.nextTokenId();

        V3Utils.Instructions memory instructions = _baseV3Instructions(V3Utils.WhatToDo.CHANGE_RANGE);
        instructions.liquidity = 100;
        instructions.fee = FEE;
        instructions.tickLower = -20;
        instructions.tickUpper = 20;

        vm.prank(ALICE);
        uint256 finalTokenId =
            staker.transform(TOKEN_ID, address(v3Utils), abi.encodeCall(V3Utils.execute, (TOKEN_ID, instructions)));

        assertEq(finalTokenId, expectedNewTokenId);
        assertEq(staker.ownerOf(TOKEN_ID), ALICE);
        assertEq(staker.ownerOf(expectedNewTokenId), ALICE);
        assertEq(npm.ownerOf(TOKEN_ID), address(staker));
        assertEq(npm.ownerOf(expectedNewTokenId), address(masterChef));
        assertEq(masterChef.positionUser(expectedNewTokenId), address(staker));

        vm.prank(ALICE);
        staker.unstakePosition(TOKEN_ID, RECIPIENT);
        assertEq(npm.ownerOf(TOKEN_ID), RECIPIENT);
    }

    function testV3UtilsWithdrawAndCollectThroughStakerPaysOwnerAndLeavesEmptyResidual() external {
        _stake();
        V3Utils v3Utils = _deployV3Utils();

        V3Utils.Instructions memory instructions = _baseV3Instructions(V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP);
        instructions.liquidity = 100;
        instructions.targetToken = address(token0);

        vm.prank(ALICE);
        uint256 finalTokenId =
            staker.transform(TOKEN_ID, address(v3Utils), abi.encodeCall(V3Utils.execute, (TOKEN_ID, instructions)));

        assertEq(finalTokenId, TOKEN_ID);
        assertEq(token0.balanceOf(ALICE), 100);
        assertEq(token1.balanceOf(ALICE), 100);
        assertEq(npm.ownerOf(TOKEN_ID), address(staker));

        vm.prank(ALICE);
        staker.unstakePosition(TOKEN_ID, RECIPIENT);
        assertEq(npm.ownerOf(TOKEN_ID), RECIPIENT);
    }

    function _stake() internal {
        vm.startPrank(ALICE);
        npm.approve(address(staker), TOKEN_ID);
        staker.stakePosition(TOKEN_ID, ALICE);
        vm.stopPrank();
    }

    function _deployV3Utils() internal returns (V3Utils v3Utils) {
        v3Utils = new V3Utils(INonfungiblePositionManager(address(npm)), address(0), address(0), address(0));
        v3Utils.setPancakeStaker(address(staker));
        staker.setTransformer(address(v3Utils), true);
    }

    function _baseV3Instructions(V3Utils.WhatToDo whatToDo)
        internal
        view
        returns (V3Utils.Instructions memory instructions)
    {
        instructions.whatToDo = whatToDo;
        instructions.feeAmount0 = type(uint128).max;
        instructions.feeAmount1 = type(uint128).max;
        instructions.deadline = 1;
        instructions.recipient = ALICE;
        instructions.recipientNFT = address(staker);
    }
}
