// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AutoCompoundSlippage.t.sol";

/// @dev Test harnesses embed creation code and use an increased size limit. The production contracts and
/// linked library are checked independently against EIP-170 below.
contract AutoCompoundCarryForwardTest is AutoCompoundSlippageTest {
    function _withoutSwap() private {
        vm.prank(admin);
        autoRange.autoCompound(AutoRangeAndCompound.AutoCompoundParams(tokenId, false, 0, block.timestamp + 1));
    }

    function _saveLeftovers() private returns (uint256 left0, uint256 left1) {
        _configure(uint64(Q64 / 100));
        npm.setNextIncreaseLiquidityResult(40e18, 60e18);
        _withoutSwap();
        left0 = autoRange.positionBalances(tokenId, token0);
        left1 = autoRange.positionBalances(tokenId, token1);
    }

    function test_StoresUnusedFeesWithoutPayingThemToOwner() public {
        uint256 before0 = IERC20(token0).balanceOf(alice);
        uint256 before1 = IERC20(token1).balanceOf(alice);
        (uint256 left0, uint256 left1) = _saveLeftovers();
        uint256 rate = autoRange.compoundRewardX64(tokenId);
        assertEq(left0, FEES0 - 40e18 - 40e18 * rate / Q64);
        assertEq(left1, FEES1 - 60e18 - 60e18 * rate / Q64);
        assertEq(IERC20(token0).balanceOf(alice), before0);
        assertEq(IERC20(token1).balanceOf(alice), before1);
    }

    function test_ReusesSavedBalancesAndOnlyChargesNewlyAddedLiquidity() public {
        (uint256 left0, uint256 left1) = _saveLeftovers();
        uint256 fee0 = autoRange.positionBalances(0, token0);
        uint256 fee1 = autoRange.positionBalances(0, token1);
        uint256 before0 = IERC20(token0).balanceOf(address(npm));
        uint256 before1 = IERC20(token1).balanceOf(address(npm));
        uint256 rate = autoRange.compoundRewardX64(tokenId);
        // No new fees: the contract can still use saved funds when configured minimums are zero.
        _withoutSwap();
        uint256 added0 = IERC20(token0).balanceOf(address(npm)) - before0;
        uint256 added1 = IERC20(token1).balanceOf(address(npm)) - before1;
        assertGt(added0, 0);
        assertGt(added1, 0);
        assertEq(autoRange.positionBalances(0, token0), fee0 + added0 * rate / Q64);
        assertEq(autoRange.positionBalances(0, token1), fee1 + added1 * rate / Q64);
        assertEq(autoRange.positionBalances(tokenId, token0), left0 - added0 - added0 * rate / Q64);
        assertEq(autoRange.positionBalances(tokenId, token1), left1 - added1 - added1 * rate / Q64);
        assertLe(autoRange.positionBalances(tokenId, token0), 2);
        assertLe(autoRange.positionBalances(tokenId, token1), 2);
    }

    function test_WithdrawerCannotSweepPositionBalances() public {
        (uint256 left0, uint256 left1) = _saveLeftovers();
        address[] memory tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
        vm.prank(admin);
        autoRange.withdrawBalances(tokens, admin);
        assertEq(autoRange.positionBalances(0, token0), 0);
        assertEq(autoRange.positionBalances(0, token1), 0);
        assertEq(IERC20(token0).balanceOf(address(autoRange)), left0);
        assertEq(IERC20(token1).balanceOf(address(autoRange)), left1);
    }

    function test_DonationIsNotCreditedAsProtocolFeesOrUserRewards() public {
        (uint256 left0, uint256 left1) = _saveLeftovers();
        uint256 fee0 = autoRange.positionBalances(0, token0);
        uint256 donation = 1 ether;
        MockERC20(token0).mint(address(autoRange), donation);
        address[] memory tokens = new address[](1);
        tokens[0] = token0;
        uint256 before = IERC20(token0).balanceOf(admin);
        vm.prank(admin);
        autoRange.withdrawBalances(tokens, admin);
        assertEq(IERC20(token0).balanceOf(admin) - before, fee0);
        assertEq(IERC20(token0).balanceOf(address(autoRange)), left0 + donation);
        assertEq(autoRange.positionBalances(tokenId, token0), left0);
        assertEq(autoRange.positionBalances(tokenId, token1), left1);
        vm.prank(alice);
        autoRange.withdrawLeftoverBalances(tokenId, alice);
        assertEq(IERC20(token0).balanceOf(address(autoRange)), donation);
        vm.prank(admin);
        autoRange.withdrawBalances(tokens, admin);
        assertEq(IERC20(token0).balanceOf(address(autoRange)), donation);
    }

    function test_OnlyPositionOwnerCanWithdrawSavedBalances() public {
        (uint256 left0, uint256 left1) = _saveLeftovers();
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        autoRange.withdrawLeftoverBalances(tokenId, bob);
        uint256 before0 = IERC20(token0).balanceOf(alice);
        uint256 before1 = IERC20(token1).balanceOf(alice);
        vm.prank(alice);
        autoRange.withdrawLeftoverBalances(tokenId, alice);
        assertEq(IERC20(token0).balanceOf(alice) - before0, left0);
        assertEq(IERC20(token1).balanceOf(alice) - before1, left1);
        assertEq(autoRange.positionBalances(tokenId, token0), 0);
        assertEq(autoRange.positionBalances(tokenId, token1), 0);
        vm.prank(alice);
        autoRange.withdrawLeftoverBalances(tokenId, alice);
        assertEq(IERC20(token0).balanceOf(alice) - before0, left0);
    }

    function test_SwapFailurePreservesSavedBalancesAndProtocolFees() public {
        (uint256 left0, uint256 left1) = _saveLeftovers();
        uint256 fee0 = autoRange.positionBalances(0, token0);
        uint256 fee1 = autoRange.positionBalances(0, token1);
        pool.setOutputBps(9000);
        vm.expectRevert(SlippageError.selector);
        _compound();
        assertEq(autoRange.positionBalances(tokenId, token0), left0);
        assertEq(autoRange.positionBalances(tokenId, token1), left1);
        assertEq(autoRange.positionBalances(0, token0), fee0);
        assertEq(autoRange.positionBalances(0, token1), fee1);
    }

    function test_TwapFailureRetainsUninvestedFeesForNextAttempt() public {
        pool.setTick(300);
        pool.setOutputBps(9000);
        _configure(uint64(Q64 / 100));
        npm.setNextIncreaseLiquidityResult(1, 1);
        _compound();
        assertEq(autoRange.positionBalances(tokenId, token0), FEES0 - 1);
        assertEq(autoRange.positionBalances(tokenId, token1), FEES1 - 1);
        pool.setTick(0);
        _withoutSwap();
        assertLe(autoRange.positionBalances(tokenId, token0), 2);
        assertLe(autoRange.positionBalances(tokenId, token1), 2);
    }

    function test_ZeroLiquidityDustIsRetainedWithoutASecondFee() public {
        _configure(uint64(Q64 / 100));
        npm.setTokensOwed(tokenId, 1000, 1);
        uint256 before0 = IERC20(token0).balanceOf(address(npm));
        _withoutSwap();
        assertEq(autoRange.positionBalances(tokenId, token0), 1000);
        assertEq(autoRange.positionBalances(tokenId, token1), 1);
        _withoutSwap();
        assertEq(IERC20(token0).balanceOf(address(npm)), before0);
        assertEq(autoRange.positionBalances(tokenId, token0), 1000);
        assertEq(autoRange.positionBalances(tokenId, token1), 1);
        assertEq(autoRange.positionBalances(0, token0), 0);
        assertEq(autoRange.positionBalances(0, token1), 0);
    }

    function test_SavedOneSidedBalanceCanCompoundOutsideRange() public {
        _configure(uint64(Q64 / 100));
        npm.setTokensOwed(tokenId, 1000, 1);
        _withoutSwap();
        pool.setTick(-200);
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(-200));
        uint256 before0 = IERC20(token0).balanceOf(address(npm));
        _withoutSwap();
        assertGt(IERC20(token0).balanceOf(address(npm)), before0);
        assertLe(autoRange.positionBalances(tokenId, token0), 2);
    }

    function test_LinkedCompounderFitsRuntimeLimitAndKeepsBotSelector() public {
        assertLe(address(autoRange).code.length, 24576);
        assertLe(address(CompoundBalanceLib).code.length, 24576);
        assertEq(AutoRangeAndCompound.autoCompoundWithVaultAndRewardCompound.selector, bytes4(0xd403dcda));
    }

    function test_LibraryCannotBeCalledDirectlyToCreditFees() public {
        (bool success,) = address(CompoundBalanceLib)
            .call(
                abi.encodeWithSelector(
                    CompoundBalanceLib.creditProtocolFees.selector,
                    uint256(0),
                    token0,
                    token1,
                    uint256(100),
                    uint256(100)
                )
            );
        assertFalse(success);
        assertEq(autoRange.positionBalances(0, token0), 0);
    }

    function test_LinkedLiquidityOperationClearsAllowances() public {
        _saveLeftovers();
        assertEq(IERC20(token0).allowance(address(autoRange), address(npm)), 0);
        assertEq(IERC20(token1).allowance(address(autoRange), address(npm)), 0);
        assertEq(IERC20(token0).balanceOf(address(CompoundBalanceLib)), 0);
        assertEq(IERC20(token1).balanceOf(address(CompoundBalanceLib)), 0);
    }

    function test_OnlyWithdrawerCanWithdrawProtocolFees() public {
        _saveLeftovers();
        address[] memory tokens = new address[](1);
        tokens[0] = token0;
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        autoRange.withdrawBalances(tokens, bob);
    }

    function test_WithdrawalTransferFailureRollsBackBothBalances() public {
        (uint256 left0, uint256 left1) = _saveLeftovers();
        uint256 before0 = IERC20(token0).balanceOf(alice);
        vm.mockCall(token1, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(false));
        vm.prank(alice);
        vm.expectRevert();
        autoRange.withdrawLeftoverBalances(tokenId, alice);
        assertEq(autoRange.positionBalances(tokenId, token0), left0);
        assertEq(autoRange.positionBalances(tokenId, token1), left1);
        assertEq(IERC20(token0).balanceOf(alice), before0);
    }
}
