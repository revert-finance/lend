// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IInterestRateModel.sol";
import "./interfaces/IErrors.sol";

/// @title Model for interest rate calculation used in Vault
/// @notice Calculates both borrow and supply rate
contract InterestRateModel is Ownable, IInterestRateModel, IErrors {
    uint256 private constant Q96 = 2 ** 96;
    uint256 public constant YEAR_SECS = 31557600; // taking into account leap years

    uint256 public constant MAX_BASE_RATE_X96 = Q96 / 10; // 10%
    uint256 public constant MAX_MULTIPLIER_X96 = Q96 * 2; // 200%

    event SetValues(
        uint256 baseRatePerYearX96, uint256 multiplierPerYearX96, uint256 jumpMultiplierPerYearX96, uint256 kinkX96
    );

    // all values are multiplied by Q96
    uint256 public multiplierPerSecondX96;
    uint256 public baseRatePerSecondX96;
    uint256 public jumpMultiplierPerSecondX96;
    uint256 public kinkX96;

    /// @notice Creates interest rate model
    /// @param baseRatePerYearX96 Base rate per year multiplied by Q96
    /// @param multiplierPerYearX96 Multiplier for utilization rate below kink multiplied by Q96
    /// @param jumpMultiplierPerYearX96 Multiplier for utilization rate above kink multiplied by Q96
    /// @param _kinkX96 Kink percentage multiplied by Q96
    constructor(
        uint256 baseRatePerYearX96,
        uint256 multiplierPerYearX96,
        uint256 jumpMultiplierPerYearX96,
        uint256 _kinkX96
    ) {
        setValues(baseRatePerYearX96, multiplierPerYearX96, jumpMultiplierPerYearX96, _kinkX96);
    }

    /// @notice Returns utilization rate X96 given cash and debt
    /// @param cash Current available cash 
    /// @param debt Current debt
    /// @return Utilization rate between 0 and Q96
    function getUtilizationRateX96(uint256 cash, uint256 debt) public pure returns (uint256) {
        if (debt == 0) {
            return 0;
        }
        return debt * Q96 / (cash + debt);
    }

    /// @notice Returns interest rates X96 given cash and debt
    /// @param cash Current available cash 
    /// @param debt Current debt
    /// @return borrowRateX96 borrow rate multiplied by Q96
    /// @return supplyRateX96 supply rate multiplied by Q96
    function getRatesPerSecondX96(uint256 cash, uint256 debt)
        public
        view
        override
        returns (uint256 borrowRateX96, uint256 supplyRateX96)
    {
        uint256 utilizationRateX96 = getUtilizationRateX96(cash, debt);

        if (utilizationRateX96 <= kinkX96) {
            borrowRateX96 = (utilizationRateX96 * multiplierPerSecondX96 / Q96) + baseRatePerSecondX96;
        } else {
            uint256 normalRateX96 = (kinkX96 * multiplierPerSecondX96 / Q96) + baseRatePerSecondX96;
            uint256 excessUtilX96 = utilizationRateX96 - kinkX96;
            borrowRateX96 = (excessUtilX96 * jumpMultiplierPerSecondX96 / Q96) + normalRateX96;
        }

        supplyRateX96 = utilizationRateX96 * borrowRateX96 / Q96;
    }

    /// @notice Update interest rate values (onlyOwner)
    /// @param baseRatePerYearX96 Base rate per year multiplied by Q96
    /// @param multiplierPerYearX96 Multiplier for utilization rate below kink multiplied by Q96
    /// @param jumpMultiplierPerYearX96 Multiplier for utilization rate above kink multiplied by Q96
    /// @param _kinkX96 Kink percentage multiplied by Q96
    function setValues(
        uint256 baseRatePerYearX96,
        uint256 multiplierPerYearX96,
        uint256 jumpMultiplierPerYearX96,
        uint256 _kinkX96
    ) public onlyOwner {
        if (
            baseRatePerYearX96 > MAX_BASE_RATE_X96 || multiplierPerYearX96 > MAX_MULTIPLIER_X96
                || jumpMultiplierPerYearX96 > MAX_MULTIPLIER_X96
        ) {
            revert InvalidConfig();
        }

        baseRatePerSecondX96 = baseRatePerYearX96 / YEAR_SECS;
        multiplierPerSecondX96 = multiplierPerYearX96 / YEAR_SECS;
        jumpMultiplierPerSecondX96 = jumpMultiplierPerYearX96 / YEAR_SECS;
        kinkX96 = _kinkX96;

        emit SetValues(baseRatePerYearX96, multiplierPerYearX96, jumpMultiplierPerYearX96, _kinkX96);
    }
}
