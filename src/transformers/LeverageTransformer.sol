// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IVault.sol";

contract LeverageTransformer {

    error SwapFailed();
    error SlippageError();

    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    address immutable public factory;
    INonfungiblePositionManager immutable public nonfungiblePositionManager;
    
    /// @notice 0x Exchange Proxy
    address immutable public swapRouter;

    constructor(INonfungiblePositionManager _nonfungiblePositionManager, address _swapRouter) {
        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = _nonfungiblePositionManager.factory();
        swapRouter = _swapRouter;
    }

    struct LeverageUpParams {

        // which token to leverage
        uint tokenId;

        // how much to borrow
        uint borrowAmount;

        // for adding liquidity slippage
        uint256 amountAddMin0;
        uint256 amountAddMin1;

        // amountIn0 is used for swap and also as minAmount0 for decreased liquidity + collected fees
        uint256 amountIn0;
        // if lendtoken needs to be swapped to token0 - set values
        uint256 amountOut0Min;
        bytes swapData0; // encoded data from 0x api call (address,bytes) - allowanceTarget,data

        // amountIn1 is used for swap and also as minAmount1 for decreased liquidity + collected fees
        uint256 amountIn1;
        // if lendtoken needs to be swapped to token1 - set values
        uint256 amountOut1Min;
        bytes swapData1; // encoded data from 0x api call (address,bytes) - allowanceTarget,data

        // recipient for leftover tokens
        address recipient;

        // for all uniswap deadlineable functions
        uint256 deadline;
    }

    // method called from transform() method in Vault
    function leverageUp(LeverageUpParams calldata params) external {

        uint amount = params.borrowAmount;

        address token = IVault(msg.sender).lendToken();
        IVault(msg.sender).borrow(params.tokenId, amount);

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

        // collect fee amount (if uint256(128).max - ALL)
        uint128 feeAmount0;
        uint128 feeAmount1;

        // amountIn0 is used for swap and also as minAmount0 for decreased liquidity + collected fees
        uint256 amountIn0;
        // if token0 needs to be swapped to targetToken - set values
        uint256 amountOut0Min;
        bytes swapData0; // encoded data from 0x api call (address,bytes) - allowanceTarget,data

        // amountIn1 is used for swap and also as minAmount1 for decreased liquidity + collected fees
        uint256 amountIn1;
        // if token1 needs to be swapped to targetToken - set values
        uint256 amountOut1Min;
        bytes swapData1; // encoded data from 0x api call (address,bytes) - allowanceTarget,data

        // recipient for leftover tokens
        address recipient;

        // for all uniswap deadlineable functions
        uint256 deadline;
    }


    // method called from transform() method in Vault
    function leverageDown(LeverageDownParams calldata params) external {

        address token = IVault(msg.sender).lendToken();
        (,,address token0, address token1,,,,,,,,) = nonfungiblePositionManager.positions(params.tokenId);

        uint amount0;
        uint amount1;
        
        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseLiquidityParams = INonfungiblePositionManager.DecreaseLiquidityParams(params.tokenId, params.liquidity, params.amountRemoveMin0, params.amountRemoveMin1, params.deadline);
        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(decreaseLiquidityParams);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams(params.tokenId, address(this), params.feeAmount0 == type(uint128).max ? type(uint128).max : SafeCast.toUint128(amount0 + params.feeAmount0), params.feeAmount1 == type(uint128).max ? type(uint128).max : SafeCast.toUint128(amount1 + params.feeAmount1));
        (amount0, amount1) = nonfungiblePositionManager.collect(collectParams);
        
        uint amount = token == token0 ? amount0 : (token == token1 ? amount1 : 0);

        if (params.amountIn0 > 0) {
            (uint amountIn, uint amountOut) = _swap(IERC20(token0), IERC20(token), params.amountIn0, params.amountOut0Min, params.swapData0);
            amount0 -= amountIn;
            amount += amountOut;
        }
        if (params.amountIn1 > 0) {
            (uint amountIn, uint amountOut) = _swap(IERC20(token1), IERC20(token), params.amountIn1, params.amountOut1Min, params.swapData1);
            amount1 -= amountIn;
            amount += amountOut;
        }

        uint repayed = IVault(msg.sender).repay(params.tokenId, amount, false);
        amount -= repayed;

        // send leftover tokens
        if (amount0 > 0 && token != token0) {
            IERC20(token0).transfer(params.recipient, amount0);
        }
        if (amount1 > 0 && token != token1) {
            IERC20(token1).transfer(params.recipient, amount1);
        }
        if (amount > 0) {
            IERC20(token).transfer(params.recipient, amount);
        }    
    }

    function _swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 amountOutMin, bytes memory swapData) internal returns (uint256 amountInDelta, uint256 amountOutDelta) {
        if (amountIn != 0 && swapData.length != 0 && address(tokenOut) != address(0)) {
            uint256 balanceInBefore = tokenIn.balanceOf(address(this));
            uint256 balanceOutBefore = tokenOut.balanceOf(address(this));

            // get router specific swap data
            (address allowanceTarget, bytes memory data) = abi.decode(swapData, (address, bytes));

            // approve needed amount
            SafeERC20.safeApprove(tokenIn, allowanceTarget, amountIn);

            // execute swap
            (bool success,) = swapRouter.call(data);
            if (!success) {
                revert SwapFailed();
            }

            // reset approval
            SafeERC20.safeApprove(tokenIn, allowanceTarget, 0);

            uint256 balanceInAfter = tokenIn.balanceOf(address(this));
            uint256 balanceOutAfter = tokenOut.balanceOf(address(this));

            amountInDelta = balanceInBefore - balanceInAfter;
            amountOutDelta = balanceOutAfter - balanceOutBefore;

            // amountMin slippage check
            if (amountOutDelta < amountOutMin) {
                revert SlippageError();
            }

            // event for any swap with exact swapped value
            emit Swap(address(tokenIn), address(tokenOut), amountInDelta, amountOutDelta);
        }
    }
}