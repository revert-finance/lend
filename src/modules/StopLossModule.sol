// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IModule.sol";
import "../NFTHolder.sol";

contract StopLossModule is IModule {

    NFTHolder public immutable holder;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;

    constructor(NFTHolder _holder, INonfungiblePositionManager _nonfungiblePositionManager) {
        holder = _holder;
        nonfungiblePositionManager = _nonfungiblePositionManager;
    }

    struct Position {
        bool isLimit;
        bool side0;
        uint minStopLossAmountOut;
        uint minStopLossSwapOut;
    }

    mapping (uint => Position) positions;


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

    // function which can be called when position is in certain state
    function stopLoss(AutoCompoundParams memory params) external {

        // TODO check if in one sided state
        // TODO check minAmountOut
        // TODO check minSwapAmountOut

        (,,,,,,,uint128 liquidity,,,,) = nonfungiblePositionManager.positions(params.tokenId);

        // decrease liquidity for given position (one sided only)
        (uint256 amount0, uint256 amount1) = holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(params.tokenId, liquidity, 0, 0, type(uint128).max, type(uint128).max, block.timestamp, address(this)));

        // TODO swap all to other token

        nonfungiblePositionManager.increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams(params.tokenId, amount0, amount1, 0, 0, block.timestamp));

        // TODO calculate fees

        // TODO manage leftover balances 

    }

    function addToken(uint256 tokenId, address owner, bytes calldata data) override external  {
        Position memory position = abi.decode(data, (Position));
        positions[tokenId] = position;
    }

    function withdrawToken(uint256 tokenId, address) override external {
         delete positions[tokenId];
    }

    function checkOnCollect(uint256, address, uint, uint) override external pure returns (bool) {
        return true;
    }
}