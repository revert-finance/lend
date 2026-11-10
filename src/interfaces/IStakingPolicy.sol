// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Vault-authenticated migration of operator staking policy when a position is replaced.
interface IStakingPolicy {
    /// @dev Implementations must verify the vault's active replacement pair with IVault.isStakingPolicyMigration.
    function migrateStakingPolicy(uint256 oldTokenId, uint256 newTokenId) external;
}
