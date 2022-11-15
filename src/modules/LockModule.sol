// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IModule.sol";
import "./Module.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import 'v3-core/libraries/FullMath.sol';

contract LockModule is Module, IModule {
  
    // errors 
    error Locked();

    constructor(NFTHolder _holder) Module(_holder) {
    }

    struct PositionConfig {
        uint32 releaseTime; // when liquidity will be accesible
    }

    mapping (uint => PositionConfig) positionConfigs;

    function addToken(uint256 tokenId, address, bytes calldata data) override onlyHolder external returns(bool) {
        PositionConfig memory config = abi.decode(data, (PositionConfig));

        // if locked can not be changed
        if (block.timestamp < positionConfigs[tokenId].releaseTime) {
            return false;
        }
        
        positionConfigs[tokenId] = config;
        return true;
    }

    function withdrawToken(uint256 tokenId, address) override onlyHolder external view returns (bool) {
        if (block.timestamp < positionConfigs[tokenId].releaseTime) {
            return false;
        }
        return true;
    }

    function checkOnCollect(uint256 tokenId, address, uint128 liquidity, uint, uint) override external view returns (bool) {
        return liquidity == 0 || block.timestamp >= positionConfigs[tokenId].releaseTime;
    }
}