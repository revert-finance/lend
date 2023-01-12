// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../TestBase.sol";

contract NFTHolderTest is TestBase {
   
    function setUp() external {
        _setupBase();
    }

    // add position with fees to compoundorModule
    function _setupPosition() internal {

        vm.prank(TEST_NFT_4_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_4_ACCOUNT, address(holder), TEST_NFT_4, "");
    }

    function testWithdrawWithoutUnwrap() external {

        _setupPosition();

        uint balance0Before = USDC.balanceOf(address(this));
        uint balance1Before = WETH_ERC20.balanceOf(address(this));

        // withdraw all fees
        vm.prank(TEST_NFT_4_ACCOUNT);
        (uint256 amount0, uint256 amount1,) = holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(TEST_NFT_4, 0, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, false, address(this), ""));

        uint balance0After = USDC.balanceOf(address(this));
        uint balance1After = WETH_ERC20.balanceOf(address(this));

        assertEq(amount0, 481306182);
        assertEq(amount1, 217965670349202189);

        assertEq(amount0, balance0After - balance0Before);
        assertEq(amount1, balance1After - balance1Before);
    }

    function testWithdrawWithUnwrap() external {

        _setupPosition();

        uint balance0Before = USDC.balanceOf(address(this));
        uint balance1Before = address(this).balance;

        // withdraw all fees
        vm.prank(TEST_NFT_4_ACCOUNT);
        (uint256 amount0, uint256 amount1,) = holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(TEST_NFT_4, 0, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, true, address(this), ""));

        uint balance0After = USDC.balanceOf(address(this));
        uint balance1After = address(this).balance;

        assertEq(amount0, 481306182);
        assertEq(amount1, 217965670349202189);

        assertEq(amount0, balance0After - balance0Before);
        assertEq(amount1, balance1After - balance1Before);
    }

    // for receiving ETH when decreasing liquidity
    receive() payable external {

    }
}
