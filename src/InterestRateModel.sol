// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IInterestRateModel.sol";

/// @title Model for interest rate calculation used in Vault
/// @notice Calculates both borrow and supply rate
contract InterestRateModel is Ownable, IInterestRateModel {

    uint private constant Q96 = 2 ** 96;
    uint public constant YEAR_SECS = 31557600; // taking into account leap years

    uint public constant MAX_BASE_RATE_X96 = Q96 / 10; // 10%
    uint public constant MAX_MULTIPLIER_X96 = Q96 * 2; // 200%

    error InvalidConfig();

    event SetValues(uint baseRatePerYearX96, uint multiplierPerYearX96, uint jumpMultiplierPerYearX96, uint kinkX96);

    // all values are multiplied by Q96
    uint public multiplierPerSecondX96;
    uint public baseRatePerSecondX96;
    uint public jumpMultiplierPerSecondX96;
    uint public kinkX96;

    constructor(uint baseRatePerYearX96, uint multiplierPerYearX96, uint jumpMultiplierPerYearX96, uint _kinkX96) {
        setValues(baseRatePerYearX96, multiplierPerYearX96, jumpMultiplierPerYearX96, _kinkX96);
    }

    function getUtilizationRateX96(uint cash, uint debt) public pure returns (uint) {
        if (debt == 0) {
            return 0;
        }
        return debt * Q96 / (cash + debt);
    }

    function getRatesPerSecondX96(uint cash, uint debt) override public view returns (uint borrowRateX96, uint supplyRateX96) {
        uint utilizationRateX96 = getUtilizationRateX96(cash, debt);

        if (utilizationRateX96 <= kinkX96) {
            borrowRateX96 = (utilizationRateX96 * multiplierPerSecondX96 / Q96) + baseRatePerSecondX96;
        } else {
            uint normalRateX96 = (kinkX96 * multiplierPerSecondX96 / Q96) + baseRatePerSecondX96;
            uint excessUtilX96 = utilizationRateX96 - kinkX96;
            borrowRateX96 = (excessUtilX96 * jumpMultiplierPerSecondX96 / Q96) + normalRateX96;
        }

        supplyRateX96 = utilizationRateX96 * borrowRateX96 / Q96;
    }

    // function to update interest rate values
    function setValues(uint baseRatePerYearX96, uint multiplierPerYearX96, uint jumpMultiplierPerYearX96, uint _kinkX96) public onlyOwner {
        
        if (baseRatePerYearX96 > MAX_BASE_RATE_X96 || multiplierPerYearX96 > MAX_MULTIPLIER_X96 || jumpMultiplierPerYearX96 > MAX_MULTIPLIER_X96) {
            revert InvalidConfig();
        }
        
        baseRatePerSecondX96 = baseRatePerYearX96 / YEAR_SECS;
        multiplierPerSecondX96 = multiplierPerYearX96 / YEAR_SECS;
        jumpMultiplierPerSecondX96 = jumpMultiplierPerYearX96 / YEAR_SECS;
        kinkX96 = _kinkX96;

        emit SetValues(baseRatePerYearX96, multiplierPerYearX96, jumpMultiplierPerYearX96, _kinkX96);
    }
}