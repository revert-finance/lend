// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AerodromeTestBase.sol";

contract BorrowDuringTransformTransformer {
    function execute(address vault, uint256 tokenId, uint256 assets) external {
        IVault(vault).borrow(tokenId, assets);
    }
}

contract UnexpectedNFTSender {
    function push(MockAerodromePositionManager npm, address from, address to, uint256 tokenId) external {
        npm.safeTransferFrom(from, to, tokenId);
    }
}

contract UnexpectedNFTTransferTransformer {
    MockAerodromePositionManager internal immutable npm;
    UnexpectedNFTSender internal immutable sender;

    constructor(MockAerodromePositionManager _npm) {
        npm = _npm;
        sender = new UnexpectedNFTSender();
    }

    function execute(address vault, uint256 unexpectedTokenId) external {
        npm.approve(address(sender), unexpectedTokenId);
        sender.push(npm, address(this), vault, unexpectedTokenId);
    }
}

contract DirectNFTTransferTransformer {
    MockAerodromePositionManager internal immutable npm;

    constructor(MockAerodromePositionManager _npm) {
        npm = _npm;
    }

    function execute(address vault, uint256 newTokenId) external {
        npm.safeTransferFrom(address(this), vault, newTokenId);
    }
}

contract TransformUnstakeExistingLoanTransformer {
    function execute(address attacker, uint256 tokenIdToUnstake) external {
        ReplacementDebtOverwriteAttacker(attacker).onTransformCallback(tokenIdToUnstake);
    }
}

contract ReplacementDebtOverwriteAttacker {
    V3Vault internal immutable vault;

    constructor(V3Vault _vault) {
        vault = _vault;
    }

    function borrow(uint256 tokenId, uint256 amount) external {
        vault.borrow(tokenId, amount);
    }

    function stake(uint256 tokenId) external {
        vault.stakePosition(tokenId);
    }

    function transform(uint256 tokenId, address transformer, bytes calldata data) external {
        vault.transform(tokenId, transformer, data);
    }

    function remove(uint256 tokenId, address recipient) external {
        vault.remove(tokenId, recipient, "");
    }

    function onTransformCallback(uint256 tokenIdToUnstake) external {
        vault.unstakePosition(tokenIdToUnstake);
    }
}

contract V3VaultTransformBorrowBufferTest is AerodromeTestBase {
    BorrowDuringTransformTransformer internal transformer;
    UnexpectedNFTTransferTransformer internal unexpectedNftTransformer;
    DirectNFTTransferTransformer internal directNftTransformer;
    TransformUnstakeExistingLoanTransformer internal unstakeExistingLoanTransformer;

    function setUp() public override {
        super.setUp();

        transformer = new BorrowDuringTransformTransformer();
        vault.setTransformer(address(transformer), true);

        unexpectedNftTransformer = new UnexpectedNFTTransferTransformer(npm);
        vault.setTransformer(address(unexpectedNftTransformer), true);

        directNftTransformer = new DirectNFTTransferTransformer(npm);
        vault.setTransformer(address(directNftTransformer), true);

        unstakeExistingLoanTransformer = new TransformUnstakeExistingLoanTransformer();
        vault.setTransformer(address(unstakeExistingLoanTransformer), true);

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

    function testTransformAllowsMigrationWhenOperatorDiffersButMaintainsCustody() external {
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

        uint256 unexpectedTokenId = 9_999_999;
        npm.setPosition(unexpectedTokenId, address(usdc), address(dai), 1, -100, 100, 1e18);
        npm.setTokensOwed(unexpectedTokenId, 0, 0);
        npm.mint(address(unexpectedNftTransformer), unexpectedTokenId);

        vm.prank(alice);
        uint256 returnedTokenId = vault.transform(
            tokenId,
            address(unexpectedNftTransformer),
            abi.encodeCall(UnexpectedNFTTransferTransformer.execute, (address(vault), unexpectedTokenId))
        );

        assertEq(returnedTokenId, unexpectedTokenId);
        assertEq(vault.ownerOf(unexpectedTokenId), alice);
        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(npm.ownerOf(tokenId), address(vault));
        assertEq(npm.ownerOf(unexpectedTokenId), address(vault));
    }

    function testTransformAllowsMigrationWhenOperatorIsActiveTransformer() external {
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

        uint256 newTokenId = 8_888_888;
        npm.setPosition(newTokenId, address(usdc), address(dai), 1, -100, 100, 1e18);
        npm.setTokensOwed(newTokenId, 0, 0);
        npm.mint(address(directNftTransformer), newTokenId);

        vm.prank(alice);
        uint256 returnedTokenId = vault.transform(
            tokenId,
            address(directNftTransformer),
            abi.encodeCall(DirectNFTTransferTransformer.execute, (address(vault), newTokenId))
        );

        assertEq(returnedTokenId, newTokenId);
        assertEq(vault.ownerOf(newTokenId), alice);
        assertEq(vault.ownerOf(tokenId), alice);
        assertEq(npm.ownerOf(newTokenId), address(vault));
        assertEq(npm.ownerOf(tokenId), address(vault));
    }

    function testTransformCannotReplaceWithExistingIndebtedToken() external {
        vm.warp(block.timestamp + 1);
        uint256 tokenIdA = createPositionProper(
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

        vm.warp(block.timestamp + 1);
        uint256 tokenIdX = createPositionProper(
            bob,
            address(usdc),
            address(dai),
            1,
            -100,
            100,
            1e18,
            50000e6,
            50000e18
        );

        ReplacementDebtOverwriteAttacker attacker = new ReplacementDebtOverwriteAttacker(vault);

        vm.startPrank(alice);
        npm.approve(address(vault), tokenIdA);
        vault.create(tokenIdA, address(attacker));
        vm.stopPrank();

        vm.startPrank(bob);
        npm.approve(address(vault), tokenIdX);
        vault.create(tokenIdX, address(attacker));
        vm.stopPrank();

        attacker.stake(tokenIdX);
        assertEq(gaugeManager.tokenIdToGauge(tokenIdX), address(usdcDaiGauge));
        assertEq(npm.ownerOf(tokenIdX), address(usdcDaiGauge));

        (, , uint256 collateralValue, ,) = vault.loanInfo(tokenIdX);
        uint256 borrowAmount = collateralValue * uint256(vault.BORROW_SAFETY_BUFFER_X32()) / Q32 / 2;
        assertGt(borrowAmount, 0);

        attacker.borrow(tokenIdX, borrowAmount);
        uint256 debtSharesBefore = vault.loans(tokenIdX);
        uint256 debtSharesTotalBefore = vault.debtSharesTotal();
        assertGt(debtSharesBefore, 0);

        vm.expectRevert(Constants.TransformFailed.selector);
        attacker.transform(
            tokenIdA,
            address(unstakeExistingLoanTransformer),
            abi.encodeCall(TransformUnstakeExistingLoanTransformer.execute, (address(attacker), tokenIdX))
        );

        assertEq(vault.loans(tokenIdX), debtSharesBefore, "existing debt must remain attached to X");
        assertEq(vault.debtSharesTotal(), debtSharesTotalBefore, "global debt accounting must remain unchanged");
        assertEq(gaugeManager.tokenIdToGauge(tokenIdX), address(usdcDaiGauge), "X should remain staked after revert");
        assertEq(npm.ownerOf(tokenIdX), address(usdcDaiGauge), "X custody should remain in the gauge after revert");

        vm.expectRevert(Constants.NeedsRepay.selector);
        attacker.remove(tokenIdX, alice);
    }
}
