// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Position-specific fee/reward carry-forward ledger. Only a registered vault's GaugeManager may
/// temporarily take its staked position's balances and return the uninvested amounts.
interface ICompoundBalanceSource {
    function compoundBalances(uint256 tokenId, bool deposit, uint256[3] calldata amounts)
        external
        returns (uint256[3] memory taken);
}
