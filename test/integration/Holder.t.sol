// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../TestBase.sol";

contract HolderTest is TestBase {
   
    function setUp() external {
        _setupBase();
    }

    // add position with fees to compoundorModule
    function _setupPosition() internal {

        vm.prank(TEST_NFT_4_ACCOUNT);
        NPM.safeTransferFrom(TEST_NFT_4_ACCOUNT, address(holder), TEST_NFT_4, "");
    }

    // test different minting to holder scenarios
    function _directV3UtilsMint(bool doRegisterOwner, bool oldV3Utils) internal {
        V3Utils.SwapAndMintParams memory params = V3Utils.SwapAndMintParams(
            DAI,
            USDC,
            500,
            MIN_TICK_500,
            -MIN_TICK_500,
            100000000000000000,
            1000000,
            TEST_NFT_ACCOUNT,
            address(holder),
            block.timestamp,
            USDC,
            0,
            0,
            "",
            0,
            0,
            "",
            0,
            0,
            doRegisterOwner,
            ""
        );

        if (oldV3Utils) {
            V3Utils newV3Utils = new V3Utils(NPM, EX0x);
            holder.setV3Utils(address(newV3Utils));
        }

        vm.prank(TEST_NFT_ACCOUNT);
        DAI.approve(address(v3utils), 100000000000000000);
        vm.prank(TEST_NFT_ACCOUNT);
        USDC.approve(address(v3utils), 1000000);

        if (!doRegisterOwner) {
            if (oldV3Utils) {
                // if using other (old) v3utils and calling without doRegisterOwner - it is added normally
            } else {
                vm.expectRevert(Holder.DirectMintingNotAllowed.selector);
            }
        } else {
            if (oldV3Utils) {
                vm.expectRevert(V3Utils.FutureOwnerNotRegistered.selector);
            }
        }
        vm.prank(TEST_NFT_ACCOUNT);
        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) = v3utils.swapAndMint(params);

        // check owner assignment
        if (!doRegisterOwner) {
            if (oldV3Utils) {
                assertEq(holder.tokenOwners(tokenId), address(v3utils));
            }
        } else {
            if (!oldV3Utils) {
                assertEq(holder.tokenOwners(tokenId), TEST_NFT_ACCOUNT);
            }
        }
    }

    function testDirectV3UtilsMintWithoutRegister() external {
        _directV3UtilsMint(false, false);
    }

    function testDirectV3UtilsMint() external {
        _directV3UtilsMint(true, false);
    }

    function testDirectV3UtilsMintWithoutRegisterOutdatedV3Utils() external {
        _directV3UtilsMint(false, true);
    }

    function testDirectV3UtilsMintOutdatedV3Utils() external {
        _directV3UtilsMint(true, true);
    }

    function testWithdrawWithoutUnwrap() external {

        _setupPosition();

        uint balance0Before = USDC.balanceOf(address(this));
        uint balance1Before = WETH_ERC20.balanceOf(address(this));

        // withdraw all fees
        vm.prank(TEST_NFT_4_ACCOUNT);
        (uint256 amount0, uint256 amount1,) = holder.decreaseLiquidityAndCollect(IHolder.DecreaseLiquidityAndCollectParams(TEST_NFT_4, 0, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, false, address(this), ""));

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
        (uint256 amount0, uint256 amount1,) = holder.decreaseLiquidityAndCollect(IHolder.DecreaseLiquidityAndCollectParams(TEST_NFT_4, 0, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, true, address(this), ""));

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
