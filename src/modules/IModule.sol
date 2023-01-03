// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IModule {
    function addToken(uint256 tokenId, address owner, bytes calldata data) external;
    function withdrawToken(uint256 tokenId, address owner) external;
    function checkOnCollect(uint256 tokenId, address owner, uint128 liquidity, uint amount0, uint amount1) external;

    // callback which allows using the decreased liquidity before other modules are checked
    function decreaseLiquidityAndCollectCallback(uint256 tokenId, uint amount0, uint amount1, bytes calldata data) external returns (bytes memory returnData);

    function needsCheckOnCollect() external returns (bool);
}