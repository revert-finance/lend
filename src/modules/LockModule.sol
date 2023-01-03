// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Module.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import 'v3-core/libraries/FullMath.sol';

/// @title LockModule
/// @notice Lets a v3 position to be locked for a certain time (but allows removal of fees at any time)
/// can NOT be used together with CollateralModule (set blocking config)
contract LockModule is Module {
  
    // errors 
    error IsLocked();

    constructor(NFTHolder _holder) Module(_holder) {
    }

    struct PositionConfig {
        uint32 releaseTime; // when liquidity will be accesible
    }

    mapping (uint => PositionConfig) positionConfigs;

    bool public immutable override needsCheckOnCollect = true;

    function addToken(uint256 tokenId, address, bytes calldata data) override onlyHolder external {
        PositionConfig memory config = abi.decode(data, (PositionConfig));

        // if locked can not be changed
        if (block.timestamp < positionConfigs[tokenId].releaseTime) {
            revert IsLocked();
        }
        
        positionConfigs[tokenId] = config;
    }

    function withdrawToken(uint256 tokenId, address) override onlyHolder external {
        if (block.timestamp < positionConfigs[tokenId].releaseTime) {
            revert IsLocked();
        }
    }

    function checkOnCollect(uint256 tokenId, address, uint128 liquidity, uint, uint) override external  {
        if (liquidity > 0 && block.timestamp < positionConfigs[tokenId].releaseTime) {
            revert IsLocked();
        }
    }
}