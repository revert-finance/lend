// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./B20TestBase.sol";

/// @notice Vault behaviour for Coinbase B20 equity collateral (plan WP3 bucket 1, proposal §3.3, §4).
///         Per-name caps on both legs, cross pairs, minLoanSize, the dual-age state table, the
///         emergency freeze tuple, and liquidation at pilot factors including the zero-reserve loss path.
contract V3VaultB20Test is B20TestBase {
    uint128 constant NVDA_AMOUNT = 100e8; // ~$21.8K
    uint128 constant MSFT_AMOUNT = 10e8; // ~$5K

    // tick deltas for underlying moves: ln(x)/ln(1.0001)
    int24 constant DOWN_30 = -3_567;
    int24 constant DOWN_40 = -5_109;
    int24 constant DOWN_60 = -9_164;
    int24 constant DOWN_70 = -12_041;

    function _capNvda() internal view returns (uint256) {
        return lendAmount() * CAP_NVDA_PILOT / Q32; // 7,000 USDC at 200K lent
    }

    function _capMsft() internal view returns (uint256) {
        return lendAmount() * CAP_MSFT_PILOT / Q32; // 5,000 USDC at 200K lent
    }

    function _debt(uint256 tokenId) internal view returns (uint256 debt) {
        (debt,,,,) = vault.loanInfo(tokenId);
    }

    /// @dev loanInfo() values the collateral and therefore reverts during a blackout; shares do not
    function _debtShares(uint256 tokenId) internal view returns (uint256) {
        return vault.loans(tokenId);
    }

    function _openNvdaLoan(uint256 borrowAmount) internal returns (uint256 tokenId) {
        tokenId = _mintNvdaPosition(borrower, NVDA_AMOUNT, 0);
        _deposit(borrower, tokenId);
        if (borrowAmount != 0) {
            _borrow(borrower, tokenId, borrowAmount);
        }
    }

    // ---- caps (collateralValueLimitFactorX32) -----------------------------------------------------

    function testPilotCapValues() external {
        // X32 factors are floored, so the caps land a few units under the round number
        assertApproxEqAbs(_capNvda(), 7_000e6, 1e3);
        assertApproxEqAbs(_capMsft(), 5_000e6, 1e3);
    }

    function testPerNameCapBindsBeforeCollateralFactor() external {
        uint256 tokenId = _openNvdaLoan(6_000e6);
        (, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        assertGt(collateralValue, 8_000e6, "CF would allow more than the cap");
        assertApproxEqRel(collateralValue * Q32 / fullValue, CF_50, 1e12);

        _expectBorrowRevert(borrower, tokenId, 2_000e6, CollateralValueLimit.selector);
        _borrow(borrower, tokenId, 900e6); // 6,900 <= 7,000
    }

    function testCapBindsOnTheWeakerLegOfACrossPair() external {
        uint256 tokenId = _mintCrossPosition(borrower, NVDA_AMOUNT, MSFT_AMOUNT);
        _deposit(borrower, tokenId);

        // NVDAc cap 7,000 would allow it; MSFTc cap 5,000 does not
        _expectBorrowRevert(borrower, tokenId, 5_500e6, CollateralValueLimit.selector);
        _borrow(borrower, tokenId, 4_500e6);

        // the cross position's debt also counts against NVDAc: 4,500 + 3,000 > 7,000
        uint256 nvdaOnly = _openNvdaLoan(0);
        _expectBorrowRevert(borrower, nvdaOnly, 3_000e6, CollateralValueLimit.selector);
        _borrow(borrower, nvdaOnly, 2_000e6);
    }

    function testSameTransactionDepositDoesNotRaiseCaps() external {
        uint256 tokenId = _openNvdaLoan(0);

        // next day: the daily lend allowance resets so a 200K deposit is admissible
        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();

        usdc.mint(borrower, 200_000e6);
        vm.startPrank(borrower);
        usdc.approve(address(vault), 200_000e6);
        vault.deposit(200_000e6, borrower);
        vm.expectRevert(CollateralValueLimit.selector);
        vault.borrow(tokenId, 8_000e6);
        vm.stopPrank();
    }

    function testCrossPairUsesMinimumCollateralFactor() external {
        uint256 tokenId = _mintCrossPosition(borrower, NVDA_AMOUNT, MSFT_AMOUNT);
        _deposit(borrower, tokenId);
        (, uint256 fullValue, uint256 collateralValue,,) = vault.loanInfo(tokenId);
        assertApproxEqRel(collateralValue * Q32 / fullValue, CF_50, 1e12); // min(50%, 55%)
    }

    function testMinLoanSizeEnforced() external {
        uint256 tokenId = _openNvdaLoan(0);
        _expectBorrowRevert(borrower, tokenId, MIN_LOAN_SIZE - 1, MinLoanSize.selector);
        _borrow(borrower, tokenId, MIN_LOAN_SIZE);
    }

    // ---- blackout table (proposal §3.3) --------------------------------------------------------------

    function testLiquidationOnlyWindow() external {
        uint256 tokenId = _openNvdaLoan(5_000e6);
        uint256 sharesBefore = _debtShares(tokenId);

        // Position becomes unhealthy while the last equity print is still fresh.
        _moveNvda(nvdaTick + DOWN_60);
        // Read through the mock so the optimizer cannot substitute a post-vm.warp block.timestamp.
        uint256 equityUpdatedAt = nvdaFeed.updatedAt();

        // The short operational window expires, while the 30h liquidation window remains open.
        vm.warp(block.timestamp + EQUITY_MAX_FEED_AGE + 1);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        nvdaFeed.setUpdatedAt(equityUpdatedAt);

        // deposit collateral: works, never touches the oracle
        uint256 newPosition = _mintNvdaPosition(borrower, NVDA_AMOUNT, 0);
        _deposit(borrower, newPosition);
        assertEq(vault.ownerOf(newPosition), borrower);

        // borrow: frozen
        _expectBorrowRevert(borrower, tokenId, 1_000e6, ChainlinkPriceError.selector);
        _expectBorrowRevert(borrower, newPosition, 1_000e6, ChainlinkPriceError.selector);

        // Normal valuation and collateral removal are frozen.
        vm.expectRevert(ChainlinkPriceError.selector);
        vault.loanInfo(tokenId);
        (,,, uint256 liquidationCost, uint256 liquidationValue) = vault.loanInfoForLiquidation(tokenId);
        assertGt(liquidationCost, 0);
        assertGt(liquidationValue, liquidationCost);
        vm.prank(borrower);
        vm.expectRevert(ChainlinkPriceError.selector);
        vault.decreaseLiquidityAndCollect(
            IVault.DecreaseLiquidityAndCollectParams({
                tokenId: newPosition,
                liquidity: 0,
                amount0Min: 0,
                amount1Min: 0,
                feeAmount0: 0,
                feeAmount1: 0,
                deadline: block.timestamp + 1,
                recipient: borrower
            })
        );

        // repay: works
        vm.startPrank(borrower);
        usdc.approve(address(vault), 100e6);
        vault.repay(tokenId, 100e6, false);
        vm.stopPrank();
        assertLt(_debtShares(tokenId), sharesBefore);

        // Liquidation uses the longer age and remains available.
        usdc.mint(liquidator, 10_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(vault), 10_000e6);
        vault.liquidate(
            IVault.LiquidateParams({
                tokenId: tokenId, amount0Min: 0, amount1Min: 0, recipient: liquidator, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
        assertEq(_debtShares(tokenId), 0);

        // lender withdraw: works while liquid USDC remains
        uint256 lenderBefore = usdc.balanceOf(lender);
        vm.prank(lender);
        vault.withdraw(10_000e6, lender, lender);
        assertEq(usdc.balanceOf(lender) - lenderBefore, 10_000e6);
    }

    function testLiquidationFailsAfterLongWindow() external {
        uint256 tokenId = _openNvdaLoan(5_000e6);
        _moveNvda(nvdaTick + DOWN_60);
        uint256 equityUpdatedAt = nvdaFeed.updatedAt();

        vm.warp(block.timestamp + EQUITY_LIQUIDATION_MAX_FEED_AGE + 1);
        usdcRefFeed.setUpdatedAt(block.timestamp);
        nvdaFeed.setUpdatedAt(equityUpdatedAt);

        vm.expectRevert(ChainlinkPriceError.selector);
        vault.loanInfoForLiquidation(tokenId);

        usdc.mint(liquidator, 10_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(vault), 10_000e6);
        vm.expectRevert(ChainlinkPriceError.selector);
        vault.liquidate(
            IVault.LiquidateParams({
                tokenId: tokenId, amount0Min: 0, amount1Min: 0, recipient: liquidator, deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    // ---- emergency freeze tuple (plan WP4/WP6) ----------------------------------------------------

    function testEmergencyFreezeBlocksAllNewBorrowsButNotRepayOrLiquidate() external {
        uint256 tokenId = _openNvdaLoan(5_000e6);

        vault.setLimits(MIN_LOAN_SIZE, 2_000_000e6, 0, 0, 0);
        assertEq(vault.globalDebtLimit(), 0);

        _expectBorrowRevert(borrower, tokenId, 1_000e6, GlobalDebtLimit.selector);

        vm.startPrank(borrower);
        usdc.approve(address(vault), 500e6);
        vault.repay(tokenId, 500e6, false);
        vm.stopPrank();
        assertLt(_debt(tokenId), 5_000e6);

        // Repayment cannot reopen borrowing capacity while the zero ceiling is active.
        _expectBorrowRevert(borrower, tokenId, 400e6, GlobalDebtLimit.selector);

        // gap -60% while frozen: liquidation still works
        _moveNvda(nvdaTick + DOWN_60);
        (,,,, uint256 liquidationValue) = vault.loanInfo(tokenId);
        assertGt(liquidationValue, 0, "loan should be liquidatable");
        _liquidate(liquidator, tokenId);
        assertEq(_debt(tokenId), 0);
    }

    // ---- liquidation at pilot factors (proposal §4.1) -----------------------------------------------

    function testThirtyPercentGapStaysHealthyAtPilotCf() external {
        uint256 tokenId = _openNvdaLoan(6_900e6); // near the cap, ~63% of the CF-allowed max
        _moveNvda(nvdaTick + DOWN_30);
        (,,,, uint256 liquidationValue) = vault.loanInfo(tokenId);
        assertEq(liquidationValue, 0, "should still be healthy");
        vm.prank(liquidator);
        vm.expectRevert(NotLiquidatable.selector);
        vault.liquidate(
            IVault.LiquidateParams({
                tokenId: tokenId, amount0Min: 0, amount1Min: 0, recipient: liquidator, deadline: block.timestamp + 1
            })
        );
    }

    function testFortyPercentGapLiquidatesWithoutBadDebt() external {
        uint256 tokenId = _openNvdaLoan(6_900e6);
        uint256 lenderAssetsBefore = vault.convertToAssets(vault.balanceOf(lender));

        _moveNvda(nvdaTick + DOWN_40);
        (uint256 debt, uint256 fullValue,,, uint256 liquidationValue) = vault.loanInfo(tokenId);
        assertGt(liquidationValue, 0);
        assertGe(fullValue, debt * 110 / 100, "full value covers debt + max penalty: no reserve cost");

        (uint256 amount0, uint256 amount1) = _liquidate(liquidator, tokenId);
        assertGt(amount0 + amount1, 0, "liquidator receives collateral");
        assertEq(_debt(tokenId), 0);
        assertGe(vault.convertToAssets(vault.balanceOf(lender)), lenderAssetsBefore, "lenders whole");
    }

    function testSeventyPercentGapSocialisesLossToLendersWithZeroReserves() external {
        uint256 tokenId = _openNvdaLoan(6_900e6);
        uint256 lenderAssetsBefore = vault.convertToAssets(vault.balanceOf(lender));

        _moveNvda(nvdaTick + DOWN_70);
        (uint256 debt, uint256 fullValue,,,) = vault.loanInfo(tokenId);
        assertLt(fullValue, debt * 110 / 100, "below the 1.10x line: protocol loss");

        _liquidate(liquidator, tokenId);
        assertEq(_debt(tokenId), 0);
        assertLt(vault.convertToAssets(vault.balanceOf(lender)), lenderAssetsBefore, "first loss hits lenders");
    }
}

/// @notice Caps are relative to lentAssets: doubling the lend base doubles every cap.
contract V3VaultB20DoubleLendTest is B20TestBase {
    function lendAmount() internal pure override returns (uint256) {
        return 400_000e6;
    }

    function testCapsScaleWithLentAssets() external {
        uint256 tokenId = _mintNvdaPosition(borrower, 200e8, 0); // ~$43.6K so the CF does not bind first
        _deposit(borrower, tokenId);
        _expectBorrowRevert(borrower, tokenId, 15_000e6, CollateralValueLimit.selector);
        _borrow(borrower, tokenId, 13_000e6); // cap is now 14,000
    }
}
