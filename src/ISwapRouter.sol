// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISwapRouter {
    function swap(bytes calldata desc) external returns (uint amountOut);
}