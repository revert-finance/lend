// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IModule.sol";
import "../NFTHolder.sol";

contract CompoundorModule is IModule {

    NFTHolder public immutable holder;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;

    constructor(NFTHolder _holder, INonfungiblePositionManager _nonfungiblePositionManager) {
        holder = _holder;
        nonfungiblePositionManager = _nonfungiblePositionManager;
    }

    /// @notice how reward should be converted
    enum RewardConversion { NONE, TOKEN_0, TOKEN_1 }

    /// @notice params for autoCompound()
    struct AutoCompoundParams {
        // tokenid to autocompound
        uint256 tokenId;
        
        // which token to convert to
        RewardConversion rewardConversion;

        // should token be withdrawn to compounder immediately
        bool withdrawReward;

        // do swap - to add max amount to position (costs more gas)
        bool doSwap;
    }

    function autoCompound(AutoCompoundParams memory params) external {

        // decrease liquidity for given position
        (uint256 amount0, uint256 amount1) = holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(params.tokenId, 0, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, address(this)));

        // TODO swap & price validation

        nonfungiblePositionManager.increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams(params.tokenId, amount0, amount1, 0, 0, block.timestamp));

        // TODO calculate fees

        // TODO manage leftover balances 

    }

    function addToken(uint256 tokenId, address owner, bytes calldata data) override external  { }

    function withdrawToken(uint256 tokenId, address owner) override external { }

    function checkOnCollect(uint256, address, uint, uint) override external pure returns (bool) {
        return true;
    }
}