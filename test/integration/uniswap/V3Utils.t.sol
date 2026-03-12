// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../../src/utils/Constants.sol";
import "../../../src/transformers/V3Utils.sol";

contract V3UtilsIntegrationTest is Test {
    uint256 constant Q64 = 2 ** 64;

    int24 constant MIN_TICK_100 = -887272;
    int24 constant MIN_TICK_500 = -887270;

    IERC20 constant WETH_ERC20 = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    address constant WHALE_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    address constant DAI_WHALE_ACCOUNT = 0x2fEb1512183545f48f6b9C5b4EbfCaF49CfCa6F3;
    address constant OPERATOR_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    address constant WITHDRAWER_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    uint64 constant MAX_REWARD = uint64(Q64 / 400); //0.25%
    uint64 constant MAX_FEE_REWARD = uint64(Q64 / 20); //5%

    address FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    address EX0x = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF; // 0x exchange proxy
    address UNIVERSAL_ROUTER = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B; // uniswap universal router

    // DAI/USDC 0.05% - one sided only DAI - current tick is near -276326 - no liquidity (-276320/-276310)
    uint256 constant TEST_NFT = 24181;
    address constant TEST_NFT_ACCOUNT = 0x8cadb20A4811f363Dadb863A190708bEd26245F8;
    address constant TEST_NFT_POOL = 0x6c6Bc977E13Df9b0de53b251522280BB72383700;

    uint256 constant TEST_NFT_2 = 7; // DAI/WETH 0.3% - one sided only WETH - with liquidity and fees (-84120/-78240)
    uint256 constant TEST_NFT_2_A = 126; // DAI/USDC 0.05% - in range (-276330/-276320)
    uint256 constant TEST_NFT_2_B = 37; // USDC/WETH 0.3% - out of range (192180/193380)
    address constant TEST_NFT_2_ACCOUNT = 0x3b8ccaa89FcD432f1334D35b10fF8547001Ce3e5;
    address constant TEST_NFT_2_POOL = 0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8;

    // DAI/USDC 0.05% - in range - with liquidity and fees
    uint256 constant TEST_NFT_3 = 4660;
    address constant TEST_NFT_3_ACCOUNT = 0xa3eF006a7da5BcD1144d8BB86EfF1734f46A0c1E;
    address constant TEST_NFT_3_POOL = 0x6c6Bc977E13Df9b0de53b251522280BB72383700;

    // USDC/WETH 0.3% - in range - with liquidity and fees
    uint256 constant TEST_NFT_4 = 827;
    address constant TEST_NFT_4_ACCOUNT = 0x96653b13bD00842Eb8Bc77dCCFd48075178733ce;
    address constant TEST_NFT_4_POOL = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;

    // DAI/USDC 0.05% - in range - with liquidity and fees
    uint256 constant TEST_NFT_5 = 23901;
    address constant TEST_NFT_5_ACCOUNT = 0x082d3e0f04664b65127876e9A05e2183451c792a;

    address constant TEST_FEE_ACCOUNT = 0x8df57E3D9dDde355dCE1adb19eBCe93419ffa0FB;

    uint256 mainnetFork;

    V3Utils v3utils;

    function setUp() external {
          string memory ANKR_RPC = string.concat(
            "https://rpc.ankr.com/eth/",
            vm.envString("ANKR_API_KEY")
        );
        mainnetFork = vm.createFork(ANKR_RPC, 15489169);
        vm.selectFork(mainnetFork);
        v3utils = new V3Utils(NPM, EX0x, UNIVERSAL_ROUTER);
    }

    function testUnauthorizedTransfer() external {
        vm.expectRevert(abi.encodePacked("ERC721: transfer caller is not owner nor approved"));
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.CHANGE_RANGE,
            address(0),
            0,
            0,
            0,
            0,
            "",
            0,
            0,
            "",
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            TEST_NFT_ACCOUNT,
            TEST_NFT_ACCOUNT,
            false,
            "",
            ""
        );
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, address(v3utils), TEST_NFT, abi.encode(inst));
    }

    function testInvalidInstructions() external {
        // reverts with ERC721Receiver error if Instructions are invalid
        vm.expectRevert(abi.encodePacked("ERC721: transfer to non ERC721Receiver implementer"));
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, address(v3utils), TEST_NFT, abi.encode(true, false, 1, "test"));
    }

    function testSendEtherNotAllowed() external {
        bool success;
        vm.expectRevert(Constants.NotWETH.selector);
        (success,) = address(v3utils).call{value: 123}("");
    }

    function testOnERC721ReceivedWrongContract() external {
        vm.expectRevert(Constants.WrongContract.selector);
        v3utils.onERC721Received(address(this), TEST_NFT_ACCOUNT, TEST_NFT, "");
    }

    function testOnERC721ReceivedSelfSend() external {
        vm.prank(address(NPM));
        vm.expectRevert(Constants.SelfSend.selector);
        v3utils.onERC721Received(address(this), address(v3utils), TEST_NFT, "");
    }

    function testExecuteRevertsOnAmountError() external {
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.COMPOUND_FEES,
            address(DAI),
            0,
            0,
            type(uint256).max,
            0,
            "",
            0,
            0,
            "",
            type(uint128).max,
            type(uint128).max,
            0,
            0,
            0,
            0,
            0,
            0,
            block.timestamp,
            TEST_NFT_ACCOUNT,
            TEST_NFT_ACCOUNT,
            false,
            "",
            ""
        );

        vm.startPrank(TEST_NFT_ACCOUNT);
        NPM.approve(address(v3utils), TEST_NFT);
        vm.expectRevert(Constants.AmountError.selector);
        v3utils.execute(TEST_NFT, inst);
        vm.stopPrank();
    }

    function testExecuteChangeRangeWithToken0Target() external {
        (,,,,,,, uint128 liquidity,,,,) = NPM.positions(TEST_NFT_2_A);
        assertGt(liquidity, 0);

        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.CHANGE_RANGE,
            address(DAI),
            0,
            0,
            0,
            0,
            "",
            0,
            0,
            "",
            type(uint128).max,
            type(uint128).max,
            500,
            -276330,
            -276320,
            liquidity,
            0,
            0,
            block.timestamp,
            TEST_NFT_2_ACCOUNT,
            TEST_NFT_2_ACCOUNT,
            false,
            "",
            ""
        );

        vm.startPrank(TEST_NFT_2_ACCOUNT);
        NPM.approve(address(v3utils), TEST_NFT_2_A);
        uint256 newTokenId = v3utils.execute(TEST_NFT_2_A, inst);
        vm.stopPrank();

        assertGt(newTokenId, TEST_NFT_2_A);
        assertEq(NPM.ownerOf(newTokenId), TEST_NFT_2_ACCOUNT);
    }

    function testExecuteWithdrawAndCollectWithToken0Target() external {
        (,,,,,,, uint128 liquidity,,,,) = NPM.positions(TEST_NFT_5);
        assertGt(liquidity, 0);

        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            address(DAI),
            0,
            0,
            0,
            0,
            "",
            0,
            0,
            "",
            type(uint128).max,
            type(uint128).max,
            0,
            0,
            0,
            liquidity / 10,
            0,
            0,
            block.timestamp,
            TEST_NFT_5_ACCOUNT,
            TEST_NFT_5_ACCOUNT,
            false,
            "",
            ""
        );

        vm.startPrank(TEST_NFT_5_ACCOUNT);
        NPM.approve(address(v3utils), TEST_NFT_5);
        v3utils.execute(TEST_NFT_5, inst);
        vm.stopPrank();

        assertEq(NPM.ownerOf(TEST_NFT_5), TEST_NFT_5_ACCOUNT);
    }

    function testTransferWithCompoundNoSwap() external {
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.COMPOUND_FEES,
            address(0),
            0,
            0,
            0,
            0,
            "",
            0,
            0,
            "",
            type(uint128).max,
            type(uint128).max,
            0,
            0,
            0,
            0,
            0,
            0,
            block.timestamp,
            TEST_NFT_3_ACCOUNT,
            TEST_NFT_3_ACCOUNT,
            false,
            "",
            ""
        );

        uint256 daiBefore = DAI.balanceOf(TEST_NFT_3_ACCOUNT);
        uint256 usdcBefore = USDC.balanceOf(TEST_NFT_3_ACCOUNT);
        (,,,,,,, uint128 liquidityBefore,,,,) = NPM.positions(TEST_NFT_3);

        assertEq(daiBefore, 14382879654257202832190);
        assertEq(usdcBefore, 754563026);
        assertEq(liquidityBefore, 12922419498089422291);

        vm.prank(TEST_NFT_3_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_3_ACCOUNT, address(v3utils), TEST_NFT_3, abi.encode(inst));

        uint256 daiAfter = DAI.balanceOf(TEST_NFT_3_ACCOUNT);
        uint256 usdcAfter = USDC.balanceOf(TEST_NFT_3_ACCOUNT);
        (,,,,,,, uint128 liquidityAfter,,,,) = NPM.positions(TEST_NFT_3);

        assertEq(daiAfter, 14382879654257202838632);
        assertEq(usdcAfter, 806331571);
        assertEq(liquidityAfter, 13034529712992826193);
    }

    function testExecuteWithPermitCompoundNoSwap() external {
        uint256 privateKey = 777;
        address owner = vm.addr(privateKey);
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(TEST_NFT_3_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_3_ACCOUNT, owner, TEST_NFT_3);

        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.COMPOUND_FEES,
            address(0),
            0,
            0,
            0,
            0,
            "",
            0,
            0,
            "",
            type(uint128).max,
            type(uint128).max,
            0,
            0,
            0,
            0,
            0,
            0,
            deadline,
            owner,
            owner,
            false,
            "",
            ""
        );

        (,,,,,,, uint128 liquidityBefore,,,,) = NPM.positions(TEST_NFT_3);
        (uint8 v, bytes32 r, bytes32 s) = _getNpmPermitSignature(TEST_NFT_3, address(v3utils), deadline, privateKey);

        vm.prank(owner);
        v3utils.executeWithPermit(TEST_NFT_3, inst, v, r, s);

        (,,,,,,, uint128 liquidityAfter,,,,) = NPM.positions(TEST_NFT_3);
        assertEq(NPM.ownerOf(TEST_NFT_3), owner);
        assertGe(liquidityAfter, liquidityBefore);
    }
  
    function test_RevertWhen_EmptySwapAndMint() external {
        V3Utils.SwapAndMintParams memory params = V3Utils.SwapAndMintParams(
            DAI,
            USDC,
            500,
            MIN_TICK_500,
            -MIN_TICK_500,
            0,
            0,
            TEST_NFT_ACCOUNT,
            TEST_NFT_ACCOUNT,
            block.timestamp,
            IERC20(address(0)),
            0,
            0,
            "",
            0,
            0,
            "",
            0,
            0,
            ""
        );

        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(); // Add explicit expectRevert
        v3utils.swapAndMint(params);
    }

    function testSwapAndMintWithApprovals() public {
        uint256 amountDAI = 1 ether;
        uint256 amountUSDC = 1000000;
        address addr = vm.addr(123);

        // give coins
        vm.deal(addr, 1 ether);
        vm.prank(WHALE_ACCOUNT);
        USDC.transfer(addr, amountUSDC);

        vm.prank(DAI_WHALE_ACCOUNT);
        DAI.transfer(addr, amountDAI);

        vm.startPrank(addr);
        DAI.approve(address(v3utils), type(uint256).max);
        USDC.approve(address(v3utils), type(uint256).max);
        vm.stopPrank();

        V3Utils.SwapAndMintParams memory params = V3Utils.SwapAndMintParams(
            DAI,
            USDC,
            500,
            MIN_TICK_500,
            -MIN_TICK_500,
            amountDAI,
            amountUSDC,
            addr,
            addr,
            block.timestamp,
            IERC20(address(0)),
            0,
            0,
            "",
            0,
            0,
            "",
            0,
            0,
            ""
        );

        vm.prank(addr);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = v3utils.swapAndMint(params);

        assertGt(tokenId, 0);
        assertGt(liquidity, 0);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
    }

    function testSwapDataError() public {
        V3Utils.SwapParams memory params = V3Utils.SwapParams(
            USDC,
            DAI,
            1000000, // 1 USDC
            1 ether, // 1 DAI
            TEST_NFT_ACCOUNT,
            _getInvalidSwapData(),
            false
        );

        vm.startPrank(TEST_NFT_ACCOUNT);
        USDC.approve(address(v3utils), 1000000);

        vm.expectRevert();
        v3utils.swap(params);
        vm.stopPrank();
    }

    function testSwapAndIncreaseLiquidityNoSwap() external {
        (uint128 liquidity, uint256 amount0, uint256 amount1) = _increaseLiquidity();
        assertGt(liquidity, 0);
        assertGt(amount0, 0);
        assertEq(amount1, 0);
    }

    function _increaseLiquidity() internal returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        V3Utils.SwapAndIncreaseLiquidityParams memory params = V3Utils.SwapAndIncreaseLiquidityParams(
            TEST_NFT,
            1000000000000000000,
            0,
            TEST_NFT_ACCOUNT,
            block.timestamp,
            IERC20(address(0)),
            0, // no swap
            0,
            "",
            0, // no swap
            0,
            "",
            0,
            0
        );

        uint256 balanceBefore = DAI.balanceOf(TEST_NFT_ACCOUNT);

        vm.startPrank(TEST_NFT_ACCOUNT);
        DAI.approve(address(v3utils), 1000000000000000000);
        (liquidity, amount0, amount1) = v3utils.swapAndIncreaseLiquidity(params);
        vm.stopPrank();

        uint256 balanceAfter = DAI.balanceOf(TEST_NFT_ACCOUNT);

        // uniswap sometimes adds not full balance (this tests that leftover tokens were returned correctly)
        assertEq(balanceBefore - balanceAfter, 999999999999999633);

        assertEq(liquidity, 2001002825163355);
        assertEq(amount0, 999999999999999633); // added amount
        assertEq(amount1, 0); // only added on one side

        uint256 balanceDAI = DAI.balanceOf(address(v3utils));
        uint256 balanceUSDC = USDC.balanceOf(address(v3utils));

        assertEq(balanceDAI, 0);
        assertEq(balanceUSDC, 0);
    }

    function _getInvalidSwapData() internal view returns (bytes memory) {
        return abi.encode(EX0x, hex"1234567890");
    }

    function _getNpmPermitSignature(uint256 tokenId, address spender, uint256 deadline, uint256 privateKey)
        internal
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        (uint96 nonce,,,,,,,,,,,) = NPM.positions(tokenId);
        bytes32 structHash = keccak256(abi.encode(NPM.PERMIT_TYPEHASH(), spender, tokenId, nonce, deadline));
        bytes32 msgHash = keccak256(abi.encodePacked("\x19\x01", NPM.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(privateKey, msgHash);
    }

}
