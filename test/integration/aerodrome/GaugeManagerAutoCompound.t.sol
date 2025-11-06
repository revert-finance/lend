// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./AerodromeTestBase.sol";
import "../../../src/transformers/AutoCompound.sol";

/**
 * @title GaugeManagerAutoCompoundTest
 * @notice Tests the GaugeManager<->AutoCompound integration, specifically the ABI encoding fix
 * @dev This test validates that ExecuteGaugeParams struct is correctly encoded when calling
 *      AutoCompound.executeForGauge through GaugeManager.transform()
 *
 * Bug Context:
 * - AutoCompound.executeForGauge expects: function executeForGauge(ExecuteGaugeParams calldata params)
 * - The ABI encoding must treat params as a TUPLE (struct), not individual parameters
 * - Before fix: GaugeManager used abi.encodeWithSelector with individual params (WRONG)
 * - After fix: GaugeManager uses abi.encode(struct) + abi.encodePacked(selector, ...) (CORRECT)
 *
 * This test will:
 * - PASS with the correct encoding (current code)
 * - FAIL with "Transform failed" if using the buggy encoding
 */
contract GaugeManagerAutoCompoundTest is AerodromeTestBase {
    AutoCompound public autoCompound;

    // Position info
    uint256 public tokenId;
    uint128 public liquidity = 1000e18;

    function setUp() public override {
        super.setUp();

        // Deploy AutoCompound with proper router addresses
        autoCompound = new AutoCompound(
            INonfungiblePositionManager(address(npm)),
            admin,      // operator
            admin,      // withdrawer
            60,         // TWAPSeconds
            200,        // maxTWAPTickDifference
            address(0), // universalRouter (not needed for this test)
            address(0), // zeroxAllowanceHolder (not needed for this test)
            address(aero) // aeroToken
        );

        // Configure AutoCompound in GaugeManager
        gaugeManager.setTransformer(address(autoCompound), true);

        // Set GaugeManager as authorized in AutoCompound
        // Note: Test contract is owner since it deployed AutoCompound
        autoCompound.setGaugeManager(address(gaugeManager), true);

        // Fund alice with tokens
        usdc.mint(alice, 10000e6);
        dai.mint(alice, 10000e18);
        aero.mint(address(usdcDaiGauge), 100e18); // Fund gauge with AERO for rewards
    }

    /**
     * @notice Test that verifies the GaugeManager->AutoCompound transform works correctly
     * @dev This test specifically exercises the code path where GaugeManager re-encodes
     *      the ExecuteGaugeParams struct. The test will FAIL if the encoding is wrong.
     */
    function testAutoCompoundThroughTransform() public {
        // 1. Create and stake a position as alice
        tokenId = createPosition(
            alice,
            address(usdc),
            address(dai),
            1,      // tickSpacing
            -100,   // tickLower
            100,    // tickUpper
            1000e18 // liquidity
        );

        // Approve and stake in GaugeManager
        vm.prank(alice);
        npm.approve(address(gaugeManager), tokenId);

        vm.prank(alice);
        gaugeManager.stakePosition(tokenId);

        // 2. Simulate some time passing and rewards accumulating
        vm.warp(block.timestamp + 1 days);

        // Mock the gauge to report rewards (gauge tracks rewards by user, not tokenId)
        usdcDaiGauge.setRewardForUser(alice, 10e18); // 10 AERO earned

        // 3. Prepare AutoCompound params
        // We'll use empty swap data since we're testing encoding, not swap logic
        AutoCompound.ExecuteGaugeParams memory params = AutoCompound.ExecuteGaugeParams({
            tokenId: tokenId,
            aeroAmount: 0, // This will be replaced by GaugeManager with actual claimed amount
            swapData0: hex"", // Empty - no swap for this test
            swapData1: hex"", // Empty - no swap for this test
            minAmount0: 0,
            minAmount1: 0,
            aeroSplitBps: 5000, // 50/50 split
            deadline: block.timestamp + 1 hours
        });

        // 4. Call transform through GaugeManager as alice
        // This is THE CRITICAL TEST: The encoding must be correct for this to succeed
        vm.prank(alice);
        bytes memory transformData = abi.encodeCall(AutoCompound.executeForGauge, (params));

        // Execute transform - this will FAIL with "Transform failed" if encoding is wrong
        uint256 newTokenId = gaugeManager.transform(
            tokenId,
            address(autoCompound),
            transformData
        );

        // 5. Verify transform succeeded
        // If we get here without reverting, the encoding was correct!
        assertEq(newTokenId, tokenId, "TokenId should remain the same");

        // Verify position is still staked
        assertEq(gaugeManager.tokenIdToGauge(tokenId), address(usdcDaiGauge), "Position should still be staked");
        assertEq(gaugeManager.positionOwners(tokenId), alice, "Alice should still be owner");
    }

}
