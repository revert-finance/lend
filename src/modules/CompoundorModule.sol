// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IModule.sol";
import "../NFTHolder.sol";

contract CompoundorModule is IModule {

    NFTHolder public immutable holder;

    constructor(NFTHolder _holder) {
        holder = _holder;
    }

    function autoCompound(uint256 tokenId) external {

        // (uint256 amount0, uint256 amount1) = holder.decreaseLiquidityAndCollect(params);

        // (optional swap) & autocompound
        
        // manage leftover balances 

        // etc..
    }

    function addToken(uint256 tokenId, address owner) override external  {
        // nothing to do
    }
    function withdrawToken(uint256 tokenId, address owner) override external {
        // nothing to do
    }
    function checkOnCollect(uint256, address, uint, uint) override external pure returns (bool) {
        return true;
    }
}