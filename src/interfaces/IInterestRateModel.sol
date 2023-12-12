// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IInterestRateModel {
    // gets borrow and supply interest rate per second
    function getRatesPerSecondX96(uint cash, uint debt) external view returns (uint borrowRateX96, uint supplyRateX96);
}