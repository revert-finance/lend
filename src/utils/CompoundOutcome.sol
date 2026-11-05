// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @dev Per-token, post-fee utilization guard. No valuation, custody or persistent accounting.
library CompoundOutcome {
    error ExcessiveCompoundLeftover();

    /// @dev Allow at most 0.5% of available units, or one smallest unit for rounding, whichever is larger.
    function check(uint256 available, uint256 used) internal pure {
        uint256 leftover = available - used;
        if (leftover > 1 && leftover > available / 200) revert ExcessiveCompoundLeftover();
    }
}
