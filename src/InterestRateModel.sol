// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IInterestRateModel.sol";

contract InterestRateModel is Ownable, IInterestRateModel {

    uint constant Q96 = 2 ** 96;
    uint constant YEAR_SECS = 31557600; // taking into account leap years

    uint constant MAX_BASE_RATE = Q96 / 10; // 10%
    uint constant MAX_MULTIPLIER = Q96 * 2; // 200%

    error InvalidConfig();

    event SetValues(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint kink);

    // all values are multiplied by Q96
    uint public multiplierPerSecond;
    uint public baseRatePerSecond;
    uint public jumpMultiplierPerSecond;
    uint public kink;

    constructor(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint _kink) {
        setValues(baseRatePerYear, multiplierPerYear, jumpMultiplierPerYear, _kink);
    }

    function getUtilizationRateX96(uint cash, uint debt) public pure returns (uint) {
        if (debt == 0) {
            return 0;
        }
        return debt * Q96 / (cash + debt);
    }

    function getBorrowRatePerSecondX96(uint cash, uint debt) override external view returns (uint) {
        uint utilizationRate = getUtilizationRateX96(cash, debt);

        if (utilizationRate <= kink) {
            return (utilizationRate * multiplierPerSecond / Q96) + baseRatePerSecond;
        } else {
            uint normalRate = (kink * multiplierPerSecond / Q96) + baseRatePerSecond;
            uint excessUtil = utilizationRate - kink;
            return (excessUtil * jumpMultiplierPerSecond / Q96) + normalRate;
        }
    }

    // function to update interest rate values
    function setValues(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint _kink) public onlyOwner {
        
        if (baseRatePerYear > MAX_BASE_RATE || multiplierPerYear > MAX_MULTIPLIER || jumpMultiplierPerYear > MAX_MULTIPLIER) {
            revert InvalidConfig();
        }
        
        baseRatePerSecond = baseRatePerYear / YEAR_SECS;
        multiplierPerSecond = multiplierPerYear / YEAR_SECS;
        jumpMultiplierPerSecond = jumpMultiplierPerYear / YEAR_SECS;
        kink = _kink;

        emit SetValues(baseRatePerYear, multiplierPerYear, jumpMultiplierPerYear, _kink);
    }
}