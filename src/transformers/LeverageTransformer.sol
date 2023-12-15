// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../Swapper.sol";

import "../interfaces/IV3Vault.sol";

/// @title LeverageTransformer
/// @notice Functionality to leverage / deleverage positions direcly in one tx
contract LeverageTransformer is Swapper {

    constructor(INonfungiblePositionManager _nonfungiblePositionManager, address _zeroxRouter, address _universalRouter) Swapper(_nonfungiblePositionManager, _zeroxRouter, _universalRouter) {
    }

    struct LeverageUpParams {

        // which token to leverage
        uint tokenId;

        // how much to borrow
        uint borrowAmount;

        // how much of borrowed lend token should be swapped to token0
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0; // encoded data from 0x api call (address,bytes) - allowanceTarget,data

        // how much of borrowed lend token should be swapped to token1
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1; // encoded data from 0x api call (address,bytes) - allowanceTarget,data

        // for adding liquidity slippage
        uint256 amountAddMin0;
        uint256 amountAddMin1;

        // recipient for leftover tokens
        address recipient;

        // for all uniswap deadlineable functions
        uint256 deadline;
    }

    // method called from transform() method in Vault
    function leverageUp(LeverageUpParams calldata params) external {

        uint amount = params.borrowAmount;

        address token = IV3Vault(msg.sender).asset();

        IV3Vault(msg.sender).borrow(params.tokenId, amount);

        (,,address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(params.tokenId);

        uint amount0 = token == token0 ? amount : 0;
        uint amount1 = token == token1 ? amount : 0;

        if (params.amountIn0 > 0) {
            (uint amountIn, uint amountOut) = _swap(IERC20(token), IERC20(token0), params.amountIn0, params.amountOut0Min, params.swapData0);
            if (token == token1) {
                amount1 -= amountIn;
            }
            amount -= amountIn;
            amount0 += amountOut;
        }
        if (params.amountIn1 > 0) {
            (uint amountIn, uint amountOut) = _swap(IERC20(token), IERC20(token1), params.amountIn1, params.amountOut1Min, params.swapData1);
            if (token == token0) {
                amount0 -= amountIn;
            }
            amount -= amountIn;
            amount1 += amountOut;
        }

        IERC20(token0).approve(address(nonfungiblePositionManager), amount0);
        IERC20(token1).approve(address(nonfungiblePositionManager), amount1);

        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseLiquidityParams = INonfungiblePositionManager.IncreaseLiquidityParams(params.tokenId, amount0, amount1, params.amountAddMin0, params.amountAddMin1, params.deadline);
        (, uint added0, uint added1) = nonfungiblePositionManager.increaseLiquidity(increaseLiquidityParams);

        // send leftover tokens
        if (amount0 > added0) {
            IERC20(token0).transfer(params.recipient, amount0 - added0);
        }
        if (amount1 > added1) {
            IERC20(token1).transfer(params.recipient, amount1 - added1);
        }
        if (token != token0 && token != token1 && amount > 0) {
            IERC20(token).transfer(params.recipient, amount);
        }
    }

    struct LeverageDownParams {

        // which token to leverage
        uint tokenId;

        // for removing - remove liquidity amount
        uint128 liquidity;
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;

        // collect fee amount (if type(uint128).max - ALL)
        uint128 feeAmount0;
        uint128 feeAmount1;

        // how much of token0 should be swapped to lend token
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0; // encoded data from 0x api call (address,bytes) - allowanceTarget,data

        // how much of token1 should be swapped to lend token
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1; // encoded data from 0x api call (address,bytes) - allowanceTarget,data

        // recipient for leftover tokens
        address recipient;

        // for all uniswap deadlineable functions
        uint256 deadline;
    }

    // method called from transform() method in Vault
    function leverageDown(LeverageDownParams calldata params) external {

        address token = IV3Vault(msg.sender).asset();
        (,,address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(params.tokenId);

        uint amount0;
        uint amount1;
        
        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseLiquidityParams = INonfungiblePositionManager.DecreaseLiquidityParams(params.tokenId, params.liquidity, params.amountRemoveMin0, params.amountRemoveMin1, params.deadline);
        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(decreaseLiquidityParams);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams(params.tokenId, address(this), params.feeAmount0 == type(uint128).max ? type(uint128).max : SafeCast.toUint128(amount0 + params.feeAmount0), params.feeAmount1 == type(uint128).max ? type(uint128).max : SafeCast.toUint128(amount1 + params.feeAmount1));
        (amount0, amount1) = nonfungiblePositionManager.collect(collectParams);
        
        uint amount = token == token0 ? amount0 : (token == token1 ? amount1 : 0);

        if (params.amountIn0 > 0 && token != token0) {
            (uint amountIn, uint amountOut) = _swap(IERC20(token0), IERC20(token), params.amountIn0, params.amountOut0Min, params.swapData0);
            amount0 -= amountIn;
            amount += amountOut;
        }
        if (params.amountIn1 > 0 && token != token1) {
            (uint amountIn, uint amountOut) = _swap(IERC20(token1), IERC20(token), params.amountIn1, params.amountOut1Min, params.swapData1);
            amount1 -= amountIn;
            amount += amountOut;
        }

        IERC20(token).approve(msg.sender, amount);
        IV3Vault(msg.sender).repay(params.tokenId, amount, false);

        // send leftover tokens
        if (amount0 > 0 && token != token0) {
            IERC20(token0).transfer(params.recipient, amount0);
        }
        if (amount1 > 0 && token != token1) {
            IERC20(token1).transfer(params.recipient, amount1);
        }
    }
}