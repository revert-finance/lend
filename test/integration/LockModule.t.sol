// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../TestBase.sol";

import "../../src/NFTHolder.sol";
import "../../src/modules/LockModule.sol";

contract LockModuleTest is Test, TestBase {
    NFTHolder holder;
    LockModule module;
    uint256 mainnetFork;
    uint8 moduleIndex;

    function setUp() external {
        mainnetFork = vm.createFork("https://rpc.flashbots.net", 15489169);
        vm.selectFork(mainnetFork);

        holder = new NFTHolder(NPM);
        module = new LockModule(holder);

        assertEq(
            address(module.factory()),
            0x1F98431c8aD98523631AE4a59f267346ea31F984
        );

        moduleIndex = holder.addModule(module, 0);
    }

    function _addLiquidityAndDecreasePartial() internal returns (uint256 amount0, uint256 amount1) {
         // add onesided liquidity
        vm.startPrank(TEST_ACCOUNT);
        DAI.approve(address(NPM), 1000000000000000000);

        uint128 liquidity;
        (
            liquidity,
            amount0,
            amount1
        ) = NPM.increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams(TEST_NFT_ID, 1000000000000000000, 0, 0, 0, block.timestamp));

        assertEq(amount0, 999999999999999633);
        assertEq(amount1, 0);

        // decrease to simulate fees
        (
            amount0,
            amount1
        ) = NPM.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams(TEST_NFT_ID, liquidity / 2, 0, 0, block.timestamp));

        vm.stopPrank();
    }

    function testLock() external {

        uint lockTime = 300;

        LockModule.PositionConfig memory config = LockModule.PositionConfig(uint32(block.timestamp + lockTime));
        NFTHolder.ModuleParams[] memory params = new NFTHolder.ModuleParams[](1);
        params[0] = NFTHolder.ModuleParams(moduleIndex, abi.encode(config));
        
        _addLiquidityAndDecreasePartial();

        vm.prank(TEST_ACCOUNT);
        NPM.safeTransferFrom(
                TEST_ACCOUNT,
                address(holder),
                TEST_NFT_ID,
                abi.encode(params)
            );

        // allow collect fees
        vm.prank(TEST_ACCOUNT);
        (uint amount0, uint amount1) = holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(TEST_NFT_ID, 0, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, false, address(this)));
        assertEq(amount0, 499999999999999566);
        assertEq(amount1, 0);

        // don't allow remove liquidity
        vm.prank(TEST_ACCOUNT);
        vm.expectRevert(LockModule.IsLocked.selector);
        holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(TEST_NFT_ID, 1, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, false, address(this)));

        // goto releasetime
        vm.warp(block.timestamp + lockTime);

        // now allowed
        vm.prank(TEST_ACCOUNT);
        holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(TEST_NFT_ID, 1, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, false, address(this)));
    }
}
