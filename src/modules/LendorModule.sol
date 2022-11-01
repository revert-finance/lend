// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "compound-protocol/ComptrollerInterface.sol";
import "compound-protocol/CErc20.sol";

import "v3-core/libraries/TickMath.sol";
import 'v3-core/libraries/FixedPoint128.sol';

import "v3-periphery/libraries/LiquidityAmounts.sol";

import "../NFTHolder.sol";
import "./Module.sol";
import "./IModule.sol";

contract LendorModule is Module, IModule {

    struct TokenConfig {
        CErc20 cToken;
        uint8 priceFeedDecimals;
        uint64 collateralFactorX64;
    }

    mapping (address => Token) tokenConfigs;

    struct PositionConfig {
        uint128 cTokenAmount;
        bool isCToken0;
    }

    mapping (uint => PositionConfig) positionConfigs;

    ComptrollerInterface public immutable comptroller;

    constructor(NFTHolder _holder, address _swapRouter, ComptrollerInterface _comptroller) Module(_holder, _swapRouter) {
        comptroller = _comptroller;
    }

    // removes liquidity from position and mints ctokens
    function lend(uint256 tokenId) external {

        // get position info
        (,,address token0, address token1, uint24 fee,int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) =  nonfungiblePositionManager.positions(params.tokenId);

        IUniswapV3Pool pool = _getPool(token0, token1, fee);

        (,int24 tick,,,,,) = pool.slot0();

        if (tick < tickLower) {
            (uint256 amount0, uint256 amount1) = holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(params.tokenId, liquidity, 0, 0, type(uint128).max, 0, block.timestamp, address(this)));
            uint cAmount = tokenConfigs[token0].cToken.mint(amount0);
            positionConfigs[tokenId].cTokenAmount = cAmount;
            positionConfigs[tokenId].isCToken0 = true;
        } else if (tick > tickUpper) {
            (uint256 amount0, uint256 amount1) = holder.decreaseLiquidityAndCollect(NFTHolder.DecreaseLiquidityAndCollectParams(params.tokenId, liquidity, 0, 0, 0, type(uint128).max, block.timestamp, address(this)));
            uint cAmount = tokenConfigs[token0].cToken.mint(amount1);
            positionConfigs[tokenId].cTokenAmount = cAmount;
            positionConfigs[tokenId].isCToken0 = true;
        }
    }

    // redeems ctokens and adds liquidity to position
    function unlend(uint256 tokenId) external {
        
    }

    function addToken(uint256 tokenId, address, bytes calldata data) override external  {
        positionConfigs[tokenId] = PositionConfig(0);
    }

    function withdrawToken(uint256 tokenId, address) override external {
        // recreate from CTokens if needed
        if (positionConfigs[tokenId].cTokenAmount > 0) {

        }
        delete positionConfigs[tokenId];
    }

    function checkOnCollect(uint256, address, uint, uint) override external pure returns (bool) {
        return true;
    }
    
    
}

error NotSupportedToken(address);
error NotWithdrawable(uint256);

