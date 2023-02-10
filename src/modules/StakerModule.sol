// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Module.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import 'v3-core/libraries/FullMath.sol';


/// @title StakerModule
/// @notice Fork of Univ3staker which is compatible with all other modules.
contract StakerModule is Module {


    bool public immutable override needsCheckOnCollect = true;

    constructor(NFTHolder _holder) Module(_holder) {
    }

    function addToken(uint256 tokenId, address, bytes calldata data) override onlyHolder external {
        // TODO init deposit struct - analog to onERC721Received in v3staker
    }

    function withdrawToken(uint256 tokenId, address) override onlyHolder external {
        // TODO analog to withdrawToken in v3staker
    }

    function checkOnCollect(uint256 tokenId, address, uint128 liquidity, uint256, uint256) override external  {
        if (liquidity > 0) {
            // TODO unstake automatically from all stakes (needs fast and limited iteration logic because liquidation may depend on this)
        }
    }
}