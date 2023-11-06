// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IInterestRateModel {
    // gets interest rate per second per unit of debt
    function getBorrowRatePerSecondX96(uint cash, uint debt) external view returns (uint256);
}