// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IModule {
    function addToken(uint256 tokenId, address owner, bytes calldata data) external;
    function withdrawToken(uint256 tokenId, address owner) external;
    function checkOnCollect(uint256 tokenId, address owner, uint amount0, uint amount1) external returns (bool);
}