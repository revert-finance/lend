// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./CoinbaseEquityBaseConfig.s.sol";
import "../src/V3Vault.sol";

/// @notice Weekend freeze / unfreeze for the Coinbase equity vault (plan WP4/WP6).
///         setLimits is owner-only (no emergencyAdmin) and the owner is the Safe, so these scripts
///         never broadcast. They read the live tuple, compute the target, simulate it as the owner
///         (forge script without --broadcast is a simulation) and print the exact Safe calldata.
///
///         FreezeBorrows:   (minLoanSize, globalLendLimit, currentDebt, 0, 0)   - Friday 15:00 ET
///         UnfreezeBorrows: manifest live tuple                                  - after the first
///                          post-closure print AND |feed - TWAP| < 2% sustained (runbook)
///
///         Note: a frozen globalDebtLimit caps *total* debt; amounts repaid during the weekend can be
///         re-borrowed up to the frozen total (verified in V3VaultB20.t.sol).
abstract contract CoinbaseEquityBorrowLimits is CoinbaseEquityBaseConfig {
    function _vault() internal returns (V3Vault vault) {
        require(block.chainid == BASE_CHAIN_ID, "BorrowLimits: wrong chain");
        vault = V3Vault(vm.envAddress("VAULT"));
        _requireCode(address(vault), "BorrowLimits: vault missing code");
        require(vault.owner() == BASE_MULTISIG, "BorrowLimits: vault not owned by multisig");
    }

    function _currentDebt(V3Vault vault) internal view returns (uint256) {
        // debtSharesTotal at the last stored exchange rate, rounded up; interest accrued since only
        // pushes total debt above the frozen limit, which is the intended direction
        uint256 shares = vault.debtSharesTotal();
        uint256 rate = vault.lastDebtExchangeRateX96();
        return (shares * rate + Q96 - 1) / Q96;
    }

    function _apply(V3Vault vault, string memory label, uint256 debtLimit, uint256 dailyLendMin, uint256 dailyDebtMin)
        internal
    {
        uint256 minLoan = vault.minLoanSize();
        uint256 lendLimit = vault.globalLendLimit();

        console2.log(label);
        console2.log("  current globalDebtLimit ", vault.globalDebtLimit());
        console2.log("  current debt            ", _currentDebt(vault));
        console2.log("  target  globalDebtLimit ", debtLimit);
        console2.log("  target  dailyLendMin    ", dailyLendMin);
        console2.log("  target  dailyDebtMin    ", dailyDebtMin);

        bytes memory data = abi.encodeWithSelector(
            V3Vault.setLimits.selector, minLoan, lendLimit, debtLimit, dailyLendMin, dailyDebtMin
        );

        // simulate as the Safe and assert the tuple lands
        vm.prank(BASE_MULTISIG);
        vault.setLimits(minLoan, lendLimit, debtLimit, dailyLendMin, dailyDebtMin);
        require(vault.globalDebtLimit() == debtLimit, "BorrowLimits: simulation mismatch");
        require(vault.minLoanSize() == minLoan && vault.globalLendLimit() == lendLimit, "BorrowLimits: tuple drift");

        _logSafeTx(label, address(vault), data);
    }
}

contract FreezeBorrows is CoinbaseEquityBorrowLimits {
    function run() external {
        V3Vault vault = _vault();
        _apply(vault, "FREEZE setLimits(minLoan, lendLimit, currentDebt, 0, 0)", _currentDebt(vault), 0, 0);
    }
}

contract UnfreezeBorrows is CoinbaseEquityBorrowLimits {
    function run() external {
        V3Vault vault = _vault();
        _apply(
            vault,
            "UNFREEZE setLimits(manifest live tuple)",
            GLOBAL_DEBT_LIMIT_LIVE,
            DAILY_LEND_INCREASE_MIN,
            DAILY_DEBT_INCREASE_MIN
        );
    }
}
