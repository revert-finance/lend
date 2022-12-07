// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../compound/CToken.sol";

interface ICollateralModule {
    function comptroller() external view returns(address);
    function getOwnerOfToken(uint256 tokenId) external view returns(address);
    function getTokensOfToken(uint256 tokenId) external view returns (address token0, address token1);
    function getTokensOfOwner(address owner) external view returns (uint[] memory tokenIds, address[] memory tokens0, address[] memory tokens1);
    function getTokenBreakdown(uint256 tokenId, uint price0, uint price1) external view returns (uint128 liquidity, uint amount0, uint amount1, uint fees0, uint fees1, uint cAmount0, uint cAmount1);
    function seizeAssets(address liquidator, address borrower, uint256 tokenId, uint256 seizeLiquidity, uint256 seizeFeesToken0, uint256 seizeFeesToken1, uint256 seizeCToken0, uint256 seizeCToken1) external;
}