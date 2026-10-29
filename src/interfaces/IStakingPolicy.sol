// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Vault-authenticated migration of operator staking policy when a position is replaced.
interface IStakingPolicy {
    function migrateStakingPolicy(uint256 oldTokenId, uint256 newTokenId) external;
}
