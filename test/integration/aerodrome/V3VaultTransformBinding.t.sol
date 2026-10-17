// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AerodromeTestBase.sol";
import "./V3VaultTransformPlanTests.t.sol";
import "../../../src/transformers/V3Utils.sol";

// ---------------------------------------------------------------------------------------------------------------
// Cantina scan (aero @ 268b484) High findings:
// - LEND-1: a former transform delegate kept its authority after the owner removed and redeposited the same NFT.
// - LEND-12: during a transform the vault accepted any fresh NFT as the replacement, so a helper could rebind the
//   live loan to an unrelated position. The vault now only accepts the token its active transformer announced.
// ---------------------------------------------------------------------------------------------------------------

contract LifecycleNoopTransformer {
    function execute() external {}
}

contract ForeignReplacementAnnouncer {
    function announce(address vault, uint256 tokenId) external {
        IVault(vault).expectReplacement(tokenId);
    }
}

/// Test transformer that owns pre-minted positions and delivers them in configurable ways.
contract ScriptedReplacementTransformer {
    MockAerodromePositionManager internal immutable npm;

    constructor(MockAerodromePositionManager _npm) {
        npm = _npm;
    }

    // asks a different contract to announce the replacement (only the active transformer may)
    function announceViaForeignContract(address vault, ForeignReplacementAnnouncer announcer, uint256 tokenId)
        external
    {
        announcer.announce(vault, tokenId);
        npm.safeTransferFrom(address(this), vault, tokenId);
    }

    // announce + deliver `first`, then deliver `second` (announced again only if `reannounce`)
    function chained(address vault, uint256 first, uint256 second, bool reannounce) external {
        IVault(vault).expectReplacement(first);
        npm.safeTransferFrom(address(this), vault, first);
        if (reannounce) {
            IVault(vault).expectReplacement(second);
        }
        npm.safeTransferFrom(address(this), vault, second);
    }
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

/// LEND-12 (simple transformers): only the announced token, announced by the active transformer, is accepted once.
contract V3VaultReplacementAnnouncementTest is AerodromeTestBase {
    ScriptedReplacementTransformer internal scripted;
    ForeignReplacementAnnouncer internal announcer;

    function setUp() public override {
        super.setUp();
        scripted = new ScriptedReplacementTransformer(npm);
        announcer = new ForeignReplacementAnnouncer();
        vault.setTransformer(address(scripted), true);
        oracle.setMaxPoolPriceDifference(type(uint16).max);
    }

    function _depositAlicePosition() internal returns (uint256 tokenId) {
        tokenId = createPosition(alice, address(usdc), address(dai), 1, -100, 100, 1000e18);
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vm.stopPrank();
    }

    function _mintTo(address to, uint256 tokenId) internal {
        npm.setPosition(tokenId, address(usdc), address(dai), 1, -100, 100, 1e18);
        npm.setTokensOwed(tokenId, 0, 0);
        npm.mint(to, tokenId);
    }

    function testExpectReplacementOutsideTransformReverts() public {
        vm.expectRevert(Unauthorized.selector);
        vault.expectReplacement(42);
    }

    function testOnlyActiveTransformerMayAnnounce() public {
        uint256 tokenId = _depositAlicePosition();
        _mintTo(address(scripted), 7_000_001);
        vm.prank(alice);
        vm.expectRevert(TransformFailed.selector);
        vault.transform(
            tokenId,
            address(scripted),
            abi.encodeCall(
                ScriptedReplacementTransformer.announceViaForeignContract, (address(vault), announcer, 7_000_001)
            )
        );
        assertEq(vault.ownerOf(tokenId), alice);
    }

    function testAnnouncementIsSingleUse() public {
        uint256 tokenId = _depositAlicePosition();
        _mintTo(address(scripted), 7_000_002);
        _mintTo(address(scripted), 7_000_003);
        vm.prank(alice);
        vm.expectRevert(TransformFailed.selector);
        vault.transform(
            tokenId,
            address(scripted),
            abi.encodeCall(ScriptedReplacementTransformer.chained, (address(vault), 7_000_002, 7_000_003, false))
        );
    }

    function testChainedReplacementsWithFreshAnnouncements() public {
        uint256 tokenId = _depositAlicePosition();
        _mintTo(address(scripted), 7_000_004);
        _mintTo(address(scripted), 7_000_005);
        vm.prank(alice);
        uint256 newTokenId = vault.transform(
            tokenId,
            address(scripted),
            abi.encodeCall(ScriptedReplacementTransformer.chained, (address(vault), 7_000_004, 7_000_005, true))
        );
        assertEq(newTokenId, 7_000_005);
        assertEq(vault.ownerOf(7_000_005), alice);
    }
}

/// Receives the position V3Utils minted during a vault transform and either forwards it, keeps it and sends an
/// unrelated substitute to the vault, or launders the substitute through V3Utils so it arrives from V3Utils itself.
contract ReplacementRoutingHelper {
    enum Mode {
        Forward,
        Substitute,
        Launder
    }

    MockAerodromePositionManager internal immutable npm;
    address internal immutable vault;
    address internal immutable v3utils;
    Mode public mode;
    uint256 public substituteTokenId;
    bool internal busy;

    constructor(MockAerodromePositionManager _npm, address _vault, address _v3utils) {
        npm = _npm;
        vault = _vault;
        v3utils = _v3utils;
    }

    function configure(Mode _mode, uint256 _substituteTokenId) external {
        mode = _mode;
        substituteTokenId = _substituteTokenId;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (!busy) {
            busy = true;
            if (mode == Mode.Forward) {
                npm.safeTransferFrom(address(this), vault, tokenId);
            } else if (mode == Mode.Substitute) {
                npm.safeTransferFrom(address(this), vault, substituteTokenId);
            } else {
                npm.safeTransferFrom(
                    address(this),
                    v3utils,
                    substituteTokenId,
                    abi.encode(changeRangeInstructions(vault, address(this)))
                );
            }
            busy = false;
        }
        return this.onERC721Received.selector;
    }
}

function changeRangeInstructions(address recipientNFT, address recipient) pure returns (V3Utils.Instructions memory) {
    return V3Utils.Instructions({
        whatToDo: V3Utils.WhatToDo.CHANGE_RANGE,
        targetToken: address(0),
        amountRemoveMin0: 0,
        amountRemoveMin1: 0,
        amountIn0: 0,
        amountOut0Min: 0,
        swapData0: "",
        amountIn1: 0,
        amountOut1Min: 0,
        swapData1: "",
        feeAmount0: 0,
        feeAmount1: 0,
        fee: 500,
        tickLower: -500,
        tickUpper: 500,
        liquidity: 0,
        amountAddMin0: 0,
        amountAddMin1: 0,
        deadline: type(uint256).max,
        recipient: recipient,
        recipientNFT: recipientNFT,
        unwrap: false,
        returnData: "",
        swapAndMintReturnData: ""
    });
}

/// LEND-12 through the real V3Utils transformer used in the scan's proof of concept.
contract V3VaultV3UtilsReplacementBindingTest is MintingNpmVaultTestBase {
    V3Utils internal v3utils;
    ReplacementRoutingHelper internal helper;
    uint256 internal tokenId;

    uint256 internal constant SUBSTITUTE_TOKEN_ID = 8_000_001;

    function setUp() public override {
        super.setUp();
        v3utils = new V3Utils(INonfungiblePositionManager(address(npm)), address(0x1), address(0x2));
        v3utils.setVault(address(vault));
        vault.setTransformer(address(v3utils), true);
        helper = new ReplacementRoutingHelper(npm, address(vault), address(v3utils));
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        tokenId = createPosition(alice, address(usdc), address(dai), 500, -100, 100, 1000e18);
        npm.setTokensOwed(tokenId, 0, 0);
        vm.startPrank(alice);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, alice);
        vm.stopPrank();

        // an unrelated, fresh position held by the helper
        npm.setPosition(SUBSTITUTE_TOKEN_ID, address(usdc), address(dai), 500, -500, 500, 1e18);
        npm.setTokensOwed(SUBSTITUTE_TOKEN_ID, 0, 0);
        npm.mint(address(helper), SUBSTITUTE_TOKEN_ID);
    }

    function _changeRange(address recipientNFT) internal returns (uint256) {
        vm.prank(alice);
        return vault.transform(
            tokenId,
            address(v3utils),
            abi.encodeCall(V3Utils.execute, (tokenId, changeRangeInstructions(recipientNFT, alice)))
        );
    }

    function _lastMinted() internal view returns (uint256) {
        return MockAutoRangeAndCompoundAerodromePositionManager(address(npm)).lastMintedTokenId();
    }

    function testChangeRangeMigratesLoanToMintedToken() public {
        uint256 returned = _changeRange(address(vault));
        uint256 minted = _lastMinted();
        assertEq(returned, minted);
        assertEq(vault.ownerOf(minted), alice);
        assertEq(npm.ownerOf(minted), address(vault));
    }

    function testHelperMayForwardTheAnnouncedToken() public {
        helper.configure(ReplacementRoutingHelper.Mode.Forward, 0);
        uint256 returned = _changeRange(address(helper));
        uint256 minted = _lastMinted();
        assertEq(returned, minted);
        assertEq(vault.ownerOf(minted), alice);
        assertEq(npm.ownerOf(minted), address(vault));
    }

    function testHelperCannotSubstituteAnUnrelatedNFT() public {
        helper.configure(ReplacementRoutingHelper.Mode.Substitute, SUBSTITUTE_TOKEN_ID);
        vm.expectRevert(TransformFailed.selector);
        _changeRange(address(helper));
        assertEq(vault.ownerOf(tokenId), alice, "loan stays on the original token");
        assertEq(vault.ownerOf(SUBSTITUTE_TOKEN_ID), address(0));
        assertEq(npm.ownerOf(SUBSTITUTE_TOKEN_ID), address(helper));
    }

    function testSubstituteLaunderedThroughV3UtilsIsRejected() public {
        // the substitute's replacement would arrive from V3Utils, the active transformer, so only the tokenId binding
        // stops it
        helper.configure(ReplacementRoutingHelper.Mode.Launder, SUBSTITUTE_TOKEN_ID);
        vm.expectRevert(TransformFailed.selector);
        _changeRange(address(helper));
        assertEq(vault.ownerOf(tokenId), alice, "loan stays on the original token");
    }
}
