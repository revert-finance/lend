// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Minimal view of a Base B20 token's ERC-8056 corporate-action multiplier.
///         1e18 means 1.0 (one token == one share). Cash dividends, splits and
///         emergency adjustments are applied by the issuer through this value.
interface IB20Multiplier {
    function multiplier() external view returns (uint256);
}
