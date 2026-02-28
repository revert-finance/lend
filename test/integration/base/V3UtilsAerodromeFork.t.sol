// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../../../src/transformers/V3Utils.sol";
import "../../../src/interfaces/aerodrome/IAerodromeSlipstreamFactory.sol";
import "../../../src/interfaces/aerodrome/IAerodromeSlipstreamPool.sol";
import "../../../src/utils/Constants.sol";

contract V3UtilsAerodromeForkTest is Test, Constants {
    uint256 constant BASE_FORK_BLOCK = 42_113_455;
    uint256 constant TEST_NFT = 50994801;

    INonfungiblePositionManager constant NPM = INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);
    IAerodromeSlipstreamFactory constant FACTORY =
        IAerodromeSlipstreamFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);
    address constant UNIVERSAL_ROUTER = 0x198EF79F1F515F02dFE9e3115eD9fC07183f02fC;

    V3Utils internal v3utils;
    address internal owner;

    function setUp() external {
        uint256 forkId = vm.createFork(_baseRpc(), BASE_FORK_BLOCK);
        vm.selectFork(forkId);

        v3utils = new V3Utils(NPM, UNIVERSAL_ROUTER, address(0));
        owner = NPM.ownerOf(TEST_NFT);
    }

    function testChangeRangeHappyPathOnBaseFork() external {
        (,, address token0, address token1, uint24 fee, int24 oldTickLower, int24 oldTickUpper, uint128 liquidity,,,,) =
            NPM.positions(TEST_NFT);
        assertGt(liquidity, 0, "expected live liquidity");

        address pool = FACTORY.getPool(token0, token1, int24(fee));
        assertTrue(pool != address(0), "pool missing");
        (, int24 currentTick,,,,) = IAerodromeSlipstreamPool(pool).slot0();
        int24 spacing = IAerodromeSlipstreamPool(pool).tickSpacing();
        int24 baseTick = currentTick - (((currentTick % spacing) + spacing) % spacing);
        int24 newTickLower = baseTick - 10 * spacing;
        int24 newTickUpper = baseTick + 10 * spacing;
        assertTrue(newTickLower != oldTickLower || newTickUpper != oldTickUpper, "same range");

        vm.prank(owner);
        NPM.approve(address(v3utils), TEST_NFT);

        V3Utils.Instructions memory instructions = V3Utils.Instructions({
            whatToDo: V3Utils.WhatToDo.CHANGE_RANGE,
            targetToken: address(0),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            feeAmount0: type(uint128).max,
            feeAmount1: type(uint128).max,
            fee: fee,
            tickLower: newTickLower,
            tickUpper: newTickUpper,
            liquidity: liquidity,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            recipient: owner,
            recipientNFT: owner,
            unwrap: false,
            returnData: "",
            swapAndMintReturnData: ""
        });

        vm.prank(owner);
        uint256 newTokenId = v3utils.execute(TEST_NFT, instructions);
        assertTrue(newTokenId != 0 && newTokenId != TEST_NFT, "new token not created");
        assertEq(NPM.ownerOf(newTokenId), owner, "new token owner mismatch");

        (,,,,, int24 mintedTickLower, int24 mintedTickUpper, uint128 mintedLiquidity,,,,) = NPM.positions(newTokenId);
        assertEq(mintedTickLower, newTickLower, "new lower tick mismatch");
        assertEq(mintedTickUpper, newTickUpper, "new upper tick mismatch");
        assertGt(mintedLiquidity, 0, "new token liquidity is zero");
    }

    function testCompoundFeesIncreaseLiquidityPathOnBaseFork() external {
        (,,,, uint24 fee,,,,,,,) = NPM.positions(TEST_NFT);
        (, uint128 oldLiquidity,,,,) = _positionLiquidity(TEST_NFT);
        assertGt(oldLiquidity, 0, "expected live liquidity");

        vm.prank(owner);
        NPM.approve(address(v3utils), TEST_NFT);

        V3Utils.Instructions memory instructions = V3Utils.Instructions({
            whatToDo: V3Utils.WhatToDo.COMPOUND_FEES,
            targetToken: address(0),
            amountRemoveMin0: 0,
            amountRemoveMin1: 0,
            amountIn0: 0,
            amountOut0Min: 0,
            swapData0: "",
            amountIn1: 0,
            amountOut1Min: 0,
            swapData1: "",
            feeAmount0: type(uint128).max,
            feeAmount1: type(uint128).max,
            fee: fee,
            tickLower: 0,
            tickUpper: 0,
            liquidity: oldLiquidity / 2,
            amountAddMin0: 0,
            amountAddMin1: 0,
            deadline: block.timestamp,
            recipient: owner,
            recipientNFT: owner,
            unwrap: false,
            returnData: "",
            swapAndMintReturnData: ""
        });

        vm.prank(owner);
        v3utils.execute(TEST_NFT, instructions);

        (, uint128 newLiquidity,,,,) = _positionLiquidity(TEST_NFT);
        assertGt(newLiquidity, 0, "position became empty");
        assertEq(NPM.ownerOf(TEST_NFT), owner, "owner changed");
    }

    function _positionLiquidity(uint256 tokenId)
        internal
        view
        returns (uint24 fee, uint128 liquidity, int24 tickLower, int24 tickUpper, address token0, address token1)
    {
        (,, token0, token1, fee, tickLower, tickUpper, liquidity,,,,) = NPM.positions(tokenId);
    }

    function _baseRpc() internal returns (string memory rpcUrl) {
        try vm.envString("BASE_RPC_URL") returns (string memory baseRpc) {
            return baseRpc;
        } catch {
            return string.concat("https://rpc.ankr.com/base/", vm.envString("ANKR_API_KEY"));
        }
    }
}
