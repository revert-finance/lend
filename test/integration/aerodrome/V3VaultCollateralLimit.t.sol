// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AerodromeTestBase.sol";

contract V3VaultCollateralLimitTest is AerodromeTestBase {
    function setUp() public override {
        super.setUp();

        oracle.setMaxPoolPriceDifference(type(uint16).max);
        vault.setLimits(0, 100_000_000, 100_000_000, 100_000_000, 100_000_000);

        uint32 limitFactor = uint32(Q32 / 2);
        vault.setTokenConfig(address(usdc), uint32(Q32 * 9 / 10), limitFactor);
        vault.setTokenConfig(address(dai), uint32(Q32 * 9 / 10), limitFactor);

        usdc.approve(address(vault), 10_000_000);
        vault.deposit(10_000_000, address(this));
    }

    function testCollateralValueLimitCannotBeBypassedViaMulticallDepositSandwich() external {
        uint256 tokenId = createPositionProper(
            alice,
            address(usdc),
            address(dai),
            1,
            -100,
            100,
            1e18,
            100e6,
            100e18
        );

        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);

        (, , uint256 collateralValue, ,) = vault.loanInfo(tokenId);
        uint256 borrowAmount = 6_000_000;
        assertGt(collateralValue, borrowAmount, "position should be healthy for the target borrow");

        vm.expectRevert(Constants.CollateralValueLimit.selector);
        vault.borrow(tokenId, borrowAmount);

        uint256 flashDepositAmount = 50_000_000;
        usdc.approve(address(vault), flashDepositAmount);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(V3Vault.deposit, (flashDepositAmount, alice));
        calls[1] = abi.encodeCall(V3Vault.borrow, (tokenId, borrowAmount));
        calls[2] = abi.encodeCall(V3Vault.withdraw, (flashDepositAmount, alice, alice));

        vm.expectRevert(Constants.CollateralValueLimit.selector);
        vault.multicall(calls);
        vm.stopPrank();

        (uint256 debtShares) = vault.loans(tokenId);
        assertEq(debtShares, 0, "bypass attempt must not leave residual debt");
    }
}
