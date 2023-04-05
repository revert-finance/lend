// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IModule {
    function addToken(uint256 tokenId, address owner, bytes calldata data) external;
    function withdrawToken(uint256 tokenId, address owner) external;
    function checkOnCollect(uint256 tokenId, address owner, uint128 liquidity, uint256 amount0, uint256 amount1) external;

    // callback which allows using the decreased liquidity before other modules are checked
    function decreaseLiquidityAndCollectCallback(uint256 tokenId, uint256 amount0, uint256 amount1, bytes memory data) external returns (bytes memory returnData);

    function needsCheckOnCollect() external returns (bool);
}