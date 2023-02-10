// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../compound/CToken.sol";

interface ICollateralModule {
    function comptroller() external view returns(address);
    function getOwnerOfPosition(uint256 tokenId) external view returns(address);
    function getTokensOfPosition(uint256 tokenId) external view returns (address token0, address token1);
    function getPositionsOfOwner(address owner) external view returns (uint256[] memory tokenIds, address[] memory tokens0, address[] memory tokens1);
    function getPositionBreakdown(uint256 tokenId, uint256 price0, uint256 price1) external view returns (uint128 liquidity, uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1, uint256 cAmount0, uint256 cAmount1);
    function seizePositionAssets(address liquidator, address borrower, uint256 tokenId, uint256 seizeLiquidity, uint256 seizeFeesToken0, uint256 seizeFeesToken1, uint256 seizeCToken0, uint256 seizeCToken1) external;
}