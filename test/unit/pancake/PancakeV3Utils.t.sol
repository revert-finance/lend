// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/transformers/V3Utils.sol";
import "../../../src/utils/Constants.sol";
import "./PancakeMasterChefV3Mocks.sol";

contract PancakeV3UtilsTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant RECIPIENT = address(0xCAFE);

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant CHANGE_RANGE_TOKEN_ID = 2;
    uint256 internal constant WITHDRAW_TOKEN_ID = 3;
    uint256 internal constant INCREASE_TOKEN_ID = 4;
    uint24 internal constant FEE = 500;

    PancakeMockERC20 internal cake;
    PancakeMockERC20 internal token0;
    PancakeMockERC20 internal token1;
    PancakeMockFactory internal factory;
    PancakeMockPool internal pool;
    PancakeMockRouter internal router;
    PancakeMockNPM internal npm;
    V3Utils internal v3Utils;

    function setUp() external {
        cake = new PancakeMockERC20("CAKE", "CAKE");
        token0 = new PancakeMockERC20("Token0", "TK0");
        token1 = new PancakeMockERC20("Token1", "TK1");
        factory = new PancakeMockFactory();
        pool = new PancakeMockPool(address(token0), address(token1), FEE);
        router = new PancakeMockRouter();
        factory.setPool(address(token0), address(token1), FEE, address(pool));

        npm = new PancakeMockNPM(address(factory), address(cake));
        v3Utils = new V3Utils(INonfungiblePositionManager(address(npm)), address(0), address(router), address(0));

        npm.mintPosition(ALICE, TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 25, 35);
        npm.mintPosition(ALICE, CHANGE_RANGE_TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 0, 0);
        npm.mintPosition(ALICE, WITHDRAW_TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 0, 0);
        npm.mintPosition(ALICE, INCREASE_TOKEN_ID, address(token0), address(token1), FEE, -10, 10, 100, 0, 0);
    }

    function testReceiveRejectsWrongContractAndSelfSend() external {
        vm.expectRevert(Constants.WrongContract.selector);
        v3Utils.onERC721Received(address(this), ALICE, TOKEN_ID, "");

        vm.expectRevert(Constants.SelfSend.selector);
        vm.prank(address(npm));
        v3Utils.onERC721Received(address(this), address(v3Utils), TOKEN_ID, "");
    }

    function testReceiveRejectsPlainEther() external {
        vm.expectRevert(Constants.NotWETH.selector);
        (bool success,) = address(v3Utils).call{value: 1}("");
        success;
    }

    function testExecuteRevertsOnAmountError() external {
        V3Utils.Instructions memory instructions = _baseInstructions(V3Utils.WhatToDo.COMPOUND_FEES);
        instructions.amountIn0 = 26;

        vm.startPrank(ALICE);
        npm.approve(address(v3Utils), TOKEN_ID);
        vm.expectRevert(Constants.AmountError.selector);
        v3Utils.execute(TOKEN_ID, instructions);
        vm.stopPrank();
    }

    function testExecuteCompoundsFeesNoSwap() external {
        V3Utils.Instructions memory instructions = _baseInstructions(V3Utils.WhatToDo.COMPOUND_FEES);

        vm.startPrank(ALICE);
        npm.approve(address(v3Utils), TOKEN_ID);
        uint256 newTokenId = v3Utils.execute(TOKEN_ID, instructions);
        vm.stopPrank();

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(TOKEN_ID);
        assertEq(newTokenId, 0);
        assertEq(liquidity, 160);
        assertEq(npm.ownerOf(TOKEN_ID), ALICE);
        assertEq(token0.balanceOf(RECIPIENT), 0);
        assertEq(token1.balanceOf(RECIPIENT), 0);
    }

    function testExecuteWithPermitCompoundsFeesNoSwap() external {
        V3Utils.Instructions memory instructions = _baseInstructions(V3Utils.WhatToDo.COMPOUND_FEES);

        vm.prank(ALICE);
        uint256 newTokenId = v3Utils.executeWithPermit(TOKEN_ID, instructions, 0, bytes32(0), bytes32(0));

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(TOKEN_ID);
        assertEq(newTokenId, 0);
        assertEq(liquidity, 160);
        assertEq(npm.ownerOf(TOKEN_ID), ALICE);
    }

    function testExecuteChangeRangeMintsNewNftToRecipient() external {
        uint256 expectedNewTokenId = npm.nextTokenId();
        V3Utils.Instructions memory instructions = _baseInstructions(V3Utils.WhatToDo.CHANGE_RANGE);
        instructions.liquidity = 100;
        instructions.fee = FEE;
        instructions.tickLower = -20;
        instructions.tickUpper = 20;
        instructions.recipientNFT = RECIPIENT;

        vm.startPrank(ALICE);
        npm.approve(address(v3Utils), CHANGE_RANGE_TOKEN_ID);
        uint256 newTokenId = v3Utils.execute(CHANGE_RANGE_TOKEN_ID, instructions);
        vm.stopPrank();

        (,,,,,,, uint128 oldLiquidity,,,,) = npm.positions(CHANGE_RANGE_TOKEN_ID);
        assertEq(newTokenId, expectedNewTokenId);
        assertEq(oldLiquidity, 0);
        assertEq(npm.ownerOf(CHANGE_RANGE_TOKEN_ID), ALICE);
        assertEq(npm.ownerOf(newTokenId), RECIPIENT);
    }

    function testExecuteWithdrawAndCollectPaysRecipient() external {
        V3Utils.Instructions memory instructions = _baseInstructions(V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP);
        instructions.liquidity = 100;
        instructions.targetToken = address(token0);

        vm.startPrank(ALICE);
        npm.approve(address(v3Utils), WITHDRAW_TOKEN_ID);
        v3Utils.execute(WITHDRAW_TOKEN_ID, instructions);
        vm.stopPrank();

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(WITHDRAW_TOKEN_ID);
        assertEq(liquidity, 0);
        assertEq(token0.balanceOf(RECIPIENT), 100);
        assertEq(token1.balanceOf(RECIPIENT), 100);
        assertEq(npm.ownerOf(WITHDRAW_TOKEN_ID), ALICE);
    }

    function testExecuteWithdrawAndCollectSwapsIntoTargetToken() external {
        V3Utils.Instructions memory instructions = _baseInstructions(V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP);
        instructions.liquidity = 100;
        instructions.targetToken = address(token0);
        instructions.amountIn1 = 100;
        instructions.amountOut1Min = 80;
        instructions.swapData1 =
            abi.encodeCall(PancakeMockRouter.swapExact, (token1, token0, uint256(100), uint256(80)));

        vm.startPrank(ALICE);
        npm.approve(address(v3Utils), WITHDRAW_TOKEN_ID);
        v3Utils.execute(WITHDRAW_TOKEN_ID, instructions);
        vm.stopPrank();

        assertEq(token0.balanceOf(RECIPIENT), 180);
        assertEq(token1.balanceOf(RECIPIENT), 0);
    }

    function testSwapRejectsSameToken() external {
        vm.expectRevert(Constants.SameToken.selector);
        v3Utils.swap(
            V3Utils.SwapParams({
                tokenIn: IERC20(address(token0)),
                tokenOut: IERC20(address(token0)),
                amountIn: 1,
                minAmountOut: 0,
                recipient: RECIPIENT,
                swapData: "",
                unwrap: false,
                permitData: ""
            })
        );
    }

    function testSwapUsesExternalRouterAndReturnsInputLeftover() external {
        token0.mint(ALICE, 100);

        vm.startPrank(ALICE);
        token0.approve(address(v3Utils), 100);
        uint256 amountOut = v3Utils.swap(
            V3Utils.SwapParams({
                tokenIn: IERC20(address(token0)),
                tokenOut: IERC20(address(token1)),
                amountIn: 100,
                minAmountOut: 90,
                recipient: RECIPIENT,
                swapData: abi.encodeCall(PancakeMockRouter.swapExact, (token0, token1, uint256(60), uint256(90))),
                unwrap: false,
                permitData: ""
            })
        );
        vm.stopPrank();

        assertEq(amountOut, 90);
        assertEq(token0.balanceOf(RECIPIENT), 40);
        assertEq(token1.balanceOf(RECIPIENT), 90);
    }

    function testSwapAndMintWithApprovalsNoSwap() external {
        token0.mint(ALICE, 100);
        token1.mint(ALICE, 200);
        uint256 expectedNewTokenId = npm.nextTokenId();

        vm.startPrank(ALICE);
        token0.approve(address(v3Utils), 100);
        token1.approve(address(v3Utils), 200);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = v3Utils.swapAndMint(
            V3Utils.SwapAndMintParams({
                token0: IERC20(address(token0)),
                token1: IERC20(address(token1)),
                fee: FEE,
                tickLower: -20,
                tickUpper: 20,
                amount0: 100,
                amount1: 200,
                recipient: RECIPIENT,
                recipientNFT: RECIPIENT,
                deadline: 1,
                swapSourceToken: IERC20(address(0)),
                amountIn0: 0,
                amountOut0Min: 0,
                swapData0: "",
                amountIn1: 0,
                amountOut1Min: 0,
                swapData1: "",
                amountAddMin0: 0,
                amountAddMin1: 0,
                returnData: "",
                permitData: ""
            })
        );
        vm.stopPrank();

        assertEq(tokenId, expectedNewTokenId);
        assertEq(liquidity, 300);
        assertEq(amount0, 100);
        assertEq(amount1, 200);
        assertEq(npm.ownerOf(tokenId), RECIPIENT);
    }

    function testSwapAndIncreaseLiquidityNoSwap() external {
        token0.mint(ALICE, 40);
        token1.mint(ALICE, 60);

        vm.startPrank(ALICE);
        npm.approve(address(v3Utils), INCREASE_TOKEN_ID);
        token0.approve(address(v3Utils), 40);
        token1.approve(address(v3Utils), 60);
        (uint128 liquidity, uint256 amount0, uint256 amount1) = v3Utils.swapAndIncreaseLiquidity(
            V3Utils.SwapAndIncreaseLiquidityParams({
                tokenId: INCREASE_TOKEN_ID,
                amount0: 40,
                amount1: 60,
                recipient: RECIPIENT,
                deadline: 1,
                swapSourceToken: IERC20(address(0)),
                amountIn0: 0,
                amountOut0Min: 0,
                swapData0: "",
                amountIn1: 0,
                amountOut1Min: 0,
                swapData1: "",
                amountAddMin0: 0,
                amountAddMin1: 0,
                permitData: ""
            })
        );
        vm.stopPrank();

        (,,,,,,, uint128 positionLiquidity,,,,) = npm.positions(INCREASE_TOKEN_ID);
        assertEq(liquidity, 100);
        assertEq(amount0, 40);
        assertEq(amount1, 60);
        assertEq(positionLiquidity, 200);
    }

    function _baseInstructions(V3Utils.WhatToDo whatToDo)
        internal
        pure
        returns (V3Utils.Instructions memory instructions)
    {
        instructions.whatToDo = whatToDo;
        instructions.feeAmount0 = type(uint128).max;
        instructions.feeAmount1 = type(uint128).max;
        instructions.deadline = 1;
        instructions.recipient = RECIPIENT;
        instructions.recipientNFT = RECIPIENT;
    }
}
