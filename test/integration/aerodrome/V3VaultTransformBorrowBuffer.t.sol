// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AerodromeTestBase.sol";

contract BorrowDuringTransformTransformer {
    function execute(address vault, uint256 tokenId, uint256 assets) external {
        IVault(vault).borrow(tokenId, assets);
    }
}

contract V3VaultTransformBorrowBufferTest is AerodromeTestBase {
    BorrowDuringTransformTransformer internal transformer;

    function setUp() public override {
        super.setUp();

        transformer = new BorrowDuringTransformTransformer();
        vault.setTransformer(address(transformer), true);
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        // Provide pool liquidity so borrows can succeed up to the health check.
        vault.setLimits(0, 10000000e6, 10000000e6, 1000000e6, 1000000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100000e6);
        vault.deposit(100000e6, alice);
        vm.stopPrank();
    }

    function testTransformBorrowCannotBypassBorrowSafetyBuffer() external {
        uint256 tokenId = createPositionProper(
            alice,
            address(usdc),
            address(dai),
            1,
            -100,
            100,
            1e18,
            50000e6,
            50000e18
        );

        vm.prank(alice);
        npm.approve(address(vault), tokenId);
        vm.prank(alice);
        vault.create(tokenId, alice);

        (, , uint256 collateralValue, ,) = vault.loanInfo(tokenId);
        assertGt(collateralValue, 0);

        uint256 bufferedMax = collateralValue * uint256(vault.BORROW_SAFETY_BUFFER_X32()) / Q32;
        uint256 amount = bufferedMax + 1;
        if (amount >= collateralValue) {
            amount = collateralValue - 1;
        }
        assertLt(amount, collateralValue);
        assertGt(amount, bufferedMax);

        // Direct borrow enforces the buffer.
        vm.prank(alice);
        vm.expectRevert(Constants.CollateralFail.selector);
        vault.borrow(tokenId, amount);

        // Transform-mode borrow used to bypass the buffer via the unbuffered end-of-transform health check.
        vm.prank(alice);
        vm.expectRevert(Constants.CollateralFail.selector);
        vault.transform(
            tokenId,
            address(transformer),
            abi.encodeCall(BorrowDuringTransformTransformer.execute, (address(vault), tokenId, amount))
        );
    }
}
