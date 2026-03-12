// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AerodromeTestBase.sol";
import "../../../src/transformers/AutoRangeAndCompound.sol";

/**
 * @title GaugeManagerAutoCompoundTest
 * @notice Tests AutoRangeAndCompound auto-compound integration through Vault->GM
 * @dev This test validates staked-position auto-compound flow via Vault.transform.
 */
contract GaugeManagerAutoCompoundTest is AerodromeTestBase {
    AutoRangeAndCompound public autoRange;

    // Position info
    uint256 public tokenId;
    uint128 public liquidity = 1000e18;

    function setUp() public override {
        super.setUp();

        autoRange = new AutoRangeAndCompound(
            INonfungiblePositionManager(address(npm)),
            admin, // operator
            admin, // withdrawer
            60, // TWAPSeconds
            200, // maxTWAPTickDifference
            address(0),
            address(0)
        );

        // Configure AutoRangeAndCompound in Vault and as a vault callback target.
        vault.setTransformer(address(autoRange), true);
        autoRange.setVault(address(vault));
        oracle.setMaxPoolPriceDifference(type(uint16).max);

        // Fund alice with tokens
        usdc.mint(alice, 10000e6);
        dai.mint(alice, 10000e18);
        aero.mint(address(usdcDaiGauge), 100e18); // Fund gauge with AERO for rewards
    }

    /**
     * @notice Test that verifies the GaugeManager->AutoRangeAndCompound autocompound transform works correctly
     * @dev This test specifically exercises the code path where GaugeManager re-encodes
     *      the ExecuteGaugeParams struct. The test will FAIL if the encoding is wrong.
     */
    function testAutoCompoundThroughVault() public {
        // 1. Create and stake a position as alice
        tokenId = createPosition(
            alice,
            address(usdc),
            address(dai),
            1, // tickSpacing
            -100, // tickLower
            100, // tickUpper
            1000e18 // liquidity
        );

        // Approve and deposit+stake in vault
        vm.prank(alice);
        npm.approve(address(vault), tokenId);

        vm.prank(alice);
        vault.create(tokenId, alice);

        vm.prank(alice);
        vault.stakePosition(tokenId);

        vm.startPrank(alice);
        vault.approveTransform(tokenId, admin, true);
        vault.approveTransform(tokenId, address(autoRange), true);
        autoRange.configToken(
            tokenId,
            address(vault),
            AutoRangeAndCompound.PositionConfig({
                lowerTickLimit: 0,
                upperTickLimit: 0,
                lowerTickDelta: 0,
                upperTickDelta: 0,
                token0SlippageX64: 0,
                token1SlippageX64: 0,
                onlyFees: false,
                autoCompound: true,
                maxRewardX64: 0,
                autoCompoundMin0: 0,
                autoCompoundMin1: 0,
                autoCompoundRewardMin: 0
            })
        );
        vm.stopPrank();

        // 2. Simulate some time passing and rewards accumulating
        vm.warp(block.timestamp + 1 days);

        // Mock the gauge to report rewards (tracked by user)
        usdcDaiGauge.setRewardForUser(alice, 10e18); // 10 AERO earned
        npm.setTokensOwed(tokenId, 0, 0);

        // 3. Prepare AutoRangeAndCompound auto-compound params (no swap, no new liquidity added)
        AutoRangeAndCompound.AutoCompoundParams memory params = AutoRangeAndCompound.AutoCompoundParams({
            tokenId: tokenId, swap0To1: true, amountIn: 0, deadline: block.timestamp + 1 hours
        });

        // 4. Call through Vault/GM as AutoRangeAndCompound operator
        vm.prank(admin);
        bytes memory transformData = abi.encodeCall(AutoRangeAndCompound.autoCompound, (params));

        // Execute transform - this will FAIL with "Transform failed" if encoding is wrong
        uint256 newTokenId = vault.transform(tokenId, address(autoRange), transformData);

        // 5. Verify transform succeeded
        // If we get here without reverting, the encoding was correct!
        assertEq(newTokenId, tokenId, "TokenId should remain the same");

        // Verify position is still staked
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge), "Position should still be staked");
    }
}
