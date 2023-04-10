// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../TestBase.sol";

contract RangeAdjustModuleTest is TestBase {
   
    uint8 moduleIndex;

    function setUp() external {
        _setupBase();
        moduleIndex = _setupRangeAdjustModule(0);
    }

    function testDirectSendNFT() external {
        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(abi.encodePacked("ERC721: transfer to non ERC721Receiver implementer")); // NFT manager doesnt resend original error for some reason
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, address(rangeAdjustModule), TEST_NFT);
    }

    function testSetTWAPSeconds() external {
        uint16 maxTWAPTickDifference = rangeAdjustModule.maxTWAPTickDifference();
        rangeAdjustModule.setTWAPConfig(120, maxTWAPTickDifference);
        assertEq(rangeAdjustModule.TWAPSeconds(), 120);

        vm.expectRevert(RangeAdjustModule.InvalidConfig.selector);
        rangeAdjustModule.setTWAPConfig(60, maxTWAPTickDifference);
    }

    function testSetMaxTWAPTickDifference() external {
        uint32 TWAPSeconds = rangeAdjustModule.TWAPSeconds();
        rangeAdjustModule.setTWAPConfig(TWAPSeconds, 5);
        assertEq(rangeAdjustModule.maxTWAPTickDifference(), 5);

        vm.expectRevert(RangeAdjustModule.InvalidConfig.selector);
        rangeAdjustModule.setTWAPConfig(TWAPSeconds, 10);
    }

    function testSetOperator() external {
        assertEq(rangeAdjustModule.operator(), OPERATOR_ACCOUNT);
        rangeAdjustModule.setOperator(TEST_NFT_ACCOUNT);
        assertEq(rangeAdjustModule.operator(), TEST_NFT_ACCOUNT);
    }


    function testUnauthorizedSetConfig() external {
        vm.expectRevert(Module.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        rangeAdjustModule.addTokenDirect(TEST_NFT_2, RangeAdjustModule.PositionConfig(0, 0, 0, 1, 0, 0));
    }

    function testResetConfig() external {
        vm.prank(TEST_NFT_ACCOUNT);
        rangeAdjustModule.addTokenDirect(TEST_NFT, RangeAdjustModule.PositionConfig(0, 0, 0, 0, 0, 0));
    }

    function testInvalidConfig() external {
        vm.expectRevert(RangeAdjustModule.InvalidConfig.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        rangeAdjustModule.addTokenDirect(TEST_NFT, RangeAdjustModule.PositionConfig(0, 0, 1, 0, 0, 0));
    }

    function testValidSetConfig() external {
        vm.prank(TEST_NFT_ACCOUNT);
        RangeAdjustModule.PositionConfig memory configIn = RangeAdjustModule.PositionConfig(1, -1, 0, 1, 123, 456);
        rangeAdjustModule.addTokenDirect(TEST_NFT, configIn);
        (int32 i1, int32 i2, int32 i3, int32 i4, uint64 i5, uint64 i6) = rangeAdjustModule.positionConfigs(TEST_NFT);
        assertEq(abi.encode(configIn), abi.encode(RangeAdjustModule.PositionConfig(i1, i2, i3, i4, i5, i6)));
    }

    function testNonOperator() external {
        vm.expectRevert(Module.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        rangeAdjustModule.execute(RangeAdjustModule.ExecuteParams(TEST_NFT, false, 0, "", block.timestamp));
    }

    function testAdjustWithoutApprove() external {
        // out of range position
        vm.prank(TEST_NFT_2_ACCOUNT);
        rangeAdjustModule.addTokenDirect(TEST_NFT_2, RangeAdjustModule.PositionConfig(0, 0, 0, 1, 0, 0));

        // fails when sending NFT
        vm.expectRevert(abi.encodePacked("Not approved"));
        
        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustModule.execute(RangeAdjustModule.ExecuteParams(TEST_NFT_2, false, 0, "", block.timestamp));
    }

    function testAdjustWithoutConfig() external {

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.setApprovalForAll(address(rangeAdjustModule), true);

        vm.expectRevert(RangeAdjustModule.NotConfigured.selector);
        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustModule.execute(RangeAdjustModule.ExecuteParams(TEST_NFT, false, 0, "", block.timestamp));
    }

    function testAdjustNotAdjustable() external {
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(rangeAdjustModule), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        rangeAdjustModule.addTokenDirect(TEST_NFT_2_A, RangeAdjustModule.PositionConfig(0, 0, 0, 60, uint64(Q64 / 100), uint64(Q64 / 100))); // 1% max fee, 1% max slippage

        // in range position cant be adjusted
        vm.expectRevert(RangeAdjustModule.NotReady.selector);
        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustModule.execute(RangeAdjustModule.ExecuteParams(TEST_NFT_2_A, false, 0, "", block.timestamp));
    }

    function testAdjustOutOfRange() external {
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(rangeAdjustModule), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        rangeAdjustModule.addTokenDirect(TEST_NFT_2, RangeAdjustModule.PositionConfig(0, 0, -int32(uint32(type(uint24).max)), int32(uint32(type(uint24).max)), 0, 0)); // 1% max fee, 1% max slippage

        // will be reverted because range Arithmetic over/underflow
        vm.expectRevert(abi.encodePacked("SafeCast: value doesn't fit in 24 bits"));
        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustModule.execute(RangeAdjustModule.ExecuteParams(TEST_NFT_2, false, 0, "", block.timestamp));
    }

    function testAdjustWithoutSwap() external {

        // using out of range position TEST_NFT_2
        // available amounts -> 311677619940061890346 506903060556612041
        // added to new position -> 311677619940061890345 77467250371417094
        
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(rangeAdjustModule), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        rangeAdjustModule.addTokenDirect(TEST_NFT_2, RangeAdjustModule.PositionConfig(0, 0, 0, 60, uint64(Q64 / 100), uint64(Q64 / 100))); // 1% max fee, 1% max slippage
        uint count = NPM.balanceOf(TEST_NFT_2_ACCOUNT);
        assertEq(count, 4);

        uint protocolDAIBalanceBefore = DAI.balanceOf(address(rangeAdjustModule));
        uint protocolWETHBalanceBefore = WETH_ERC20.balanceOf(address(rangeAdjustModule));

        uint ownerDAIBalanceBefore = DAI.balanceOf(TEST_NFT_2_ACCOUNT);
        uint ownerWETHBalanceBefore = TEST_NFT_2_ACCOUNT.balance;

        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustModule.execute(RangeAdjustModule.ExecuteParams(TEST_NFT_2, false, 0, "", block.timestamp)); // max fee with 1% is 7124618988448545

        // is not adjustable yet because config was removed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(RangeAdjustModule.NotConfigured.selector);
        rangeAdjustModule.execute(RangeAdjustModule.ExecuteParams(TEST_NFT_2, false, 0, "", block.timestamp));

        // protocol fee
        assertEq(DAI.balanceOf(address(rangeAdjustModule)) - protocolDAIBalanceBefore, 1558388099700309450);
        assertEq(WETH_ERC20.balanceOf(address(rangeAdjustModule)) - protocolWETHBalanceBefore, 2534515302783060);

        // leftovers returned to owner
        assertEq(DAI.balanceOf(TEST_NFT_2_ACCOUNT) - ownerDAIBalanceBefore, 0); // all was added to position
        assertEq(TEST_NFT_2_ACCOUNT.balance - ownerWETHBalanceBefore, 427288631134268972); // leftover + fee + deposited = total in old position

        count = NPM.balanceOf(TEST_NFT_2_ACCOUNT);
        assertEq(count, 5);

        // new NFT is latest NFT - because of the order they are added
        uint tokenId = NPM.tokenOfOwnerByIndex(TEST_NFT_2_ACCOUNT, count - 1);

        // is not adjustable yet because in range
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(RangeAdjustModule.NotReady.selector);
        rangeAdjustModule.execute(RangeAdjustModule.ExecuteParams(tokenId, false, 0, "", block.timestamp));

        // newly minted token
        assertEq(tokenId, 309207);

        (, , , , , int24 tickLowerAfter, int24 tickUpperAfter , uint128 liquidity, , , , ) = NPM.positions(tokenId);
        (, , address token0 , address token1 , uint24 fee , , , uint128 liquidityOld, , , , ) = NPM.positions(TEST_NFT_2);

        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(FACTORY, PoolAddress.getPoolKey(token0, token1, fee)));
        (uint160 sqrtPriceX96, int24 currentTick,,,,,) = pool.slot0();

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLowerAfter), TickMath.getSqrtRatioAtTick(tickUpperAfter), liquidity);

        // new position amounts
        assertEq(amount0, 310119231840361580895); //DAI
        assertEq(amount1, 77079914119560008); //WETH

        // check tick range correct
        assertEq(tickLowerAfter, -73260);
        assertEq(currentTick,  -73244);
        assertEq(tickUpperAfter, -73260 + 60);

        assertEq(liquidity, 3658702973175179764265);
        assertEq(liquidityOld, 0);
    }

    function testAdjustWithSwap() external {

        // using out of range position TEST_NFT_2
        // available amounts -> DAI 311677619940061890346 WETH 506903060556612041
        // swapping 0.3 WETH -> DAI (so more can be added to new position) 
        // added to new position -> 767197802262466967698 190686467137733081
        
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(rangeAdjustModule), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        rangeAdjustModule.addTokenDirect(TEST_NFT_2, RangeAdjustModule.PositionConfig(0, 0, 0, 60, uint64(Q64 / 100), uint64(Q64 / 100))); // 1% max fee, 1% max slippage
       
        uint protocolDAIBalanceBefore = DAI.balanceOf(address(rangeAdjustModule));
        uint protocolWETHBalanceBefore = WETH_ERC20.balanceOf(address(rangeAdjustModule));

        uint ownerDAIBalanceBefore = DAI.balanceOf(TEST_NFT_2_ACCOUNT);
        uint ownerWETHBalanceBefore = TEST_NFT_2_ACCOUNT.balance;

        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustModule.execute(RangeAdjustModule.ExecuteParams(TEST_NFT_2, false, 300000000000000000, _get03WETHToDAISwapData(), block.timestamp)); // max fee with 1% is 7124618988448545

        // protocol fee
        assertEq(DAI.balanceOf(address(rangeAdjustModule)) - protocolDAIBalanceBefore, 3835989011312334835);
        assertEq(WETH_ERC20.balanceOf(address(rangeAdjustModule)) - protocolWETHBalanceBefore, 1034515302783060);

        // leftovers returned to owner
        assertEq(DAI.balanceOf(TEST_NFT_2_ACCOUNT) - ownerDAIBalanceBefore, 0); // all was added to position
        assertEq(TEST_NFT_2_ACCOUNT.balance - ownerWETHBalanceBefore, 16135510451784564); // leftover + fee + deposited = total in old position

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
        assertEq(amount0, 763361813251154632863); //DAI
        assertEq(amount1, 189733034802044416); //WETH

        // check tick range correct
        assertEq(tickLowerAfter, -73260);
        assertEq(currentTick,  -73244);
        assertEq(tickUpperAfter, -73260 + 60);

        assertEq(liquidity, 9005936585023173514183);
        assertEq(liquidityOld, 0);
    }

    function testDoubleAdjust() external {
                
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(rangeAdjustModule), true);

        // bad config so it can be adjusted multiple times
        vm.prank(TEST_NFT_2_ACCOUNT);
        rangeAdjustModule.addTokenDirect(TEST_NFT_2, RangeAdjustModule.PositionConfig(-100000, -100000, 0, 60, uint64(Q64 / 100), uint64(Q64 / 100)));

        // first adjust ok
        vm.prank(OPERATOR_ACCOUNT);
        rangeAdjustModule.execute(RangeAdjustModule.ExecuteParams(TEST_NFT_2, false, 0, "", block.timestamp));

        uint count = NPM.balanceOf(TEST_NFT_2_ACCOUNT);
        uint tokenId = NPM.tokenOfOwnerByIndex(TEST_NFT_2_ACCOUNT, count - 1);

        // newly minted token
        assertEq(tokenId, 309207);

        // second ajust leads to same range error
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(RangeAdjustModule.SameRange.selector);
        rangeAdjustModule.execute(RangeAdjustModule.ExecuteParams(tokenId, false, 0, "", block.timestamp));
    }

    function testOracleCheck() external {

        // create range adjustor with more strict oracle config    
        rangeAdjustModule = new RangeAdjustModule(NPM, EX0x, OPERATOR_ACCOUNT, 60 * 30, 4);

        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(rangeAdjustModule), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        rangeAdjustModule.addTokenDirect(TEST_NFT_2, RangeAdjustModule.PositionConfig(-100000, -100000, 0, 60, uint64(Q64 / 100), uint64(Q64 / 100)));

        // TWAPCheckFailed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(Module.TWAPCheckFailed.selector);
        rangeAdjustModule.execute(RangeAdjustModule.ExecuteParams(TEST_NFT_2, false, 0, "", block.timestamp));
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