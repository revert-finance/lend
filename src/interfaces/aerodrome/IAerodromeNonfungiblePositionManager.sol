// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

/// @title Aerodrome Slipstream Nonfungible Position Manager Interface
/// @notice Aerodrome's position manager is compatible with Uniswap V3
/// @dev The main difference is that positions store tickSpacing instead of fee tier.
///      The tickSpacing is an immutable parameter of the pool that determines
///      the granularity of price levels. Unlike Uniswap V3's fixed fee tiers,
///      Aerodrome can set arbitrary trading fees independently from tick spacing.
interface IAerodromeNonfungiblePositionManager is INonfungiblePositionManager {
    // Aerodrome uses the same interface as Uniswap V3
    // The positions() function returns fee (uint24) but it actually contains tickSpacing
    // No conversion needed - we use the tickSpacing value directly to identify pools
}