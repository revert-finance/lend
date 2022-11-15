// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IModule {
    function addToken(uint256 tokenId, address owner, bytes calldata data) external returns (bool);
    function withdrawToken(uint256 tokenId, address owner) external returns (bool);
    function checkOnCollect(uint256 tokenId, address owner, uint128 liquidity, uint amount0, uint amount1) external view returns (bool);
}