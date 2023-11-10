// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// base contracts
import "../../src/InterestRateModel.sol";

contract InterestRateModelIntegrationTest is Test {
   
    uint constant Q32 = 2 ** 32;
    uint constant Q96 = 2 ** 96;

    uint constant YEAR_SECS = 31556925216; // taking into account leap years

    uint256 mainnetFork;
    InterestRateModel interestRateModel;

    function setUp() external {

        // 5% base rate - after 80% - 109% (like in compound v2 deployed) 
        interestRateModel = new InterestRateModel(0, Q96 * 5 / 100, Q96 * 109 / 100, Q96 * 80 / 100);
    }

    function testUtilizationRates() external {
        assertEq(interestRateModel.getUtilizationRateX96(10, 0), 0);
        assertEq(interestRateModel.getUtilizationRateX96(10, 10), Q96 / 2);
        assertEq(interestRateModel.getUtilizationRateX96(0, 10), Q96);
    }

    function testInterestRates() external {
        assertEq(interestRateModel.getBorrowRatePerSecondX96(10, 0) * YEAR_SECS, 0); // 0% for 0% utilization
        assertEq(interestRateModel.getBorrowRatePerSecondX96(10000000, 10000000) * YEAR_SECS, 1980704062856608435230950304); // 2.5% per year for 50% utilization
        assertEq(interestRateModel.getBorrowRatePerSecondX96(0, 10) * YEAR_SECS, 20440865928680199049058853120); // 25.8% per year for 100% utilization
    }
}