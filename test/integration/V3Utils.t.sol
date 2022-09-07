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
    uint constant TEST_NFT_ID = 24181; // DAI/USCD 0.05%

    function setUp() public {
        mainnetFork = vm.createFork("https://rpc.ankr.com/eth", 15489169);
        vm.selectFork(mainnetFork);
        c = new V3Utils(WETH, FACTORY, NPM, 10 ** 16, msg.sender);
    }

    function testFailUnathorizedTransfer() public {
        V3Utils.Instructions memory inst = V3Utils.Instructions(V3Utils.WhatToDo.NOTHING,address(0),0,"",0,"", 0, 0, 0, false, 0, 0, "");
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(inst));
    }

    function testTransferWithNoAction() public {
        assertEq(NPM.ownerOf(TEST_NFT_ID), TEST_ACCOUNT);
        V3Utils.Instructions memory inst = V3Utils.Instructions(V3Utils.WhatToDo.NOTHING,address(0),0,"",0,"", 0, 0, 0, false, 0, 0, "");
        vm.prank(TEST_ACCOUNT);
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(inst));
        assertEq(NPM.ownerOf(TEST_NFT_ID), TEST_ACCOUNT);
    }

    function testTransferWithNoActionBurn() public {
        V3Utils.Instructions memory inst = V3Utils.Instructions(V3Utils.WhatToDo.NOTHING,address(0),0,"",0,"", 0, 0, 0, true, 0, 0, "");
        vm.prank(TEST_ACCOUNT);
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(inst));
    }

    function testFailTransferWithNoActionBurn() public {
        V3Utils.Instructions memory inst = V3Utils.Instructions(V3Utils.WhatToDo.NOTHING,address(0),0,"",0,"", 0, 0, 0, true, 0, 0, "");
        _increaseLiquidity();
        vm.prank(TEST_ACCOUNT);
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(inst));
    }

    function testTransferWithChangeRange() public {

        // add liquidity to existing (empty) position (add 1 DAI / 0 USDC)
        _increaseLiquidity();

        uint countBefore = NPM.balanceOf(TEST_ACCOUNT);

        // swap half of DAI to USDC and add full range
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.CHANGE_RANGE,
            address(USDC),
            500000000000000000,
            _get05DAIToUSDCSwapData(),
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

    function testTransferWithWithdrawAndSwap() public {

        // add liquidity to existing (empty) position (add 1 DAI / 0 USDC)
        (uint128 liquidity, uint256 amount0, uint256 amount1) = _increaseLiquidity();

        assertEq(liquidity, 1981190916003322);
        assertEq(amount0, 990099009900989845);
        assertEq(amount1, 0);

        uint countBefore = NPM.balanceOf(TEST_ACCOUNT);

        // swap half of DAI to USDC and add full range
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.WITHDRAW_AND_SWAP,
            address(USDC),
            990099009900989844, // uniswap returns 1 less when getting liquidity - this must be traded
            _get990099009900989844DAIToUSDCSwapData(),
            0,
            "",
            0,
            0,
            0,
            true, // burn empty token afterwards
            liquidity,
            block.timestamp,
            "");

        vm.prank(TEST_ACCOUNT);
        NPM.safeTransferFrom(TEST_ACCOUNT, address(c), TEST_NFT_ID, abi.encode(inst));

        uint countAfter = NPM.balanceOf(TEST_ACCOUNT);
        assertGt(countBefore, countAfter); // removed 1 burned
    }

    function testSwapAndIncreaseLiquidity() public {

        V3Utils.SwapAndIncreaseLiquidityParams memory params = V3Utils.SwapAndIncreaseLiquidityParams(
            TEST_NFT_ID,
            0,
            1000000,
            block.timestamp,
            _get1USDCToDAISwapData(),
            false,
            1000000
        );

        vm.prank(TEST_ACCOUNT);
        USDC.approve(address(c), 1000000);

        vm.prank(TEST_ACCOUNT);
        (uint128 liquidity, uint256 amount0, uint256 amount1) = c.swapAndIncreaseLiquidity(params);

        assertGt(liquidity, 0);
        assertGt(amount0, 0);
        assertEq(amount1, 0); // one sided adding
    }

    function testSwapAndMint() public {
        // https://api.0x.org/swap/v1/quote?buyToken=DAI&sellToken=USDC&sellAmount=1000000

        V3Utils.SwapAndMintParams memory params = V3Utils.SwapAndMintParams(
            DAI,
            USDC,
            500,
            MIN_TICK_500,
            -MIN_TICK_500,
            0,
            2000000,
            TEST_ACCOUNT,
            block.timestamp,
            _get1USDCToDAISwapData(),
            false,
            1000000
        );

        vm.prank(TEST_ACCOUNT);
        USDC.approve(address(c), 2000000);

        vm.prank(TEST_ACCOUNT);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = c.swapAndMint(params);

        assertGt(tokenId, 0);
        assertGt(liquidity, 0);

        // big range so both sided - DAI only from swap
        assertGt(amount0, 0);
        assertGt(amount1, 0);
    }



    function _increaseLiquidity() internal returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        V3Utils.SwapAndIncreaseLiquidityParams memory params = V3Utils.SwapAndIncreaseLiquidityParams(
            TEST_NFT_ID,
            1000000000000000000,
            0,
            block.timestamp,
            "",
            false,
            0 // no swap
        );

        address beneficiary = c.protocolFeeBeneficiary();

        uint balanceBefore = DAI.balanceOf(TEST_ACCOUNT);
        uint beneficiaryBefore = DAI.balanceOf(beneficiary);

        vm.startPrank(TEST_ACCOUNT);
        DAI.approve(address(c), 1000000000000000000);
        (liquidity, amount0, amount1) = c.swapAndIncreaseLiquidity(params);
        vm.stopPrank();

        uint balanceAfter = DAI.balanceOf(TEST_ACCOUNT);
        uint beneficiaryAfter = DAI.balanceOf(beneficiary);

        assertEq(liquidity, 1981190916003322);
        assertEq(amount0, 990099009900989845); // amount minus fee
        assertEq(amount1, 0); // only added on one side     

        assertEq(balanceBefore - balanceAfter, amount0 + (beneficiaryAfter - beneficiaryBefore));
    }

    function _get1USDCToDAISwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=USDC&buyToken=DAI&sellAmount=1000000
        return abi.encode(EX0x, EX0x, hex"d9627aa4000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000dbd77a86ff7cebd00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000006b175474e89094c44da98b954eedeac495271d0f869584cd000000000000000000000000100000000000000000000000000000000000001100000000000000000000000000000000000000000000003ad56e32f663185fa5");
    }

    function _get05DAIToUSDCSwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=500000000000000000
        return abi.encode(EX0x, EX0x, hex"d9627aa4000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000006f05b59d3b2000000000000000000000000000000000000000000000000000000000000000787fe000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd000000000000000000000000100000000000000000000000000000000000001100000000000000000000000000000000000000000000002d8d167adc6318718d");
    }

    function _get990099009900989844DAIToUSDCSwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=990099009900989844
        return abi.encode(EX0x, EX0x, hex"d9627aa400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000dbd89cdc19d4d9400000000000000000000000000000000000000000000000000000000000eeaad000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000c39d5c33d36318aa04");
    }
}
