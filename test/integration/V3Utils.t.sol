// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../src/utils/Constants.sol";
import "../../src/transformers/V3Utils.sol";

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
    address UNIVERSAL_ROUTER = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD; // uniswap universal router
    address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

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
        mainnetFork = vm.createFork("https://rpc.ankr.com/eth", 15489169);
        vm.selectFork(mainnetFork);
        v3utils = new V3Utils(NPM, EX0x, UNIVERSAL_ROUTER, PERMIT2);
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

    function testTransferDecreaseSlippageError() external {
        // add liquidity to existing (empty) position (add 1 DAI / 0 USDC)
        _increaseLiquidity();

        (,,,,,,, uint128 liquidityBefore,,,,) = NPM.positions(TEST_NFT);

        // swap a bit more dai than available - fails with slippage error because not enough liquidity + fees is collected
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.CHANGE_RANGE,
            address(USDC),
            1000000000000000001,
            400000,
            1000000000000000001,
            400000,
            _get05DAIToUSDCSwapData(),
            0,
            0,
            "",
            type(uint128).max, // take all fees
            type(uint128).max, // take all fees
            100, // change fee as well
            MIN_TICK_100,
            -MIN_TICK_100,
            liquidityBefore, // take all liquidity
            0,
            0,
            block.timestamp,
            TEST_NFT_ACCOUNT,
            TEST_NFT_ACCOUNT,
            false,
            "",
            ""
        );

        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert("Price slippage check");
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, address(v3utils), TEST_NFT, abi.encode(inst));
    }

    function testTransferAmountError() external {
        // add liquidity to existing (empty) position (add 1 DAI / 0 USDC)
        _increaseLiquidity();

        (,,,,,,, uint128 liquidityBefore,,,,) = NPM.positions(TEST_NFT);

        // swap a bit more dai than available - fails with slippage error because not enough liquidity + fees is collected
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.CHANGE_RANGE,
            address(USDC),
            0,
            0,
            1000000000000000001,
            400000,
            _get05DAIToUSDCSwapData(),
            0,
            0,
            "",
            type(uint128).max, // take all fees
            type(uint128).max, // take all fees
            100, // change fee as well
            MIN_TICK_100,
            -MIN_TICK_100,
            liquidityBefore, // take all liquidity
            0,
            0,
            block.timestamp,
            TEST_NFT_ACCOUNT,
            TEST_NFT_ACCOUNT,
            false,
            "",
            ""
        );

        vm.prank(TEST_NFT_ACCOUNT);
        vm.expectRevert(Constants.AmountError.selector);
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, address(v3utils), TEST_NFT, abi.encode(inst));
    }

    function testTransferWithChangeRange() external {
        // add liquidity to existing (empty) position (add 1 DAI / 0 USDC)
        _increaseLiquidity();

        uint256 countBefore = NPM.balanceOf(TEST_NFT_ACCOUNT);

        (,,,,,,, uint128 liquidityBefore,,,,) = NPM.positions(TEST_NFT);

        // swap half of DAI to USDC and add full range
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.CHANGE_RANGE,
            address(USDC),
            0,
            0,
            500000000000000000,
            400000,
            _get05DAIToUSDCSwapData(),
            0,
            0,
            "",
            type(uint128).max, // take all fees
            type(uint128).max, // take all fees
            100, // change fee as well
            MIN_TICK_100,
            -MIN_TICK_100,
            liquidityBefore, // take all liquidity
            0,
            0,
            block.timestamp,
            TEST_NFT_ACCOUNT,
            TEST_NFT_ACCOUNT,
            false,
            "",
            ""
        );

        // using approve / execute pattern
        vm.prank(TEST_NFT_ACCOUNT);
        NPM.approve(address(v3utils), TEST_NFT);

        vm.prank(TEST_NFT_ACCOUNT);
        v3utils.execute(TEST_NFT, inst);

        // now we have 2 NFTs (1 empty)
        uint256 countAfter = NPM.balanceOf(TEST_NFT_ACCOUNT);
        assertGt(countAfter, countBefore);

        (,,,,,,, uint128 liquidityAfter,,,,) = NPM.positions(TEST_NFT);
        assertEq(liquidityAfter, 0);
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

    function testTransferWithCompoundSwap() external {
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.COMPOUND_FEES,
            address(USDC),
            0,
            0,
            500000000000000000,
            400000,
            _get05DAIToUSDCSwapData(),
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

        assertEq(daiAfter, 14382879654257202836992);
        assertEq(usdcAfter, 807250914);
        assertEq(liquidityAfter, 13034375296304506054);
    }

    function _testTransferWithWithdrawAndSwap() internal {
        // add liquidity to existing (empty) position (add 1 DAI / 0 USDC)
        (uint128 liquidity,,) = _increaseLiquidity();

        uint256 countBefore = NPM.balanceOf(TEST_NFT_ACCOUNT);

        // swap half of DAI to USDC and add full range
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            address(USDC),
            0,
            0,
            990099009900989844, // uniswap returns 1 less when getting liquidity - this must be traded
            900000,
            _get1DAIToUSDSwapData(),
            0,
            0,
            "",
            0,
            0,
            0,
            0,
            0,
            liquidity,
            0,
            0,
            block.timestamp,
            TEST_NFT_ACCOUNT,
            TEST_NFT_ACCOUNT,
            false,
            "",
            ""
        );

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, address(v3utils), TEST_NFT, abi.encode(inst));

        uint256 countAfter = NPM.balanceOf(TEST_NFT_ACCOUNT);

        assertEq(countAfter, countBefore); // nft returned
    }

    function _testTransferWithCollectAndSwap() internal {
        // add liquidity to existing (empty) position (add 1 DAI / 0 USDC)
        (uint128 liquidity,,) = _increaseLiquidity();

        // decrease liquidity without collect (simulate fee growth)
        vm.prank(TEST_NFT_ACCOUNT);
        (uint256 amount0, uint256 amount1) = NPM.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams(TEST_NFT, liquidity, 0, 0, block.timestamp)
        );

        // should be same amount as added
        assertEq(amount0, 1000000000000000000);
        assertEq(amount1, 0);

        uint256 countBefore = NPM.balanceOf(TEST_NFT_ACCOUNT);

        // swap half of DAI to USDC and add full range
        V3Utils.Instructions memory inst = V3Utils.Instructions(
            V3Utils.WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP,
            address(USDC),
            0,
            0,
            990099009900989844, // uniswap returns 1 less when getting liquidity - this must be traded
            900000,
            _get1DAIToUSDSwapData(),
            0,
            0,
            "",
            SafeCast.toUint128(amount0),
            SafeCast.toUint128(amount1),
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

        vm.prank(TEST_NFT_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_ACCOUNT, address(v3utils), TEST_NFT, abi.encode(inst));

        uint256 countAfter = NPM.balanceOf(TEST_NFT_ACCOUNT);

        assertEq(countAfter, countBefore); // nft returned
    }

    function testFailEmptySwapAndIncreaseLiquidity() external {
        V3Utils.SwapAndIncreaseLiquidityParams memory params = V3Utils.SwapAndIncreaseLiquidityParams(
            TEST_NFT, 0, 0, TEST_NFT_ACCOUNT, block.timestamp, IERC20(address(0)), 0, 0, "", 0, 0, "", 0, 0, ""
        );

        vm.prank(TEST_NFT_ACCOUNT);
        v3utils.swapAndIncreaseLiquidity(params);
    }

    function testSwapAndIncreaseLiquidity() external {
        V3Utils.SwapAndIncreaseLiquidityParams memory params = V3Utils.SwapAndIncreaseLiquidityParams(
            TEST_NFT,
            0,
            1000000,
            TEST_NFT_ACCOUNT,
            block.timestamp,
            USDC,
            1000000,
            900000000000000000,
            _get1USDCToDAISwapData(),
            0,
            0,
            "",
            0,
            0,
            ""
        );

        vm.prank(TEST_NFT_ACCOUNT);
        USDC.approve(address(v3utils), 1000000);

        vm.prank(TEST_NFT_ACCOUNT);
        (uint128 liquidity, uint256 amount0, uint256 amount1) = v3utils.swapAndIncreaseLiquidity(params);

        uint256 feeBalance = DAI.balanceOf(TEST_FEE_ACCOUNT);

        assertEq(liquidity, 1981476553512400);
        assertEq(amount0, 990241757080297141);
        assertEq(amount0 / feeBalance, 100);
        assertEq(amount1, 0); // one sided adding
    }

    function testSwapAndIncreaseLiquiditBothSides() external {
        // add liquidity to another positions which is not owned

        V3Utils.SwapAndIncreaseLiquidityParams memory params = V3Utils.SwapAndIncreaseLiquidityParams(
            TEST_NFT_5,
            0,
            2000000,
            TEST_NFT_ACCOUNT,
            block.timestamp,
            USDC,
            1000000,
            900000000000000000,
            _get1USDCToDAISwapData(),
            0,
            0,
            "",
            0,
            0,
            ""
        );

        vm.prank(TEST_NFT_ACCOUNT);
        USDC.approve(address(v3utils), 2000000);

        uint256 usdcBefore = USDC.balanceOf(TEST_NFT_ACCOUNT);
        uint256 daiBefore = DAI.balanceOf(TEST_NFT_ACCOUNT);

        vm.prank(TEST_NFT_ACCOUNT);
        (uint128 liquidity, uint256 amount0, uint256 amount1) = v3utils.swapAndIncreaseLiquidity(params);

        uint256 usdcAfter = USDC.balanceOf(TEST_NFT_ACCOUNT);
        uint256 daiAfter = DAI.balanceOf(TEST_NFT_ACCOUNT);

        // close to 1% of swapped amount
        uint256 feeBalance = DAI.balanceOf(TEST_FEE_ACCOUNT);
        assertEq(feeBalance, 9845545793003026);

        assertEq(liquidity, 19461088218850);
        assertEq(amount0, 907298600975927920);
        assertEq(amount1, 1000000);

        // all usdc spent
        assertEq(usdcBefore - usdcAfter, 2000000);
        //some dai returned - because not 100% correct swap ratio
        assertEq(daiAfter - daiBefore, 82943156104369254);
    }

    function testFailEmptySwapAndMint() external {
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
            "",
            ""
        );

        vm.prank(TEST_NFT_ACCOUNT);
        v3utils.swapAndMint(params);
    }

    function testSwapAndMint() external {
        _testSwapAndMint(MIN_TICK_500, -MIN_TICK_500, 990200219842, 990241757079820864, 990159);
    }

    function testSwapAndMintOneSided0() external {
        _testSwapAndMint(MIN_TICK_500, MIN_TICK_500 + 200000, 837822485815257126640, 0, 1000000);
    }

    function testSwapAndMintOneSided1() external {
        _testSwapAndMint(
            -MIN_TICK_500 - 200000, -MIN_TICK_500, 829646810475079457895164424733679, 990241757080297174, 0
        );
    }

    function _testSwapAndMint(int24 lower, int24 upper, uint256 eLiquidity, uint256 eAmount0, uint256 eAmount1)
        internal
    {
        V3Utils.SwapAndMintParams memory params = V3Utils.SwapAndMintParams(
            DAI,
            USDC,
            500,
            lower,
            upper,
            0,
            2000000,
            TEST_NFT_ACCOUNT,
            TEST_NFT_ACCOUNT,
            block.timestamp,
            USDC,
            1000000,
            900000000000000000,
            _get1USDCToDAISwapData(),
            0,
            0,
            "",
            0,
            0,
            "",
            ""
        );

        vm.prank(TEST_NFT_ACCOUNT);
        USDC.approve(address(v3utils), 2000000);

        vm.prank(TEST_NFT_ACCOUNT);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = v3utils.swapAndMint(params);

        // close to 1% of swapped amount
        uint256 feeBalance = DAI.balanceOf(TEST_FEE_ACCOUNT);
        assertEq(feeBalance, 9845545793003026);

        assertGt(tokenId, 0);
        assertEq(liquidity, eLiquidity);
        assertEq(amount0, eAmount0);
        assertEq(amount1, eAmount1);
    }

    function testSwapAndMintPermit2() public {
        // use newer fork which has permit2
        mainnetFork = vm.createFork("https://rpc.ankr.com/eth", 18521658);
        vm.selectFork(mainnetFork);
        v3utils = new V3Utils(NPM, EX0x, UNIVERSAL_ROUTER, PERMIT2);

        uint256 amountDAI = 1 ether;
        uint256 amountUSDC = 1000000;
        uint256 privateKey = 123;
        address addr = vm.addr(privateKey);

        // give coins
        vm.deal(addr, 1 ether);
        vm.prank(WHALE_ACCOUNT);
        USDC.transfer(addr, amountUSDC);

        vm.prank(DAI_WHALE_ACCOUNT);
        DAI.transfer(addr, amountDAI);

        vm.prank(addr);
        USDC.approve(PERMIT2, type(uint256).max);

        vm.prank(addr);
        DAI.approve(PERMIT2, type(uint256).max);

        ISignatureTransfer.TokenPermissions[] memory permissions = new ISignatureTransfer.TokenPermissions[](2);
        permissions[0] = ISignatureTransfer.TokenPermissions(address(DAI), amountDAI);
        permissions[1] = ISignatureTransfer.TokenPermissions(address(USDC), amountUSDC);

        ISignatureTransfer.PermitBatchTransferFrom memory tf =
            ISignatureTransfer.PermitBatchTransferFrom(permissions, 1, block.timestamp);

        bytes memory signature = _getPermitBatchTransferFromSignature(tf, privateKey, address(v3utils));
        bytes memory permitData = abi.encode(tf, signature);

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
            "",
            permitData
        );

        vm.prank(addr);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = v3utils.swapAndMint(params);

        assertEq(tokenId, 599811);
        assertEq(liquidity, 999808574760);
        assertEq(amount0, 999617186163914918);
        assertEq(amount1, 1000000);
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
            TEST_NFT_ACCOUNT,
            TEST_NFT_ACCOUNT,
            block.timestamp,
            WETH_ERC20,
            500000000000000000, // 0.5ETH
            662616334956561731436,
            _get05ETHToDAISwapData(),
            500000000000000000, // 0.5ETH
            661794703,
            _get05ETHToUSDCSwapData(),
            0,
            0,
            "",
            ""
        );

        vm.prank(TEST_NFT_ACCOUNT);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) =
            v3utils.swapAndMint{value: 1 ether}(params);

        assertGt(tokenId, 0);
        assertEq(liquidity, 751622492052728);
        assertEq(amount0, 751654021355164315226);
        assertEq(amount1, 751590965);

        uint256 feeBalance0 = DAI.balanceOf(TEST_FEE_ACCOUNT);
        uint256 feeBalance1 = USDC.balanceOf(TEST_FEE_ACCOUNT);
        assertEq(feeBalance0, 4960241781990859038);
        assertEq(feeBalance1, 4953598);
    }

    function testSwapETHUSDC() public {
        V3Utils.SwapParams memory params = V3Utils.SwapParams(
            WETH_ERC20,
            USDC,
            500000000000000000, // 0.5ETH
            661794703,
            TEST_NFT_ACCOUNT,
            _get05ETHToUSDCSwapData(),
            false,
            ""
        );

        vm.prank(TEST_NFT_ACCOUNT);
        uint256 amountOut = v3utils.swap{value: (1 ether) / 2}(params);

        // fee in output token
        uint256 inputTokenBalance = WETH_ERC20.balanceOf(address(v3utils));

        // swapped to USDC - fee
        assertEq(amountOut, 752453266);

        // input token no leftovers allowed
        assertEq(inputTokenBalance, 0);

        uint256 feeBalance = USDC.balanceOf(TEST_FEE_ACCOUNT);
        assertEq(feeBalance, 4953598);
    }

    function testSwapUSDCDAI() public {
        V3Utils.SwapParams memory params = V3Utils.SwapParams(
            USDC,
            DAI,
            1000000, // 1 USDC
            9 ether / 10,
            TEST_NFT_ACCOUNT,
            _get1USDCToDAISwapData(),
            false,
            ""
        );

        vm.startPrank(TEST_NFT_ACCOUNT);
        USDC.approve(address(v3utils), 1000000);
        uint256 amountOut = v3utils.swap(params);
        vm.stopPrank();

        uint256 inputTokenBalance = USDC.balanceOf(address(v3utils));

        // swapped to DAI - fee
        assertEq(amountOut, 990241757080297174);

        // input token no leftovers allowed
        assertEq(inputTokenBalance, 0);

        uint256 feeBalance = DAI.balanceOf(TEST_FEE_ACCOUNT);
        assertEq(feeBalance, 9845545793003026);

        uint256 otherFeeBalance = USDC.balanceOf(TEST_FEE_ACCOUNT);
        assertEq(otherFeeBalance, 0);
    }

    function testSwapSlippageError() public {
        V3Utils.SwapParams memory params = V3Utils.SwapParams(
            USDC,
            DAI,
            1000000, // 1 USDC
            1 ether, // 1 DAI - will be less than 10**18 - this causes revert
            TEST_NFT_ACCOUNT,
            _get1USDCToDAISwapData(),
            false,
            ""
        );

        vm.startPrank(TEST_NFT_ACCOUNT);
        USDC.approve(address(v3utils), 1000000);

        vm.expectRevert(Constants.SlippageError.selector);
        v3utils.swap(params);
        vm.stopPrank();
    }

    function testSwapDataError() public {
        V3Utils.SwapParams memory params = V3Utils.SwapParams(
            USDC,
            DAI,
            1000000, // 1 USDC
            1 ether, // 1 DAI
            TEST_NFT_ACCOUNT,
            _getInvalidSwapData(),
            false,
            ""
        );

        vm.startPrank(TEST_NFT_ACCOUNT);
        USDC.approve(address(v3utils), 1000000);

        vm.expectRevert();
        v3utils.swap(params);
        vm.stopPrank();
    }

    function testSwapUSDCETH() public {
        V3Utils.SwapParams memory params = V3Utils.SwapParams(
            USDC,
            WETH_ERC20,
            1000000, // 1 USDC
            1 ether / 2000,
            TEST_NFT_ACCOUNT,
            _get1USDCToWETHSwapData(),
            true, // unwrap to real ETH
            ""
        );

        uint256 balanceBefore = TEST_NFT_ACCOUNT.balance;

        vm.startPrank(TEST_NFT_ACCOUNT);
        USDC.approve(address(v3utils), 1000000);
        uint256 amountOut = v3utils.swap(params);
        vm.stopPrank();

        uint256 inputTokenBalance = USDC.balanceOf(address(v3utils));
        uint256 balanceAfter = TEST_NFT_ACCOUNT.balance;

        // swapped to ETH - fee
        assertEq(amountOut, 650596134294829);
        assertEq(amountOut, balanceAfter - balanceBefore);

        // input token no leftovers allowed
        assertEq(inputTokenBalance, 0);

        uint256 feeBalance = WETH_ERC20.balanceOf(TEST_FEE_ACCOUNT);
        assertEq(feeBalance, 5561996757275);
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
            0,
            ""
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

    function _get1USDCToDAISwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=USDC&buyToken=DAI&sellAmount=1000000&slippagePercentage=0.01&feeRecipient=0x8df57E3D9dDde355dCE1adb19eBCe93419ffa0FB&buyTokenPercentageFee=0.01
        return abi.encode(
            EX0x,
            abi.encode(
                Swapper.ZeroxRouterData(
                    EX0x,
                    hex"415565b0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000006b175474e89094c44da98b954eedeac495271d0f00000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000da9d72c692dbf4e00000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000000190000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000034000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000006b175474e89094c44da98b954eedeac495271d0f00000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000002c000000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000025375736869537761700000000000000000000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000dccd1a52cca5d60000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000d9e1ce17f2641f24ae83637ab66a2cca9c378b9f00000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000002000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000006b175474e89094c44da98b954eedeac495271d0f0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006b175474e89094c44da98b954eedeac495271d0f0000000000000000000000000000000000000000000000000022fa78c39c9e120000000000000000000000008df57e3d9ddde355dce1adb19ebce93419ffa0fb0000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000d5d77f6b6f6356bff0"
                )
            )
        );
    }

    function _get1USDCToWETHSwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=USDC&buyToken=WETH&sellAmount=1000000&slippagePercentage=0.25&feeRecipient=0x8df57E3D9dDde355dCE1adb19eBCe93419ffa0FB&buyTokenPercentageFee=0.01
        return abi.encode(
            EX0x,
            abi.encode(
                Swapper.ZeroxRouterData(
                    EX0x,
                    hex"415565b0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000001f9dc54188eb400000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000038000000000000000000000000000000000000000000000000000000000000004800000000000000000000000000000000000000000000000000000000000000019000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000002c000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000002800000000000000000000000000000000000000000000000000000000000000280000000000000000000000000000000000000000000000000000000000000024000000000000000000000000000000000000000000000000000000000000f4240000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002800000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000003556e697377617000000000000000000000000000000000000000000000000000000000000000000000000000000f42400000000000000000000000000000000000000000000000000001feeb54efd7cf00000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000020000000000000000000000000c0a47dfe034b400b47bdad5fecda2621de6c4d950000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000001000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000000000000000000000000000000050f00d7491b0000000000000000000000008df57e3d9ddde355dce1adb19ebce93419ffa0fb0000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000869584cd0000000000000000000000001000000000000000000000000000000000000011000000000000000000000000000000000000000000000078be83f2d76356c092"
                )
            )
        );
    }

    function _get1DAIToUSDSwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=1000000000000000000&slippagePercentage=0.01&feeRecipient=0x8df57E3D9dDde355dCE1adb19eBCe93419ffa0FB&buyTokenPercentageFee=0.01
        return abi.encode(
            EX0x,
            abi.encode(
                Swapper.ZeroxRouterData(
                    EX0x,
                    hex"415565b00000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000eef0f00000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000000001900000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000340000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000002c00000000000000000000000000000000000000000000000000de0b6b3a7640000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000002536869626153776170000000000000000000000000000000000000000000000000000000000000000de0b6b3a764000000000000000000000000000000000000000000000000000000000000000f154a000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000003f7724180aa6b939894b5ca4314783b0b36b329000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000001000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000263b0000000000000000000000008df57e3d9ddde355dce1adb19ebce93419ffa0fb0000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000869584cd000000000000000000000000100000000000000000000000000000000000001100000000000000000000000000000000000000000000004dfad63cf16356c0a2"
                )
            )
        );
    }

    function _get05DAIToUSDCSwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=DAI&buyToken=USDC&sellAmount=500000000000000000&slippagePercentage=0.01&feeRecipient=0x8df57E3D9dDde355dCE1adb19eBCe93419ffa0FB&buyTokenPercentageFee=0.01
        return abi.encode(
            EX0x,
            abi.encode(
                Swapper.ZeroxRouterData(
                    EX0x,
                    hex"415565b00000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000006f05b59d3b2000000000000000000000000000000000000000000000000000000000000000777fa00000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000000001900000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000340000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000002c000000000000000000000000000000000000000000000000006f05b59d3b200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000025368696261537761700000000000000000000000000000000000000000000000000000000000000006f05b59d3b200000000000000000000000000000000000000000000000000000000000000078b18000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000003f7724180aa6b939894b5ca4314783b0b36b329000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000001000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000131e0000000000000000000000008df57e3d9ddde355dce1adb19ebce93419ffa0fb0000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000020000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000bde5ecabc66356c0b3"
                )
            )
        );
    }

    function _get05ETHToDAISwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=WETH&buyToken=DAI&sellAmount=500000000000000000&slippagePercentage=0.25&feeRecipient=0x8df57E3D9dDde355dCE1adb19eBCe93419ffa0FB&buyTokenPercentageFee=0.01
        return abi.encode(
            EX0x,
            abi.encode(
                Swapper.ZeroxRouterData(
                    EX0x,
                    hex"415565b0000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000006b175474e89094c44da98b954eedeac495271d0f00000000000000000000000000000000000000000000000006f05b59d3b2000000000000000000000000000000000000000000000000001ae3b7e205f992effe00000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000520000000000000000000000000000000000000000000000000000000000000062000000000000000000000000000000000000000000000000000000000000000190000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000046000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000006b175474e89094c44da98b954eedeac495271d0f00000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000420000000000000000000000000000000000000000000000000000000000000042000000000000000000000000000000000000000000000000000000000000003e000000000000000000000000000000000000000000000000006f05b59d3b2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000420000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000001942616c616e636572563200000000000000000000000000000000000000000000000000000000000006f05b59d3b2000000000000000000000000000000000000000000000000001b288e33a4c130911c000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000001c0000000000000000000000000ba12222222228d8ba445958a75a0704d566bf2c80000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020c45d42f801105e861e86658648e3678ad7aa70f900010000000000000000011e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000006b175474e89094c44da98b954eedeac495271d0f0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006b175474e89094c44da98b954eedeac495271d0f00000000000000000000000000000000000000000000000044d6519ec79da11e0000000000000000000000008df57e3d9ddde355dce1adb19ebce93419ffa0fb0000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000869584cd000000000000000000000000100000000000000000000000000000000000001100000000000000000000000000000000000000000000008699f81faa6356c0c5"
                )
            )
        );
    }

    function _get05ETHToUSDCSwapData() internal view returns (bytes memory) {
        // https://api.0x.org/swap/v1/quote?sellToken=WETH&buyToken=USDC&sellAmount=500000000000000000&slippagePercentage=0.25&feeRecipient=0x8df57E3D9dDde355dCE1adb19eBCe93419ffa0FB&buyTokenPercentageFee=0.01
        return abi.encode(
            EX0x,
            abi.encode(
                Swapper.ZeroxRouterData(
                    EX0x,
                    hex"415565b0000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000006f05b59d3b20000000000000000000000000000000000000000000000000000000000001d86975100000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000000190000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000034000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000002c000000000000000000000000000000000000000000000000006f05b59d3b200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000025375736869537761700000000000000000000000000000000000000000000000000000000000000006f05b59d3b20000000000000000000000000000000000000000000000000000000000001dd22d4f000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000d9e1ce17f2641f24ae83637ab66a2cca9c378b9f00000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000002000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000001000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000004b95fe0000000000000000000000008df57e3d9ddde355dce1adb19ebce93419ffa0fb0000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000bf186b7e2a6356c0d5"
                )
            )
        );
    }

    function _getInvalidSwapData() internal view returns (bytes memory) {
        return abi.encode(EX0x, hex"1234567890");
    }

    function _getPermitBatchTransferFromSignature(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        uint256 privateKey,
        address to
    ) internal returns (bytes memory sig) {
        bytes32 _PERMIT_BATCH_TRANSFER_FROM_TYPEHASH = keccak256(
            "PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
        );
        bytes32 _TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
        bytes32[] memory tokenPermissions = new bytes32[](permit.permitted.length);
        for (uint256 i = 0; i < permit.permitted.length; ++i) {
            tokenPermissions[i] = keccak256(abi.encode(_TOKEN_PERMISSIONS_TYPEHASH, permit.permitted[i]));
        }

        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IPermit2(PERMIT2).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        _PERMIT_BATCH_TRANSFER_FROM_TYPEHASH,
                        keccak256(abi.encodePacked(tokenPermissions)),
                        to,
                        permit.nonce,
                        permit.deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }
}
