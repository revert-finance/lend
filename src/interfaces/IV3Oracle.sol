// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IV3Oracle {
    // gets value and prices for a given v3 nft denominated in token
    // reverts if any involved token is not configured
    // reverts if prices are not valid given oracle configuration
    function getValue(uint256 tokenId, address token) external view returns (uint256 value, uint256 feeValue, uint price0X06, uint price1X06);

    // gets breakdown of position specifying liquidity amounts and available fee amounts
    function getPositionBreakdown(uint256 tokenId) external view returns (address token0, address token1, uint128 liquidity, uint256 amount0, uint256 amount1, uint128 fees0, uint128 fees1);
}
