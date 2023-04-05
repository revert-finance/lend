// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../TestBase.sol";

contract StopLossLimitorIntegrationTest is TestBase {
   
    function setUp() external {
        _setupBase();
    }

    function testDirectSendNFT() external {
        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(abi.encodePacked("ERC721: transfer to non ERC721Receiver implementer")); // NFT manager doesnt resend original error for some reason
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, address(stopLossLimitor), TEST_NFT);
    }

    function testSetTWAPSeconds() external {
        uint16 maxTWAPTickDifference = stopLossLimitor.maxTWAPTickDifference();
        stopLossLimitor.setTWAPConfig(120, maxTWAPTickDifference);
        assertEq(stopLossLimitor.TWAPSeconds(), 120);

        vm.expectRevert(Runner.InvalidConfig.selector);
        stopLossLimitor.setTWAPConfig(60, maxTWAPTickDifference);
    }

    function testSetMaxTWAPTickDifference() external {
        uint32 TWAPSeconds = stopLossLimitor.TWAPSeconds();
        stopLossLimitor.setTWAPConfig(TWAPSeconds, 5);
        assertEq(stopLossLimitor.maxTWAPTickDifference(), 5);

        vm.expectRevert(Runner.InvalidConfig.selector);
        stopLossLimitor.setTWAPConfig(TWAPSeconds, 10);
    }

    function testSetOperator() external {
        assertEq(stopLossLimitor.operator(), OPERATOR_ACCOUNT);
        stopLossLimitor.setOperator(TEST_NFT_ACCOUNT);
        assertEq(stopLossLimitor.operator(), TEST_NFT_ACCOUNT);
    }


    function testUnauthorizedSetConfig() external {
        vm.expectRevert(StopLossLimitor.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        stopLossLimitor.setConfig(TEST_NFT_2, StopLossLimitor.PositionConfig(false, false, false, 0, 0, 0, 0));
    }

    function testResetConfig() external {
        vm.prank(TEST_NFT_ACCOUNT);
        stopLossLimitor.setConfig(TEST_NFT, StopLossLimitor.PositionConfig(false, false, false, 0, 0, 0, 0));
    }

    function testInvalidConfig() external {
        vm.expectRevert(Runner.InvalidConfig.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        stopLossLimitor.setConfig(TEST_NFT, StopLossLimitor.PositionConfig(true, false, false, 800000, -800000, 0, 0));
    }

    function testValidSetConfig() external {
        vm.prank(TEST_NFT_ACCOUNT);
        StopLossLimitor.PositionConfig memory configIn = StopLossLimitor.PositionConfig(true, false, false, -800000, 800000, 0, 0);
        stopLossLimitor.setConfig(TEST_NFT, configIn);
        (bool i1, bool i2, bool i3, int24 i4, int24 i5, uint64 i6, uint64 i7) = stopLossLimitor.configs(TEST_NFT);
        assertEq(abi.encode(configIn), abi.encode(StopLossLimitor.PositionConfig(i1, i2, i3, i4, i5, i6, i7)));
    }

    function testNonOperator() external {
        vm.expectRevert(StopLossLimitor.Unauthorized.selector);
        vm.prank(TEST_NFT_ACCOUNT);
        stopLossLimitor.run(StopLossLimitor.RunParams(TEST_NFT, 0, "", block.timestamp, 0));
    }

    function testRunWithoutApprove() external {
        // out of range position
        vm.prank(TEST_NFT_2_ACCOUNT);
        stopLossLimitor.setConfig(TEST_NFT_2, StopLossLimitor.PositionConfig(true, false, false, -84121, -78240, 0, 0));

        // fails when sending NFT
        vm.expectRevert(abi.encodePacked("ERC721: approve caller is not owner nor approved for all"));
        
        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitor.run(StopLossLimitor.RunParams(TEST_NFT_2, 0, "", block.timestamp, 0));
    }

    function testRunWithoutConfig() external {

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.setApprovalForAll(address(stopLossLimitor), true);

        vm.expectRevert(StopLossLimitor.NotConfigured.selector);
        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitor.run(StopLossLimitor.RunParams(TEST_NFT, 0, "", block.timestamp, 0));
    }

    function testRunNotReady() external {
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(stopLossLimitor), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        stopLossLimitor.setConfig(TEST_NFT_2_A, StopLossLimitor.PositionConfig(true, false, false, -276331, -276320, 0, 0));

        // in range position cant be run
        vm.expectRevert(StopLossLimitor.NotReady.selector);
        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitor.run(StopLossLimitor.RunParams(TEST_NFT_2_A, 0, "", block.timestamp, 0));
    }

    function testLimitOrder() external {

        // using out of range position TEST_NFT_2
        // available amounts -> DAI (fees) 311677619940061890346 WETH(fees + liquidity) 506903060556612041
        
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(stopLossLimitor), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        stopLossLimitor.setConfig(TEST_NFT_2, StopLossLimitor.PositionConfig(true, false, false, -84121, -78240, uint64(Q64 / 100), uint64(Q64 / 100))); // 1% max fee, 1% max slippage

        uint operatorBalanceBefore = OPERATOR_ACCOUNT.balance;
        uint ownerDAIBalanceBefore = DAI.balanceOf(TEST_NFT_2_ACCOUNT);
        uint ownerWETHBalanceBefore = TEST_NFT_2_ACCOUNT.balance;

        // is not runnable with swap
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(StopLossLimitor.SwapWrong.selector);
        stopLossLimitor.run(StopLossLimitor.RunParams(TEST_NFT_2, 123, _getWETHToDAISwapData(), block.timestamp, 1000000000));

        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitor.run(StopLossLimitor.RunParams(TEST_NFT_2, 0, "", block.timestamp, 1000000000)); // max fee with 1% is 7124618988448545

        // is not runnable anymore because config was removed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(StopLossLimitor.NotConfigured.selector);
        stopLossLimitor.run(StopLossLimitor.RunParams(TEST_NFT_2, 0, "", block.timestamp, 1000000000));

        // fee sent to operator
        assertEq(OPERATOR_ACCOUNT.balance - operatorBalanceBefore, 1000000000);

        // leftovers returned to owner
        assertEq(DAI.balanceOf(TEST_NFT_2_ACCOUNT) - ownerDAIBalanceBefore, 311677619940061890346); // all available
        assertEq(TEST_NFT_2_ACCOUNT.balance - ownerWETHBalanceBefore, 506903060556612041 - 1000000000); // all available
    }

    function testStopLoss() external {
        // using out of range position TEST_NFT_2
        // available amounts -> DAI (fees) 311677619940061890346 WETH(fees + liquidity) 506903060556612041
        
        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(stopLossLimitor), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        stopLossLimitor.setConfig(TEST_NFT_2, StopLossLimitor.PositionConfig(true, true, true, -84121, -78240, uint64(Q64 / 100), uint64(Q64 / 100))); // 1% max fee, 1% max slippage

        uint operatorBalanceBefore = DAI.balanceOf(OPERATOR_ACCOUNT);
        uint ownerDAIBalanceBefore = DAI.balanceOf(TEST_NFT_2_ACCOUNT);
        uint ownerWETHBalanceBefore = TEST_NFT_2_ACCOUNT.balance;

        // is not runnable without swap
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(StopLossLimitor.SwapWrong.selector);
        stopLossLimitor.run(StopLossLimitor.RunParams(TEST_NFT_2, 0, "", block.timestamp, 1000000000));

        vm.prank(OPERATOR_ACCOUNT);
        stopLossLimitor.run(StopLossLimitor.RunParams(TEST_NFT_2, 506903060556612041, _getWETHToDAISwapData(), block.timestamp, 1000000000));

        // is not runnable anymore because config was removed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(StopLossLimitor.NotConfigured.selector);
        stopLossLimitor.run(StopLossLimitor.RunParams(TEST_NFT_2, 506903060556612041, _getWETHToDAISwapData(), block.timestamp, 1000000000));

        // fee sent to operator
        assertEq(DAI.balanceOf(OPERATOR_ACCOUNT) - operatorBalanceBefore, 1000000000);

        // leftovers returned to owner
        assertEq(DAI.balanceOf(TEST_NFT_2_ACCOUNT) - ownerDAIBalanceBefore, 1081354966761116147203); // all available
        assertEq(TEST_NFT_2_ACCOUNT.balance - ownerWETHBalanceBefore, 0); // all available
    }

    
    function testOracleCheck() external {

        // create range adjustor with more strict oracle config    
        stopLossLimitor = new StopLossLimitor(v3utils, OPERATOR_ACCOUNT, 60 * 30, 4);

        vm.prank(TEST_NFT_2_ACCOUNT);
        NPM.setApprovalForAll(address(stopLossLimitor), true);

        vm.prank(TEST_NFT_2_ACCOUNT);
        stopLossLimitor.setConfig(TEST_NFT_2, StopLossLimitor.PositionConfig(true, false, false, -84121, -78240, uint64(Q64 / 100), uint64(Q64 / 100)));

        // OraclePriceCheckFailed
        vm.prank(OPERATOR_ACCOUNT);
        vm.expectRevert(Runner.OraclePriceCheckFailed.selector);
        stopLossLimitor.run(StopLossLimitor.RunParams(TEST_NFT_2, 0, "", block.timestamp, 1000000000));
    }


    function _getWETHToDAISwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=WETH&buyToken=DAI&sellAmount=506903060556612041&slippagePercentage=0.25
        return
            abi.encode(
                EX0x,
                hex"6af479b200000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000708e1a5dc0901c90000000000000000000000000000000000000000000000259f6c7a7e07497b8c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002bc02aaa39b223fe8d0a0e5c4f27ead9083c756cc20001f46b175474e89094c44da98b954eedeac495271d0f000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000c4cce18ee664276707"
            );
    }
}