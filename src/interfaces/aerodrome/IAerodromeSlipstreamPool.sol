// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "v3-core/interfaces/IUniswapV3Pool.sol";

/// @title Aerodrome Slipstream Pool Interface
/// @notice Extends Uniswap V3 pool with Aerodrome-specific functionality
interface IAerodromeSlipstreamPool is IUniswapV3Pool {
    // Aerodrome Slipstream pools are compatible with Uniswap V3 pools
    // This interface exists for clarity and potential future extensions
}