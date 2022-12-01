// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "compound-protocol/CToken.sol";

interface ICollateralModule {
    function getTokensOfOwner(address owner) external view returns (uint[] memory tokenIds, CToken[] memory cTokens0, CToken[] memory cTokens1);
    function getTokenBreakdown(uint256 tokenId, uint price0, uint price1) external view returns (uint amount0, uint amount1, uint fees0, uint fees1, uint cAmount0, uint cAmount1);
}