// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../interfaces/IV3Oracle.sol";

/// @notice V3Vault logic kept out of the vault's runtime bytecode to stay below the EIP-170 limit: liquidation math,
/// the liquidated share transfer, reserve socialization and per-token collateral accounting. The external functions
/// run via DELEGATECALL in the vault's context, so the position manager and oracle are called by the vault itself and
/// storage references point into the vault.
library VaultLib {
    uint256 internal constant Q32 = 2 ** 32;
    uint256 internal constant Q96 = 2 ** 96;

    error CollateralValueLimit();

    // configured collateral tokens (storage layout of V3Vault.tokenConfigs)
    struct TokenConfig {
        uint32 collateralFactorX32; // how much this token is valued as collateral
        uint32 collateralValueLimitFactorX32; // how much asset equivalent may be lent out given this collateral
        uint192 totalDebtShares; // how much debt shares are theoretically backed by this collateral
    }

    struct ReserveLiquidationInput {
        uint256 reserveCost;
        uint256 reserves;
        uint256 totalSupply; // lender shares
        uint256 effectiveTotalSupply; // lender shares net of same-transaction inflation (daily cap base)
        uint256 lendExchangeRateX96;
        uint256 dailyDebtIncreaseLimitMin;
        uint256 maxDailyDebtIncreaseX32;
        uint256 dailyDebtIncreaseLimitLeft;
        bool resetToday; // daily debt limit was already reset today
    }

    /// @dev Formerly V3Vault._updateAndCheckCollateral: moves the loan's debt shares between the collateral tokens'
    /// totals and enforces each token's collateral value limit when shares increase. `lentAssets` is only read then.
    function updateAndCheckCollateral(
        mapping(address => TokenConfig) storage tokenConfigs,
        INonfungiblePositionManager nonfungiblePositionManager,
        uint256 tokenId,
        uint256 debtExchangeRateX96,
        uint256 lentAssets,
        uint256 oldShares,
        uint256 newShares
    ) external {
        if (oldShares == newShares) {
            return;
        }
        (,, address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(tokenId);

        // remove previous collateral - add new collateral
        if (oldShares > newShares) {
            uint192 difference = SafeCast.toUint192(oldShares - newShares);
            tokenConfigs[token0].totalDebtShares -= difference;
            tokenConfigs[token1].totalDebtShares -= difference;
        } else {
            uint192 difference = SafeCast.toUint192(newShares - oldShares);
            tokenConfigs[token0].totalDebtShares += difference;
            tokenConfigs[token1].totalDebtShares += difference;

            // check if current value of used collateral is more than allowed limit
            // if collateral is decreased - never revert
            _checkCollateralValueLimit(tokenConfigs[token0], debtExchangeRateX96, lentAssets);
            _checkCollateralValueLimit(tokenConfigs[token1], debtExchangeRateX96, lentAssets);
        }
    }

    function _checkCollateralValueLimit(TokenConfig storage config, uint256 debtExchangeRateX96, uint256 lentAssets)
        private
        view
    {
        uint256 collateralValueLimitFactorX32 = config.collateralValueLimitFactorX32;
        if (
            collateralValueLimitFactorX32 < type(uint32).max
                && Math.mulDiv(config.totalDebtShares, debtExchangeRateX96, Q96, Math.Rounding.Up)
                    > lentAssets * collateralValueLimitFactorX32 / Q32
        ) {
            revert CollateralValueLimit();
        }
    }

    /// @dev Formerly V3Vault._handleReserveLiquidation: when reserves do not cover a liquidation shortfall, the missing
    /// amount is socialized across lenders by lowering the lend exchange rate, and the remaining daily debt headroom is
    /// rescaled to the post-haircut cap. Returns the values the vault writes back.
    function handleReserveLiquidation(ReserveLiquidationInput memory input)
        external
        pure
        returns (uint256 missing, uint256 newLendExchangeRateX96, uint256 newDailyDebtIncreaseLimitLeft)
    {
        newLendExchangeRateX96 = input.lendExchangeRateX96;
        newDailyDebtIncreaseLimitLeft = input.dailyDebtIncreaseLimitLeft;

        // if not enough - democratize debt
        if (input.reserveCost > input.reserves) {
            missing = input.reserveCost - input.reserves;

            uint256 totalLent = Math.mulDiv(input.totalSupply, input.lendExchangeRateX96, Q96, Math.Rounding.Up);
            uint256 preHaircutDailyDebtCap = _dailyIncreaseLimit(
                input.effectiveTotalSupply,
                input.lendExchangeRateX96,
                input.dailyDebtIncreaseLimitMin,
                input.maxDailyDebtIncreaseX32
            );

            // this lines distribute missing amount and remove it from all lent amount proportionally
            newLendExchangeRateX96 = (totalLent - missing) * input.lendExchangeRateX96 / totalLent;

            // A reserve socialization haircut reduces the lender base mid-day.
            // Rescale remaining daily debt headroom so it tracks the post-haircut cap while preserving already-used budget.
            uint256 postHaircutDailyDebtCap = _dailyIncreaseLimit(
                input.effectiveTotalSupply,
                newLendExchangeRateX96,
                input.dailyDebtIncreaseLimitMin,
                input.maxDailyDebtIncreaseX32
            );
            if (input.resetToday && postHaircutDailyDebtCap < preHaircutDailyDebtCap) {
                uint256 capReduction = preHaircutDailyDebtCap - postHaircutDailyDebtCap;
                newDailyDebtIncreaseLimitLeft =
                    capReduction >= input.dailyDebtIncreaseLimitLeft ? 0 : input.dailyDebtIncreaseLimitLeft - capReduction;
            }
        }
    }

    // mirrors V3Vault._calculateDailyIncreaseLimit for a given effective lender share supply
    function _dailyIncreaseLimit(
        uint256 effectiveTotalSupply,
        uint256 lendExchangeRateX96,
        uint256 minLimit,
        uint256 limitFactorX32
    ) private pure returns (uint256) {
        uint256 limit =
            Math.mulDiv(effectiveTotalSupply, lendExchangeRateX96, Q96, Math.Rounding.Up) * limitFactorX32 / Q32;
        return minLimit > limit ? minLimit : limit;
    }

    /// @dev Formerly V3Vault._calculateLiquidation. The penalty bounds are passed in so the vault's public
    /// constants remain the single source of truth.
    function calculateLiquidation(
        uint256 debt,
        uint256 fullValue,
        uint256 collateralValue,
        uint256 minPenaltyX32,
        uint256 maxPenaltyX32
    ) external pure returns (uint256 liquidationValue, uint256 liquidatorCost, uint256 reserveCost) {
        // in a standard liquidation - liquidator pays complete debt (and get part or all of position)
        // if position has less than enough value - liquidation cost maybe less - rest is payed by protocol or lenders collectively
        liquidatorCost = debt;

        // position value needed to pay debt at max penalty
        uint256 maxPenaltyValue = debt * (Q32 + maxPenaltyX32) / Q32;

        // if position is more valuable than debt with max penalty
        if (fullValue >= maxPenaltyValue) {
            if (collateralValue != 0) {
                // position value when position started to be liquidatable
                uint256 startLiquidationValue = debt * fullValue / collateralValue;
                uint256 penaltyFractionX96 =
                    (Q96 - ((fullValue - maxPenaltyValue) * Q96 / (startLiquidationValue - maxPenaltyValue)));
                uint256 penaltyX32 = minPenaltyX32 + (maxPenaltyX32 - minPenaltyX32) * penaltyFractionX96 / Q96;

                liquidationValue = debt * (Q32 + penaltyX32) / Q32;
            } else {
                liquidationValue = maxPenaltyValue;
            }
        } else {
            uint256 penalty = debt * maxPenaltyX32 / Q32;

            // if value is enough to pay penalty
            if (fullValue > penalty) {
                liquidatorCost = fullValue - penalty;
            } else {
                // this extreme case leads to free liquidation
                liquidatorCost = 0;
            }

            liquidationValue = fullValue;
            reserveCost = debt - liquidatorCost; // Remaining to pay is taken from reserves
        }
    }

    /// @dev Formerly V3Vault._sendPositionValue: removes the liquidated share of liquidity and fees and sends it.
    function sendPositionValue(
        INonfungiblePositionManager nonfungiblePositionManager,
        IV3Oracle oracle,
        uint256 tokenId,
        uint256 liquidationValue,
        uint256 fullValue,
        uint256 feeValue,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1) {
        uint128 liquidity;
        uint128 fees0;
        uint128 fees1;

        // if full position is liquidated - no analysis needed
        if (liquidationValue == fullValue) {
            (,,,,,,, liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);
            fees0 = type(uint128).max;
            fees1 = type(uint128).max;
        } else {
            (liquidity, fees0, fees1) = oracle.getLiquidityAndFees(tokenId);

            // only take needed fees
            if (liquidationValue <= feeValue) {
                liquidity = 0;
                fees0 = SafeCast.toUint128(liquidationValue * fees0 / feeValue);
                fees1 = SafeCast.toUint128(liquidationValue * fees1 / feeValue);
            } else {
                // take all fees and needed liquidity
                fees0 = type(uint128).max;
                fees1 = type(uint128).max;
                liquidity = SafeCast.toUint128((liquidationValue - feeValue) * liquidity / (fullValue - feeValue));
            }
        }

        if (liquidity != 0) {
            nonfungiblePositionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, liquidity, 0, 0, deadline)
            );
        }

        (amount0, amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(tokenId, recipient, fees0, fees1)
        );
    }
}
