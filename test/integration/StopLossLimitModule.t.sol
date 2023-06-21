// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../TestBase.sol";

contract StopLossLimitModuleTest is TestBase {

    uint8 moduleIndex;

    function setUp() external {
        _setupBase();
        moduleIndex = _setupStopLossLimitModule(0);
    }

    function _addToModule(
        bool firstTime,
        uint tokenId,
        bool isActive,
        bool token0Swap,
        bool token1Swap,
        uint64 token0SlippageX64,
        uint64 token1SlippageX64,
        int24 token0TriggerTick,
        int24 token1TriggerTick
    ) internal {
        StopLossLimitModule.PositionConfig memory config = StopLossLimitModule.PositionConfig(
                isActive,
                token0Swap,
                token1Swap,
                token0TriggerTick,
                token1TriggerTick,
                token0SlippageX64,
                token1SlippageX64
            );

        IHolder.ModuleParams[] memory params = new IHolder.ModuleParams[](1);
        params[0] = IHolder.ModuleParams(moduleIndex, abi.encode(config));

        if (firstTime) {
            vm.prank(TEST_NFT_ACCOUNT);
            NPM.safeTransferFrom(
                TEST_NFT_ACCOUNT,
                address(holder),
                tokenId,
                abi.encode(params)
            );
        } else {
            vm.prank(TEST_NFT_ACCOUNT);
            holder.addTokenToModule(tokenId, params[0]);
        }
    }

    function testAddAndRemove() external {

        _addToModule(true, TEST_NFT, true, false, false, 0, 0, type(int24).min, type(int24).max);

        vm.prank(TEST_NFT_ACCOUNT);
        holder.removeTokenFromModule(TEST_NFT, moduleIndex);

        vm.prank(TEST_NFT_ACCOUNT);
        holder.withdrawToken(TEST_NFT, TEST_NFT_ACCOUNT, "");
    }

    function testNoLiquidity() external {
        _addToModule(true, TEST_NFT, true, false, false, 0, 0, type(int24).min, type(int24).max);

        (, , , , , , , uint128 liquidity, , , , ) = NPM.positions(TEST_NFT);

        assertEq(liquidity, 0);

        vm.expectRevert(StopLossLimitModule.NoLiquidity.selector);
        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT, "", block.timestamp));
    }

    function _addLiquidity() internal returns (uint256 amount0, uint256 amount1) {
         // add onesided liquidity
        vm.startPrank(TEST_NFT_ACCOUNT);
        DAI.approve(address(NPM), 1000000000000000000);
        (, amount0, amount1) = NPM.increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams(TEST_NFT, 1000000000000000000, 0, 0, 0, block.timestamp));

        assertEq(amount0, 999999999999999633);
        assertEq(amount1, 0);

        vm.stopPrank();
    }

    function testRangesAndActions() external {

        (uint amount0, uint amount1) = _addLiquidity();
        
        (, ,address token0, address token1, uint24 fee , int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) = NPM.positions(TEST_NFT);

        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(FACTORY, PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee})));

        (, int24 tick, , , , , ) = pool.slot0();

        assertGt(liquidity, 0);
        assertEq(tickLower, -276320);
        assertEq(tickUpper, -276310);
        assertEq(tick, -276325);
    
        _addToModule(true, TEST_NFT, true, false, false, 0, 0, -276325, type(int24).max);
        vm.expectRevert(StopLossLimitModule.NotInCondition.selector);
        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT, "", block.timestamp));

        uint balanceBeforeOwner = DAI.balanceOf(TEST_NFT_ACCOUNT);

        _addToModule(false, TEST_NFT, true, false, false, 0, 0, -276324, type(int24).max);

        // execute limit order - without swap
        vm.prank(OPERATOR_ACCOUNT); 
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT, "", block.timestamp));

        (, ,, , ,, ,liquidity, , , , ) = NPM.positions(TEST_NFT);
        assertEq(liquidity, 0);

        uint balanceAfterOwner = DAI.balanceOf(TEST_NFT_ACCOUNT);

        // check paid fee
        uint balanceBefore = DAI.balanceOf(address(this));
        stopLossLimitModule.withdrawBalance(address(DAI), address(this));
        uint balanceAfter = DAI.balanceOf(address(this));

        assertEq(balanceAfterOwner + balanceAfter - balanceBeforeOwner - balanceBefore + 1, amount0); // +1 because Uniswap imprecision (remove same liquidity returns 1 less)

        // cant execute again
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(StopLossLimitModule.NotConfigured.selector);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT, "", block.timestamp));

        // add new liquidity
        (amount0, amount1) = _addLiquidity();

        // change to swap
        _addToModule(false, TEST_NFT, true, true, true, uint64(Q64 / 100), uint64(Q64 / 100), -276324, type(int24).max);

        // execute without swap data fails because not allowed by config
        vm.expectRevert(StopLossLimitModule.MissingSwapData.selector);
        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT, "", block.timestamp));

        // execute stop loss order - with swap
        uint swapBalanceBefore = USDC.balanceOf(TEST_NFT_ACCOUNT);
        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT, _getDAIToUSDSwapData(), block.timestamp));
        uint swapBalanceAfter = USDC.balanceOf(TEST_NFT_ACCOUNT);
        
        // protocol fee
        balanceBefore = USDC.balanceOf(address(this));
        stopLossLimitModule.withdrawBalance(address(USDC), address(this));
        balanceAfter = USDC.balanceOf(address(this));

        assertEq(swapBalanceAfter - swapBalanceBefore, 988879);
        assertEq(balanceAfter - balanceBefore, 4969);
    }

     function testDirectSendNFT() external {
        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(abi.encodePacked("ERC721: transfer to non ERC721Receiver implementer")); // NFT manager doesnt resend original error for some reason
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, address(stopLossLimitModule), TEST_NFT);
    }

    function testSetTWAPSeconds() external {
        uint16 maxTWAPTickDifference = stopLossLimitModule.maxTWAPTickDifference();
        stopLossLimitModule.setTWAPConfig(maxTWAPTickDifference, 120);
        assertEq(stopLossLimitModule.TWAPSeconds(), 120);

        vm.expectRevert(Module.InvalidConfig.selector);
        stopLossLimitModule.setTWAPConfig(maxTWAPTickDifference, 60);
    }

    function testSetMaxTWAPTickDifference() external {
        uint32 TWAPSeconds = stopLossLimitModule.TWAPSeconds();
        stopLossLimitModule.setTWAPConfig(5, TWAPSeconds);
        assertEq(stopLossLimitModule.maxTWAPTickDifference(), 5);

        vm.expectRevert(Module.InvalidConfig.selector);
        stopLossLimitModule.setTWAPConfig(10, TWAPSeconds);
    }

    function testSetOperator() external {
        assertEq(stopLossLimitModule.operator(), OPERATOR_ACCOUNT);
        stopLossLimitModule.setOperator(TEST_NFT_ACCOUNT);
        assertEq(stopLossLimitModule.operator(), TEST_NFT_ACCOUNT);
    }


    function testUnauthorizedSetConfig() external {
        vm.expectRevert(Module.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        stopLossLimitModule.addTokenDirect(TEST_NFT_2, StopLossLimitModule.PositionConfig(false, false, false, 0, 0, 0, 0));
    }

    function testResetConfig() external {
        vm.prank(TEST_NFT_ACCOUNT);
        stopLossLimitModule.addTokenDirect(TEST_NFT, StopLossLimitModule.PositionConfig(false, false, false, 0, 0, 0, 0));
    }

    function testInvalidConfig() external {
        vm.expectRevert(Module.InvalidConfig.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        stopLossLimitModule.addTokenDirect(TEST_NFT, StopLossLimitModule.PositionConfig(true, false, false, 800000, -800000,  0, 0));
    }

    function testValidSetConfig() external {
        vm.prank(TEST_NFT_ACCOUNT);
        StopLossLimitModule.PositionConfig memory configIn = StopLossLimitModule.PositionConfig(true, false, false, -800000, 800000, 0, 0);
        stopLossLimitModule.addTokenDirect(TEST_NFT, configIn);
        (bool i1, bool i2, bool i3, int24 i4, int24 i5, uint64 i6, uint64 i7) = stopLossLimitModule.positionConfigs(TEST_NFT);
        assertEq(abi.encode(configIn), abi.encode(StopLossLimitModule.PositionConfig(i1, i2, i3, i4, i5, i6, i7)));
    }

    function testNonOperator() external {
        vm.expectRevert(Module.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT, "", block.timestamp));
    }

    function testRunWithoutApprove() external {
        // out of range position
        vm.prank(TEST_NFT_2_ACCOUNT);
        stopLossLimitModule.addTokenDirect(TEST_NFT_2, StopLossLimitModule.PositionConfig(true, false, false, -84121, -78240, 0, 0));

        // fails when sending NFT
        vm.expectRevert(abi.encodePacked("Not approved"));
        
        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_2, "", block.timestamp));
    }

    function testRunWithoutConfig() external {

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.setApprovalForAll(address(stopLossLimitModule), true);

        vm.expectRevert(StopLossLimitModule.NotConfigured.selector);
        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT, "", block.timestamp));
    }

    function testRunNotReady() external {
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(stopLossLimitModule), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        stopLossLimitModule.addTokenDirect(TEST_NFT_2_A, StopLossLimitModule.PositionConfig(true, false, false, -276331, -276320, 0, 0));

        // in range position cant be run
        vm.expectRevert(StopLossLimitModule.NotInCondition.selector);
        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_2_A, "", block.timestamp));
    }

    function testOracleCheck() external {

        // create range adjustor with more strict oracle config    
        stopLossLimitModule = new StopLossLimitModule(NPM, EX0x, OPERATOR_ACCOUNT, 60 * 30, 4);

        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(stopLossLimitModule), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        stopLossLimitModule.addTokenDirect(TEST_NFT_2, StopLossLimitModule.PositionConfig(true, true, true, -84121, -78240, uint64(Q64 / 100), uint64(Q64 / 100)));

        // TWAPCheckFailed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(Module.TWAPCheckFailed.selector);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_2, _getWETHToDAISwapData(), block.timestamp));
    }


    // tests LimitOrder without adding to module
    function testLimitOrder() external {

        // using out of range position TEST_NFT_2
        // available amounts -> DAI (fees) 311677619940061890346 WETH(fees + liquidity) 506903060556612041
        
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(stopLossLimitModule), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        stopLossLimitModule.addTokenDirect(TEST_NFT_2, StopLossLimitModule.PositionConfig(true, false, false, -84121, -78240, uint64(Q64 / 100), uint64(Q64 / 100))); // 1% max slippage

        uint contractWETHBalanceBefore = WETH_ERC20.balanceOf(address(stopLossLimitModule));
        uint contractDAIBalanceBefore = DAI.balanceOf(address(stopLossLimitModule));

        uint ownerDAIBalanceBefore = DAI.balanceOf(TEST_NFT_2_ACCOUNT);
        uint ownerWETHBalanceBefore = TEST_NFT_2_ACCOUNT.balance;

        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_2, "", block.timestamp)); // max fee with 1% is 7124618988448545

        // is not runnable anymore because no more liquidity
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(StopLossLimitModule.NotConfigured.selector);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_2, "", block.timestamp));

        // fee stored for owner in contract
        assertEq(WETH_ERC20.balanceOf(address(stopLossLimitModule)) - contractWETHBalanceBefore, 2534515302783060);
        assertEq(DAI.balanceOf(address(stopLossLimitModule)) - contractDAIBalanceBefore, 1558388099700309450);

        // leftovers returned to owner
        assertEq(DAI.balanceOf(TEST_NFT_2_ACCOUNT) - ownerDAIBalanceBefore, 310119231840361580896); // all available
        assertEq(TEST_NFT_2_ACCOUNT.balance - ownerWETHBalanceBefore, 504368545253828981); // all available
    }

    // tests StopLoss without adding to module
    function testStopLoss() external {
        // using out of range position TEST_NFT_2
        // available amounts -> DAI (fees) 311677619940061890346 WETH(fees + liquidity) 506903060556612041
        
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(stopLossLimitModule), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        stopLossLimitModule.addTokenDirect(TEST_NFT_2, StopLossLimitModule.PositionConfig(true, true, true, -84121, -78240, uint64(Q64 / 100), uint64(Q64 / 100))); // 1% max slippage

        uint contractWETHBalanceBefore = WETH_ERC20.balanceOf(address(stopLossLimitModule));
        uint contractDAIBalanceBefore = DAI.balanceOf(address(stopLossLimitModule));

        uint ownerDAIBalanceBefore = DAI.balanceOf(TEST_NFT_2_ACCOUNT);
        uint ownerWETHBalanceBefore = TEST_NFT_2_ACCOUNT.balance;

        // is not runnable without swap
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(StopLossLimitModule.MissingSwapData.selector);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_2, "", block.timestamp));

        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_2, _getWETHToDAISwapData(), block.timestamp));

        // is not runnable anymore because no more liquidity
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(StopLossLimitModule.NotConfigured.selector);
        stopLossLimitModule.execute(StopLossLimitModule.ExecuteParams(TEST_NFT_2, _getWETHToDAISwapData(), block.timestamp));

        // fee stored for owner in contract
        assertEq(WETH_ERC20.balanceOf(address(stopLossLimitModule)) - contractWETHBalanceBefore, 0);
        assertEq(DAI.balanceOf(address(stopLossLimitModule)) - contractDAIBalanceBefore, 5406774833810580731);

        // leftovers returned to owner
        assertEq(DAI.balanceOf(TEST_NFT_2_ACCOUNT) - ownerDAIBalanceBefore, 1075948191928305566472); // all available
        assertEq(TEST_NFT_2_ACCOUNT.balance - ownerWETHBalanceBefore, 0); // all available
    }

    function _getWETHToDAISwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=WETH&buyToken=DAI&sellAmount=506903060556612041&slippagePercentage=0.25
        return
            abi.encode(
                EX0x,
                hex"6af479b200000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000708e1a5dc0901c90000000000000000000000000000000000000000000000259f6c7a7e07497b8c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002bc02aaa39b223fe8d0a0e5c4f27ead9083c756cc20001f46b175474e89094c44da98b954eedeac495271d0f000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000c4cce18ee664276707"
            );
    }

    function _getDAIToUSDSwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=999999999999999632&slippagePercentage=0.05
        return
            abi.encode(
                EX0x,
                hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000de0b6b3a763fe9000000000000000000000000000000000000000000000000000000000000e777d000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd0000000000000000000000001000000000000000000000000000000000000011000000000000000000000000000000000000000000000045643479ef636e6e94"
            );
    }
}
