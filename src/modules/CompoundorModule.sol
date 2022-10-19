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
        // holder.decreaseLiquidityAndCollect(params);

        // autocompound
        
        // manage leftover balances 

        // etc..
    }

    function addToken(uint256 tokenId, address owner) override external  {
        // nothing to do
    }
    function withdrawToken(uint256 tokenId, address owner) override external {
        // nothing to do
    }
    function allowCollect(uint256, uint, uint) override external pure returns (bool) {
        return true;
    }
}