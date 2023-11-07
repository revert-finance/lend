// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVault {
    function lendToken() external returns (address);
    function ownerOf(uint tokenId) external returns (address);

    function borrow(uint tokenId, uint amount) external;
    function repay(uint tokenId, uint amount, bool isShare) external returns (uint);
}