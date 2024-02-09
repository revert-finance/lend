// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// base contracts
import "../../src/InterestRateModel.sol";

contract InterestRateModelIntegrationTest is Test {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q96 = 2 ** 96;

    uint256 constant YEAR_SECS = 31557600; // taking into account leap years

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
        (uint256 borrowRateX96, uint256 lendRateX96) = interestRateModel.getRatesPerSecondX96(10, 0);
        assertEq(borrowRateX96 * YEAR_SECS, 0); // 0% for 0% utilization
        assertEq(lendRateX96 * YEAR_SECS, 0); // 0% for 0% utilization

        (borrowRateX96, lendRateX96) = interestRateModel.getRatesPerSecondX96(10000000, 10000000);
        assertEq(borrowRateX96 * YEAR_SECS, 1980704062856608439809600800); // 2.5% per year for 50% utilization
        assertEq(lendRateX96 * YEAR_SECS, 990352031428304219889021600); // 1.25% for 50% utilization

        (borrowRateX96, lendRateX96) = interestRateModel.getRatesPerSecondX96(0, 10);
        assertEq(borrowRateX96 * YEAR_SECS, 20440865928680199099069868800); // 25.8% per year for 100% utilization
        assertEq(lendRateX96 * YEAR_SECS, 20440865928680199099069868800); // 25.8% per year for 100% utilization
    }
}
