// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IModule.sol";
import "./Module.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import 'v3-core/libraries/FullMath.sol';


/// @title StakerModule
/// @notice Fork of Univ3staker which is compatible with all other modules.
contract StakerModule is Module, IModule {

    // TODO add full code from staker into the module - adjust only module specific methods slightly
  
    constructor(NFTHolder _holder) Module(_holder) {
    }

    function addToken(uint256 tokenId, address, bytes calldata data) override onlyHolder external {
        // TODO init deposit struct - analog to onERC721Received in v3staker
    }

    function withdrawToken(uint256 tokenId, address) override onlyHolder external {
        // TODO analog to withdrawToken in v3staker
    }

    function checkOnCollect(uint256 tokenId, address, uint128 liquidity, uint, uint) override external  {
        if (liquidity > 0) {
            // TODO unstake automatically from all stakes (needs fast and limited iteration logic)
        }
    }

    function decreaseLiquidityAndCollectCallback(uint256 tokenId, uint amount0, uint amount1) override external { }
}