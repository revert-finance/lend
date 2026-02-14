// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Compatibility reader for pool `slot0()` that only decodes the needed fields (sqrtPriceX96, tick).
/// @dev Some CL pool deployments (including Slipstream variants) may return a different `slot0()` tuple shape than Uniswap V3.
library Slot0Reader {
    error Slot0ReadFailed();

    function read(address pool) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        if (!ok || data.length < 64) revert Slot0ReadFailed();
        (sqrtPriceX96, tick) = abi.decode(data, (uint160, int24));
    }
}

