// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISwapRouter {
    // uses approved tokens - swaps as instructed in desc - returns how much was recieved
    function swap(bytes calldata desc) external payable returns (uint amountOut);
}