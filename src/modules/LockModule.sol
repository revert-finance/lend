// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Module.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import 'v3-core/libraries/FullMath.sol';

/// @title LockModule
/// @notice This contract allows locking a Uniswap V3 position for a specified time, while permitting fee withdrawals at any time.
/// It cannot be used in conjunction with the CollateralModule (set blocking config).
contract LockModule is Module {
  
    // errors 
    error IsLocked();

    constructor(INonfungiblePositionManager _npm) Module(_npm) {
    }

    struct PositionConfig {
        uint32 releaseTime; // when liquidity will be accesible
    }

    mapping (uint256 => PositionConfig) positionConfigs;

    bool public immutable override needsCheckOnCollect = true;

    /// @notice Adds a token
    /// @param tokenId The token ID of the position.
    /// @param data The configuration data for the locked position.
    function addToken(uint256 tokenId, address, bytes calldata data) override onlyHolder external {
        PositionConfig memory config = abi.decode(data, (PositionConfig));

        // if locked can not be changed
        if (block.timestamp < positionConfigs[tokenId].releaseTime) {
            revert IsLocked();
        }
        
        positionConfigs[tokenId] = config;
    }

    /// @notice Withdraws a token
    /// @param tokenId The token ID of the position.
    function withdrawToken(uint256 tokenId, address) override onlyHolder external view {
        if (block.timestamp < positionConfigs[tokenId].releaseTime) {
            revert IsLocked();
        }
    }

    /// @notice Checks if this module allows collect
    /// @param tokenId The token ID of the position.
    /// @param liquidity The amount of liquidity to be collected.
    function checkOnCollect(uint256 tokenId, address, uint128 liquidity, uint256, uint256) override external view {
        if (liquidity > 0 && block.timestamp < positionConfigs[tokenId].releaseTime) {
            revert IsLocked();
        }
    }

    /// @notice Returns the configuration of a locked position.
    /// @param tokenId The token ID of the position.
    /// @return config The configuration data for the locked position.
    function getConfig(uint256 tokenId) override external view returns (bytes memory config) {
        return abi.encode(positionConfigs[tokenId]);
    }
}