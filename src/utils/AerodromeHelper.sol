// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title Helper functions for Aerodrome integration
library AerodromeHelper {
    /// @notice Maps Uniswap V3 fee tiers to Aerodrome tick spacings
    /// @param fee The Uniswap V3 fee tier
    /// @return tickSpacing The corresponding Aerodrome tick spacing
    // TODO this isnt right, they change it however they want
    function feeToTickSpacing(uint24 fee) internal pure returns (int24 tickSpacing) {
        if (fee == 100) tickSpacing = 1;        // 0.01% fee -> 1 tick spacing
        else if (fee == 500) tickSpacing = 10;  // 0.05% fee -> 10 tick spacing
        else if (fee == 3000) tickSpacing = 50; // 0.30% fee -> 50 tick spacing
        else if (fee == 10000) tickSpacing = 200; // 1.00% fee -> 200 tick spacing
        else revert("Invalid fee tier");
    }

    /// @notice Maps Aerodrome tick spacings to Uniswap V3 fee tiers
    /// @param tickSpacing The Aerodrome tick spacing
    /// @return fee The corresponding Uniswap V3 fee tier
    // TODO this isnt right, they change it however they want
    function tickSpacingToFee(int24 tickSpacing) internal pure returns (uint24 fee) {
        if (tickSpacing == 1) fee = 100;        // 1 tick spacing -> 0.01% fee
        else if (tickSpacing == 10) fee = 500;  // 10 tick spacing -> 0.05% fee
        else if (tickSpacing == 50) fee = 3000; // 50 tick spacing -> 0.30% fee
        else if (tickSpacing == 200) fee = 10000; // 200 tick spacing -> 1.00% fee
        else revert("Invalid tick spacing");
    }
}