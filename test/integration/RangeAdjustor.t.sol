// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../TestBase.sol";

contract RangeAdjustorIntegrationTest is TestBase {
   
    function setUp() external {
        _setupBase();
    }

    function testSetOperator() external {
        assertEq(rangeAdjustor.operator(), OPERATOR_ACCOUNT);
        rangeAdjustor.setOperator(TEST_NFT_ACCOUNT);
        assertEq(rangeAdjustor.operator(), TEST_NFT_ACCOUNT);
    }

    function testUnauthorizedSetConfig() external {
        vm.expectRevert(RangeAdjustor.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        rangeAdjustor.setConfig(TEST_NFT_2, RangeAdjustor.PositionConfig(0, 0, 0, 1, 0, 0));
    }

    function testResetConfig() external {
        vm.prank(TEST_NFT_ACCOUNT);
        rangeAdjustor.setConfig(TEST_NFT, RangeAdjustor.PositionConfig(0, 0, 0, 0, 0, 0));
    }

    function testInvalidConfig() external {
        vm.expectRevert(RangeAdjustor.InvalidConfig.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        rangeAdjustor.setConfig(TEST_NFT, RangeAdjustor.PositionConfig(0, 0, 1, 0, 0, 0));
    }

    function testValidSetConfig() external {
        vm.prank(TEST_NFT_ACCOUNT);
        RangeAdjustor.PositionConfig memory configIn = RangeAdjustor.PositionConfig(1, -1, 0, 1, 123, 456);
        rangeAdjustor.setConfig(TEST_NFT, configIn);
        (int32 i1, int32 i2, int32 i3, int32 i4, uint64 i5, uint64 i6) = rangeAdjustor.configs(TEST_NFT);
        assertEq(abi.encode(configIn), abi.encode(RangeAdjustor.PositionConfig(i1, i2, i3, i4, i5, i6)));
    }

    function testNonOperator() external {
        vm.expectRevert(RangeAdjustor.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        rangeAdjustor.adjust(RangeAdjustor.AdjustParams(TEST_NFT, false, 0, "", block.timestamp, false, 0));
    }

    function testAdjustWithoutApprove() external {
        // out of range position
        vm.prank(TEST_NFT_2_ACCOUNT);
        rangeAdjustor.setConfig(TEST_NFT_2, RangeAdjustor.PositionConfig(0, 0, 0, 1, 0, 0));

        // fails when sending NFT
        vm.expectRevert(abi.encodePacked("ERC721: transfer caller is not owner nor approved"));
        
        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustor.adjust(RangeAdjustor.AdjustParams(TEST_NFT_2, false, 0, "", block.timestamp, false, 0));
    }

    function testAdjustWithoutConfig() external {

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.setApprovalForAll(address(rangeAdjustor), true);

        vm.expectRevert(RangeAdjustor.NotConfigured.selector);
        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustor.adjust(RangeAdjustor.AdjustParams(TEST_NFT, false, 0, "", block.timestamp, false, 0));
    }

    function testAdjustNotAdjustable() external {
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(rangeAdjustor), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        rangeAdjustor.setConfig(TEST_NFT_2_A, RangeAdjustor.PositionConfig(0, 0, 0, 60, uint64(Q64 / 100), uint64(Q64 / 100))); // 1% max fee, 1% max slippage

        // in range position cant be adjusted
        vm.expectRevert(RangeAdjustor.NotReady.selector);
        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustor.adjust(RangeAdjustor.AdjustParams(TEST_NFT_2_A, false, 0, "", block.timestamp, false, 0));
    }

    function testAdjustOutOfRange() external {
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(rangeAdjustor), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        rangeAdjustor.setConfig(TEST_NFT_2, RangeAdjustor.PositionConfig(0, 0, type(int32).min, type(int32).max, 0, 0)); // 1% max fee, 1% max slippage

        // will be reverted because range Arithmetic over/underflow
        vm.expectRevert();
        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustor.adjust(RangeAdjustor.AdjustParams(TEST_NFT_2, false, 0, "", block.timestamp, false, 0));
    }

    function testAdjustWithoutSwap() external {

        // using out of range position TEST_NFT_2
        // available amounts -> 311677619940061890346 506903060556612041
        // added to new position -> 311677619940061890345 77467250371417094
        
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(rangeAdjustor), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        rangeAdjustor.setConfig(TEST_NFT_2, RangeAdjustor.PositionConfig(0, 0, 0, 60, uint64(Q64 / 100), uint64(Q64 / 100))); // 1% max fee, 1% max slippage
        uint count = NPM.balanceOf(TEST_NFT_2_ACCOUNT);
        assertEq(count, 4);

        uint operatorBalanceBefore = WETH_ERC20.balanceOf(OPERATOR_ACCOUNT);
        uint ownerDAIBalanceBefore = DAI.balanceOf(TEST_NFT_2_ACCOUNT);
        uint ownerWETHBalanceBefore = WETH_ERC20.balanceOf(TEST_NFT_2_ACCOUNT);

        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustor.adjust(RangeAdjustor.AdjustParams(TEST_NFT_2, false, 0, "", block.timestamp, false, 1000000000)); // max fee with 1% is 7124618988448545

        // is not adjustable yet because config was removed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(RangeAdjustor.NotConfigured.selector);
        rangeAdjustor.adjust(RangeAdjustor.AdjustParams(TEST_NFT_2, false, 0, "", block.timestamp, false, 1000000000));

        // fee sent to operator
        assertEq(WETH_ERC20.balanceOf(OPERATOR_ACCOUNT) - operatorBalanceBefore, 1000000000);

        // leftovers returned to owner
        assertEq(DAI.balanceOf(TEST_NFT_2_ACCOUNT) - ownerDAIBalanceBefore, 0); // all was added to position
        assertEq(WETH_ERC20.balanceOf(TEST_NFT_2_ACCOUNT) - ownerWETHBalanceBefore, 429435809185194946); // leftover + fee + deposited = total in old position

        count = NPM.balanceOf(TEST_NFT_2_ACCOUNT);
        assertEq(count, 5);

        // new NFT is latest NFT - because of the order they are added
        uint tokenId = NPM.tokenOfOwnerByIndex(TEST_NFT_2_ACCOUNT, count - 1);

        // is not adjustable yet because in range
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(RangeAdjustor.NotReady.selector);
        rangeAdjustor.adjust(RangeAdjustor.AdjustParams(tokenId, false, 0, "", block.timestamp, false, 1000000000));

        // newly minted token
        assertEq(tokenId, 309207);

        (, , , , , int24 tickLowerAfter, int24 tickUpperAfter , uint128 liquidity, , , , ) = NPM.positions(tokenId);
        (, , address token0 , address token1 , uint24 fee , , , uint128 liquidityOld, , , , ) = NPM.positions(TEST_NFT_2);

        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(FACTORY, PoolAddress.getPoolKey(token0, token1, fee)));
        (uint160 sqrtPriceX96, int24 currentTick,,,,,) = pool.slot0();

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLowerAfter), TickMath.getSqrtRatioAtTick(tickUpperAfter), liquidity);

        // new position amounts
        assertEq(amount0, 311677619940061890345); //DAI
        assertEq(amount1, 77467250371417094); //WETH

        // check tick range correct
        assertEq(tickLowerAfter, -73260);
        assertEq(currentTick,  -73244);
        assertEq(tickUpperAfter, -73260 + 60);

        assertEq(liquidity, 3677088415251436948990);
        assertEq(liquidityOld, 0);
    }

    function testAdjustWithSwap() external {

        // using out of range position TEST_NFT_2
        // available amounts -> DAI 311677619940061890346 WETH 506903060556612041
        // swapping 0.3 WETH -> DAI (so more can be added to new position) 
        // added to new position -> 767197802262466967698 190686467137733081
        
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(rangeAdjustor), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        rangeAdjustor.setConfig(TEST_NFT_2, RangeAdjustor.PositionConfig(0, 0, 0, 60, uint64(Q64 / 100), uint64(Q64 / 100))); // 1% max fee, 1% max slippage
       
        uint operatorBalanceBefore = WETH_ERC20.balanceOf(OPERATOR_ACCOUNT);
        uint ownerDAIBalanceBefore = DAI.balanceOf(TEST_NFT_2_ACCOUNT);
        uint ownerWETHBalanceBefore = WETH_ERC20.balanceOf(TEST_NFT_2_ACCOUNT);

        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustor.adjust(RangeAdjustor.AdjustParams(TEST_NFT_2, false, 300000000000000000, _get03WETHToDAISwapData(), block.timestamp, false, 1000000000)); // max fee with 1% is 7124618988448545

        // fee sent to operator
        assertEq(WETH_ERC20.balanceOf(OPERATOR_ACCOUNT) - operatorBalanceBefore, 1000000000);

        // leftovers returned to owner
        assertEq(DAI.balanceOf(TEST_NFT_2_ACCOUNT) - ownerDAIBalanceBefore, 0); // all was added to position
        assertEq(WETH_ERC20.balanceOf(TEST_NFT_2_ACCOUNT) - ownerWETHBalanceBefore, 16216592418878959); // leftover + fee + deposited = total in old position

        uint count = NPM.balanceOf(TEST_NFT_2_ACCOUNT);

        // new NFT is latest NFT - because of the order they are added
        uint tokenId = NPM.tokenOfOwnerByIndex(TEST_NFT_2_ACCOUNT, count - 1);

        // newly minted token
        assertEq(tokenId, 309207);

        (, , , , , int24 tickLowerAfter, int24 tickUpperAfter , uint128 liquidity, , , , ) = NPM.positions(tokenId);
        (, , address token0 , address token1 , uint24 fee , , , uint128 liquidityOld, , , , ) = NPM.positions(TEST_NFT_2);

        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(FACTORY, PoolAddress.getPoolKey(token0, token1, fee)));
        (uint160 sqrtPriceX96, int24 currentTick,,,,,) = pool.slot0();

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLowerAfter), TickMath.getSqrtRatioAtTick(tickUpperAfter), liquidity);

        // new position amounts
        assertEq(amount0, 767197802262466967698); //DAI
        assertEq(amount1, 190686467137733081); //WETH

        // check tick range correct
        assertEq(tickLowerAfter, -73260);
        assertEq(currentTick,  -73244);
        assertEq(tickUpperAfter, -73260 + 60);

        assertEq(liquidity, 9051192547761983431298);
        assertEq(liquidityOld, 0);
    }

    function testDoubleAdjust() external {
                
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(rangeAdjustor), true);

        // bad config so it can be adjusted multiple times
        vm.prank(TEST_NFT_2_ACCOUNT);
        rangeAdjustor.setConfig(TEST_NFT_2, RangeAdjustor.PositionConfig(-100000, -100000, 0, 60, uint64(Q64 / 100), uint64(Q64 / 100)));

        // first adjust ok
        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustor.adjust(RangeAdjustor.AdjustParams(TEST_NFT_2, false, 0, "", block.timestamp, false, 7124618988448545));

        uint count = NPM.balanceOf(TEST_NFT_2_ACCOUNT);
        uint tokenId = NPM.tokenOfOwnerByIndex(TEST_NFT_2_ACCOUNT, count - 1);

        // newly minted token
        assertEq(tokenId, 309207);

        // second ajust leads to same range error
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(RangeAdjustor.SameRange.selector);
        rangeAdjustor.adjust(RangeAdjustor.AdjustParams(tokenId, false, 0, "", block.timestamp, false, 7124618988448545));
    }

    function _get03WETHToDAISwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=WETH&buyToken=DAI&sellAmount=300000000000000000&slippagePercentage=0.25
        return
            abi.encode(
                EX0x,
                hex"6af479b200000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000429d069189e00000000000000000000000000000000000000000000000000130ac08c36b9dfe37f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002bc02aaa39b223fe8d0a0e5c4f27ead9083c756cc20001f46b175474e89094c44da98b954eedeac495271d0f000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000ce62b248cc6402739e"
            );
    }
}