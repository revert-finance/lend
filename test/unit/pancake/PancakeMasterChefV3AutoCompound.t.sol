// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/automators/Automator.sol";
import "../../../src/automators/PancakeMasterChefV3Staker.sol";
import "../../../src/transformers/PancakeMasterChefV3AutoCompound.sol";
import "../../../src/utils/Constants.sol";
import "./PancakeMasterChefV3Mocks.sol";

contract PancakeMasterChefV3AutoCompoundTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant OPERATOR = address(0x0A);
    address internal constant WITHDRAWER = address(0x0B);

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant CAKE_TOKEN_ID = 2;
    uint256 internal constant MISSING_POOL_TOKEN_ID = 3;
    uint256 internal constant DIRECT_TOKEN_ID = 4;
    uint24 internal constant FEE = 500;

    PancakeMockERC20 internal cake;
    PancakeMockERC20 internal token0;
    PancakeMockERC20 internal token1;
    PancakeMockFactory internal factory;
    PancakeMockPool internal pool;
    PancakeMockPool internal cakePool;
    PancakeMockPool internal cakeToken1Pool;
    PancakeMockNPM internal npm;
    PancakeMockMasterChef internal masterChef;
    PancakeMasterChefV3Staker internal staker;
    PancakeMasterChefV3AutoCompound internal autoCompound;

    function setUp() external {
        cake = new PancakeMockERC20("CAKE", "CAKE");
        token0 = new PancakeMockERC20("Token0", "TK0");
        token1 = new PancakeMockERC20("Token1", "TK1");
        factory = new PancakeMockFactory();

        pool = new PancakeMockPool(address(token0), address(token1), FEE);
        cakePool = new PancakeMockPool(address(cake), address(token0), FEE);
        cakeToken1Pool = new PancakeMockPool(address(cake), address(token1), FEE);
        factory.setPool(address(token0), address(token1), FEE, address(pool));
        factory.setPool(address(cake), address(token0), FEE, address(cakePool));
        factory.setPool(address(cake), address(token1), FEE, address(cakeToken1Pool));
        token0.mint(address(cakePool), 1_000_000);

        npm = new PancakeMockNPM(address(factory), address(token0));
        masterChef = new PancakeMockMasterChef(address(cake), address(npm));
        staker = new PancakeMasterChefV3Staker(
            INonfungiblePositionManager(address(npm)), IPancakeMasterChefV3(address(masterChef)), IERC20(address(cake))
        );
        autoCompound = new PancakeMasterChefV3AutoCompound(
            INonfungiblePositionManager(address(npm)),
            IERC20(address(cake)),
            OPERATOR,
            WITHDRAWER,
            60,
            100,
            address(0),
            address(0)
        );

        autoCompound.setPancakeStaker(address(staker));
        staker.setTransformer(address(autoCompound), true);

        npm.mintPosition(ALICE, TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 1_000, 1_000);
        npm.mintPosition(ALICE, CAKE_TOKEN_ID, address(cake), address(token1), FEE, -10, 10, 100, 0, 1_000);

        _stakeAndApprove(TOKEN_ID);
        _stakeAndApprove(CAKE_TOKEN_ID);
    }

    function testFeeOnlyCompoundUsesNormalTransformAndKeepsProtocolFees() external {
        PancakeMasterChefV3AutoCompound.ExecuteParams memory params = _params(TOKEN_ID);

        vm.prank(OPERATOR);
        autoCompound.executeWithPancakeStaker(params, address(staker));

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(TOKEN_ID);
        assertEq(liquidity, 2_060);
        assertEq(npm.ownerOf(TOKEN_ID), address(masterChef));
        assertEq(token0.balanceOf(ALICE), 1);
        assertEq(token1.balanceOf(ALICE), 1);
        assertEq(token0.balanceOf(address(autoCompound)), 19);
        assertEq(token1.balanceOf(address(autoCompound)), 19);
    }

    function testFeeOnlyCompoundWorksForOwnerHeldPosition() external {
        npm.mintPosition(ALICE, DIRECT_TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 1_000, 1_000);

        vm.prank(ALICE);
        npm.approve(address(autoCompound), DIRECT_TOKEN_ID);

        PancakeMasterChefV3AutoCompound.ExecuteParams memory params = _params(DIRECT_TOKEN_ID);

        vm.prank(OPERATOR);
        autoCompound.execute(params);

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(DIRECT_TOKEN_ID);
        assertEq(liquidity, 2_060);
        assertEq(npm.ownerOf(DIRECT_TOKEN_ID), ALICE);
        assertEq(staker.ownerOf(DIRECT_TOKEN_ID), address(0));
        assertEq(token0.balanceOf(ALICE), 1);
        assertEq(token1.balanceOf(ALICE), 1);
        assertEq(token0.balanceOf(address(autoCompound)), 19);
        assertEq(token1.balanceOf(address(autoCompound)), 19);
    }

    function testDirectFeeOnlyCompoundRejectsNonOperator() external {
        npm.mintPosition(ALICE, DIRECT_TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 1_000, 1_000);

        vm.prank(ALICE);
        npm.approve(address(autoCompound), DIRECT_TOKEN_ID);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(ALICE);
        autoCompound.execute(_params(DIRECT_TOKEN_ID));
    }

    function testConfiguredPositionRejectsTooSmallFeeCompound() external {
        uint64 maxReward = autoCompound.MAX_REWARD_X64();

        vm.prank(ALICE);
        autoCompound.configToken(
            TOKEN_ID,
            address(staker),
            PancakeMasterChefV3AutoCompound.CompoundConfig({
                configured: true,
                autoCompoundMin0: 2_000,
                autoCompoundMin1: 0,
                minCakeReward: 0,
                maxRewardX64: maxReward
            })
        );

        vm.expectRevert(Constants.NotEnoughReward.selector);
        vm.prank(OPERATOR);
        autoCompound.executeWithPancakeStaker(_params(TOKEN_ID), address(staker));
    }

    function testConfiguredPositionRejectsRewardAboveOwnerCap() external {
        vm.prank(ALICE);
        autoCompound.configToken(
            TOKEN_ID,
            address(staker),
            PancakeMasterChefV3AutoCompound.CompoundConfig({
                configured: true, autoCompoundMin0: 0, autoCompoundMin1: 0, minCakeReward: 0, maxRewardX64: 0
            })
        );

        vm.expectRevert(Constants.ExceedsMaxReward.selector);
        vm.prank(OPERATOR);
        autoCompound.executeWithPancakeStaker(_params(TOKEN_ID), address(staker));
    }

    function testConfiguredPositionRejectsTooSmallCakeReward() external {
        masterChef.setReward(TOKEN_ID, 100);
        uint64 maxReward = autoCompound.MAX_REWARD_X64();

        vm.prank(ALICE);
        autoCompound.configToken(
            TOKEN_ID,
            address(staker),
            PancakeMasterChefV3AutoCompound.CompoundConfig({
                configured: true, autoCompoundMin0: 0, autoCompoundMin1: 0, minCakeReward: 101, maxRewardX64: maxReward
            })
        );

        PancakeMasterChefV3AutoCompound.ExecuteParams memory params = _params(TOKEN_ID);
        params.cakeSplitBps = 10_000;
        params.token0CakePool = IUniswapV3Pool(address(cakePool));
        autoCompound.setRewardAnchor(address(token0), 1);

        vm.expectRevert(Constants.NotEnoughReward.selector);
        vm.prank(OPERATOR);
        autoCompound.executeWithRewardPancakeStaker(params, address(staker));
    }

    function testSetPancakeStakerRejectsZeroAddress() external {
        vm.expectRevert(Constants.InvalidConfig.selector);
        autoCompound.setPancakeStaker(address(0));
    }

    function testDeactivatedPancakeStakerCannotExecute() external {
        autoCompound.setPancakeStaker(address(staker), false);

        vm.expectRevert(Constants.Unauthorized.selector);
        vm.prank(OPERATOR);
        autoCompound.executeWithPancakeStaker(_params(TOKEN_ID), address(staker));
    }

    function testAutomatorRoleSettersRejectZeroAddress() external {
        vm.expectRevert(Automator.ZeroAddress.selector);
        autoCompound.setWithdrawer(address(0));

        vm.expectRevert(Automator.ZeroAddress.selector);
        autoCompound.setOperator(address(0), true);
    }

    function testAutomatorWithdrawalsRejectZeroRecipient() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token0);

        vm.startPrank(WITHDRAWER);
        vm.expectRevert(Automator.ZeroAddress.selector);
        autoCompound.withdrawBalances(tokens, address(0));

        vm.expectRevert(Automator.ZeroAddress.selector);
        autoCompound.withdrawETH(address(0));
        vm.stopPrank();
    }

    function testFeeOnlyCompoundRejectsMissingPositionPool() external {
        PancakeMockERC20 token2 = new PancakeMockERC20("Token2", "TK2");
        npm.mintPosition(
            ALICE, MISSING_POOL_TOKEN_ID, address(token0), address(token2), FEE, -10, 10, 100, 1_000, 1_000
        );
        _stakeAndApprove(MISSING_POOL_TOKEN_ID);

        PancakeMasterChefV3AutoCompound.ExecuteParams memory params = _params(MISSING_POOL_TOKEN_ID);

        vm.expectRevert(Constants.InvalidPool.selector);
        vm.prank(OPERATOR);
        autoCompound.executeWithPancakeStaker(params, address(staker));
    }

    function testRewardCompoundUsesRewardTransformAndCake() external {
        masterChef.setReward(CAKE_TOKEN_ID, 1_000);

        PancakeMasterChefV3AutoCompound.ExecuteParams memory params = _params(CAKE_TOKEN_ID);
        params.cakeSplitBps = 10_000;
        params.minCakeReward = 1_000;

        vm.prank(OPERATOR);
        autoCompound.executeWithPancakeStakerAndRewardCompound(params, address(staker));

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(CAKE_TOKEN_ID);
        assertEq(liquidity, 2_060);
        assertEq(npm.ownerOf(CAKE_TOKEN_ID), address(masterChef));
        assertEq(cake.balanceOf(ALICE), 1);
        assertEq(token1.balanceOf(ALICE), 1);
        assertEq(cake.balanceOf(address(autoCompound)), 19);
        assertEq(token1.balanceOf(address(autoCompound)), 19);
    }

    function testRewardCompoundRejectsNonCanonicalAnchorPool() external {
        masterChef.setReward(TOKEN_ID, 100);
        autoCompound.setRewardAnchor(address(token0), 1);
        PancakeMockPool roguePool = new PancakeMockPool(address(cake), address(token0), FEE);

        PancakeMasterChefV3AutoCompound.ExecuteParams memory params = _params(TOKEN_ID);
        params.cakeSplitBps = 10_000;
        params.token0CakePool = IUniswapV3Pool(address(roguePool));

        vm.expectRevert(Constants.InvalidPool.selector);
        vm.prank(OPERATOR);
        autoCompound.executeWithRewardPancakeStaker(params, address(staker));
    }

    function testRewardCompoundRevertsWhenPoolOutputBelowValidatedMinimum() external {
        masterChef.setReward(TOKEN_ID, 100);
        autoCompound.setRewardAnchor(address(token0), 1);
        cakePool.setOutputBps(100);

        PancakeMasterChefV3AutoCompound.ExecuteParams memory params = _params(TOKEN_ID);
        params.cakeSplitBps = 10_000;
        params.token0CakePool = IUniswapV3Pool(address(cakePool));

        vm.expectRevert(Constants.SlippageError.selector);
        vm.prank(OPERATOR);
        autoCompound.executeWithRewardPancakeStaker(params, address(staker));
    }

    function _stakeAndApprove(uint256 tokenId) internal {
        vm.startPrank(ALICE);
        npm.approve(address(staker), tokenId);
        staker.stakePosition(tokenId, ALICE);
        staker.approveTransform(tokenId, address(autoCompound), true);
        vm.stopPrank();
    }

    function _params(uint256 tokenId)
        internal
        pure
        returns (PancakeMasterChefV3AutoCompound.ExecuteParams memory params)
    {
        params.tokenId = tokenId;
        params.deadline = 1;
    }
}
