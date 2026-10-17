// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AerodromeTestBase.sol";

// ---------------------------------------------------------------------------------------------------------------
// Cantina scan (aero @ 268b484) High findings:
// - LEND-1: a former transform delegate kept its authority after the owner removed and redeposited the same NFT.
// - LEND-12: during a transform the vault accepted any fresh NFT as the replacement, so a helper could rebind the
//   live loan to an unrelated position. The vault now only accepts the token its active transformer announced.
// ---------------------------------------------------------------------------------------------------------------

contract LifecycleNoopTransformer {
    function execute() external {}
}

/// LEND-1: transform approvals belong to one deposit of a token and expire when it leaves the vault.
contract V3VaultTransformApprovalLifecycleTest is AerodromeTestBase {
    LifecycleNoopTransformer internal noop;

    function setUp() public override {
        super.setUp();
        noop = new LifecycleNoopTransformer();
        vault.setTransformer(address(noop), true);
        oracle.setMaxPoolPriceDifference(type(uint16).max);
    }

    function _deposit(uint256 tokenId) internal {
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vm.stopPrank();
    }

    function _noopTransform(address caller, uint256 tokenId) internal {
        vm.prank(caller);
        vault.transform(tokenId, address(noop), abi.encodeCall(LifecycleNoopTransformer.execute, ()));
    }

    function testRemovalExpiresDelegateApprovalForRedeposit() public {
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000e18);
        _deposit(tokenId);
        vm.prank(alice);
        vault.approveTransform(tokenId, bob, true);
        assertTrue(vault.transformApprovals(alice, tokenId, bob));
        _noopTransform(bob, tokenId);

        // alice removes the NFT and later deposits the same tokenId again without revoking bob first
        vm.prank(alice);
        vault.remove(tokenId, alice, "");
        _deposit(tokenId);

        assertFalse(vault.transformApprovals(alice, tokenId, bob), "approval expired with the earlier deposit");
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        vault.transform(tokenId, address(noop), abi.encodeCall(LifecycleNoopTransformer.execute, ()));

        // a fresh approval for the new deposit works again
        vm.prank(alice);
        vault.approveTransform(tokenId, bob, true);
        assertTrue(vault.transformApprovals(alice, tokenId, bob));
        _noopTransform(bob, tokenId);
    }

    function testRevokedApprovalBlocksDelegate() public {
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000e18);
        _deposit(tokenId);
        vm.startPrank(alice);
        vault.approveTransform(tokenId, bob, true);
        vault.approveTransform(tokenId, bob, false);
        vm.stopPrank();
        assertFalse(vault.transformApprovals(alice, tokenId, bob));
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        vault.transform(tokenId, address(noop), abi.encodeCall(LifecycleNoopTransformer.execute, ()));
    }

    function testApprovalWithoutOwnershipIsRejected() public {
        uint256 tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000e18);
        _deposit(tokenId);
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        vault.approveTransform(tokenId, bob, true);
    }
}
