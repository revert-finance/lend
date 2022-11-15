// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./../../../src/modules/IModule.sol";
import "./../../../src/NFTHolder.sol";

contract TestModule is IModule {

    error CheckCollectError();

    NFTHolder holder;
    bool checkOnCollectResponse;

    constructor(NFTHolder _holder, bool _checkOnCollectResponse) {
        holder = _holder;
        checkOnCollectResponse = _checkOnCollectResponse;
    }

    function addToken(uint256 tokenId, address, bytes calldata data) override external {
    }

    function withdrawToken(uint256 tokenId, address) override external {
    }

    function checkOnCollect(uint256, address, uint128, uint, uint) override external {
        if (!checkOnCollectResponse) {
            revert CheckCollectError();
        }
    }

    function triggerCollectForTesting(uint256 tokenId) external {
        holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(tokenId, 0, 0, 0, 0, 0, 0, address(this)));
    }
}