// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../integration/aerodrome/AerodromeTestBase.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../../src/utils/Constants.sol";

contract MaliciousNftReceiver is IERC721Receiver {
    V3Vault public immutable vault;

    constructor(V3Vault _vault) {
        vault = _vault;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        // Try a few re-entrancy-style calls and swallow failures.
        try vault.withdrawReserves(0, address(this)) {} catch {}
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract MockTransformerMintNewForInvariant {
    MockAerodromePositionManager public immutable npm;
    address public immutable vault;

    constructor(MockAerodromePositionManager _npm, address _vault) {
        npm = _npm;
        vault = _vault;
    }

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
        npm.safeTransferFrom(address(this), vault, newTokenId, "");
    }
}

contract AtlasHandler is Test, Constants {
    V3Vault public immutable vault;
    GaugeManager public immutable gm;
    MockAerodromePositionManager public immutable npm;
    MockERC20 public immutable usdc;
    MockERC20 public immutable dai;

    address public immutable alice;
    address public immutable bob;
    address public immutable carol;

    MaliciousNftReceiver public immutable maliciousReceiver;
    MockTransformerMintNewForInvariant public immutable mintNew;

    uint256[] public tokenIds; // tokens still tracked by the vault (not removed)
    uint256[] public removedTokenIds; // tokens removed from the protocol (for postcondition invariants)

    constructor(
        V3Vault _vault,
        GaugeManager _gm,
        MockAerodromePositionManager _npm,
        MockERC20 _usdc,
        MockERC20 _dai,
        address _alice,
        address _bob,
        address _carol
    ) {
        vault = _vault;
        gm = _gm;
        npm = _npm;
        usdc = _usdc;
        dai = _dai;
        alice = _alice;
        bob = _bob;
        carol = _carol;

        maliciousReceiver = new MaliciousNftReceiver(_vault);
        mintNew = new MockTransformerMintNewForInvariant(_npm, address(_vault));
    }

    function actors(uint256 i) public view returns (address) {
        if (i % 3 == 0) return alice;
        if (i % 3 == 1) return bob;
        return carol;
    }

    function _tokenCount() internal view returns (uint256) {
        return tokenIds.length;
    }

    function tokenIdCount() external view returns (uint256) {
        return tokenIds.length;
    }

    function tokenIdAt(uint256 i) external view returns (uint256) {
        return tokenIds[i];
    }

    function removedTokenIdCount() external view returns (uint256) {
        return removedTokenIds.length;
    }

    function removedTokenIdAt(uint256 i) external view returns (uint256) {
        return removedTokenIds[i];
    }

    function mintNewTransformer() external view returns (address) {
        return address(mintNew);
    }

    function _pickToken(uint256 seed) internal view returns (uint256 tokenId, bool ok) {
        uint256 n = _tokenCount();
        if (n == 0) return (0, false);
        tokenId = tokenIds[seed % n];
        ok = tokenId != 0 && vault.ownerOf(tokenId) != address(0);
    }

    function _removeTracked(uint256 tokenId) internal {
        uint256 n = tokenIds.length;
        for (uint256 i = 0; i < n; i++) {
            if (tokenIds[i] == tokenId) {
                tokenIds[i] = tokenIds[n - 1];
                tokenIds.pop();
                return;
            }
        }
    }

    // Transition: USDC deposit (lender -> vault)
    function lendDeposit(uint256 actorSeed, uint256 amountSeed) external {
        address lender = actors(actorSeed);
        uint256 amount = bound(amountSeed, 1e6, 10_000e6);

        vm.startPrank(lender);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amount, lender);
        vm.stopPrank();
    }

    // Transition: USDC withdraw (vault -> lender)
    function lendWithdraw(uint256 actorSeed, uint256 amountSeed) external {
        address lender = actors(actorSeed);
        uint256 maxW = vault.maxWithdraw(lender);
        if (maxW == 0) return;

        uint256 amount = bound(amountSeed, 1e6, 10_000e6);
        if (amount > maxW) amount = maxW;
        if (amount == 0) return;

        vm.prank(lender);
        vault.withdraw(amount, lender, lender);
    }

    // Transition: create+deposit a new position NFT (wallet -> vault)
    function nftCreateDeposit(uint256 actorSeed) external {
        address owner = actors(actorSeed);

        // Unique tokenId; depends on timestamp in AerodromeTestBase helpers, so warp to avoid collisions.
        vm.warp(block.timestamp + 1);
        uint256 tokenId = uint256(keccak256(abi.encodePacked(owner, address(usdc), address(dai), block.timestamp)));
        npm.mint(owner, tokenId);
        npm.setPosition(tokenId, address(usdc), address(dai), 1, -100, 100, 1e18);
        npm.setTokensOwed(tokenId, 0, 0);

        vm.startPrank(owner);
        npm.approve(address(vault), tokenId);
        vault.create(tokenId, owner);
        vm.stopPrank();

        tokenIds.push(tokenId);
    }

    // Transition: stake (vault -> gauge)
    function nftStake(uint256 seed) external {
        (uint256 tokenId, bool ok) = _pickToken(seed);
        if (!ok) return;
        if (gm.tokenIdToGauge(tokenId) != address(0)) return;

        address owner = vault.ownerOf(tokenId);
        vm.prank(owner);
        vault.stakePosition(tokenId);
    }

    // Transition: unstake (gauge -> vault)
    function nftUnstake(uint256 seed) external {
        (uint256 tokenId, bool ok) = _pickToken(seed);
        if (!ok) return;
        if (gm.tokenIdToGauge(tokenId) == address(0)) return;

        address owner = vault.ownerOf(tokenId);
        vm.prank(owner);
        vault.unstakePosition(tokenId);
    }

    // Transition: borrow (vault -> borrower)
    function borrow(uint256 seed, uint256 amountSeed) external {
        (uint256 tokenId, bool ok) = _pickToken(seed);
        if (!ok) return;
        if (gm.tokenIdToGauge(tokenId) != address(0)) return; // keep simple: borrow only unstaked

        address owner = vault.ownerOf(tokenId);
        uint256 amount = bound(amountSeed, 1e6, 5_000e6);

        // Avoid reverts on liquidity: ensure vault has enough USDC.
        if (usdc.balanceOf(address(vault)) < amount) return;

        // Avoid reverts on health: only borrow if it succeeds.
        vm.startPrank(owner);
        try vault.borrow(tokenId, amount) {} catch {}
        vm.stopPrank();
    }

    // Transition: repay (borrower -> vault)
    function repay(uint256 seed, uint256 amountSeed) external {
        (uint256 tokenId, bool ok) = _pickToken(seed);
        if (!ok) return;
        address owner = vault.ownerOf(tokenId);
        (uint256 debtShares) = vault.loans(tokenId);
        if (debtShares == 0) return;

        uint256 amount = bound(amountSeed, 1e6, 10_000e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        // best-effort repay (may clamp internally)
        try vault.repay(tokenId, amount, false) {} catch {}
        vm.stopPrank();
    }

    // Transition: transform that changes tokenId (unstaked only)
    function transformMintNew(uint256 seed) external {
        (uint256 tokenId, bool ok) = _pickToken(seed);
        if (!ok) return;
        if (gm.tokenIdToGauge(tokenId) != address(0)) return;

        // Make sure transformer is allowlisted (idempotent).
        try vault.setTransformer(address(mintNew), true) {} catch {}

        address owner = vault.ownerOf(tokenId);
        uint256 newTokenId = uint256(keccak256(abi.encodePacked(tokenId, "new", block.timestamp)));
        vm.prank(owner);
        try vault.transform(
            tokenId, address(mintNew), abi.encodeCall(MockTransformerMintNewForInvariant.exec, (tokenId, newTokenId))
        ) returns (
            uint256 returned
        ) {
            if (returned == newTokenId) {
                tokenIds.push(newTokenId);
            }
        } catch {}
    }

    // Transition: remove (vault -> recipient)
    function remove(uint256 seed, uint256 toSeed) external {
        (uint256 tokenId, bool ok) = _pickToken(seed);
        if (!ok) return;
        (uint256 debtShares) = vault.loans(tokenId);
        if (debtShares != 0) return;

        address owner = vault.ownerOf(tokenId);
        address to = toSeed % 2 == 0 ? address(maliciousReceiver) : actors(toSeed);

        vm.prank(owner);
        try vault.remove(tokenId, to, "") {
            _removeTracked(tokenId);
            removedTokenIds.push(tokenId);
        } catch {}
    }

    // Transition: direct NFT safeTransfer into vault creates a new loan for `from`.
    function attack_rawNftSafeTransferIntoVault(uint256 actorSeed) external {
        address owner = actors(actorSeed);
        vm.warp(block.timestamp + 1);
        uint256 tokenId = uint256(keccak256(abi.encodePacked("raw", owner, block.timestamp)));
        npm.mint(owner, tokenId);
        npm.setPosition(tokenId, address(usdc), address(dai), 1, -100, 100, 1e18);
        vm.startPrank(owner);
        npm.approve(address(vault), tokenId);
        npm.safeTransferFrom(owner, address(vault), tokenId, "");
        vm.stopPrank();
        if (vault.ownerOf(tokenId) == owner) {
            tokenIds.push(tokenId);
        }
    }

    // Negative transition: transform by non-owner without approveTransform must revert (Unauthorized)
    function attack_unauthorizedTransform(uint256 seed, uint256 actorSeed) external {
        (uint256 tokenId, bool ok) = _pickToken(seed);
        if (!ok) return;
        if (gm.tokenIdToGauge(tokenId) != address(0)) return;

        address owner = vault.ownerOf(tokenId);
        address attacker = actors(actorSeed);
        if (attacker == owner) return;

        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        vault.transform(
            tokenId, address(mintNew), abi.encodeCall(MockTransformerMintNewForInvariant.exec, (tokenId, tokenId + 1))
        );
    }
}

contract AtlasInvariantsTest is AerodromeTestBase {
    AtlasHandler internal handler;

    address internal carol = address(0x4);

    function setUp() public override {
        super.setUp();

        // Make vault usable: default limits are 0.
        vault.setLimits(0, 10_000_000e6, 10_000_000e6, 10_000_000e6, 10_000_000e6);
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        // Ensure vault has baseline liquidity so borrow paths can execute.
        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(50_000e6, bob);
        vm.stopPrank();

        usdc.mint(carol, 100_000e6);
        dai.mint(carol, 100_000e18);

        handler = new AtlasHandler(vault, gaugeManager, npm, usdc, dai, alice, bob, carol);
        vault.setTransformer(handler.mintNewTransformer(), true);
    }

    function testFuzz_AtlasRandomWalk(uint256 seed) public {
        // Random walk over the atlas transitions; check invariants after each step.
        uint256 steps = 32;
        for (uint256 i = 0; i < steps; i++) {
            bytes32 h = keccak256(abi.encode(seed, i));
            uint256 choice = uint256(h) % 10;

            if (choice == 0) {
                handler.lendDeposit(uint256(h >> 8), uint256(h >> 16));
            } else if (choice == 1) {
                handler.lendWithdraw(uint256(h >> 8), uint256(h >> 16));
            } else if (choice == 2) {
                handler.nftCreateDeposit(uint256(h >> 8));
            } else if (choice == 3) {
                handler.nftStake(uint256(h >> 8));
            } else if (choice == 4) {
                handler.nftUnstake(uint256(h >> 8));
            } else if (choice == 5) {
                handler.borrow(uint256(h >> 8), uint256(h >> 16));
            } else if (choice == 6) {
                handler.repay(uint256(h >> 8), uint256(h >> 16));
            } else if (choice == 7) {
                handler.transformMintNew(uint256(h >> 8));
            } else if (choice == 8) {
                handler.remove(uint256(h >> 8), uint256(h >> 16));
            } else {
                // Alternate between the two negative transitions.
                if ((uint256(h >> 8) & 1) == 0) {
                    handler.attack_rawNftSafeTransferIntoVault(uint256(h >> 16));
                } else {
                    handler.attack_unauthorizedTransform(uint256(h >> 16), uint256(h >> 24));
                }
            }

            _assertInvariants();
        }
    }

    // -------- Invariants (high-signal) --------

    function _assertInvariants() internal {
        _invariant_transformedTokenIdCleared();
        _invariant_totalAssetsMatchesUSDCBalance();
        _invariant_vaultInfoAccountingIsSelfConsistent();
        _invariant_totalSupplyEqualsSumActorShareBalances();
        _invariant_maxRedeemAndMaxWithdrawAreBounded();
        _invariant_debtSharesTotalEqualsSumLoans();
        _invariant_tokenConfigTotalsMatchDebtSharesTotalForUsdcDaiOnly();
        _invariant_tokenConfigTotalsMatchLoansForKnownTokens();
        _invariant_trackedNFTCustodyMatchesStakedFlag();
        _invariant_trackedNFTOwnerIsKnownActor();
        _invariant_nftApprovalsClearedForTrackedTokens();
        _invariant_loanListsAreSelfConsistent();
        _invariant_removedTokensAreNotInProtocolOrCustodiedByVault();
        _invariant_removedTokensNotInOwnerLoanLists();
    }

    function _invariant_transformedTokenIdCleared() internal {
        assertEq(vault.transformedTokenId(), 0, "transformedTokenId must be 0 post-tx");
    }

    function _invariant_totalAssetsMatchesUSDCBalance() internal {
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)), "totalAssets must match USDC balance");
        (,, uint256 balance,,,) = vault.vaultInfo();
        assertEq(balance, usdc.balanceOf(address(vault)), "vaultInfo.balance must match USDC balance");
    }

    function _invariant_vaultInfoAccountingIsSelfConsistent() internal {
        (uint256 debt, uint256 lentDown, uint256 balance, uint256 reserves, uint256 debtX96, uint256 lendX96) =
            vault.vaultInfo();

        uint256 Q96 = 2 ** 96;
        uint256 debtCalc = Math.mulDiv(vault.debtSharesTotal(), debtX96, Q96, Math.Rounding.Up);
        uint256 lentCalcDown = Math.mulDiv(vault.totalSupply(), lendX96, Q96, Math.Rounding.Down);
        uint256 lentCalcUp = Math.mulDiv(vault.totalSupply(), lendX96, Q96, Math.Rounding.Up);

        assertEq(debt, debtCalc, "vaultInfo.debt must match debtSharesTotal conversion");
        assertEq(lentDown, lentCalcDown, "vaultInfo.lent must match totalSupply conversion (down)");

        uint256 reservesCalc = balance + debtCalc > lentCalcUp ? (balance + debtCalc - lentCalcUp) : 0;
        assertEq(reserves, reservesCalc, "vaultInfo.reserves must match max(0, balance+debt-lentUp)");
    }

    function _invariant_totalSupplyEqualsSumActorShareBalances() internal {
        // In this harness there are no share transfers; only deposits/withdraws for (alice,bob,carol).
        uint256 sum = vault.balanceOf(alice) + vault.balanceOf(bob) + vault.balanceOf(carol);
        assertEq(vault.totalSupply(), sum, "totalSupply must equal sum(share balances) for known actors");
    }

    function _invariant_maxRedeemAndMaxWithdrawAreBounded() internal {
        _assertMaxBoundsFor(alice);
        _assertMaxBoundsFor(bob);
        _assertMaxBoundsFor(carol);
    }

    function _assertMaxBoundsFor(address who) internal {
        uint256 maxR = vault.maxRedeem(who);
        uint256 maxW = vault.maxWithdraw(who);
        assertLe(maxR, vault.balanceOf(who), "maxRedeem must be <= share balance");
        assertLe(maxW, vault.totalAssets(), "maxWithdraw must be <= vault totalAssets");
    }

    function _invariant_debtSharesTotalEqualsSumLoans() internal {
        uint256 n = handler.tokenIdCount();
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.tokenIdAt(i);
            (uint256 shares) = vault.loans(tokenId);
            sum += shares;
        }
        assertEq(sum, vault.debtSharesTotal(), "debtSharesTotal must equal sum(loans[].debtShares)");
    }

    function _invariant_tokenConfigTotalsMatchDebtSharesTotalForUsdcDaiOnly() internal {
        // Handler only creates USDC/DAI positions, so totalDebtShares must match debtSharesTotal for both tokens.
        (,, uint192 usdcDebtShares) = vault.tokenConfigs(address(usdc));
        (,, uint192 daiDebtShares) = vault.tokenConfigs(address(dai));
        (,, uint192 wethDebtShares) = vault.tokenConfigs(address(weth));

        assertEq(uint256(usdcDebtShares), vault.debtSharesTotal(), "USDC totalDebtShares must equal debtSharesTotal");
        assertEq(uint256(daiDebtShares), vault.debtSharesTotal(), "DAI totalDebtShares must equal debtSharesTotal");
        assertEq(uint256(wethDebtShares), 0, "WETH totalDebtShares must be 0 in this harness");
    }

    function _invariant_tokenConfigTotalsMatchLoansForKnownTokens() internal {
        uint256 n = handler.tokenIdCount();
        uint192 usdcSum;
        uint192 daiSum;
        uint192 wethSum;

        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.tokenIdAt(i);
            (uint256 shares) = vault.loans(tokenId);
            if (shares == 0) continue;

            (,, address token0, address token1,,,,,,,,) = npm.positions(tokenId);
            if (token0 == address(usdc) || token1 == address(usdc)) usdcSum += uint192(shares);
            if (token0 == address(dai) || token1 == address(dai)) daiSum += uint192(shares);
            if (token0 == address(weth) || token1 == address(weth)) wethSum += uint192(shares);
        }

        (,, uint192 usdcDebtShares) = vault.tokenConfigs(address(usdc));
        (,, uint192 daiDebtShares) = vault.tokenConfigs(address(dai));
        (,, uint192 wethDebtShares) = vault.tokenConfigs(address(weth));

        assertEq(usdcDebtShares, usdcSum, "tokenConfigs[USDC].totalDebtShares mismatch");
        assertEq(daiDebtShares, daiSum, "tokenConfigs[DAI].totalDebtShares mismatch");
        assertEq(wethDebtShares, wethSum, "tokenConfigs[WETH].totalDebtShares mismatch");
    }

    function _invariant_trackedNFTCustodyMatchesStakedFlag() internal {
        uint256 n = handler.tokenIdCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.tokenIdAt(i);
            address owner = vault.ownerOf(tokenId);
            assertTrue(owner != address(0), "tracked token must have owner");

            address gauge = gaugeManager.tokenIdToGauge(tokenId);
            address nftOwner = npm.ownerOf(tokenId);

            // GM should never retain custody at end of a call.
            assertTrue(nftOwner != address(gaugeManager), "GM must not custody NFT post-tx");

            if (gauge == address(0)) {
                assertEq(nftOwner, address(vault), "unstaked token must be in vault custody");
            } else {
                assertEq(nftOwner, gauge, "staked token must be in gauge custody");
            }
        }
    }

    function _invariant_trackedNFTOwnerIsKnownActor() internal {
        uint256 n = handler.tokenIdCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.tokenIdAt(i);
            address owner = vault.ownerOf(tokenId);
            assertTrue(owner == alice || owner == bob || owner == carol, "tracked token owner must be known actor");
        }
    }

    function _invariant_nftApprovalsClearedForTrackedTokens() internal {
        uint256 n = handler.tokenIdCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.tokenIdAt(i);
            assertEq(npm.getApproved(tokenId), address(0), "NPM approval must be cleared");
        }
    }

    function _invariant_loanListsAreSelfConsistent() internal {
        _assertLoanListFor(alice);
        _assertLoanListFor(bob);
        _assertLoanListFor(carol);
    }

    function _assertLoanListFor(address who) internal {
        uint256 n = vault.loanCount(who);
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = vault.loanAtIndex(who, i);
            assertEq(vault.ownerOf(tokenId), who, "loanAtIndex token must map back to owner");
        }
    }

    function _invariant_removedTokensAreNotInProtocolOrCustodiedByVault() internal {
        uint256 n = handler.removedTokenIdCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.removedTokenIdAt(i);
            assertEq(vault.ownerOf(tokenId), address(0), "removed token must not be owned by protocol");
            assertEq(gaugeManager.tokenIdToGauge(tokenId), address(0), "removed token must not be staked");
            assertTrue(npm.ownerOf(tokenId) != address(vault), "removed token must not be in vault custody");
            assertTrue(npm.ownerOf(tokenId) != address(gaugeManager), "removed token must not be in GM custody");
            (uint256 shares) = vault.loans(tokenId);
            assertEq(shares, 0, "removed token must not carry debt shares");
        }
    }

    function _invariant_removedTokensNotInOwnerLoanLists() internal {
        uint256 n = handler.removedTokenIdCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.removedTokenIdAt(i);
            _assertNotInLoanList(alice, tokenId);
            _assertNotInLoanList(bob, tokenId);
            _assertNotInLoanList(carol, tokenId);
        }
    }

    function _assertNotInLoanList(address who, uint256 tokenId) internal {
        uint256 n = vault.loanCount(who);
        for (uint256 i = 0; i < n; i++) {
            assertTrue(vault.loanAtIndex(who, i) != tokenId, "removed token must not appear in loan list");
        }
    }
}
