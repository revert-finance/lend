// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../TestBase.sol";
import "../../src/V3Utils.sol";

contract V3UtilsIntegrationTest is Test, TestBase {

    V3Utils c;
    uint256 mainnetFork;

    address constant TEST_ACCOUNT = 0x8cadb20A4811f363Dadb863A190708bEd26245F8;

    uint constant TEST_NFT_ID = 24181; // DAI/USCD 0.05% - one sided only DAI - current tick is near -276326
    uint constant TEST_NFT_ID_IN_RANGE = 23901; // DAI/USCD 0.05% - two sided

    address constant BENEFICIARY_ACCOUNT = 0xA53858bd4a9490a4063C5abF55bf88b4D35ECaf2;

    function setUp() external {
        mainnetFork = vm.createFork("https://rpc.ankr.com/eth", 15489169);
        vm.selectFork(mainnetFork);
        c = new V3Utils(WETH, NPM, EX0x, 10 ** 16, BENEFICIARY_ACCOUNT);
        vm.deal(BENEFICIARY_ACCOUNT, 1 ether);
    }

    function testUnauthorizedTransfer() external {
        vm.expectRevert(abi.encodePacked("ERC721: transfer caller is not owner nor approved"));
        V3Utils.Instructions memory inst = V3Utils.Instructions(V3Utils.WhatToDo.NOTHING,address(0),0,0,"",0,0,"", 0, 0, 0, false, 0, 0, "");
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(inst));
    }

    function testInvalidInstructions() external {
        // reverts with ERC721Receiver error if Instructions are invalid
        vm.expectRevert(abi.encodePacked("ERC721: transfer to non ERC721Receiver implementer"));
        vm.prank(TEST_ACCOUNT);
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(true, false, 1, "test"));
    }

    function testTransferWithNoAction() external {
        assertEq(NPM.ownerOf(TEST_NFT_ID), TEST_ACCOUNT);
        V3Utils.Instructions memory inst = V3Utils.Instructions(V3Utils.WhatToDo.NOTHING,address(0),0,0,"",0,0,"", 0, 0, 0, false, 0, 0, "");
        vm.prank(TEST_ACCOUNT);
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(inst));
        assertEq(NPM.ownerOf(TEST_NFT_ID), TEST_ACCOUNT);
    }

    function testTransferWithNoActionBurn() external {
        V3Utils.Instructions memory inst = V3Utils.Instructions(V3Utils.WhatToDo.NOTHING,address(0),0,0,"",0,0,"", 0, 0, 0, true, 0, 0, "");
        vm.prank(TEST_ACCOUNT);
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(inst));
    }

    function testTransferWithNoActionBurnFail() external {
        V3Utils.Instructions memory inst = V3Utils.Instructions(V3Utils.WhatToDo.NOTHING,address(0),0,0,"",0,0,"", 0, 0, 0, true, 0, 0, "");
        _increaseLiquidity();
        vm.prank(TEST_ACCOUNT);
        vm.expectRevert(abi.encodePacked("Not cleared"));
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(inst));
    }

    function testTransferWithChangeRange() external {

        // add liquidity to existing (empty) position (add 1 DAI / 0 USDC)
        _increaseLiquidity();

        uint countBefore = NPM.balanceOf(TEST_ACCOUNT);

        // swap half of DAI to USDC and add full range
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.CHANGE_RANGE,
            address(USDC),
            500000000000000000,
            400000,
            _get05DAIToUSDCSwapData(),
            0,
            0,
            "",
            100, // change fee as well
            MIN_TICK_100,
            -MIN_TICK_100,
            false,
            0,
            block.timestamp,
            "");

        vm.prank(TEST_ACCOUNT);
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(inst));

        uint countAfter = NPM.balanceOf(TEST_ACCOUNT);
        assertGt(countAfter, countBefore);
    }

    function testTransferWithdrawAndSwap() external {
        _testTransferWithWithdrawAndSwap(true, false);
    }
    function testTransferWithdrawAndSwapBurn() external {
        _testTransferWithWithdrawAndSwap(true, true);
    }
    function testTransferCollectAndSwap() external {
        _testTransferWithWithdrawAndSwap(false, false);
    }
    function testFailTransferCollectAndSwapBurn() external {
        _testTransferWithWithdrawAndSwap(false, true);
    }

    function _testTransferWithWithdrawAndSwap(bool withdrawLiquidity, bool burnOrReturn) internal {

        // add liquidity to existing (empty) position (add 1 DAI / 0 USDC)
        (uint128 liquidity,,) = _increaseLiquidity();

        uint countBefore = NPM.balanceOf(TEST_ACCOUNT);

        // swap half of DAI to USDC and add full range
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.WITHDRAW_COLLECT_AND_SWAP,
            address(USDC),
            990099009900989844, // uniswap returns 1 less when getting liquidity - this must be traded
            900000,
            _get990099009900989844DAIToUSDCSwapData(),
            0,
            0,
            "",
            0,
            0,
            0,
            burnOrReturn,
            withdrawLiquidity ? liquidity : 0,
            block.timestamp,
            "");

        vm.prank(TEST_ACCOUNT);
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(inst));

        uint countAfter = NPM.balanceOf(TEST_ACCOUNT);

        if (burnOrReturn) {
            assertGt(countBefore, countAfter); // removed 1 burned
        } else {
            assertEq(countAfter, countBefore); // nft returned
        }
    }

    function testFailEmptySwapAndIncreaseLiquidity() external {

        V3Utils.SwapAndIncreaseLiquidityParams memory params = V3Utils.SwapAndIncreaseLiquidityParams(
            TEST_NFT_ID, 0, 0, block.timestamp, IERC20(address(0)), 0, 0, "", 0, 0, "");

        vm.prank(TEST_ACCOUNT);
        c.swapAndIncreaseLiquidity(params);
    }

    function testSwapAndIncreaseLiquidity() external {

        V3Utils.SwapAndIncreaseLiquidityParams memory params = V3Utils.SwapAndIncreaseLiquidityParams(
            TEST_NFT_ID,
            0,
            1000000,
            block.timestamp,
            USDC,
            1000000,
            900000000000000000,
            _get1USDCToDAISwapData(),
            0,
            0,
            ""
        );

        vm.prank(TEST_ACCOUNT);
        USDC.approve(address(c), 1000000);

        vm.prank(TEST_ACCOUNT);
        (uint128 liquidity, uint256 amount0, uint256 amount1) = c.swapAndIncreaseLiquidity(params);

        assertEq(liquidity, 1981363879662845);
        assertEq(amount0, 990185448389405712);
        assertEq(amount1, 0); // one sided adding
    }

    function testSwapAndIncreaseLiquiditBothSides() external {

        V3Utils.SwapAndIncreaseLiquidityParams memory params = V3Utils.SwapAndIncreaseLiquidityParams(
            TEST_NFT_ID_IN_RANGE,
            0,
            2000000,
            block.timestamp,
            USDC,
            1000000,
            900000000000000000,
            _get1USDCToDAISwapData(),
            0,
            0,
            ""
        );

        vm.prank(TEST_ACCOUNT);
        USDC.approve(address(c), 2000000);

        uint usdcBefore = USDC.balanceOf(TEST_ACCOUNT);
        uint daiBefore = DAI.balanceOf(TEST_ACCOUNT);

        vm.prank(TEST_ACCOUNT);
        (uint128 liquidity, uint256 amount0, uint256 amount1) = c.swapAndIncreaseLiquidity(params);

        uint usdcAfter = USDC.balanceOf(TEST_ACCOUNT);
        uint daiAfter = DAI.balanceOf(TEST_ACCOUNT);

        assertEq(liquidity, 19268403984395);
        assertEq(amount0, 898315437527657511);
        assertEq(amount1, 990099);

        // aaaalmost all usdc spent
        assertEq(usdcBefore - usdcAfter, 1999999);
        //some dai returned - because not 100% correct swap ratio
        assertEq(daiAfter - daiBefore, 92788710970366114);
    }

    function testFailEmptySwapAndMint() external {
        V3Utils.SwapAndMintParams memory params = V3Utils.SwapAndMintParams(
            DAI, USDC, 500, MIN_TICK_500, -MIN_TICK_500, 0, 0, TEST_ACCOUNT, block.timestamp, IERC20(address(0)), 0, 0, "", 0, 0, "");

        vm.prank(TEST_ACCOUNT);
        c.swapAndMint(params);
    }

    function testSwapAndMint() external {
        _testSwapAndMint(MIN_TICK_500, -MIN_TICK_500, 990140532991, 990182067725057610, 990099);
    }
    function testSwapAndMintOneSided0() external {
        _testSwapAndMint(MIN_TICK_500, MIN_TICK_500 + 200000, 829527205383200265829, 0, 990099);
    }
    function testSwapAndMintOneSided1() external {
        _testSwapAndMint(-MIN_TICK_500-200000, -MIN_TICK_500, 829599633787704127364982047010492, 990185448389406138, 0);
    }

    function _testSwapAndMint(int24 lower, int24 upper, uint eLiquidity, uint eAmount0, uint aAmount1) internal {
        V3Utils.SwapAndMintParams memory params = V3Utils.SwapAndMintParams(
            DAI,
            USDC,
            500,
            lower,
            upper,
            0,
            2000000,
            TEST_ACCOUNT,
            block.timestamp,
            USDC,
            1000000,
            900000000000000000,
            _get1USDCToDAISwapData(),
            0,
            0,
            ""
        );

        vm.prank(TEST_ACCOUNT);
        USDC.approve(address(c), 2000000);

        vm.prank(TEST_ACCOUNT);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = c.swapAndMint(params);

        assertGt(tokenId, 0);
        assertEq(liquidity, eLiquidity);
        assertEq(amount0, eAmount0);
        assertEq(amount1, aAmount1);
    }

    function testSwapAndMintWithETH() public {
        V3Utils.SwapAndMintParams memory params = V3Utils.SwapAndMintParams(
            DAI,
            USDC,
            500,
            MIN_TICK_500,
            -MIN_TICK_500,
            0,
            0,
            TEST_ACCOUNT,
            block.timestamp,
            WETH,
            500000000000000000, // 0.5ETH
            759195948032664079460,
            _get05ETHToDAISwapData(),
            500000000000000000, // 0.5ETH
            757406864,
            _get05ETHToUSDCSwapData()
        );

        vm.prank(TEST_ACCOUNT);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = c.swapAndMint{value: 1 ether}(params);

        assertGt(tokenId, 0);
        assertEq(liquidity, 749939243373435);
        assertEq(amount0, 749970702066413447600);
        assertEq(amount1, 749907786);
    }

    function testWithdrawProtocolFeeUnauthorized() external {
        vm.expectRevert(abi.encodePacked("!beneficiary"));
        c.withdrawProtocolFee(DAI);
    }

    function _increaseLiquidity() internal returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        V3Utils.SwapAndIncreaseLiquidityParams memory params = V3Utils.SwapAndIncreaseLiquidityParams(
            TEST_NFT_ID,
            1000000000000000000,
            0,
            block.timestamp,
            IERC20(address(0)),
            0, // no swap
            0,
            "",
            0, // no swap
            0,
            ""
        );

        uint balanceBefore = DAI.balanceOf(TEST_ACCOUNT);

        vm.startPrank(TEST_ACCOUNT);
        DAI.approve(address(c), 1000000000000000000);
        (liquidity, amount0, amount1) = c.swapAndIncreaseLiquidity(params);
        vm.stopPrank();

        uint balanceAfter = DAI.balanceOf(TEST_ACCOUNT);

        vm.prank(BENEFICIARY_ACCOUNT);
        uint fees = c.withdrawProtocolFee(DAI);

        assertEq(liquidity, 1981190916003322);
        assertEq(amount0, 990099009900989845); // amount minus fee
        assertEq(amount1, 0); // only added on one side     

        vm.prank(BENEFICIARY_ACCOUNT);
        uint fees2 = c.withdrawProtocolFee(DAI);
        assertEq(fees2, 0); // already withdrawn

        assertEq(balanceBefore - balanceAfter, amount0 + fees);

        uint balanceDAI = DAI.balanceOf(address(c));
        uint balanceUSDC = USDC.balanceOf(address(c));

        assertEq(balanceDAI, 0);
        assertEq(balanceUSDC, 0);
    }

    function _get1USDCToDAISwapData() internal pure returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=USDC&buyToken=DAI&sellAmount=1000000
        return abi.encode(hex"d9627aa4000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000dbd77a86ff7cebd00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000006b175474e89094c44da98b954eedeac495271d0f869584cd000000000000000000000000100000000000000000000000000000000000001100000000000000000000000000000000000000000000003ad56e32f663185fa5");
    }

    function _get1DAIToUSDSwapData() internal pure returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=1000000000000000000
        return abi.encode(hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000f10d1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd0000000000000000000000001000000000000000000000000000000000000011000000000000000000000000000000000000000000000091e225855e631b431b");
    }

    function _get05DAIToUSDCSwapData() internal pure returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=500000000000000000
        return abi.encode(hex"d9627aa4000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000006f05b59d3b2000000000000000000000000000000000000000000000000000000000000000787fe000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd000000000000000000000000100000000000000000000000000000000000001100000000000000000000000000000000000000000000002d8d167adc6318718d");
    }

    function _get990099009900989844DAIToUSDCSwapData() internal pure returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=990099009900989844
        return abi.encode(hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000dbd89cdc19d4d9400000000000000000000000000000000000000000000000000000000000eeaad000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000c39d5c33d36318aa04");
    }

    function _get05ETHToDAISwapData() internal pure returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=WETH&buyToken=DAI&sellAmount=500000000000000000&slippagePercentage=0.5
        return abi.encode(hex"6af479b2000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000006f05b59d3b20000000000000000000000000000000000000000000000000017b96004de16f5ba880000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002bc02aaa39b223fe8d0a0e5c4f27ead9083c756cc20001f46b175474e89094c44da98b954eedeac495271d0f000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000788bf52b4e631f3b4a");
    }

    function _get05ETHToUSDCSwapData() internal pure returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=WETH&buyToken=USDC&sellAmount=500000000000000000&slippagePercentage=0.5
        return abi.encode(hex"d9627aa4000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000006f05b59d3b20000000000000000000000000000000000000000000000000000000000001a1ec65a00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000f7f7a41bab631f3b5e");
    }

}
