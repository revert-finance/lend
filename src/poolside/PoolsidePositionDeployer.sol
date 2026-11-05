// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./PoolsidePosition.sol";

/// @dev Linked creation code keeps the factory below EIP-170. Solidity's library delegatecall runs
/// CREATE in the factory's context, so the holder's immutable registry remains the factory.
/// No storage writes, configurable targets or upgrade authority.
library PoolsidePositionDeployer {
    function deploy(address beneficiary, PoolsidePosition.Bindings memory bindings)
        external
        returns (PoolsidePosition)
    {
        return new PoolsidePosition(beneficiary, bindings);
    }
}
