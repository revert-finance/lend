// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../integration/aerodrome/AerodromeTestBase.sol";

contract MockTransformerNoop {
    function exec() external {}
}

contract MockTransformerMintNew {
    MockAerodromePositionManager public immutable npm;
    address public immutable vault;

    constructor(MockAerodromePositionManager _npm, address _vault) {
        npm = _npm;
        vault = _vault;
    }

    // Called by the vault during V3Vault.transform/_transformUnstaked via low-level call.
    function exec(uint256 oldTokenId, uint256 newTokenId) external {
        (
            ,,
            address token0,
            address token1,
            uint24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,,,,
        ) = npm.positions(oldTokenId);

        npm.mint(address(this), newTokenId);
        npm.setPosition(newTokenId, token0, token1, int24(uint24(tickSpacing)), tickLower, tickUpper, liquidity);

        // Sending a new tokenId into the vault while `transformedTokenId != 0` triggers migration in vault callback.
        npm.safeTransferFrom(address(this), vault, newTokenId, "");
    }

    // Attempts to steal a token from the vault (should be impossible after a tokenId-changing transform).
    function steal(uint256 tokenId, address to) external {
        npm.safeTransferFrom(vault, to, tokenId);
    }
}

contract AtlasTransitionsTest is AerodromeTestBase {
    MockTransformerNoop internal noop;
    MockTransformerMintNew internal mintNew;

    function setUp() public override {
        super.setUp();

        // Make vault usable: default limits are 0.
        vault.setLimits(0, 10_000_000e6, 10_000_000e6, 10_000_000e6, 10_000_000e6);
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        noop = new MockTransformerNoop();
        mintNew = new MockTransformerMintNew(npm, address(vault));
        vault.setTransformer(address(noop), true);
        vault.setTransformer(address(mintNew), true);
    }

    function _depositPosition(address owner) internal returns (uint256 tokenId) {
        vm.warp(block.timestamp + 1);
        tokenId = createPositionProper(
            owner,
            address(usdc),
            address(dai),
            1, // tickSpacing
            -100,
            100,
            1000e18,
            50_000e6,
            50_000e18
        );

        vm.prank(owner);
        npm.approve(address(vault), tokenId);
        vm.prank(owner);
        vault.create(tokenId, owner);
    }

    function _lendToVault(address lender, uint256 amount) internal {
        vm.prank(lender);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(lender);
        vault.deposit(amount, lender);
    }

    function testCreateRegistersOwnerLoanAndCustody() public {
        uint256 tokenId = _depositPosition(alice);

        assertEq(vault.ownerOf(tokenId), alice);
        (uint256 debtShares) = vault.loans(tokenId);
        assertEq(debtShares, 0);
        assertEq(npm.ownerOf(tokenId), address(vault));
    }

    function testRawSafeTransferIntoVaultCreatesLoan() public {
        vm.warp(block.timestamp + 1);
        uint256 tokenId = createPositionProper(alice, address(usdc), address(dai), 1, -100, 100, 1e18, 100e6, 100e18);

        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        npm.safeTransferFrom(alice, address(vault), tokenId, "");
        vm.stopPrank();

        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(npm.ownerOf(tokenId), address(vault));
    }

    function testStakeThenUnstakeMovesCustodyAndTracksGauge() public {
        uint256 tokenId = _depositPosition(alice);

        vm.prank(alice);
        vault.stakePosition(tokenId);

        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
        assertEq(npm.ownerOf(tokenId), address(usdcDaiGauge));

        vm.prank(alice);
        vault.unstakePosition(tokenId);

        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
        assertEq(npm.ownerOf(tokenId), address(vault));
    }

    function testClaimRewardsRequiresStakedAndPaysOwner() public {
        uint256 tokenId = _depositPosition(alice);
        vm.prank(alice);
        vault.stakePosition(tokenId);

        // Rewards accrue to GaugeManager in the mock gauge (it is the staker).
        usdcDaiGauge.setRewardRate(0);
        usdcDaiGauge.setRewardForUser(address(gaugeManager), 5e18);

        uint256 beforeBal = aero.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = gaugeManager.claimRewards(tokenId, alice);

        assertEq(paid, 5e18);
        assertEq(aero.balanceOf(alice) - beforeBal, 5e18);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
    }

    function testCompoundRewardsReturnsZeroWhenNoRewardsAndKeepsStaked() public {
        uint256 tokenId = _depositPosition(alice);
        vm.prank(alice);
        vault.stakePosition(tokenId);

        // Ensure compound path short-circuits (no swaps).
        usdcDaiGauge.setRewardRate(0);
        usdcDaiGauge.setRewardForUser(address(gaugeManager), 0);

        vm.prank(alice);
        (uint256 aeroAmt, uint256 added0, uint256 added1) =
            gaugeManager.compoundRewards(tokenId, 0, 0, block.timestamp + 1 hours);

        assertEq(aeroAmt, 0);
        assertEq(added0, 0);
        assertEq(added1, 0);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
        assertEq(npm.ownerOf(tokenId), address(usdcDaiGauge));
    }

    function testTransformHandlesStakedPositionAndRestakes() public {
        uint256 tokenId = _depositPosition(alice);
        vm.prank(alice);
        vault.stakePosition(tokenId);

        vm.prank(alice);
        vault.transform(tokenId, address(noop), abi.encodeCall(MockTransformerNoop.exec, ()));

        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
        assertEq(npm.ownerOf(tokenId), address(usdcDaiGauge));
    }

    function testTransformUnstakesExecutesAndRestakes() public {
        uint256 tokenId = _depositPosition(alice);
        vm.prank(alice);
        vault.stakePosition(tokenId);

        vm.prank(alice);
        uint256 newTokenId = vault.transform(tokenId, address(noop), abi.encodeCall(MockTransformerNoop.exec, ()));

        assertEq(newTokenId, tokenId);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge));
        assertEq(npm.ownerOf(tokenId), address(usdcDaiGauge));
    }

    function testTokenIdChangingTransformClearsOldApprovalAndPreventsSteal() public {
        uint256 tokenId = _depositPosition(alice);

        uint256 newTokenId = tokenId + 1;
        vm.prank(alice);
        uint256 returned = vault.transform(
            tokenId, address(mintNew), abi.encodeCall(MockTransformerMintNew.exec, (tokenId, newTokenId))
        );

        assertEq(returned, newTokenId);
        assertEq(npm.ownerOf(newTokenId), address(vault));
        assertEq(vault.ownerOf(newTokenId), alice);

        // Old token remains in vault custody as a debt=0 position.
        assertEq(npm.ownerOf(tokenId), address(vault));
        assertEq(vault.ownerOf(tokenId), alice);

        // Both approvals must be cleared after transform completes.
        assertEq(npm.getApproved(newTokenId), address(0));
        assertEq(npm.getApproved(tokenId), address(0));

        // Transformer must not be able to pull the old token out of the vault afterwards.
        vm.expectRevert();
        mintNew.steal(tokenId, bob);
    }

    function testRemoveAutoUnstakesAndTransfersToRecipient() public {
        uint256 tokenId = _depositPosition(alice);
        vm.prank(alice);
        vault.stakePosition(tokenId);

        address recipient = address(0xBEEF);
        vm.prank(alice);
        vault.remove(tokenId, recipient, "");

        assertEq(vault.ownerOf(tokenId), address(0));
        assertEq(npm.ownerOf(tokenId), recipient);
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0));
    }

    function testBorrowAndRepayMoveUSDCAndMaintainDebtShares() public {
        _lendToVault(bob, 50_000e6);
        uint256 tokenId = _depositPosition(alice);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.borrow(tokenId, 1_000e6);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 1_000e6);
        assertEq(vaultBefore - usdc.balanceOf(address(vault)), 1_000e6);
        assertGt(vault.debtSharesTotal(), 0);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.repay(tokenId, type(uint256).max, false);
        vm.stopPrank();

        (uint256 debtShares) = vault.loans(tokenId);
        assertEq(debtShares, 0);
        assertEq(vault.debtSharesTotal(), 0);
    }

    function testDepositWithdrawRedeemMoveUSDCAndKeepExchangeRateAccounting() public {
        uint256 bobBefore = usdc.balanceOf(bob);

        _lendToVault(bob, 2_000e6);
        assertEq(usdc.balanceOf(bob), bobBefore - 2_000e6);
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)));

        // Withdraw by assets.
        vm.prank(bob);
        vault.withdraw(500e6, bob, bob);
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)));

        // Redeem remaining shares.
        uint256 sharesLeft = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(sharesLeft, bob, bob);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)));

        // Bob got back (approximately) what he put in; in this mock setup exchange rates should be stable.
        assertEq(usdc.balanceOf(bob), bobBefore);
    }

    function testTransformAuthorizationAndApprovalMigrationOnTokenIdChange() public {
        uint256 tokenId = _depositPosition(alice);

        // Non-owner cannot transform unless approved by owner via approveTransform().
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        vault.transform(tokenId, address(noop), abi.encodeCall(MockTransformerNoop.exec, ()));

        // Owner approves bob to transform this token.
        vm.prank(alice);
        vault.approveTransform(tokenId, bob, true);
        assertTrue(vault.transformApprovals(alice, tokenId, bob));

        // Bob can now run a tokenId-changing transform and approval must migrate.
        uint256 newTokenId = tokenId + 123;
        vm.prank(bob);
        uint256 returned = vault.transform(
            tokenId, address(mintNew), abi.encodeCall(MockTransformerMintNew.exec, (tokenId, newTokenId))
        );
        assertEq(returned, newTokenId);

        assertFalse(vault.transformApprovals(alice, tokenId, bob));
        assertTrue(vault.transformApprovals(alice, newTokenId, bob));
    }

    function testDecreaseLiquidityAndCollectPaysRecipientAndClearsFees() public {
        uint256 tokenId = _depositPosition(alice);

        // Make "fees" claimable without touching liquidity (mock NPM does not implement decreaseLiquidity).
        npm.setLiquidity(tokenId, 0);
        (,, address token0, address token1,,,,,,,,) = npm.positions(tokenId);

        uint128 owed0 = token0 == address(usdc) ? uint128(123e6) : uint128(456e18);
        uint128 owed1 = token1 == address(usdc) ? uint128(789e6) : uint128(111e18);
        npm.setTokensOwed(tokenId, owed0, owed1);

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = vault.decreaseLiquidityAndCollect(
            IVault.DecreaseLiquidityAndCollectParams({
                tokenId: tokenId,
                liquidity: 0,
                amount0Min: 0,
                amount1Min: 0,
                feeAmount0: type(uint128).max,
                feeAmount1: type(uint128).max,
                recipient: alice,
                deadline: block.timestamp + 1 hours
            })
        );

        assertEq(amount0, owed0);
        assertEq(amount1, owed1);

        // Fees must be cleared in the position manager.
        (,,,,,,,,,, uint128 owed0After, uint128 owed1After) = npm.positions(tokenId);
        assertEq(owed0After, 0);
        assertEq(owed1After, 0);
    }

    function testLiquidateUnhealthyPositionUsesAllowedUSDCAndNFTPaths() public {
        // Provide liquidity to the vault.
        _lendToVault(bob, 100_000e6);

        uint256 tokenId = _depositPosition(alice);

        // Borrow while position has value (liquidity > 0).
        vm.prank(alice);
        vault.borrow(tokenId, 10_000e6);

        // Make position severely undercollateralized but keep some fee value so liquidation can collect without decreaseLiquidity.
        npm.setLiquidity(tokenId, 0);
        (,, address token0, address token1,,,,,,,,) = npm.positions(tokenId);
        uint128 owed0 = token0 == address(usdc) ? uint128(500e6) : uint128(500e18);
        uint128 owed1 = token1 == address(usdc) ? uint128(0) : uint128(0);
        npm.setTokensOwed(tokenId, owed0, owed1);

        // Liquidator must approve vault to pull USDC.
        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        IVault.LiquidateParams memory params = IVault.LiquidateParams({
            tokenId: tokenId, amount0Min: 0, amount1Min: 0, recipient: bob, deadline: block.timestamp + 1 hours
        });
        (uint256 amount0, uint256 amount1) = vault.liquidate(params);
        vm.stopPrank();

        // Loan must be cleaned up (debt is cleared).
        (uint256 debtShares) = vault.loans(tokenId);
        assertEq(debtShares, 0);
        assertEq(vault.debtSharesTotal(), 0);

        // Liquidation collected some fees (as reported by mock NPM).
        assertTrue(amount0 != 0 || amount1 != 0);
    }

    function testWithdrawReservesTransfersOnlyUnprotectedAmount() public {
        // Reserve withdrawals are only possible when:
        // reserves > protected, where protected = lentAssetsUp * reserveProtectionFactorX32 / Q32.
        // With reserveFactorX32 == 0, reserves are expected to remain ~0 (no spread),
        // so we enable a large reserveFactor to deterministically generate reserves.
        uint256 Q32 = 2 ** 32;
        vault.setReserveFactor(type(uint32).max); // keep almost all interest as reserves (Q32 is uint256)

        // Create reserves by introducing debt and letting interest accrue.
        _lendToVault(bob, 10_000e6);
        uint256 tokenId = _depositPosition(alice);

        vm.prank(alice);
        vault.borrow(tokenId, 9_000e6);

        // Accrue interest once; 1 hour is enough with the mock IRM.
        vm.warp(block.timestamp + 1 hours);

        (uint256 debt, uint256 lentDown, uint256 balance, uint256 reserves,, uint256 lendExchangeRateX96) =
            vault.vaultInfo();
        assertGt(debt, 0, "expected debt");
        assertGt(lentDown, 0, "expected lent");
        assertGt(reserves, 0, "expected reserves");

        // Mirror withdrawReserves(): protected uses lend rounding UP.
        uint256 Q96 = 2 ** 96;
        uint256 lentUp = Math.mulDiv(vault.totalSupply(), lendExchangeRateX96, Q96, Math.Rounding.Up);
        uint256 protected = lentUp * vault.reserveProtectionFactorX32() / Q32;
        uint256 unprotected = reserves > protected ? reserves - protected : 0;
        uint256 available = balance > unprotected ? unprotected : balance;
        assertGt(available, 0, "expected withdrawable reserves");

        uint256 amount = available > 1e6 ? 1e6 : available;
        uint256 receiverBefore = usdc.balanceOf(address(0xCAFE));
        vault.withdrawReserves(amount, address(0xCAFE));
        assertEq(usdc.balanceOf(address(0xCAFE)) - receiverBefore, amount);
    }
}
